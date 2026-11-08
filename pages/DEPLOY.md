# WindowsBridge Pages — staged browser onboarding release

**Status: preview design only.** Keep current production `windowsbridge.pages.dev` untouched until explicitly approved and E2E verified.

## Existing baseline

- Production Pages project: `windowsbridge` on Cloudflare. Current observed GET / and GET /install.ps1: HTTP 200 `text/plain`.
- Existing dynamic Mode 2 script origin: `ZTD38F/WindowsBridge:main/install.ps1`.
- Prior production deployment (2026-10-29): `207c8473-7ec4-44f1-8bb1-25cf03ae17cf`.
- Earlier pinned rollback deployment: `ffd74b9f-e3d1-4716-bf02-1c4794949418`.
- In-place deployment is **not** authorized in this PR. This is a direct-upload project; merging GitHub commits alone cannot deploy it.

## Proposed preview acceptance gates

1. Build in a new empty directory. Assert that it contains only `_worker.js`, `index.html`, `style.css`, `app.js`.
2. Execute Node route-contract tests and automated Chrome desktop/mobile screenshots. Confirm no overflow, accessible focus, clipboard stable command, proper dark styling, and no external network requests by the landing page.
3. Deploy **to an isolated preview target only** after explicit authorization; do not overwrite the production project. Confirm Pages `env.ASSETS` binding works in advanced Worker mode.
4. Check browser Accept `text/html` GET / → 200 HTML, assets → 200, HEAD empty, POST → 405, CSP and no-store.
5. Check PowerShell/curl GET / and GET /install.ps1 → exact source bytes from the intended GitHub commit via fresh Atom SHA, unchanged headers and no redirect. The user-facing copied launcher must use **stable**, not main.
6. Verify native PowerShell onboarding / restricted key handling / tunnel startup / actual ChatGPT read-only MCP call on an authorized Windows test machine. Keep credentials out of logs and screenshots.
7. Record deployment ID, source commit SHA, HTML screenshot hashes, verification receipts, and existing production rollback target.
8. Only after separate sign-off, roll out production. If any contract fails, immediately return to the previous deployment; never claim E2E from CI alone.

## Risk controls

Browser detection relies on `Accept: text/html`; the explicit `/install.ps1` script endpoint always stays PowerShell. The browser UI fails with 503 if static assets are missing, rather than accidentally printing or executing a script. No unapproved Cloudflare settings or live Windows installations are modified.
