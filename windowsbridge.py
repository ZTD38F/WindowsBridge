from __future__ import annotations

import base64
import csv
import ctypes
import fnmatch
import hashlib
import io
import json
import os
import platform
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
import uuid
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import psutil
from mcp.server import MCPServer
from mcp.types import ToolAnnotations

if sys.platform != "win32":
    raise RuntimeError("WindowsBridge only runs on Windows")

import winreg

VERSION = "0.4.0"
mcp = MCPServer("WindowsBridge")


READ_ONLY_CLOSED = ToolAnnotations(
    read_only_hint=True,
    destructive_hint=False,
    idempotent_hint=True,
    open_world_hint=False,
)
READ_ONLY_OPEN = ToolAnnotations(
    read_only_hint=True,
    destructive_hint=False,
    idempotent_hint=True,
    open_world_hint=True,
)
WRITE_SAFE = ToolAnnotations(
    read_only_hint=False,
    destructive_hint=False,
    idempotent_hint=False,
    open_world_hint=False,
)
WRITE_DESTRUCTIVE = ToolAnnotations(
    read_only_hint=False,
    destructive_hint=True,
    idempotent_hint=False,
    open_world_hint=False,
)
EXECUTE_TOOL = ToolAnnotations(
    read_only_hint=False,
    destructive_hint=True,
    idempotent_hint=False,
    open_world_hint=True,
)

# The tunnel credential is needed by tunnel-client, not by the MCP child.
# Remove inherited secrets before any shell/process tool can see them.
for _secret_env in (
    "CONTROL_PLANE_API_KEY",
    "OPENAI_API_KEY",
    "OPENAI_ADMIN_KEY",
):
    os.environ.pop(_secret_env, None)

MAX_CAPTURE = max(4096, int(os.getenv("WINDOWSBRIDGE_MAX_CAPTURE_BYTES", "131072")))
MAX_HASH_BYTES = max(1024 * 1024, int(os.getenv("WINDOWSBRIDGE_MAX_HASH_BYTES", str(128 * 1024 * 1024))))
MAX_BINARY_BYTES = max(1024 * 1024, int(os.getenv("WINDOWSBRIDGE_MAX_BINARY_BYTES", str(10 * 1024 * 1024))))
EXEC_MAX_TIMEOUT = max(1, min(int(os.getenv("WINDOWSBRIDGE_EXEC_MAX_TIMEOUT", "900")), 3600))
SESSION_MAX_LINES = max(100, int(os.getenv("WINDOWSBRIDGE_SESSION_MAX_LINES", "5000")))
MAX_SESSIONS = max(1, min(int(os.getenv("WINDOWSBRIDGE_MAX_SESSIONS", "16")), 64))

PROGRAM_DATA = Path(os.getenv("PROGRAMDATA", r"C:\ProgramData"))
STATE_ROOT = PROGRAM_DATA / "WindowsBridge"
AUDIT_LOG = Path(os.getenv("WINDOWSBRIDGE_AUDIT_LOG", str(STATE_ROOT / "audit.jsonl")))
DEFAULT_PROTECTED = [
    STATE_ROOT / "config.json",
    STATE_ROOT / "runtime.env",
]

SECRET_PATTERNS = [
    re.compile(r"(?i)(authorization:\s*bearer\s+)[^\s]+"),
    re.compile(r"(?i)((?:password|token|api[_-]?key|secret)\s*[=:]\s*)[^\s]+"),
    re.compile(r"\b(?:sk|ghp|github_pat)_[A-Za-z0-9_-]{12,}\b"),
]


def _redact(value: str) -> str:
    out = value
    for pattern in SECRET_PATTERNS:
        if pattern.groups:
            out = pattern.sub(lambda m: (m.group(1) if m.lastindex else "") + "[REDACTED]", out)
        else:
            out = pattern.sub("[REDACTED]", out)
    return out


def _truncate(value: str, limit: int = MAX_CAPTURE) -> tuple[str, bool]:
    raw = value.encode("utf-8", errors="replace")
    if len(raw) <= limit:
        return _redact(value), False
    return _redact(raw[:limit].decode("utf-8", errors="replace") + "\n…[truncated]"), True


def _rotate_log(path: Path, max_bytes: int = 10 * 1024 * 1024, keep: int = 5) -> None:
    try:
        if not path.exists() or path.stat().st_size <= max_bytes:
            return
        for index in range(keep, 0, -1):
            src = path if index == 1 else Path(f"{path}.{index - 1}")
            dst = Path(f"{path}.{index}")
            if src.exists():
                if dst.exists():
                    dst.unlink()
                src.replace(dst)
    except OSError:
        pass


def _audit(tool: str, target: str, result: str = "ok", details: dict[str, Any] | None = None) -> None:
    def clean(obj: Any) -> Any:
        if isinstance(obj, str):
            return _redact(obj)
        if isinstance(obj, dict):
            return {str(k): clean(v) for k, v in obj.items()}
        if isinstance(obj, (list, tuple)):
            return [clean(v) for v in obj]
        return obj

    record = clean({
        "ts": int(time.time()),
        "tool": tool,
        "target": target,
        "result": result,
        "details": details or {},
    })
    try:
        AUDIT_LOG.parent.mkdir(parents=True, exist_ok=True)
        _rotate_log(AUDIT_LOG)
        with AUDIT_LOG.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")
    except OSError:
        pass


def _protected_paths() -> list[Path]:
    raw = os.getenv("WINDOWSBRIDGE_PROTECTED_PATHS", "")
    extra = [Path(x.strip()).resolve(strict=False) for x in raw.split(";") if x.strip()]
    return [p.resolve(strict=False) for p in DEFAULT_PROTECTED] + extra


def _allowed_roots() -> list[Path] | None:
    raw = os.getenv("WINDOWSBRIDGE_ALLOWED_ROOTS", "*").strip()
    if not raw or raw == "*":
        return None
    return [Path(x.strip()).resolve(strict=False) for x in raw.split(";") if x.strip()]


def _inside(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def _check_path(path: Path) -> Path:
    rp = path.resolve(strict=False)
    for protected in _protected_paths():
        if _inside(rp, protected) or rp == protected:
            raise PermissionError(f"Path is protected from WindowsBridge file tools: {rp}")
    roots = _allowed_roots()
    if roots is not None and not any(_inside(rp, root) or rp == root for root in roots):
        raise PermissionError(f"Path is outside WINDOWSBRIDGE_ALLOWED_ROOTS: {rp}")
    return rp


def _resolve_existing(path: str) -> Path:
    rp = Path(path).expanduser().resolve(strict=True)
    return _check_path(rp)


def _resolve_write(path: str) -> Path:
    raw = Path(path).expanduser()
    parent = raw.parent.resolve(strict=True)
    return _check_path((parent / raw.name).resolve(strict=False))


def _sha256(path: Path) -> str | None:
    if not path.is_file() or path.stat().st_size > MAX_HASH_BYTES:
        return None
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _atomic_write(path: Path, data: bytes, expected_sha256: str | None = None) -> dict[str, Any]:
    if path.exists() and expected_sha256 is not None:
        current = _sha256(path)
        if current != expected_sha256:
            raise RuntimeError(f"CONFLICT: expected sha256 {expected_sha256}, current {current}")
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp_name, path)
    finally:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass
    return {"path": str(path), "size": len(data), "sha256": _sha256(path)}


def _clean_env() -> dict[str, str]:
    # Commands get a minimal Windows environment instead of inheriting every
    # machine-level variable from the SYSTEM task.
    allowed = {
        "PATH", "PATHEXT", "SYSTEMROOT", "WINDIR", "COMSPEC",
        "TEMP", "TMP", "PROGRAMDATA", "PROGRAMFILES", "PROGRAMFILES(X86)",
        "COMMONPROGRAMFILES", "COMMONPROGRAMFILES(X86)",
        "PROCESSOR_ARCHITECTURE", "NUMBER_OF_PROCESSORS",
        "USERNAME", "USERDOMAIN", "COMPUTERNAME", "HOMEDRIVE", "HOMEPATH",
        "LANG", "TZ",
    }
    return {k: v for k, v in os.environ.items() if k.upper() in allowed}


def _run(argv: list[str], cwd: str | None = None, timeout: int = 120, stdin_text: str | None = None) -> dict[str, Any]:
    if not argv or len(argv) > 128:
        raise ValueError("argv must contain 1-128 arguments")
    timeout = max(1, min(int(timeout), EXEC_MAX_TIMEOUT))
    target = str(_resolve_existing(cwd)) if cwd else None
    started = time.monotonic()
    flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    try:
        proc = subprocess.run(
            argv,
            cwd=target,
            input=stdin_text,
            text=True,
            capture_output=True,
            env=_clean_env(),
            timeout=timeout,
            creationflags=flags,
            check=False,
        )
        stdout, st = _truncate(proc.stdout or "")
        stderr, et = _truncate(proc.stderr or "")
        return {
            "exit_code": proc.returncode,
            "timed_out": False,
            "duration_seconds": round(time.monotonic() - started, 3),
            "stdout": stdout,
            "stderr": stderr,
            "stdout_truncated": st,
            "stderr_truncated": et,
        }
    except subprocess.TimeoutExpired as exc:
        out = exc.stdout.decode(errors="replace") if isinstance(exc.stdout, bytes) else (exc.stdout or "")
        err = exc.stderr.decode(errors="replace") if isinstance(exc.stderr, bytes) else (exc.stderr or "")
        stdout, st = _truncate(out)
        stderr, et = _truncate(err)
        return {
            "exit_code": None,
            "timed_out": True,
            "duration_seconds": round(time.monotonic() - started, 3),
            "stdout": stdout,
            "stderr": stderr,
            "stdout_truncated": st,
            "stderr_truncated": et,
        }


def _powershell(script: str, timeout: int = 120, cwd: str | None = None) -> dict[str, Any]:
    return _run(
        ["powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", "-"],
        cwd=cwd,
        timeout=timeout,
        stdin_text=script,
    )


@mcp.tool(annotations=READ_ONLY_CLOSED)
def machine_info() -> dict[str, Any]:
    vm = psutil.virtual_memory()
    drives = []
    for part in psutil.disk_partitions(all=False):
        try:
            usage = psutil.disk_usage(part.mountpoint)
            drives.append({
                "device": part.device,
                "mountpoint": part.mountpoint,
                "fstype": part.fstype,
                "total": usage.total,
                "used": usage.used,
                "free": usage.free,
            })
        except (PermissionError, OSError):
            continue
    try:
        is_admin = bool(ctypes.windll.shell32.IsUserAnAdmin())
    except Exception:
        is_admin = None
    return {
        "windowsbridge_version": VERSION,
        "hostname": socket.gethostname(),
        "platform": platform.platform(),
        "release": platform.release(),
        "version": platform.version(),
        "architecture": platform.machine(),
        "python": platform.python_version(),
        "pid": os.getpid(),
        "identity": os.environ.get("USERNAME"),
        "is_admin": is_admin,
        "boot_time": int(psutil.boot_time()),
        "uptime_seconds": int(time.time() - psutil.boot_time()),
        "memory": {"total": vm.total, "available": vm.available, "used": vm.used},
        "drives": drives,
        "allowed_roots": "*" if _allowed_roots() is None else [str(p) for p in _allowed_roots() or []],
        "capabilities": {
            "filesystem": True,
            "binary_io": True,
            "exec": True,
            "powershell": True,
            "process_sessions": True,
            "services": True,
            "registry": True,
            "event_log": True,
            "scheduled_tasks": True,
            "network": True,
        },
    }


@mcp.tool(annotations=READ_ONLY_CLOSED)
def file_stat(path: str) -> dict[str, Any]:
    p = _resolve_existing(path)
    st = p.stat()
    return {
        "path": str(p),
        "type": "dir" if p.is_dir() else "file" if p.is_file() else "other",
        "size": st.st_size,
        "ctime": int(st.st_ctime),
        "mtime": int(st.st_mtime),
        "sha256": _sha256(p),
    }


@mcp.tool(annotations=READ_ONLY_CLOSED)
def list_files(path: str = ".", limit: int = 500, include_hidden: bool = True) -> dict[str, Any]:
    target = _resolve_existing(path)
    if not target.is_dir():
        raise NotADirectoryError(str(target))
    limit = max(1, min(int(limit), 5000))
    entries = []
    items = sorted(target.iterdir(), key=lambda p: p.name.lower())
    for item in items:
        if not include_hidden and item.name.startswith("."):
            continue
        try:
            st = item.stat()
            entries.append({
                "name": item.name,
                "path": str(item),
                "type": "dir" if item.is_dir() else "file" if item.is_file() else "other",
                "size": st.st_size,
                "mtime": int(st.st_mtime),
            })
        except OSError as exc:
            entries.append({"name": item.name, "path": str(item), "error": str(exc)})
        if len(entries) >= limit:
            break
    return {"path": str(target), "entries": entries, "truncated": len(entries) < len(items)}


@mcp.tool(annotations=READ_ONLY_CLOSED)
def read_text(path: str, max_bytes: int = 262144) -> dict[str, Any]:
    p = _resolve_existing(path)
    if not p.is_file():
        raise FileNotFoundError(str(p))
    cap = max(1, min(int(max_bytes), 4 * 1024 * 1024))
    with p.open("rb") as handle:
        data = handle.read(cap + 1)
    return {
        "path": str(p),
        "text": data[:cap].decode("utf-8", errors="replace"),
        "truncated": len(data) > cap,
        "size": p.stat().st_size,
        "sha256": _sha256(p),
    }


@mcp.tool(annotations=READ_ONLY_CLOSED)
def read_file(path: str, offset: int = 0, length: int = 1000, tail: bool = False) -> dict[str, Any]:
    p = _resolve_existing(path)
    if not p.is_file():
        raise FileNotFoundError(str(p))
    length = max(1, min(int(length), 10000))
    with p.open("r", encoding="utf-8", errors="replace") as handle:
        lines = handle.readlines()
    if tail:
        selected = lines[-length:]
        start = max(0, len(lines) - len(selected))
    else:
        start = max(0, int(offset))
        selected = lines[start:start + length]
    next_offset = start + len(selected) if start + len(selected) < len(lines) else None
    return {
        "path": str(p),
        "text": "".join(selected),
        "start_line": start,
        "returned_lines": len(selected),
        "next_offset": next_offset,
        "truncated": next_offset is not None,
        "size": p.stat().st_size,
        "sha256": _sha256(p),
    }


@mcp.tool(annotations=READ_ONLY_CLOSED)
def read_binary_base64(path: str, max_bytes: int = MAX_BINARY_BYTES) -> dict[str, Any]:
    p = _resolve_existing(path)
    if not p.is_file():
        raise FileNotFoundError(str(p))
    cap = max(1, min(int(max_bytes), MAX_BINARY_BYTES))
    with p.open("rb") as handle:
        data = handle.read(cap + 1)
    return {
        "path": str(p),
        "base64": base64.b64encode(data[:cap]).decode("ascii"),
        "size": p.stat().st_size,
        "truncated": len(data) > cap,
        "sha256": _sha256(p),
    }


@mcp.tool(annotations=WRITE_DESTRUCTIVE)
def write_text(path: str, content: str, expected_sha256: str | None = None) -> dict[str, Any]:
    p = _resolve_write(path)
    result = _atomic_write(p, content.encode("utf-8"), expected_sha256)
    _audit("write_text", str(p), details={"size": result["size"]})
    return result


@mcp.tool(annotations=WRITE_DESTRUCTIVE)
def write_binary_base64(path: str, base64_data: str, expected_sha256: str | None = None) -> dict[str, Any]:
    data = base64.b64decode(base64_data, validate=True)
    if len(data) > MAX_BINARY_BYTES:
        raise ValueError(f"binary payload exceeds {MAX_BINARY_BYTES} bytes")
    p = _resolve_write(path)
    result = _atomic_write(p, data, expected_sha256)
    _audit("write_binary_base64", str(p), details={"size": result["size"]})
    return result


@mcp.tool(annotations=WRITE_DESTRUCTIVE)
def edit_text(path: str, old_text: str, new_text: str, expected_replacements: int = 1, expected_sha256: str | None = None) -> dict[str, Any]:
    p = _resolve_existing(path)
    text = p.read_text(encoding="utf-8", errors="strict")
    count = text.count(old_text)
    if count != int(expected_replacements):
        raise RuntimeError(f"REPLACEMENT_COUNT_MISMATCH: expected {expected_replacements}, found {count}")
    result = _atomic_write(p, text.replace(old_text, new_text).encode("utf-8"), expected_sha256)
    result["replacements"] = count
    _audit("edit_text", str(p), details={"replacements": count})
    return result


@mcp.tool(annotations=WRITE_SAFE)
def make_directory(path: str) -> dict[str, Any]:
    p = _resolve_write(path)
    p.mkdir(parents=True, exist_ok=True)
    _audit("make_directory", str(p))
    return {"path": str(p), "created": True}


@mcp.tool(annotations=WRITE_DESTRUCTIVE)
def move_path(source: str, destination: str) -> dict[str, Any]:
    src = _resolve_existing(source)
    dst = _resolve_write(destination)
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(src), str(dst))
    _audit("move_path", str(dst), details={"source": str(src)})
    return {"source": str(src), "destination": str(dst)}


@mcp.tool(annotations=WRITE_SAFE)
def copy_path(source: str, destination: str, overwrite: bool = False) -> dict[str, Any]:
    src = _resolve_existing(source)
    dst = _resolve_write(destination)
    if dst.exists() and not overwrite:
        raise FileExistsError(str(dst))
    if src.is_dir():
        shutil.copytree(src, dst, dirs_exist_ok=overwrite)
    else:
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
    _audit("copy_path", str(dst), details={"source": str(src), "overwrite": overwrite})
    return {"source": str(src), "destination": str(dst)}


@mcp.tool(annotations=WRITE_DESTRUCTIVE)
def delete_path(path: str, recursive: bool = False) -> dict[str, Any]:
    p = _resolve_existing(path)
    if p.is_dir():
        if not recursive:
            p.rmdir()
        else:
            shutil.rmtree(p)
    else:
        p.unlink()
    _audit("delete_path", str(p), details={"recursive": recursive})
    return {"path": str(p), "deleted": True}


@mcp.tool(annotations=READ_ONLY_CLOSED)
def search_files(root: str, pattern: str = "*", max_results: int = 500, max_depth: int = 20) -> dict[str, Any]:
    base = _resolve_existing(root)
    if not base.is_dir():
        raise NotADirectoryError(str(base))
    max_results = max(1, min(int(max_results), 5000))
    max_depth = max(0, min(int(max_depth), 100))
    base_parts = len(base.parts)
    results: list[str] = []
    for current, dirs, files in os.walk(base):
        current_path = Path(current)
        depth = len(current_path.parts) - base_parts
        if depth >= max_depth:
            dirs[:] = []
        for name in dirs + files:
            if fnmatch.fnmatch(name, pattern):
                candidate = current_path / name
                try:
                    _check_path(candidate)
                except PermissionError:
                    continue
                results.append(str(candidate))
                if len(results) >= max_results:
                    return {"root": str(base), "results": results, "truncated": True}
    return {"root": str(base), "results": results, "truncated": False}


@mcp.tool(annotations=READ_ONLY_CLOSED)
def search_text(root: str, query: str, glob: str = "*", regex: bool = False, case_sensitive: bool = False, max_results: int = 500) -> dict[str, Any]:
    base = _resolve_existing(root)
    flags = 0 if case_sensitive else re.IGNORECASE
    rx = re.compile(query, flags) if regex else None
    needle = query if case_sensitive else query.lower()
    max_results = max(1, min(int(max_results), 5000))
    files = [base] if base.is_file() else [p for p in base.rglob(glob) if p.is_file()]
    results = []
    for path in files:
        try:
            rp = _resolve_existing(str(path))
            if rp.stat().st_size > 8 * 1024 * 1024:
                continue
            with rp.open("r", encoding="utf-8", errors="replace") as handle:
                for number, line in enumerate(handle, 1):
                    hay = line if case_sensitive else line.lower()
                    matched = bool(rx.search(line)) if rx else needle in hay
                    if matched:
                        results.append({"path": str(rp), "line": number, "text": line.rstrip()[:1000]})
                        if len(results) >= max_results:
                            return {"results": results, "truncated": True}
        except (OSError, PermissionError, UnicodeError):
            continue
    return {"results": results, "truncated": False}


@mcp.tool(annotations=EXECUTE_TOOL)
def run_command(argv: list[str], cwd: str | None = None, timeout_seconds: int = 120) -> dict[str, Any]:
    started = time.monotonic()
    result = _run(argv, cwd=cwd, timeout=timeout_seconds)
    result.update({"executable": argv[0], "argument_count": len(argv), "cwd": cwd})
    _audit("run_command", argv[0], result="timeout" if result["timed_out"] else ("ok" if result["exit_code"] == 0 else "error"), details={"argument_count": len(argv), "duration": round(time.monotonic() - started, 3)})
    return result


@mcp.tool(annotations=EXECUTE_TOOL)
def powershell(script: str, cwd: str | None = None, timeout_seconds: int = 120) -> dict[str, Any]:
    result = _powershell(script, timeout=timeout_seconds, cwd=cwd)
    _audit("powershell", "script", result="timeout" if result["timed_out"] else ("ok" if result["exit_code"] == 0 else "error"), details={"script_chars": len(script)})
    return result


@dataclass
class Session:
    id: str
    proc: subprocess.Popen[str]
    argv: list[str]
    cwd: str | None
    started: float = field(default_factory=time.time)
    stdout: deque[str] = field(default_factory=lambda: deque(maxlen=SESSION_MAX_LINES))
    stderr: deque[str] = field(default_factory=lambda: deque(maxlen=SESSION_MAX_LINES))
    out_cursor: int = 0
    err_cursor: int = 0
    lock: threading.Lock = field(default_factory=threading.Lock)


_SESSIONS: dict[str, Session] = {}
_SESSIONS_GUARD = threading.Lock()


def _pump(stream: Any, buf: deque[str]) -> None:
    try:
        for line in iter(stream.readline, ""):
            buf.append(_redact(line.rstrip("\n")))
    finally:
        try:
            stream.close()
        except Exception:
            pass


def _session_info(session: Session) -> dict[str, Any]:
    code = session.proc.poll()
    return {
        "session_id": session.id,
        "pid": session.proc.pid,
        "argv0": session.argv[0],
        "argument_count": len(session.argv),
        "cwd": session.cwd,
        "started_at": int(session.started),
        "running": code is None,
        "exit_code": code,
    }


@mcp.tool(annotations=WRITE_SAFE)
def start_process(argv: list[str], cwd: str | None = None) -> dict[str, Any]:
    with _SESSIONS_GUARD:
        live = [s for s in _SESSIONS.values() if s.proc.poll() is None]
        if len(live) >= MAX_SESSIONS:
            raise RuntimeError("SESSION_LIMIT")
    target = str(_resolve_existing(cwd)) if cwd else None
    flags = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0) | getattr(subprocess, "CREATE_NO_WINDOW", 0)
    proc = subprocess.Popen(
        argv,
        cwd=target,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
        env=_clean_env(),
        creationflags=flags,
    )
    sid = uuid.uuid4().hex
    session = Session(sid, proc, argv, target)
    with _SESSIONS_GUARD:
        _SESSIONS[sid] = session
    threading.Thread(target=_pump, args=(proc.stdout, session.stdout), daemon=True).start()
    threading.Thread(target=_pump, args=(proc.stderr, session.stderr), daemon=True).start()
    _audit("start_process", argv[0], details={"pid": proc.pid, "argument_count": len(argv)})
    return _session_info(session)


def _get_session(session_id: str) -> Session:
    try:
        return _SESSIONS[session_id]
    except KeyError:
        raise KeyError("PROCESS_SESSION_NOT_FOUND")


@mcp.tool(annotations=READ_ONLY_CLOSED)
def list_sessions() -> dict[str, Any]:
    with _SESSIONS_GUARD:
        return {"sessions": [_session_info(s) for s in _SESSIONS.values()]}


@mcp.tool(annotations=READ_ONLY_CLOSED)
def read_process_output(session_id: str, max_lines: int = 200) -> dict[str, Any]:
    session = _get_session(session_id)
    max_lines = max(1, min(int(max_lines), 2000))
    with session.lock:
        out = list(session.stdout)
        err = list(session.stderr)
        new_out = out[session.out_cursor:session.out_cursor + max_lines]
        new_err = err[session.err_cursor:session.err_cursor + max_lines]
        session.out_cursor += len(new_out)
        session.err_cursor += len(new_err)
    result = _session_info(session)
    result.update({
        "stdout": "\n".join(new_out),
        "stderr": "\n".join(new_err),
        "stdout_has_more": session.out_cursor < len(out),
        "stderr_has_more": session.err_cursor < len(err),
    })
    return result


@mcp.tool(annotations=EXECUTE_TOOL)
def send_process_input(session_id: str, data: str) -> dict[str, Any]:
    session = _get_session(session_id)
    if session.proc.poll() is not None:
        raise RuntimeError("PROCESS_EXITED")
    assert session.proc.stdin is not None
    session.proc.stdin.write(data)
    session.proc.stdin.flush()
    return _session_info(session)


@mcp.tool(annotations=WRITE_DESTRUCTIVE)
def kill_process(session_id: str, force: bool = False) -> dict[str, Any]:
    session = _get_session(session_id)
    if session.proc.poll() is None:
        if force:
            session.proc.kill()
        else:
            session.proc.terminate()
        try:
            session.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            session.proc.kill()
            session.proc.wait(timeout=3)
    _audit("kill_process", session_id, details={"force": force})
    return _session_info(session)


@mcp.tool(annotations=READ_ONLY_CLOSED)
def process_list(limit: int = 300) -> dict[str, Any]:
    limit = max(1, min(int(limit), 3000))
    items = []
    for proc in psutil.process_iter(["pid", "ppid", "name", "username", "memory_info", "cpu_percent", "create_time", "status"]):
        try:
            info = proc.info
            mem = info.get("memory_info")
            items.append({
                "pid": info.get("pid"),
                "ppid": info.get("ppid"),
                "name": info.get("name"),
                "username": info.get("username"),
                "rss": getattr(mem, "rss", None),
                "cpu_percent": info.get("cpu_percent"),
                "status": info.get("status"),
                "create_time": int(info.get("create_time") or 0),
            })
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue
    items.sort(key=lambda x: (-(x.get("rss") or 0), x.get("pid") or 0))
    return {"processes": items[:limit], "count": len(items), "truncated": len(items) > limit}


@mcp.tool(annotations=WRITE_DESTRUCTIVE)
def terminate_pid(pid: int, force: bool = False) -> dict[str, Any]:
    proc = psutil.Process(int(pid))
    if force:
        proc.kill()
    else:
        proc.terminate()
    try:
        code = proc.wait(timeout=5)
    except psutil.TimeoutExpired:
        proc.kill()
        code = proc.wait(timeout=3)
    _audit("terminate_pid", str(pid), details={"force": force})
    return {"pid": int(pid), "terminated": True, "exit_code": code}


@mcp.tool(annotations=READ_ONLY_CLOSED)
def service_list(limit: int = 1000) -> dict[str, Any]:
    services = []
    for svc in psutil.win_service_iter():
        try:
            data = svc.as_dict()
            services.append({
                "name": data.get("name"),
                "display_name": data.get("display_name"),
                "status": data.get("status"),
                "start_type": data.get("start_type"),
                "username": data.get("username"),
                "binpath": data.get("binpath"),
            })
        except (psutil.NoSuchProcess, OSError):
            continue
    services.sort(key=lambda x: (x.get("display_name") or x.get("name") or "").lower())
    limit = max(1, min(int(limit), 5000))
    return {"services": services[:limit], "count": len(services), "truncated": len(services) > limit}


@mcp.tool(annotations=READ_ONLY_CLOSED)
def service_status(name: str) -> dict[str, Any]:
    svc = psutil.win_service_get(name)
    data = svc.as_dict()
    return {
        "name": data.get("name"),
        "display_name": data.get("display_name"),
        "status": data.get("status"),
        "start_type": data.get("start_type"),
        "username": data.get("username"),
        "binpath": data.get("binpath"),
        "description": data.get("description"),
        "pid": data.get("pid"),
    }


def _service_action(name: str, action: str) -> dict[str, Any]:
    if not re.fullmatch(r"[A-Za-z0-9_.\-]{1,256}", name):
        raise ValueError("invalid service name")
    result = _run(["sc.exe", action, name], timeout=60)
    _audit(f"service_{action}", name, result="ok" if result["exit_code"] == 0 else "error")
    return {"service": name, "action": action, **result}


@mcp.tool(annotations=WRITE_SAFE)
def service_start(name: str) -> dict[str, Any]:
    return _service_action(name, "start")


@mcp.tool(annotations=WRITE_DESTRUCTIVE)
def service_stop(name: str) -> dict[str, Any]:
    return _service_action(name, "stop")


@mcp.tool(annotations=WRITE_DESTRUCTIVE)
def service_restart(name: str) -> dict[str, Any]:
    stop = _service_action(name, "stop")
    time.sleep(1)
    start = _service_action(name, "start")
    return {"service": name, "stop": stop, "start": start}


REGISTRY_ROOTS = {
    "HKLM": winreg.HKEY_LOCAL_MACHINE,
    "HKEY_LOCAL_MACHINE": winreg.HKEY_LOCAL_MACHINE,
    "HKCU": winreg.HKEY_CURRENT_USER,
    "HKEY_CURRENT_USER": winreg.HKEY_CURRENT_USER,
    "HKCR": winreg.HKEY_CLASSES_ROOT,
    "HKEY_CLASSES_ROOT": winreg.HKEY_CLASSES_ROOT,
    "HKU": winreg.HKEY_USERS,
    "HKEY_USERS": winreg.HKEY_USERS,
    "HKCC": winreg.HKEY_CURRENT_CONFIG,
    "HKEY_CURRENT_CONFIG": winreg.HKEY_CURRENT_CONFIG,
}


def _registry_root(root: str) -> Any:
    try:
        return REGISTRY_ROOTS[root.upper()]
    except KeyError:
        raise ValueError(f"unsupported registry root: {root}")


@mcp.tool(annotations=READ_ONLY_CLOSED)
def registry_get(root: str, path: str, value_name: str | None = None) -> dict[str, Any]:
    hive = _registry_root(root)
    with winreg.OpenKey(hive, path, 0, winreg.KEY_READ) as key:
        if value_name is not None:
            value, typ = winreg.QueryValueEx(key, value_name)
            return {"root": root, "path": path, "value_name": value_name, "value": value, "type": typ}
        values = []
        index = 0
        while True:
            try:
                name, value, typ = winreg.EnumValue(key, index)
                values.append({"name": name, "value": value, "type": typ})
                index += 1
            except OSError:
                break
        subkeys = []
        index = 0
        while True:
            try:
                subkeys.append(winreg.EnumKey(key, index))
                index += 1
            except OSError:
                break
        return {"root": root, "path": path, "values": values, "subkeys": subkeys}


@mcp.tool(annotations=WRITE_DESTRUCTIVE)
def registry_set(root: str, path: str, value_name: str, value: Any, value_type: str = "REG_SZ") -> dict[str, Any]:
    hive = _registry_root(root)
    types = {
        "REG_SZ": winreg.REG_SZ,
        "REG_EXPAND_SZ": winreg.REG_EXPAND_SZ,
        "REG_DWORD": winreg.REG_DWORD,
        "REG_QWORD": winreg.REG_QWORD,
        "REG_MULTI_SZ": winreg.REG_MULTI_SZ,
    }
    try:
        reg_type = types[value_type.upper()]
    except KeyError:
        raise ValueError(f"unsupported registry value type: {value_type}")
    if reg_type in (winreg.REG_DWORD, winreg.REG_QWORD):
        value = int(value)
    elif reg_type == winreg.REG_MULTI_SZ and not isinstance(value, list):
        raise ValueError("REG_MULTI_SZ requires a list of strings")
    else:
        value = str(value)
    with winreg.CreateKeyEx(hive, path, 0, winreg.KEY_SET_VALUE) as key:
        winreg.SetValueEx(key, value_name, 0, reg_type, value)
    _audit("registry_set", f"{root}\\{path}", details={"value_name": value_name, "value_type": value_type})
    return {"root": root, "path": path, "value_name": value_name, "updated": True}


@mcp.tool(annotations=WRITE_DESTRUCTIVE)
def registry_delete(root: str, path: str, value_name: str | None = None, delete_key: bool = False) -> dict[str, Any]:
    hive = _registry_root(root)
    if delete_key:
        winreg.DeleteKey(hive, path)
    else:
        if value_name is None:
            raise ValueError("value_name is required unless delete_key=true")
        with winreg.OpenKey(hive, path, 0, winreg.KEY_SET_VALUE) as key:
            winreg.DeleteValue(key, value_name)
    _audit("registry_delete", f"{root}\\{path}", details={"value_name": value_name, "delete_key": delete_key})
    return {"root": root, "path": path, "deleted": True}


@mcp.tool(annotations=READ_ONLY_CLOSED)
def event_log(log_name: str = "System", query: str = "*", max_events: int = 100) -> dict[str, Any]:
    max_events = max(1, min(int(max_events), 1000))
    result = _run(["wevtutil.exe", "qe", log_name, f"/q:{query}", f"/c:{max_events}", "/rd:true", "/f:text"], timeout=120)
    return {"log": log_name, "query": query, **result}


@mcp.tool(annotations=READ_ONLY_CLOSED)
def scheduled_tasks(query: str = "", limit: int = 500) -> dict[str, Any]:
    result = _run(["schtasks.exe", "/Query", "/FO", "CSV", "/V"], timeout=120)
    if result["exit_code"] != 0:
        return result
    reader = csv.DictReader(io.StringIO(result["stdout"]))
    q = query.lower().strip()
    rows = []
    for row in reader:
        if q and q not in json.dumps(row, ensure_ascii=False).lower():
            continue
        rows.append(row)
        if len(rows) >= max(1, min(int(limit), 5000)):
            break
    return {"tasks": rows, "count": len(rows), "source_truncated": result.get("stdout_truncated", False)}


@mcp.tool(annotations=READ_ONLY_CLOSED)
def installed_apps(limit: int = 1000) -> dict[str, Any]:
    locations = [
        (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"),
        (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"),
    ]
    apps: dict[tuple[str, str], dict[str, Any]] = {}
    for hive, key_path in locations:
        try:
            with winreg.OpenKey(hive, key_path, 0, winreg.KEY_READ) as root:
                for i in range(winreg.QueryInfoKey(root)[0]):
                    try:
                        subname = winreg.EnumKey(root, i)
                        with winreg.OpenKey(root, subname) as sub:
                            def qv(name: str) -> Any:
                                try:
                                    return winreg.QueryValueEx(sub, name)[0]
                                except OSError:
                                    return None
                            name = qv("DisplayName")
                            if not name:
                                continue
                            version = qv("DisplayVersion")
                            publisher = qv("Publisher")
                            install_location = qv("InstallLocation")
                            apps[(str(name), str(version or ""))] = {
                                "name": name,
                                "version": version,
                                "publisher": publisher,
                                "install_location": install_location,
                            }
                    except OSError:
                        continue
        except OSError:
            continue
    items = sorted(apps.values(), key=lambda x: str(x.get("name", "")).lower())
    limit = max(1, min(int(limit), 5000))
    return {"apps": items[:limit], "count": len(items), "truncated": len(items) > limit}


@mcp.tool(annotations=READ_ONLY_CLOSED)
def network_info() -> dict[str, Any]:
    addrs = psutil.net_if_addrs()
    stats = psutil.net_if_stats()
    data = {}
    for name, values in addrs.items():
        data[name] = {
            "is_up": stats.get(name).isup if name in stats else None,
            "speed_mbps": stats.get(name).speed if name in stats else None,
            "addresses": [
                {"family": str(v.family), "address": v.address, "netmask": v.netmask, "broadcast": v.broadcast}
                for v in values
            ],
        }
    return {"interfaces": data}


@mcp.tool(annotations=READ_ONLY_CLOSED)
def listening_ports(limit: int = 1000) -> dict[str, Any]:
    items = []
    for conn in psutil.net_connections(kind="inet"):
        if conn.status != psutil.CONN_LISTEN:
            continue
        laddr = conn.laddr
        items.append({
            "ip": laddr.ip if laddr else None,
            "port": laddr.port if laddr else None,
            "pid": conn.pid,
            "family": str(conn.family),
            "type": str(conn.type),
        })
    items.sort(key=lambda x: (x.get("port") or 0, x.get("pid") or 0))
    limit = max(1, min(int(limit), 5000))
    return {"listeners": items[:limit], "count": len(items), "truncated": len(items) > limit}


@mcp.tool(annotations=READ_ONLY_OPEN)
def tcp_probe(host: str, port: int, timeout_seconds: float = 5.0) -> dict[str, Any]:
    started = time.monotonic()
    try:
        with socket.create_connection((host, int(port)), timeout=max(0.1, min(float(timeout_seconds), 30.0))):
            return {"host": host, "port": int(port), "ok": True, "latency_ms": round((time.monotonic() - started) * 1000, 2)}
    except OSError as exc:
        return {"host": host, "port": int(port), "ok": False, "latency_ms": round((time.monotonic() - started) * 1000, 2), "error": str(exc)}


@mcp.tool(annotations=READ_ONLY_OPEN)
def http_probe(url: str, timeout_seconds: float = 10.0) -> dict[str, Any]:
    started = time.monotonic()
    req = urllib.request.Request(url, method="GET", headers={"User-Agent": f"WindowsBridge/{VERSION}"})
    try:
        with urllib.request.urlopen(req, timeout=max(0.1, min(float(timeout_seconds), 30.0))) as resp:
            return {
                "url": url,
                "ok": True,
                "status": resp.status,
                "latency_ms": round((time.monotonic() - started) * 1000, 2),
                "final_url": resp.geturl(),
                "content_type": resp.headers.get("Content-Type"),
            }
    except Exception as exc:
        return {"url": url, "ok": False, "latency_ms": round((time.monotonic() - started) * 1000, 2), "error": str(exc)}


@mcp.tool(annotations=READ_ONLY_CLOSED)
def bridge_self_check() -> dict[str, Any]:
    checks = {
        "platform_windows": sys.platform == "win32",
        "state_root_exists": STATE_ROOT.exists(),
        "python": platform.python_version(),
        "is_admin": bool(ctypes.windll.shell32.IsUserAnAdmin()),
        "powershell_available": shutil.which("powershell.exe") is not None,
        "service_control_available": shutil.which("sc.exe") is not None,
        "event_log_available": shutil.which("wevtutil.exe") is not None,
        "task_scheduler_available": shutil.which("schtasks.exe") is not None,
    }
    return {"ok": all(v is True or isinstance(v, str) for v in checks.values()), "checks": checks, "version": VERSION}


if __name__ == "__main__":
    mcp.run()
