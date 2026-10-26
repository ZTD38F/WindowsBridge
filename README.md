# WindowsBridge

WindowsBridge gives ChatGPT controlled access to an authorized Windows computer through the official OpenAI Secure MCP Tunnel.

## Installer download — pending verified Pages shortcut

A CyberVoid-style, readable Win+R → Ctrl+V → Enter launcher is being prepared through Cloudflare Pages. The short domain is **not deployed/verified**; meanwhile use the official installer file below, review it and run the saved local script using your organization's permitted PowerShell procedure.

```text
[Download the stable installer](https://raw.githubusercontent.com/ZTD38F/WindowsBridge/stable/install.ps1)
```

The installer file is public and auditable. This interim source link intentionally avoids hidden or encoded launch commands. It is not an automatic install.

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

WindowsBridge has a built-in generation-aware updater. The long-lived OpenAI
Secure MCP Tunnel points to an authenticated loopback supervisor instead of
owning the Python MCP runtime as a stdio child.

For an ordinary runtime update WindowsBridge stages a new immutable generation,
starts it on the inactive backend port, validates health and MCP tool-schema
compatibility, atomically switches the supervisor route, drains in-flight
requests assigned to the previous generation, observes the candidate, and then
commits it. If persistent process sessions are still owned by the current
generation, activation is deferred rather than breaking those handles.

`TRANSPORT_UPDATE` is separate: the verified tunnel binary is replaced only
when its pinned version changes, using the shortest controlled reconnect and
automatic binary/config rollback if readiness fails.

Useful commands:

```powershell
windowsbridgectl check
windowsbridgectl status
windowsbridgectl update-status
windowsbridgectl update-now
windowsbridgectl logs 200
windowsbridgectl auto-update-enable
windowsbridgectl auto-update-disable
```

The first upgrade from the legacy stdio topology performs one controlled
migration. Subsequent normal runtime updates do not intentionally restart the
tunnel transport.

## Architecture

```text
ChatGPT
  ↓
OpenAI Secure MCP Tunnel (long-lived)
  ↓
authenticated loopback supervisor/router :18766
  ├─ active WindowsBridge generation :18771
  └─ candidate WindowsBridge generation :18772
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

## Planned short installer address

The desired Cloudflare Pages URL is `windowsbridge.pages.dev`, following the CyberVoid user experience. **This is a proposed name, not an active or verified service.** Do not use the URL until account ownership, deployment, pinned source and HTTP behavior have been verified. The long-term Windows launch format is Win+R → Ctrl+V → Enter with a short readable command and visible console; no encoded commands.

## Update channels

- `stable`: normal installations and automatic updates.
- `main`: development only.

Development source (not for routine installation):

```text
[Development installer source](https://raw.githubusercontent.com/ZTD38F/WindowsBridge/main/install.ps1)
```

## Uninstall — source file (manual)

**Warning:** running this local file removes the WindowsBridge runtime and scheduled tasks. Review it before executing.

```text
[Uninstaller source — removes local runtime](https://raw.githubusercontent.com/ZTD38F/WindowsBridge/stable/uninstall.ps1)
```

Uninstall removes WindowsBridge, its runtime task, update task, and global control command. It intentionally does not delete the OpenAI tunnel object or Platform runtime API key.

## Status

Current line: **0.3.0 RC**.

The repository and Windows GitHub Actions are tested. A real fresh-machine Windows end-to-end installation is still required before calling 0.3.0 production-final.
