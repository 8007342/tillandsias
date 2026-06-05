# Step 34 — Pre-Vault spec & litmus reconciliation

- **Status**: ready
- **Owner host**: linux
- **Branch**: linux-next
- **Depends on**: []
- **Specs**: tillandsias-vault, podman-secrets-integration, secrets-management,
  git-mirror-service, podman-idiomatic-patterns

## Goal

Several **active** specs and their bindings still encode the pre-Vault secret model or
contradict the post-hardening reality. Reconcile them so the active spec set tells one story.

## Tasks

- [ ] **tillandsias-vault self-contradiction**: the requirement says the legacy flow is
  "completely removed" + has a "Legacy flags are rejected" scenario, but two invariants still
  treat the flags as reachable — `spec.md:253-256` (`linux_init WITHOUT --without-vault …`)
  and `:258-261` (`legacy_keyring_secret_flow REQUIRES … --legacy-keyring-secrets …`). Replace
  both with invariants that match "rejected/removed". Also fix the `## Status` header
  (`phase: 6` → reflect 6.5 hardening).
- [ ] **podman-secrets-integration** (active, 22 `tillandsias-github-token` refs, 0
  `vault-token` refs): tombstone the GitHub-token-as-podman-secret scenarios and document the
  **current** podman-secret usage — `tillandsias-vault-unseal` → `/run/secrets/vault-unseal`
  (tmpfs) and per-container `tillandsias-vault-token-<role>-<id>` → `/run/secrets/vault-token`.
- [ ] **secrets-management**: it is `superseded` but not tombstoned; `:10` still says "for one
  release behind the deprecated `--legacy-keyring-secrets` flag" (now removed). Move to a full
  tombstone (`status: obsolete`, `tombstone: superseded:tillandsias-vault`) and drop it from the
  active set in `openspec/litmus-bindings.yaml` if still active.
- [ ] **git-mirror-service:153**: remove/rewrite the `--legacy-keyring-secrets` start scenario.
- [ ] **podman-idiomatic-patterns:88-90** (low-confidence): scenario "Secret created at startup
  from host keyring" may still be accurate for the HKDF-derived unseal-key podman secret —
  confirm against `vault_bootstrap.rs` before editing; either keep + clarify it refers to the
  unseal key, or rewrite if it implies the GitHub token.
- [ ] **litmus-bindings hygiene**: re-verify coverage_ratio/active flags after the above; ensure
  no active binding pins a removed symbol.

## Acceptance evidence

- `./scripts/run-litmus-test.sh --phase pre-build --size instant --compact` PASS (active-spec
  count adjusted if `secrets-management` is fully tombstoned).
- No active spec presents `--legacy-keyring-secrets`/`--without-vault` or the
  `tillandsias-github-token` podman secret as a current contract.
