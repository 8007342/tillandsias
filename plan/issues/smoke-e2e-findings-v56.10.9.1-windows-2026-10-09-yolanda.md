# Smoke e2e findings — v56.10.9.1 — Windows (yolanda) — 2026-10-09

Reported by yolanda-windows to the macuahuitl coordinator; relayed verbatim in substance.

**Verdict: W1 SOFT reinstall PASS on v56.10.9.1** (integrity, prompts, handover, tray version, install log, Vault seal, GitHub sign-in survival).

- Integrity: `sha256sum -c SHA256SUMS-windows` 4/4 OK; cosign v3.0.5 verify-blob 5/5 "Verified OK" (`[.]` identity regexp, GitHub Actions issuer); the irm-fetched install-windows.ps1 matches (fd211dc9…).
- Run 1 (17:17:49Z, from 56.10.8.1): `$env:TILLANDSIAS_VERSION='v56.10.9.1'; irm …/v56.10.9.1/install-windows.ps1 | iex`, SOFT, exit 0. Zero prompts and no power-user lines. No "superseded" line, so the 1562-bqcg handover now works: VM handshake success ×3, tray 56.10.9.1 (d3e8c8729), `--status-once` READY. The Vault reports "provisioning persisted from a prior boot". GitHub survival was UNMEASURED because no token existed.
- The operator signed in to GitHub from the tray at 17:40:09Z.
- Run 2 (17:42:15Z, 56.10.9.1 to 56.10.9.1), SOFT, exit 0: no re-login asked for; "signed-in" resolved at 17:44:19Z; 0 404s on secret/data/github/token; guest "verdict=valid"; same seal (one "vault initialized" ever, 2026-10-08 23:24:21Z); cloud projects count=15, equal to the pre-install count.
- Observations: the installer provisions twice per install (filed 1565-qtuk). The image wipe on SOFT is by design (host-state-lifecycle). The two existing installer prompts were not exercised, because .wslconfig was complete and HCS access was already present.
