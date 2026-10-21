# Windows 11 Upgrade Manager

Beautiful, interactive PowerShell 5.1 UI for upgrading Windows 11 **without wiping apps or files**. Built for x64 Windows 11 PCs; no third-party Windows images, registry bypasses or external PowerShell modules.

## One-liner (Win + R → Ctrl + V → Enter)

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/ZTD38F/WindowsBridge/main/tools/windows11-upgrade/bootstrap.ps1 | iex"
```

**Security:** The bootstrap is delivered over HTTPS from the linked GitHub repository. It fetches the full script from the GitHub Contents API, validates Git blob SHA-1, saves a local `.ps1` file, and runs it without `Invoke-Expression`. The first-hop bootstrap is still fetched dynamically and should only be run if you trust the repository. For higher assurance, review the source and launch the downloaded local scripts. Enterprise application controls still apply.

## What it can do

- Show version/build/edition, free disk space, admin/restart status, and BitLocker warning.
- Discover applicable feature updates Windows Update *actually offers to this device*, rather than inventing download links.
- Automatically prefer the newest **stable** offered upgrade; avoid Insider-only builds.
- Choose a different offered feature upgrade (if available) or an official user-provided Windows 11 ISO.
- Download/install via Windows Update Agent (WUA) only after explicit approval.
- ISO: verify Microsoft signature on `setup.exe`, run Microsoft Setup **compatibility scan first**, proceed only on scan success, run `/auto upgrade` to preserve apps and data.
- Keep reboot under user control, with opt-in auto-reboot after separate confirmation.
- Write diagnostics to `%LOCALAPPDATA%\Windows11UpgradeManager\Logs`.

## Current releases (21 October 2026)

- Microsoft latest general availability: **26H2**; this is a quick enablement-package update from **24H2 or 25H2** (KB5121794) **if prerequisites and applicability are met**.
- 25H2 remains an optional target **only if Windows Update offers it or you have a compatible ISO**. The default Microsoft ISO download page currently distributes 26H2.
- **Prerequisite** for 26H2 enablement: September 22, 2026 cumulative update (KB5124010) or newer. The updater **does not bypass safeguard holds**.

## Modes

1. Fastest offered Windows Update feature upgrade.
2. Choose an offered version.
3. Official ISO / mounted media upgrade (compatible image required).
4. Reboot, Dynamic Update, and quiet ISO installation settings.
5. Diagnostics and official Microsoft release info.

Run locally after saving:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Win11Upgrade.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Win11Upgrade.ps1 -DiagnosticOnly
```

## Important safeguards and known limitations

- **Back up important data first**, keep the device powered, and retain the BitLocker recovery key. Setup may fail or roll back.
- `24H2 → 26H2` through WUA is typically small/quick. ISO updates may download multiple GB and take much longer.
- A feature upgrade might not be offered yet due to phased rollout, policies/WSUS, unmet prerequisites, or a compatibility hold. **This tool won't install an unoffered Windows Update feature upgrade.**
- The ISO path is user-provided, not silently downloaded; language, edition and architecture must be compatible for apps/files retention.
- The ISO route uses `/noreboot`, which only suppresses the first reboot. Microsoft Setup can still restart later once you manually continue the installation.
- The tool does not guarantee 100% preservation of programs/data or successful installation; Microsoft Setup makes the final compatibility decision.
- Only Windows 11 stable builds are targeted; Windows Insider and cross-architecture installations are not supported.
- PowerShell Constrained Language Mode, WDAC, AppLocker and enterprise restrictions may block script operations. No attempts are made to bypass them.
- Currently no live end-to-end upgrade has been run; tests exercise parser/classifier/safety paths, not the real installation process.

### References

- [Windows 11 downloads](https://www.microsoft.com/software-download/windows11)
- [Windows 11 26H2 release health](https://learn.microsoft.com/windows/release-health/status-windows-11-26h2)
- [KB5121794 enablement package](https://support.microsoft.com/en-us/servicing/os/windows-11/2026/09/kb5121794-feature-update-to-windows-11-version-26h2)
- [Windows Setup CLI options](https://learn.microsoft.com/windows-hardware/manufacture/desktop/windows-setup-command-line-options?view=windows-11)