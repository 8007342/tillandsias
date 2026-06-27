# Git Mirror Relay: "fetch first" Rejection — Root Cause & Fix

**Status:** `completed`
**Owner:** forge
**Date:** 2026-06-27T01:20Z
**Trace:** `spec:git-mirror-service`

## Summary

The git mirror's post-receive hook failed to relay a forge push to GitHub with
`! [rejected] fetch first` because the mirror was out of sync — GitHub had
commits the mirror didn't know about. The push was silently lost (hook exits 0
on failure). The same vulnerability exists in the startup retry-push loop in
`entrypoint.sh`.

## Root Cause

The `post-receive-hook.sh` at `images/git/post-receive-hook.sh` runs
`git push "$PUSH_URL" $REFSPECS` without first fetching upstream state. When
the mirror is stale (e.g. another host pushed to GitHub directly, or the mirror
was restarted and partially re-seeded), the push is rejected as non-fast-forward
because `NEWSHA` does not descend from the current upstream HEAD.

The hook always exits 0 regardless of push success/failure, so the forge never
sees the relay failure as an error. The warning is logged but there is no retry
or reconciliation mechanism beyond the best-effort startup retry in
`entrypoint.sh` (which also does not fetch before pushing).

## Contributing Factor

The git mirror container `(build_git_run_args` in
`crates/tillandsias-headless/src/main.rs`) does not pass `HTTP_PROXY`,
`HTTPS_PROXY`, or `NO_PROXY` environment variables. While pushes to GitHub
evidently reach GitHub (the rejection error confirms TCP connectivity), the
missing proxy env vars make the outbound path fragile — it relies on transparent
proxying rather than explicit proxy configuration.

## Fix Applied

### 1. `images/git/post-receive-hook.sh` — fetch before push

Added `git fetch origin` before the `git push` call so tracking refs reflect
GitHub's actual state. If the fetch fails (logged, non-fatal), the push will
fail visibly instead of silently diverging.

### 2. `images/git/entrypoint.sh` — fetch before startup retry push

Added `git -C "$mirror" fetch origin` before the startup retry-push loop so
stranded commits from a prior session are pushed against the correct upstream
state.

### 3. `crates/tillandsias-headless/src/main.rs` — proxy env vars for git mirror

Added `HTTP_PROXY`, `HTTPS_PROXY`, `http_proxy`, `https_proxy` (each pointing
to `http://proxy:3128`) and `NO_PROXY`/`no_proxy` (listing
`localhost,127.0.0.1,git-service,tillandsias-git,vault,inference`) to
`build_git_run_args`. This ensures the git mirror's outbound `git push` to
GitHub explicitly uses the enclave proxy rather than depending on transparent
proxying.


## Files Changed

- `images/git/post-receive-hook.sh` — fetch before push
- `images/git/entrypoint.sh` — fetch before startup retry-push
- `crates/tillandsias-headless/src/main.rs` — proxy env vars in
  `build_git_run_args`

## Verification

- `litmus:git-mirror-safe-refspec-push` — PASS
- `cargo test git_run_args` — 6/6 PASS (including
  `git_run_args_forward_project_remote_url_when_present`,
  `git_run_args_mount_vault_token_when_supplied`,
  `git_run_args_use_image_entrypoint_and_persist_srv_git`)
- `cargo check` — all crates compile
- `litmus --phase pre-build --size instant` — 109/111 PASS (2 pre-existing
  podman-dependent failures unrelated to this change)
