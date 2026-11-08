# WindowsBridge — Pages setup UX (preview)

The published Pages site currently responds with PowerShell source for browser and CLI requests. This **preview branch only** introduces a browser-specific UI, preserving the stable CLI contract. Production is unchanged.

## Route contract

| Request | Preview response |
|---|---|
| Browser `GET /` with `Accept: text/html` | Russian WindowsBridge setup landing (`text/html`) |
| `GET /setup`, `GET /setup/`, `GET /index.html` | Same static landing |
| `GET /style.css`, `GET /app.js` | Same-origin local assets with strict CSP |
| CLI `GET /` (no HTML Accept) | Fresh, byte-identical PowerShell source from the configured `REDIRECT_URL` |
| Any `GET /install.ps1` | Fresh, byte-identical PowerShell source, regardless of Accept |
| `HEAD` supported | Matching MIME, zero body |
| `POST` | HTTP 405 |
| Browser UI but missing `ASSETS` binding | HTTP 503, no fallback to raw script |

This preview's **intended** script origin is `https://raw.githubusercontent.com/ZTD38F/WindowsBridge/stable/install.ps1`, matching the UI **Copy command** and the installer's default channel. Existing production still uses `main` and is unchanged. A preview deployment MUST explicitly configure `REDIRECT_URL` to the stable URL; do not use the production binding unchanged. The display never asks for an API key or tunnel identifier; these remain inside the native PowerShell installer.

The existing Worker continues to validate upstream HTTPS targets, follow at most two safe redirects, prefer GitHub Atom commit pinning and SHA-identified source content, and return no-store / no-sniff responses. New static assets are explicitly allowlisted; the browser UI uses a strict same-origin CSP, no analytics, no trackers and no network calls. The generated core from `ZTD38F/Cloudflare-Pages-Router` remains intact underneath the small preview-only dispatch branch; avoid overwriting the local hook with a generator refresh until integrated upstream.

## Verification and release

Run `node --test pages/site.test.mjs` and `bash pages/build-site.sh <new-output-directory>`. The build includes exactly four assets: `_worker.js`, `index.html`, `style.css`, `app.js`.

A **real deployment** must be separately approved. Before release, create a Pages preview deployment without taking over production, verify an actual browser screenshot and clipboard flow, test CLI `GET /`, `GET /install.ps1`, HEAD/POST, Source SHA/HTTP headers, Cloudflare asset availability, and test one fresh Windows → OpenAI Tunnel → ChatGPT read-only MCP call. Keep the previous production deployment and a rollback manifest.

Only CI simulation is possible from this branch alone. No screenshot or local HTTP test demonstrates that the production URL was changed.
