# FIXED: deploy-key generation test hit the real macOS Keychain, not a hermetic store (2026-07-10)

- class: bug (test hermeticity) — FIXED this cycle (macOS overnight 7/8)
- found by: macOS full-workspace `cargo test` sweep
- fix commit: this cycle's osx-next commit

## Bug

`tillandsias-core::gh_auth_deploy_key::deploy_mode_generates_key_and_writes_config`
was designed to be hermetic — it injects `LITMUS_SECRET_TOOL_STORE` and a fake
`secret-tool` PATH shim so the generated deploy key never touches the real
keyring. But `scripts/generate-repo-key.sh` branches on `uname -s`, and its
**Darwin** arm used the real macOS `security` Keychain command, which the
Linux-only `secret-tool` shim does not intercept. So on macOS the test:

1. wrote the private key into the developer's login Keychain (side effect), and
2. failed `secret_store_get` read-back under a non-interactive/automation
   session, dying with "keyring read-back mismatch; private key was not stored
   correctly" (exit 3), and
3. would fail the "exactly one secret in the fake keystore" assertion anyway,
   since nothing was written to `LITMUS_SECRET_TOOL_STORE`.

## Fix

`secret_store_set` / `secret_store_get` now honor `LITMUS_SECRET_TOOL_STORE`
as a cross-platform file store (ahead of the `uname` branch), using the exact
`<store>/<service|account slug>` format that
`scripts/test-support/secret-tool-fake.sh` uses — so the Linux path is
byte-identical and the macOS path stops touching the real Keychain. Production
(env var unset) uses the real platform keyring unchanged. The test passes on
macOS and never mutates the login Keychain.

Verified: `cargo test -p tillandsias-core --test gh_auth_deploy_key` 5/5 pass.
