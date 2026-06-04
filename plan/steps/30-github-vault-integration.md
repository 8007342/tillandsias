# Step 30 — GitHub & Vault Integration Integrity

Status: ready
Owner: linux-host
Depends on: [agent-launch-stability]

## Goal
Fix the broken `tillandsias --github-login` flow and ensure the tray correctly handles unauthenticated states.

## Findings (Investigator Report)
1.  **Secret Desync**: `remote_projects.rs` still expects the legacy `tillandsias-github-token` Podman secret, but the modern flow relies on Vault.
2.  **Missing Pre-Check**: `discover_github_projects` polls GitHub every 5 minutes regardless of auth state, causing repeated container launch failures on every tray refresh when logged out.
3.  **Push Failure**: The `rewrite_origin_for_enclave_push` logic in `lib-common.sh` may not be handling authenticated `git://` URLs correctly if the mirror service is still initializing.

## Tasks
- [x] **GitHub Login Repair**:
    - [x] Verify the containerized `gh` session before token extraction and Vault persistence.
    - [x] Keep login Vault-only; creating the legacy Podman secret is forbidden by `spec:tillandsias-vault`.
- [ ] **Tray UX Guard**:
    - [ ] Implement `is_gh_authenticated()` check in `remote_projects.rs`.
    - [ ] Show a "🔵 GitHub Login..." menu item in the tray when unauthenticated, instead of the project list.
- [ ] **Remote Push Debugging**:
    - [ ] Audit `rewrite_origin_for_enclave_push` and ensure the `git-service` can handle the forwarded traffic.
- [x] **Vault Secret Capture**: Ensure the GitHub token is written to Vault and verified by read-back. Host-native keychain persistence is superseded by the Vault-exclusive contract.
- [ ] **Remote Projects Vault Migration**: Replace the remaining legacy `tillandsias-github-token` mounts in `remote_projects.rs` with short-lived `git-mirror` AppRole Vault access.

## Completion Evidence
- `45e5e955` — verify GitHub login before Vault write.
- `1bdd048e` — pin Vault-only GitHub token capture and read-back verification.
- Pre-build instant litmus: 103/103 PASS across 87/87 active specs.

## Exit Criteria
- `tillandsias --github-login` completes successfully and populates the Vault.
- `git push` works seamlessly from inside any forge agent session.
- Tray menu accurately reflects authentication state.
