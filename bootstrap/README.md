# Bootstrap status

The bootstrap service in this directory is **experimental and not a production install endpoint yet**.

Production promotion requires Windows CI, a live Windows installation test, immutable source pinning, one-time bundle expiry/deletion validation, and a matching installer contract. Until those gates pass, do not deploy `bootstrap/server.py` as the public one-click installer.
