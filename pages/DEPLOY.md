# WindowsBridge Pages rollout and rollback

Production: `https://windowsbridge.pages.dev/` (Cloudflare Pages project `windowsbridge`, branch `main`).
- Verified **dynamic Mode 2** deployment, 2026-10-29: `207c8473-7ec4-44f1-8bb1-25cf03ae17cf`.
- Prior **pinned script** deployment for rollback: `ffd74b9f-e3d1-4716-bf02-1c4794949418`.
- GitHub source: `ZTD38F/WindowsBridge:main/install.ps1`. The Worker reads GitHub Atom for the current SHA and then raw content by immutable SHA (fresh query parameter on every network request).

1. `node --test pages/site.test.mjs` and `bash pages/build-site.sh <unused-empty-directory>`.
2. Confirm the existing Cloudflare Pages project has `REDIRECT_URL=https://raw.githubusercontent.com/ZTD38F/WindowsBridge/main/install.ps1` in both production and preview settings. Do not print tokens.
3. Deploy the allowlisted build directory to existing project `windowsbridge` with branch `main`, using the authorized Cloudflare API. This is a **direct upload project**; merging GitHub changes does not itself deploy.
4. Verify public `GET /`, `GET /install.ps1`, HEAD, POST, browser and CLI user agents, MIME, no Location, `X-CFPR-Git-Commit`, source SHA-256 matching the actual current GitHub file and Cloudflare production deployment ID.
5. For rollback, retain the prior pinned Worker source and production deployment `ffd74b9f-e3d1-4716-bf02-1c4794949418`. Old pinned Workers **do not** follow `main`; returning to the old deployment is a deliberate freshness regression.

Never reintroduce old HTML installer behavior or silently overwrite unrelated Pages projects. The six-digit nonce alone does not defeat GitHub raw CDN's five-minute branch cache; the Atom-SHA lookup is essential.
