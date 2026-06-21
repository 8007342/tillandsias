# github-e2e/push-from-host — completed

## Claim

- **Claimed**: 2026-06-21T03:55:06Z by `big-pickle` (linux_mutable)
- **Completed**: 2026-06-21T03:55:06Z
- **Branch**: `linux-next`

## Summary

Updated `run_github_login` in `crates/tillandsias-headless/src/main.rs` to configure
git credential helper on the host after the containerized `--github-login` flow succeeds.

## What changed

Added host-side `gh auth login --with-token` + `gh auth setup-git` at the end of the
`#[cfg(feature = "vault")]` block in `run_github_login`:

1. Exec `podman exec <container> gh auth token` to retrieve the token from the
   login container (where `gh auth login` was already run).
2. Pipe the token to host `gh auth login --hostname github.com --git-protocol https --with-token`.
3. Run `gh auth setup-git` on the host to configure `credential.helper`.

This ensures `git push origin` works from the host working tree after running
`tillandsias --github-login`.

## Verification

- `cargo test -p tillandsias-headless --bin tillandsias` — 86 tests passed
- `cargo test --workspace` — all tests passed
- `cargo check -p tillandsias-headless` — compiles clean

## Residual

None. This slice is closed.
