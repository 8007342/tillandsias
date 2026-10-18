# v56.10.17.1 e2e smoke — windows PASS with a recorded deviation (2026-10-17, yolanda)

**PASS** v56.10.17.1 on Windows (yolanda). Reported by the yolanda-windows session to the coordinator on 2026-10-17. The operator approved running the smoke on this pre-release.

| Arm | Result |
|---|---|
| §1 install | PASS: `install-windows.ps1` pinned through TILLANDSIAS_VERSION, exit 0; tray `--version` reports 56.10.17.1 (bf21de967) |
| §2 reset | PASS: the tillandsias distro unregistered and the runtime caches purged by name; the builder disk untouched |
| §3 cold `--provision-once` | PASS: exit 0 in about 2.5 min; status-once reads Ready with podman_ready=True |
| diagnose | PASS: exit 0; version and guest_version both 56.10.17.1 |

Caveats:
- cosign could-not-run (cosign-absent); the signature was NOT checked.
- Deviation from the clean-room runbook (804-ckst): the Credential Manager entries vault-shamir-share-v1 and vault-root-token-v1 were NOT cleared, under the operator's standing rule never to touch real credentials. The guest may have received the existing share.

Evidence: target/smoke-e2e on yolanda.
