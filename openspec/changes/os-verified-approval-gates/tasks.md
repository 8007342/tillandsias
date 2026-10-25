## 1. Linux: approval broker and record (order 1879-5jkt)

- [ ] 1.1 Write the statement canonicaliser and a fixture that fails today (no `tillandsias approval` subcommand)
- [ ] 1.2 Broker module in tillandsias-headless: nonce issue, expiry, single use, journal
- [ ] 1.3 `tillandsias approval request|verify` CLI; SSHSIG via `ssh-keygen -Y sign/verify`, namespace `tillandsias-approval@v1`
- [ ] 1.4 Note writer for `refs/notes/tillandsias/approvals` and the `Approved-by:` trailer

## 2. Linux: key enrolment (order 1880-9wpd)

- [ ] 2.1 Enrol an `ed25519-sk -O verify-required` key from the tray; write allowed-signers into mirror state
- [ ] 2.2 polkit action `org.tillandsias.approve` with `auth_self` for the software fallback; key sealed in Vault
- [ ] 2.3 Statement `strength` reflects the path actually used

## 3. Linux: mirror verification (order 1881-ynjn)

- [ ] 3.1 pre-receive: verify approval notes for integration/default updates from the seed; refuse before relay
- [ ] 3.2 Fixture: unapproved, expired, mismatched and valid pushes; work refs ungated
- [ ] 3.3 Seed the Tillandsias project `warn`, then `enforced` after enrolment

## 4. Linux: gate table in host tools and scripts (order 1882-kkww)

- [ ] 4.1 Gate table; `cost` marker on descriptors; `handle_mcp_jsonrpc` returns `awaiting_approval`
- [ ] 4.2 Ignore agent-supplied approval arguments
- [ ] 4.3 Wrap `gh workflow run` and integration-branch PR creation in host scripts and skills
- [ ] 4.4 Coordinate with order 1853-qr4h so its deploy tool is born gated

## 5. Linux: dialog (order 1883-c8xr)

- [ ] 5.1 Curated sentence table and lint test
- [ ] 5.2 Mācron SVG poses per action kind, workshop scene with existing tillandsia SVGs; check against the macron.dev canon QA list
- [ ] 5.3 GTK4 `tillandsias-approval-dialog`, argv-only launch, normal window level

## 6. Linux: lifecycle splash (order 1884-ptnt)

- [ ] 6.1 Stage-to-scene map from `TrayStatusStage`; stall timer per stage
- [ ] 6.2 Splash window, normal level, closable; shutdown reversal

## 7. Linux: first-use download window (order 1885-2r2f)

- [ ] 7.1 Read the PR #650 download manifest; needed vs removable
- [ ] 7.2 `statvfs` storage bar; window; download starts only on Approve

## 8. macOS and Windows (orders 1886-hf9j, 1887-n244, 1888-e3yh, 1889-dr6k)

- [ ] 8.1 macOS: Secure Enclave key (CryptoKit, wrapped blob), LAContext, SSHSIG ecdsa-sha2-nistp256 envelope, AppKit dialog
- [ ] 8.2 macOS: splash and download window (URL volume resource values)
- [ ] 8.3 Windows: measure Hello signature padding; KeyCredentialManager signer or WebAuthn fallback; SSHSIG envelope; dialog
- [ ] 8.4 Windows: splash and download window (GetDiskFreeSpaceExW)

## 9. Open questions for the operator

- [ ] 9.1 Should one approval cover a batch (for example a land-queue run of several PRs), or one approval per push?
- [ ] 9.2 Should GitHub-side rules (required signed approvals, workflow_dispatch restricted to the operator) close the raw-`gh` door for host agents?
- [ ] 9.3 Software fallback on a Linux host without a YubiKey: allow with a `software-password` label, or refuse cost-bearing actions there?
- [ ] 9.4 Are daily autonomous cuts (standing ruling) still autonomous, or does each release dispatch now need a touch?
- [ ] 9.5 PR #650's change does not yet define a download manifest by name; confirm it will, or which change owns it
