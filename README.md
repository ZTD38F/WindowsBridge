# WindowsBridge

WindowsBridge gives ChatGPT controlled access to an authorized Windows computer through the official OpenAI Secure MCP Tunnel.

## Install

Stable one-line install:

```powershell
irm https://raw.githubusercontent.com/ZTD38F/WindowsBridge/stable/install.ps1 | iex
```

The installer requests normal UAC elevation and then guides a first-time user through the only manual OpenAI steps:

Before UAC elevation, the bootstrap resolves the selected GitHub channel to an immutable commit SHA and re-downloads the elevated installer from that exact commit.

1. **Tunnel**
   - opens `https://platform.openai.com/settings/organization/tunnels`
   - recommended name: `WindowsBridge - <COMPUTERNAME>`
   - paste the resulting `tunnel_...` ID back into PowerShell
2. **Runtime API key**
   - opens `https://platform.openai.com/settings/organization/api-keys`
   - recommended name: `WindowsBridge Runtime - <COMPUTERNAME>`
   - Restricted key with only **Tunnels → Read + Use**
   - paste it into the hidden PowerShell prompt
3. **ChatGPT connector**
   - after the local tunnel is actually ready, opens `https://chatgpt.com/#settings/Connectors`
   - Name: `WindowsBridge - <COMPUTERNAME>`
   - Connection: `Tunnel`
   - Authentication: `No authentication` (NoAuth)

NoAuth is the MCP-server authentication mode. The Secure MCP Tunnel itself remains authenticated by the restricted runtime API key.

## What installation does automatically

- resolves the stable channel to an immutable Git commit;
- stages the complete WindowsBridge release before activation;
- downloads `uv` from official GitHub Releases and verifies SHA-256;
- keeps the managed Python runtime and cache under `C:\ProgramData\WindowsBridge`;
- installs pinned Python dependencies;
- downloads the official OpenAI `tunnel-client` and verifies its GitHub SHA-256 digest;
- stores each release's tunnel-client alongside that release so rollback is complete;
- protects the runtime key with Windows DPAPI LocalMachine;
- applies ACLs by Windows SIDs, not localized account names;
- creates the SYSTEM startup task;
- prevents duplicate tunnel runtimes with a global mutex;
- waits for `/readyz`, not merely process startup or `doctor`;
- rotates tunnel and audit logs;
- keeps recent releases for rollback;
- installs `windowsbridgectl`;
- enables safe daily automatic updates by default.

No inbound MCP, RDP, SSH, or WindowsBridge-specific public port is opened.

## Automatic updates

WindowsBridge follows the **stable** GitHub branch, never unreleased `main` by default.

A SYSTEM Scheduled Task checks once per day. An update is applied only through the same staged installer and must pass tunnel readiness; otherwise the previous release pointer is restored.

Update progress is stored atomically in `%ProgramData%\WindowsBridge\update-state.json` with non-secret current, candidate, and previous generation IDs. `update-status` reports the last durable state and rollback reason after the shell or browser has closed.

The current installer-based updater still performs a controlled tunnel restart and reports `LEGACY_RESTARTING` plus `transport_restart_required: true`. It is not presented as seamless; issue #2 tracks the long-lived supervisor/router needed for ordinary runtime updates without a transport restart.

Useful commands:

```powershell
windowsbridgectl check
windowsbridgectl status
windowsbridgectl doctor
windowsbridgectl logs 200
windowsbridgectl restart
windowsbridgectl update-status
windowsbridgectl update-now
windowsbridgectl repair
windowsbridgectl ui
windowsbridgectl auto-update-enable
windowsbridgectl auto-update-disable
```

To opt out when installing:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/ZTD38F/WindowsBridge/stable/install.ps1))) -DisableAutoUpdate
```

## Architecture

```text
ChatGPT
  ↓
OpenAI Secure MCP Tunnel
  ↓
tunnel-client
  ↓
WindowsBridge MCP
  ↓
Windows
```

Current core exposes 40 typed MCP tools for system information, files, execution, persistent processes, services, registry, Event Log, scheduled tasks, installed applications, and networking.

Every tool has MCP safety annotations describing read-only, destructive, idempotent, and open-world behavior. Arbitrary `run_command` and `powershell` remain explicit full-control escape hatches and run with the bridge's OS privileges.

## Local health and control

The tunnel health/admin listener is loopback-only:

`http://127.0.0.1:18765`

WindowsBridge uses:

- `/healthz` for liveness;
- `/readyz` for the installation/update success gate;
- `/ui` for local tunnel diagnostics.

Use `windowsbridgectl ui` to open the UI.

## Security model

WindowsBridge currently runs its core runtime as SYSTEM because the intended use case is full administration of an authorized private Windows machine.

Key controls include:

- DPAPI LocalMachine protection for the OpenAI runtime key;
- ACLs restricted using SYSTEM and BUILTIN\Administrators SIDs;
- OpenAI/tunnel secrets removed from MCP child environments;
- allowlisted environment inherited by arbitrary child processes;
- protected WindowsBridge credential/config paths;
- mutation audit logging with rotation;
- verified GitHub release assets;
- immutable source commit per activated version;
- transactional release directories and rollback;
- one active local tunnel runtime enforced by mutex;
- CI PowerShell parsing, Python compilation, secret guards, onboarding-contract checks, tool-annotation checks, and Windows artifact builds.

## Update channels

- `stable`: normal installations and automatic updates.
- `main`: development only.

To test main explicitly:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/ZTD38F/WindowsBridge/main/install.ps1))) -SourceRef main
```

## Uninstall

```powershell
irm https://raw.githubusercontent.com/ZTD38F/WindowsBridge/stable/uninstall.ps1 | iex
```

Uninstall removes WindowsBridge, its runtime task, update task, and global control command. It intentionally does not delete the OpenAI tunnel object or Platform runtime API key.

## Status

Current line: **0.3.0 RC**.

The repository and Windows GitHub Actions are tested. A real fresh-machine Windows end-to-end installation is still required before calling 0.3.0 production-final.
