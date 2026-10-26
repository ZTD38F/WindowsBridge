# WindowsBridge

WindowsBridge gives ChatGPT controlled access to an authorized Windows computer through the official OpenAI Secure MCP Tunnel.

## Install (Win + R → Ctrl + V → Enter)

1. Press **Win + R** to open Windows Run.
2. Press **Ctrl + V** to paste the entire command below.
3. Press **Enter**. The installer opens PowerShell and requests UAC only when needed.

```text
powershell.exe -NoExit -NoProfile -ExecutionPolicy Bypass -EncodedCommand JABFAHIAcgBvAHIAQQBjAHQAaQBvAG4AUAByAGUAZgBlAHIAZQBuAGMAZQA9ACcAUwB0AG8AcAAnADsAJABwAD0ASgBvAGkAbgAtAFAAYQB0AGgAIAAkAGUAbgB2ADoAVABFAE0AUAAgACcAVwBpAG4AZABvAHcAcwBCAHIAaQBkAGcAZQAtAGkAbgBzAHQAYQBsAGwALgBwAHMAMQAnADsASQBuAHYAbwBrAGUALQBXAGUAYgBSAGUAcQB1AGUAcwB0ACAALQBVAHMAZQBCAGEAcwBpAGMAUABhAHIAcwBpAG4AZwAgAC0AVQByAGkAIAAnAGgAdAB0AHAAcwA6AC8ALwByAGEAdwAuAGcAaQB0AGgAdQBiAHUAcwBlAHIAYwBvAG4AdABlAG4AdAAuAGMAbwBtAC8AWgBUAEQAMwA4AEYALwBXAGkAbgBkAG8AdwBzAEIAcgBpAGQAZwBlAC8AcwB0AGEAYgBsAGUALwBpAG4AcwB0AGEAbABsAC4AcABzADEAJwAgAC0ATwB1AHQARgBpAGwAZQAgACQAcAA7ACYAIAAkAHAA
```

The command downloads the stable installer to a local .ps1 file and runs it; it does **not** pipe remote text into `Invoke-Expression`. `-EncodedCommand` uses UTF-16LE only for robust Win+R quoting, **not** for security or integrity verification. Review the linked installer source before running untrusted code. Restricted Windows policies still apply.

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

## Update channels

- `stable`: normal installations and automatic updates.
- `main`: development only.

To test main explicitly (development only): **Win + R → Ctrl + V → Enter**.

```text
powershell.exe -NoExit -NoProfile -ExecutionPolicy Bypass -EncodedCommand JABFAHIAcgBvAHIAQQBjAHQAaQBvAG4AUAByAGUAZgBlAHIAZQBuAGMAZQA9ACcAUwB0AG8AcAAnADsAJABwAD0ASgBvAGkAbgAtAFAAYQB0AGgAIAAkAGUAbgB2ADoAVABFAE0AUAAgACcAVwBpAG4AZABvAHcAcwBCAHIAaQBkAGcAZQAtAG0AYQBpAG4ALQBpAG4AcwB0AGEAbABsAC4AcABzADEAJwA7AEkAbgB2AG8AawBlAC0AVwBlAGIAUgBlAHEAdQBlAHMAdAAgAC0AVQBzAGUAQgBhAHMAaQBjAFAAYQByAHMAaQBuAGcAIAAtAFUAcgBpACAAJwBoAHQAdABwAHMAOgAvAC8AcgBhAHcALgBnAGkAdABoAHUAYgB1AHMAZQByAGMAbwBuAHQAZQBuAHQALgBjAG8AbQAvAFoAVABEADMAOABGAC8AVwBpAG4AZABvAHcAcwBCAHIAaQBkAGcAZQAvAG0AYQBpAG4ALwBpAG4AcwB0AGEAbABsAC4AcABzADEAJwAgAC0ATwB1AHQARgBpAGwAZQAgACQAcAA7ACYAIAAkAHAAIAAtAFMAbwB1AHIAYwBlAFIAZQBmACAAbQBhAGkAbgA=
```

## Uninstall (Win + R → Ctrl + V → Enter)

**Warning:** this removes the local WindowsBridge runtime and its scheduled tasks. Only run it if you intend to uninstall. Press **Win + R**, then **Ctrl + V** to paste the full command, then **Enter**.

```text
powershell.exe -NoExit -NoProfile -ExecutionPolicy Bypass -EncodedCommand JABFAHIAcgBvAHIAQQBjAHQAaQBvAG4AUAByAGUAZgBlAHIAZQBuAGMAZQA9ACcAUwB0AG8AcAAnADsAJABwAD0ASgBvAGkAbgAtAFAAYQB0AGgAIAAkAGUAbgB2ADoAVABFAE0AUAAgACcAVwBpAG4AZABvAHcAcwBCAHIAaQBkAGcAZQAtAHUAbgBpAG4AcwB0AGEAbABsAC4AcABzADEAJwA7AEkAbgB2AG8AawBlAC0AVwBlAGIAUgBlAHEAdQBlAHMAdAAgAC0AVQBzAGUAQgBhAHMAaQBjAFAAYQByAHMAaQBuAGcAIAAtAFUAcgBpACAAJwBoAHQAdABwAHMAOgAvAC8AcgBhAHcALgBnAGkAdABoAHUAYgB1AHMAZQByAGMAbwBuAHQAZQBuAHQALgBjAG8AbQAvAFoAVABEADMAOABGAC8AVwBpAG4AZABvAHcAcwBCAHIAaQBkAGcAZQAvAHMAdABhAGIAbABlAC8AdQBuAGkAbgBzAHQAYQBsAGwALgBwAHMAMQAnACAALQBPAHUAdABGAGkAbABlACAAJABwADsAJgAgACQAcAA=
```

Uninstall removes WindowsBridge, its runtime task, update task, and global control command. It intentionally does not delete the OpenAI tunnel object or Platform runtime API key.

## Status

Current line: **0.3.0 RC**.

The repository and Windows GitHub Actions are tested. A real fresh-machine Windows end-to-end installation is still required before calling 0.3.0 production-final.
