# P1: vault secret refresh races under concurrent bootstraps ("secret name in use") — 2026-07-04

- class: bug (P1, concurrency)
- filed: 2026-07-04
- owner: linux
- status: done
- trace: spec:ephemeral-secret-refresh
- found-by: live reproduction on a Fedora 44 rootless SELinux-Enforcing host

## Symptom

During a real curl-install reproduction (v0.3.260703.2, after `podman system
reset`), `tillandsias --init --debug` failed at vault bring-up:

```
[tillandsias-vault] refreshing podman secret tillandsias-vault-tls-cert from /tmp/tillandsias-ca/vault.crt
Error bringing Vault up: podman secret create tillandsias-vault-tls-cert failed: Error: tillandsias-vault-tls-cert: secret name in use
```

## Root cause — a race, not a stale-secret problem

The secret-refresh helpers (`create_unseal_secret`, `create_token_podman_secret`,
`create_file_podman_secret`) did a **non-atomic** two-step:

```
podman secret rm   <name>     # best-effort, errors swallowed
podman secret create <name>   # fails "secret name in use" if it already exists
```

When two vault bootstraps run **concurrently** — e.g. `--init` on the host while
a tray/forge launch also calls `ensure_vault_running` (observed: forges for
project "lakanoa" were live, vault was `Up (healthy)`, git-mirror tokens were
being minted) — the steps interleave:

```
A: secret rm cert      -> gone
B: secret rm cert      -> gone (already)
A: secret create cert  -> ok (now exists)
B: secret create cert  -> FAIL "secret name in use"   <-- spurious bootstrap failure
```

So one of the two callers fails even though vault is perfectly healthy. Also note
`podman system reset` does NOT remove podman **secrets** (podman 5.x), so stale
secrets across runs compound the window.

## Fix

Replace the racy `rm`+`create` with podman's server-side atomic
`secret create --replace` (podman 4.7+; confirmed on 5.8.3: "If a secret with the
same name exists, replace it") in all three helpers, and drop the separate
`secret rm` preambles. `--replace` is idempotent, so two concurrent callers both
succeed (last write wins) with no "name in use". The legitimate AppRole-lease
`secret rm` *cleanup* calls (post-use teardown) are unrelated and unchanged.

Regression test `vault_secret_create_uses_atomic_replace_not_racy_rm_create`
asserts each of the three create helpers uses `--replace` and carries no racy
`["secret", "rm", …]` preamble.

## Note on severity

Not a hard install blocker in isolation (a lone `--init` with no concurrent forge
would not race), but it makes `--init` flaky whenever the tray/forges are active —
which is the normal steady state — and produced the exact "vault won't come up"
failures the operator hit. Fixed at the source.

## Verifiable closure

- `./build.sh --check` + vault unit tests green; the regression test fails if any
  helper reverts to rm+create.
- Ships in the next release for operator re-test.
