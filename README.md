# WindowsBridge

WindowsBridge is a Windows remote-operations MCP agent for ChatGPT using the official OpenAI Secure MCP Tunnel.

## Status

- **v0.1:** manual tunnel configuration; retained as the fallback path.
- **v0.2 RC:** hardened runtime + one-click bootstrap building blocks. Windows and bootstrap CI are green.
- **Production one-click is not promoted yet.** A live Windows end-to-end install must pass before the public README points users at a one-line installer.

The target UX is:

```powershell
irm 'https://windowsbridge.sonoryx.store/i/<one-time-token>' | iex
```

The one-time URL will carry only temporary bootstrap authority. Tunnel ID and runtime credentials are provisioned before the laptop install and are never committed to GitHub or typed into PowerShell. Windows may still show the normal UAC approval prompt; WindowsBridge does not bypass UAC.

## Architecture

`ChatGPT -> OpenAI Secure MCP Tunnel -> tunnel-client.exe -> WindowsBridge MCP -> Windows`

The Windows computer establishes the outbound connection; no inbound MCP/RDP/SSH port is required.

## v0.2 hardening already implemented

- `windowsbridge_v2.py` with a minimal allowlisted environment for child commands.
- Improved credential redaction and a built-in `bridge_self_check` tool.
- `requirements.lock` for reproducible v0.2 dependency installation.
- `bootstrap-client.ps1` for validated HTTPS bootstrap retrieval and normal UAC self-elevation.
- Experimental one-time bootstrap server under `bootstrap/`; intentionally not production-deployed yet.
- GitHub Actions on Windows and Linux: Python compile/import checks, PowerShell parser checks, bootstrap compile checks, and a committed-secret pattern guard.

## Current fallback install

Until the production one-click gate is complete, the supported fallback remains:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
irm https://raw.githubusercontent.com/ZTD38F/WindowsBridge/main/install.ps1 -OutFile install.ps1
.\install.ps1
```

This fallback currently asks for an OpenAI Tunnel ID and Runtime API key.

## Release gate for one-click

Before promotion, WindowsBridge must pass all of the following:

1. Pre-provision a Secure MCP Tunnel and least-privilege runtime key.
2. Align the production bootstrap endpoint and installer contract.
3. Make bootstrap credentials short-lived, single-use, atomic, no-store, and absent from access logs.
4. Bootstrap from an immutable commit/tag rather than moving `main`.
5. Verify the official tunnel-client release digest before installation.
6. Stage updates and retain the previous working release until tunnel health and startup health both pass.
7. Test fresh Windows 11 without Python, Windows with existing Python, reinstall/repair, uninstall/reinstall, reboot reconnect, network interruption, expired/used bootstrap links, revoked credentials, and ARM64.

## Main MCP tools

- System: `machine_info`, `bridge_self_check`, `installed_apps`, `scheduled_tasks`, `event_log`
- Files: metadata, listing, text/binary read-write, search, copy/move/delete, atomic edits
- Execution: `run_command`, `powershell`
- Persistent processes: start/read/input/kill/list sessions and terminate PID
- Services: list/status/start/stop/restart
- Registry: get/set/delete
- Network: interfaces, listening ports, TCP/HTTP probes

## Security model

The installed agent is intended for a privately owned Windows computer. Administrative installation gives the MCP agent machine-level capability, so tunnel credentials are protected separately from normal tool access. The MCP child removes OpenAI/tunnel credentials from its environment, v0.2 narrows the environment inherited by child commands, and file tools block WindowsBridge's own credential configuration.

## Repository

Current development line: **0.2 release candidate**. Do not describe it as production one-click until the release gate above is complete.
