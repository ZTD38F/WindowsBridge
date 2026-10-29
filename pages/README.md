# WindowsBridge Cloudflare Pages — Mode 2 (Proxy S / Text Plain)

This directory is the **GitHub source of truth** for https://windowsbridge.pages.dev/.

- Both `/` and `/install.ps1` return the raw pinned PowerShell installer as HTTP 200, `Content-Type: text/plain; charset=utf-8`.
- Every user agent (browser, Windows PowerShell, curl) gets **identical bytes**. The Pages hostname stays in place: no HTTP redirect and no Secure Install HTML interface.
- Immutable upstream: `https://raw.githubusercontent.com/ZTD38F/WindowsBridge/be3b7dc179c6410e787c0925fccfdc0ca7f35dc9/install.ps1`.
- SHA-256 of the pinned installer: `17adb84585c0310f4f8b372cb0ea117619d0b6ddb671e4551ced244d0a5c3c14`.
- The `_worker.js` checks upstream status and MIME, rejects oversize and empty responses, disables caching and supplies CSP/nosniff. Unsupported methods return 405; upstream errors return 502.
- `index.html` is only a minimal static safety fallback; normal traffic is always handled by `_worker.js`. Old HTML UI, JS, CSS and `_redirects` are **not deployed**.
- Instructions for Win+R → Ctrl+V → Enter belong to the separate CyberVoid project, not to this raw-script endpoint.
- An HTTP deployment does not prove the install script was run successfully on a Windows machine.

Test: `node --test pages/site.test.mjs`.
Build: `bash pages/build-site.sh /tmp/windowsbridge-mode2-build`.
Deploy the build output to the existing Cloudflare Pages project `windowsbridge` on production branch `main`, then compare browser and PowerShell HTTP responses and SHA-256 with `install.ps1`.
