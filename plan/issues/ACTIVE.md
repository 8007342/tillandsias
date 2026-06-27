# Active Plan Frontier

Last updated: 2026-06-27T04:05Z

## This Cycle (2026-06-27T03:12Z, linux_mutable — meta-orch + worker drain)

- **Cycle type**: meta-orchestration worker drain on mutable Linux.
- **Completed orders**: 106 (TPROXY verdict), 107 (proxy centralization), 111 (zeroclaw release packaging).
- **Windows integration**: merged `origin/windows-next@bb1d1f9c` (WSL2 parity: podman.socket, VAULT_API_BASE_URL, DNS routing).
- **Active work in progress**: Order 112 (`forge-harness-auth-device-flow`) — ready, estimated 8h; deferred to next cycle.
- **Latest published release**: `v0.3.260626.3` on `main`. Zeroclaw release packaging (order 111) requires a new release to be effective.

## Previous Cycle (2026-06-26T15:35Z, linux_mutable — hardcoded-ip DNS migration)

- **Cycle type**: advance-work implementation for `hardcoded-ip/dns-migration`.
- **Implementation**: Vault service identity moved from the singleton enclave IP to `vault` service DNS. Vault launch no longer uses `--ip`, TLS leaf generation/refresh pins `DNS:vault`, macOS VM cloud-init and the control-wire GitHub-login path export `TILLANDSIAS_VAULT_API_BASE_URL=https://vault:8200`, and rootful VM guests route the single-label `vault` lookup to the Podman network gateway discovered by `podman network inspect`.
- **Verification**: `cargo test -p tillandsias-headless enclave_` PASS; `cargo test -p tillandsias-headless vault_` PASS; `cargo test -p tillandsias-vm-layer vz_cloud_init_headless_service_has_control_wire_preflight` PASS; `cargo check -p tillandsias-macos-tray` PASS; stale Vault-IP Rust source scan returned no matches; `./build.sh --check` PASS.
- **E2E gate**: local-build smoke not started because `scripts/e2e-preflight.sh eligibility` returned `skip:smoke-lock-held`.
- **Ledger hygiene**: Stale macOS child statuses closed under already-done parent packets: `macos-tray-icon-missing-T-fallback/fix-icon` and `vault-unseal-fails-macos-after-db616e06/fix-unseal`.
- **Additional worker drain**: Order 99 `github-login-readiness-before-credentials` completed. Guest `--github-login` now verifies Vault and the actual ephemeral login helper container before any credential prompt, and no longer requires a pre-existing `tillandsias-git` project mirror.
- **Residual blocker**: `hardcoded-ip/remove-port-publish` remains blocked because native Linux still defaults to `https://127.0.0.1:8201`. Removing the publish requires a non-published native host access path such as vsock or podman-exec.
- **Release**: still held for the current post-build local-smoke failure class unless explicitly waived. Latest successful published release remains v0.3.260626.3 / tag `vv0.3.260626.3` on main.
