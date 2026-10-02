# WindowsBridge

WindowsBridge is a Windows remote-operations MCP agent for ChatGPT, modeled after ServerBridge and connected through OpenAI Secure MCP Tunnel.

## Architecture

`ChatGPT -> OpenAI Secure MCP Tunnel -> tunnel-client.exe -> WindowsBridge MCP -> Windows`

No inbound firewall port is required. The Windows machine initiates outbound HTTPS to OpenAI.

## Access model

The installer registers WindowsBridge as a Scheduled Task running as `SYSTEM` with highest privileges. That intentionally gives the MCP agent machine-level administrative access. The tunnel runtime API key is stored with Windows DPAPI (`LocalMachine`) and the installation directory is ACL-restricted to SYSTEM and local Administrators.

The MCP child deletes inherited OpenAI/tunnel API-key environment variables before registering any command tools. Typed file tools additionally block WindowsBridge's own credential config.

## Main tools

- System: `machine_info`, `installed_apps`, `scheduled_tasks`, `event_log`
- Files: file metadata, listing, text/binary read-write, search, copy/move/delete, atomic writes/edits
- Execution: `run_command`, `powershell`
- Persistent processes: start/read/input/kill/list sessions and terminate PID
- Services: list/status/start/stop/restart
- Registry: get/set/delete
- Network: interfaces, listening ports, TCP/HTTP probes

## Install

Open **PowerShell as Administrator**:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
irm https://raw.githubusercontent.com/ZTD38F/WindowsBridge/main/install.ps1 -OutFile install.ps1
.\install.ps1
```

The installer asks for an OpenAI Tunnel ID and Runtime API key, downloads the official Windows `tunnel-client`, creates a dedicated Python virtual environment, validates the tunnel with `doctor`, and starts WindowsBridge at boot.

After installation open ChatGPT -> Settings -> Connectors, select the tunnel, and rescan MCP tools.

## Logs

Tunnel log:

`C:\ProgramData\WindowsBridge\logs\tunnel.log`

Mutation audit:

`C:\ProgramData\WindowsBridge\audit.jsonl`

## Uninstall

```powershell
irm https://raw.githubusercontent.com/ZTD38F/WindowsBridge/main/uninstall.ps1 -OutFile uninstall.ps1
.\uninstall.ps1
```

The local agent is removed. The OpenAI tunnel object is intentionally left intact so it can be reused or deleted separately.

## Version

Current development release: **0.1.0**.
