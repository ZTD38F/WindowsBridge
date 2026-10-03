# WindowsBridge

WindowsBridge is a Windows remote-operations MCP agent for ChatGPT using the official OpenAI Secure MCP Tunnel.

## GitHub-only installation

WindowsBridge no longer depends on any personal VPS or `*.sonoryx.store` bootstrap service.

The software supply chain is:

```text
GitHub raw install.ps1
        ↓
ZTD38F/WindowsBridge GitHub Release → WindowsBridge.exe
        ↓
openai/tunnel-client GitHub Release → tunnel-client.exe
        ↓
OpenAI Secure MCP Tunnel
        ↓
ChatGPT
```

Canonical install command:

```powershell
irm https://raw.githubusercontent.com/ZTD38F/WindowsBridge/main/install.ps1 | iex
```

The installer self-elevates through the normal Windows UAC prompt, downloads verified GitHub Release assets, installs the SYSTEM startup task, runs `tunnel-client doctor --explain`, and rolls back the executables if validation fails.

### First-time OpenAI credentials

The official tunnel runtime requires both a tunnel ID and a runtime API key. OpenAI documents these as mandatory: the tunnel ID comes from Tunnels management and the runtime key comes from Platform Runtime API keys with Tunnels Read + Use.

WindowsBridge therefore checks, in order:

1. parameters supplied to `install.ps1`;
2. `WINDOWSBRIDGE_TUNNEL_ID` and `WINDOWSBRIDGE_RUNTIME_API_KEY` environment variables;
3. an existing DPAPI-protected WindowsBridge installation;
4. on a genuinely fresh machine, a one-time secure prompt.

GitHub cannot safely publish a private OpenAI runtime key inside a public repository or Release asset. WindowsBridge deliberately does not hard-code or expose that credential.

After the first successful installation, reinstall/update is zero-input because the key is stored with Windows DPAPI LocalMachine.

## Binary releases

GitHub Actions builds a standalone `WindowsBridge.exe` with PyInstaller. The target Windows machine does **not** need Python, pip, winget, or a local source checkout.

Every push to `main` updates the GitHub prerelease tag `edge`. Version tags `v*` produce normal GitHub Releases.

The installer verifies GitHub's SHA-256 digest for:

- `WindowsBridge.exe` from `ZTD38F/WindowsBridge`;
- the official Windows `tunnel-client` archive from `openai/tunnel-client`.

## Architecture

`ChatGPT -> OpenAI Secure MCP Tunnel -> tunnel-client.exe -> WindowsBridge.exe -> Windows`

No inbound MCP, RDP, SSH, or custom WindowsBridge port is required.

## Main MCP tools

- System: `machine_info`, `bridge_self_check`, `installed_apps`, `scheduled_tasks`, `event_log`
- Files: metadata, listing, text/binary read-write, search, copy/move/delete, atomic edits
- Execution: `run_command`, `powershell`
- Persistent processes: start/read/input/kill/list sessions and terminate PID
- Services: list/status/start/stop/restart
- Registry: get/set/delete
- Network: interfaces, listening ports, TCP/HTTP probes

## Security model

The installed agent is intended for an authorized Windows computer and runs as SYSTEM, so it has machine-level capability.

Key protections:

- runtime API key is stored using Windows DPAPI LocalMachine;
- installation directory ACL is restricted to SYSTEM and local Administrators;
- the MCP child removes OpenAI/tunnel credential variables from its environment;
- v0.2 uses an allowlisted child-process environment;
- WindowsBridge configuration/credential paths are blocked from normal MCP file tools;
- modifying operations are audited;
- CI rejects common committed-secret patterns;
- CI rejects WindowsBridge installation dependencies on the former personal-server hostname.

## Development status

Current line: **0.2 RC**.

Before calling the first-install flow fully zero-input, OpenAI tunnel credentials must already exist outside the public GitHub repository. This is an authentication boundary, not an installer limitation.
