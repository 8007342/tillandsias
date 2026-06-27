# Step 101 — Remove stale auth preflight requiring tillandsias-git from released headless

- **Status**: pending
- **Owner host**: linux
- **Branch**: linux-next
- **Depends on**: podman-health-lifecycle-facade
- **Audit origin**: `plan/issues/build-install-smoke-e2e-findings-2026-06-25.md`

## Why this exists

The macOS VZ VM `--github-login` flow is blocked by a stale auth preflight check in the **released** `tillandsias-headless-aarch64-unknown-linux-musl` binary (fetched by cloud-init `fetch-headless.sh` from GitHub releases). The check requires `tillandsias-git` container to be running before proceeding, but:

1. No existing bootstrap code starts the git container before the preflight
2. Starting it via vsock exec PTY hangs (podman run/start hangs on long-lived containers via PTY)
3. The current source tree on `osx-next`/`linux-next` has already removed this check

The fix is already in source — a new release needs to be cut so the macOS host can re-provision and pick up the fixed binary.

## What to do

1. **Verify current source** — Confirm the `tillandsias-git` container-running preflight is not present in `crates/tillandsias-headless/src/`. If traces remain, remove them.
2. **Cut a new release** — Bump VERSION, tag, trigger release workflow_dispatch so the aarch64 musl binary is published to GitHub releases.

## Verification on macOS

After the release is published:
1. Fresh VM provision
2. `--github-login` should proceed past preflight to the vault healthcheck + token prompt
