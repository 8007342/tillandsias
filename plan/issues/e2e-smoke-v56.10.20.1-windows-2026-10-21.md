# v56.10.20.1 e2e smoke — windows PASS with a recorded deviation (2026-10-21, yolanda)

**PASS** v56.10.20.1 on Windows (yolanda). Reported by the yolanda-windows session to the coordinator on 2026-10-21. The operator approved running the smoke on this pre-release.

| Arm | Result |
|---|---|
| §1 install | PASS: `install-windows.ps1` pinned through TILLANDSIAS_VERSION, exit 0; tray `--version` reports 56.10.20.1 (f0e61287e) |
| §2 reset | PASS: the tillandsias distro unregistered and the runtime caches purged by name; the builder disk untouched |
| §3 cold `--provision-once` | PASS: exit 0 in 1m22s (03:10:37 to 03:11:59 local); status-once reads Ready with podman_ready=True |
| diagnose | PASS: exit 0; version and guest_version both 56.10.20.1 |
| vault/proxy stack (1118 slice 2a) | PASS: after a later guest boot, tillandsias-vault and tillandsias-proxy both (healthy) with restarts=0; vault unsealed from the prior boot's provisioning ("vault is unsealed and serving"); `podman secret ls` is empty (0) |

Caveats:
- cosign could-not-run (cosign-absent); the signature was NOT checked.
- Deviation from the clean-room runbook (804-ckst): the Credential Manager entries vault-shamir-share-v1 and vault-root-token-v1 were NOT cleared, under the operator's standing rule never to touch real credentials.
- The vault/proxy check ran about 3 minutes after the smoke, on a guest boot my own `wsl -d tillandsias` probe caused with NO tray running. The vault unsealed with no host delivery, so the per-container tmpfs key survives a no-tray reboot here. The vault entrypoint still logs "using unseal key from secret" although no podman secret exists: stale wording, worth a look under 1118.

Evidence: target/smoke-e2e on yolanda.
