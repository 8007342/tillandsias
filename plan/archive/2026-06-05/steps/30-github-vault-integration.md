# Step 30 — GitHub & Vault Integration Integrity

Status: completed
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
- [x] **Tray UX Guard**:
    - [x] Preserve the existing cached credential-health gate and one-shot GitHub login guidance.
    - [x] Recognize Vault failures as the unauthenticated state instead of matching the retired legacy secret name.
- [x] **Remote Push Debugging**:
    - [x] Audit `rewrite_origin_for_enclave_push`; it routes supported GitHub HTTPS/SSH origins through `git://git-service/<project>`.
    - [x] Confirm git-service uses scoped `git-mirror` AppRole access for upstream forwarding.
- [x] **Vault Secret Capture**: Ensure the GitHub token is written to Vault and verified by read-back. Host-native keychain persistence is superseded by the Vault-exclusive contract.
- [x] **Remote Projects Vault Migration**: Replace the remaining legacy `tillandsias-github-token` mounts in `remote_projects.rs` with short-lived `git-mirror` AppRole Vault access.

## Completion Evidence
- `45e5e955` — verify GitHub login before Vault write.
- `1bdd048e` — pin Vault-only GitHub token capture and read-back verification.
- `88bbb84f` — migrate remote-project discovery and clone to scoped Vault leases.
- Pre-build instant litmus: 103/103 PASS across 87/87 active specs.

## Exit Criteria
- `tillandsias --github-login` completes successfully and populates the Vault.
- `git push` works seamlessly from inside any forge agent session.
- Tray menu accurately reflects authentication state.
