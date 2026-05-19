# Release Recovery — Static Cloud, Musl Release, Silverblue Installer

## Status

in_progress

## Goal

Restore the release path:

```bash
./build.sh --ci-full --install
tillandsias --init --debug
tillandsias --debug --tray
```

Then push `linux-next`, fast-forward merge to `main`, run the static cloud
convergence check, publish a GitHub Release, and update the root README for the
Fedora Silverblue curl installer.

## Current Work

- Git identity propagation and remote project menu flicker fixes are preserved.
- Hosted workflows are being reduced to static checks only.
- The release workflow is being replaced with a Linux musl binary publisher.
- The installer is being narrowed to a userspace Linux binary install with
  Podman as the only runtime dependency.
- Local validation has passed through full install, `--init`, and tray startup.
- Main convergence run `26128121882` passed on `f71b1f33`.
- Release run `26128319662` failed before artifact upload because the hosted
  runner lacked `x86_64-linux-musl-gcc`; retry after installing `musl-tools`.

## Process Log

Detailed command output stays out of the plan. Keep compact process/run entries
in `plan/localwork/release-recovery/processes.md`.

## Exit Criteria

- Local full install chain passes.
- Tray smoke launches from the installed binary and is stopped cleanly.
- `main` convergence passes on GitHub Actions.
- Release workflow publishes `tillandsias-linux-x86_64`, installer helpers,
  `SHA256SUMS`, and Cosign bundles.
- README install docs match the released artifact.
