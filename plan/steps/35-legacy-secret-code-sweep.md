# Step 35 — Dead pre-Vault code & test-fixture sweep

- **Status**: ready
- **Owner host**: linux
- **Branch**: linux-next
- **Depends on**: [] (coordinate ordering with step 34; both touch secret surfaces)
- **Specs**: tillandsias-vault, git-mirror-service, gh-auth-script

## Goal

Remove now-unreachable legacy code branches and fix test fixtures / annotations that still
exercise or name the removed `tillandsias-github-token` podman secret — including a fixture
that directly **contradicts** an existing Vault-only litmus.

## Tasks

- [ ] **git image legacy branches** (unreachable since `main.rs:313` rejects the flags):
  `images/git/entrypoint.sh:31-36`, `images/git/post-receive-hook.sh:107`,
  `images/git/Containerfile:36` — drop the `--legacy-keyring-secrets`/`tillandsias-github-token`
  fallback paths (or reduce to a one-line tombstone comment).
- [ ] **contradictory test fixtures**: `scripts/test-support/github-login-fake.sh:33-40` and
  `scripts/test-support/podman-mock.sh:48` still `podman secret create … tillandsias-github-token`,
  while `openspec/litmus-tests/litmus-vault-github-token-capture-shape.yaml:37` asserts the
  `create_github_podman_secret` symbol is **absent**. Update the fakes to the Vault write/read-back
  contract (and any litmus that consumes them).
- [ ] **methodology examples**: `methodology/litmus-framework.yaml:168,187,197,246,398,465` use
  `tillandsias-github-token` as the worked credential example — update to a Vault example so the
  authoritative methodology doesn't model the removed flow.
- [ ] **stale annotations in live code**: `main.rs:3271-3279` `run_github_login` still logs
  `secret_name = "tillandsias-github-token"` under `@trace spec:secret-rotation` (a retired spec)
  though the token now goes to Vault `secret/github/token` — retrace to `tillandsias-vault` and
  fix the log field. Clean the stale `crates/tillandsias-headless/Cargo.toml:72` legacy comment.
- [ ] **defensive cleanup, keep**: `scripts/cleanup-secrets.sh:59` removing a stray
  `tillandsias-github-token` is fine to retain (cleans legacy leftovers) — just comment it as such.

## Acceptance evidence

- `rg -n "tillandsias-github-token|legacy-keyring-secrets|without-vault" --glob '!plan/**'
  --glob '!**/archive/**'` returns only intentional tombstones/cleanup comments.
- `cargo test -p tillandsias-headless` PASS; affected litmus PASS; `./build.sh --check` PASS.

## Note (flag-don't-fix)

Per coordination canon, sibling-owned (`macos`/`windows`) scopes are out of bounds here; if
a sweep surfaces rustfmt/clippy drift in sibling crates, flag it in the queue, don't reformat.
