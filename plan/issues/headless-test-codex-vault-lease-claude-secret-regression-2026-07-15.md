# Pre-existing test failure on linux-next @ f97ec125: codex_forge_mounts_scoped_vault_lease_only_for_codex — Claude args now carry --secret

- Date: 2026-07-15
- Class: bugfix (test-vs-behavior reconciliation; blocks green `--test` on every host)
- Filed by: macos-osx-next meta-orchestration cycle 2026-07-15T05:21Z
- Pickup: linux (the vault-lease mounting and its test are linux-owned surfaces)

## Observed

`cargo test -p tillandsias-headless` fails 1/162 on the merged head
(verified PRE-EXISTING with the macOS working tree stashed — not caused by
local edits):

```
tests::codex_forge_mounts_scoped_vault_lease_only_for_codex
assertion failed: !has_arg(&claude_args, "--secret")   (main.rs:11251)
```

`build_forge_agent_run_args_with_vault(…, ForgeAgentMode::Claude, …,
Some("must-not-mount"))` now emits a `--secret` arg for Claude, while the
test pins the old contract "only Codex mounts the scoped vault lease".

## Likely cause

The agent-login vault-parity work (orders 303/304 family) extended
vault-lease mounting to more harness lanes, and this pin was not updated —
or the extension over-mounts for Claude unintentionally. Either the
CONTRACT changed (update/replace the pin: which modes mount, and that the
lease name still never leaks into non-consuming lanes) or the BEHAVIOR is
wrong (restore Codex-only). The linux owner of 303/304 should decide;
until then every host's full `--test` gate is red on this one.

## Repro

`cargo test -p tillandsias-headless codex_forge_mounts_scoped_vault_lease`
on f97ec125 (any platform; the test is argv-shape only, no podman needed).
