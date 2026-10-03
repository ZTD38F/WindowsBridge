# WindowsBridge

WindowsBridge is a Windows remote-operations MCP agent for ChatGPT using the official OpenAI Secure MCP Tunnel.

## One-line GitHub installation

WindowsBridge has **no dependency on a personal VPS or WindowsBridge web server**.

Paste one line into PowerShell:

```powershell
irm https://raw.githubusercontent.com/ZTD38F/WindowsBridge/main/install.ps1 | iex
```

The installer automatically:

1. requests normal Windows UAC elevation when required;
2. resolves `main` to an immutable GitHub commit SHA;
3. downloads `windowsbridge.py` and `requirements.lock` from that exact commit;
4. downloads `uv` from the official `astral-sh/uv` GitHub Release and verifies its GitHub SHA-256 digest;
5. creates an isolated Python 3.12 environment and installs pinned WindowsBridge dependencies;
6. downloads the official `openai/tunnel-client` Windows archive from GitHub Releases and verifies its GitHub SHA-256 digest;
7. runs `tunnel-client doctor --explain`;
8. stores the runtime credential with Windows DPAPI LocalMachine;
9. registers WindowsBridge as a SYSTEM startup task;
10. preserves the previous working source commit for rollback if an update fails.

No inbound MCP, RDP, SSH, or WindowsBridge-specific port is opened.

## First-time guided setup

On a clean Windows computer the installer walks the user through the OpenAI setup instead of showing unexplained prompts.

### Step 1 — Create the tunnel

The installer automatically opens:

`https://platform.openai.com/settings/organization/tunnels`

Create a tunnel with:

- **Name:** `WindowsBridge`
- **Workspace:** if OpenAI shows a workspace selector, choose the ChatGPT workspace where WindowsBridge will be used.

Then copy the resulting ID and paste it into the installer. A valid ID looks like:

`tunnel_0123456789abcdef0123456789abcdef`

The installer validates the ID before continuing.

### Step 2 — Create the runtime key

The installer automatically opens:

`https://platform.openai.com/settings/organization/api-keys`

Create:

- **Name:** `WindowsBridge Runtime`
- **Type/access:** `Restricted`
- **Tunnels → Read**
- **Tunnels → Use**

Do **not** use an Admin API key for the long-running WindowsBridge runtime.

Paste the new runtime key into the PowerShell prompt. Input is hidden. WindowsBridge stores it using Windows DPAPI LocalMachine after the tunnel passes validation.

### Step 3 — Add WindowsBridge to ChatGPT

After `tunnel-client doctor --explain` succeeds and the startup task is healthy, the installer automatically opens:

`https://chatgpt.com/#settings/Connectors`

Create/configure the connector as:

- **Name:** `WindowsBridge`
- **Connection:** `Tunnel`
- **Tunnel:** select the `WindowsBridge` tunnel or paste its `tunnel_...` ID.
- **Authentication:** `No authentication` (**NoAuth**)

`No authentication` is the authentication mode between ChatGPT and the MCP server. It does **not** mean the OpenAI Secure MCP Tunnel itself is unauthenticated; the tunnel runtime still uses the restricted Runtime API key.

## First installation: OpenAI credentials

The official Secure MCP Tunnel requires two values:

- `CONTROL_PLANE_TUNNEL_ID` — an existing OpenAI tunnel ID;
- `CONTROL_PLANE_API_KEY` — a runtime API key whose principal has Tunnels Read + Use.

WindowsBridge checks for these values from installer parameters, environment variables, or an existing DPAPI-protected installation. On a completely fresh machine, if they do not already exist, it asks for them once.

A public GitHub repository cannot securely contain a private OpenAI runtime API key, so WindowsBridge intentionally does not hard-code one. After the first successful setup, reinstall/update is zero-input because the credential is already protected locally with DPAPI.

## GitHub supply chain

```text
raw.githubusercontent.com/ZTD38F/WindowsBridge
              │
              ├─ install.ps1
              │
              └─ immutable source commit
                       │
                       ├─ windowsbridge.py
                       └─ requirements.lock

github.com/astral-sh/uv/releases
              └─ verified uv bootstrap

github.com/openai/tunnel-client/releases
              └─ verified tunnel-client

Windows → OpenAI Secure MCP Tunnel → ChatGPT
```

The repository also builds a standalone `WindowsBridge.exe` as a GitHub Actions artifact for validation and future packaging, but production installation does not depend on GitHub Release publishing permissions.

## Main MCP tools

- System: `machine_info`, `bridge_self_check`, `installed_apps`, `scheduled_tasks`, `event_log`
- Files: metadata, listing, text/binary read-write, search, copy/move/delete, atomic edits
- Execution: `run_command`, `powershell`
- Persistent processes: start/read/input/kill/list sessions and terminate PID
- Services: list/status/start/stop/restart
- Registry: get/set/delete
- Network: interfaces, listening ports, TCP/HTTP probes

## Security model

WindowsBridge runs as SYSTEM on an authorized Windows computer, so it deliberately has machine-level capability.

Controls include:

- Windows DPAPI LocalMachine for the runtime API key;
- SYSTEM/Administrators-only ACL on the installation directory;
- OpenAI/tunnel credentials removed from the MCP child environment;
- allowlisted environment inherited by arbitrary child processes;
- credential/config paths protected from normal MCP filesystem tools;
- mutation audit logging;
- immutable GitHub source commit per install;
- SHA-256 verification of GitHub Release bootstrap assets;
- staged install and rollback pointer;
- CI compilation and PowerShell parser checks;
- CI secret-pattern guard;
- CI guard rejecting personal-server dependencies.

## Update

Run the same one-line command again. Existing OpenAI tunnel credentials are reused automatically.

## Uninstall

```powershell
irm https://raw.githubusercontent.com/ZTD38F/WindowsBridge/main/uninstall.ps1 | iex
```

The local WindowsBridge installation is removed. The OpenAI tunnel object and Platform runtime API key are intentionally left untouched.

## Status

Current development line: **0.2 RC**.
