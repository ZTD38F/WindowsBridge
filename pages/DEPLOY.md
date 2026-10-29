# WindowsBridge Cloudflare Pages deployment — Mode 2

Production: `https://windowsbridge.pages.dev/` (Cloudflare Pages project `windowsbridge`, direct-upload project, production branch `main`).

Verified production deployment on 2026-10-29: `ffd74b9f-e3d1-4716-bf02-1c4794949418`.
Prior production deployment available for rollback: `5c3a2968-5c67-4e73-b284-59a634ca4a51`.

Canonical source: `pages/_worker.js` pinned to WindowsBridge Git commit `be3b7dc179c6410e787c0925fccfdc0ca7f35dc9`.

```bash
node --test pages/site.test.mjs
bash pages/build-site.sh /tmp/windowsbridge-mode2-build
```

Use the existing authorized Cloudflare deployment channel for production `main`. This project is not Git-connected, so commits alone do not deploy. Never print API credentials, deploy credentials from the repository, or overwrite unrelated projects.

Independent E2E acceptance: verify `GET /`, `GET /install.ps1`, `HEAD /install.ps1`, and `POST /`; check browser and PowerShell user agents, HTTP 200 for GET/HEAD, `text/plain`, no Location header, `405` for POST, and full-body SHA-256 matching pinned `install.ps1`. Confirm Cloudflare latest production deployment ID. Retain rollback metadata.

Do not redeploy the old Secure Install HTML interface or the old `302` GitHub redirect Worker.
