# v56.10.17.1 e2e smoke — linux (Silverblue) PASS (2026-10-17, lenovinha)

**PASS** v56.10.17.1 on Fedora Silverblue (lenovinha). Reported by the lenovinha-silverblue session to the coordinator on 2026-10-17.

| Arm | Result |
|---|---|
| curl install | PASS: exit 0, version v56.10.17.1 |
| SOFT reset | PASS: Verified:KEEP (vault-data and the keyring share kept) |
| Images | PASS: 17 images rebuilt |
| Tray, Vault, proxy | PASS: tray up, vault and proxy healthy, `--status-check` ok |

Caveats: cosign could-not-run (cosign-absent), so only the SHA256 check passed. The first GitHub rotation check ran before Vault was up and gave about a minute of HTTP 401s; it self-healed on the 60 s retry. Filed and fixed as 1776-74hj (#527).
