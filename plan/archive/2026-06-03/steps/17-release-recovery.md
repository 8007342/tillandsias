# Release Recovery — Static Cloud, Musl Release, Silverblue Installer

## Status

completed

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
- Local validation passed through full install, `--init`, and tray startup.
- Main convergence runs `26128121882` and `26128506885` passed.
- Release run `26128319662` failed before artifact upload because the hosted
  runner lacked `x86_64-linux-musl-gcc`; the workflow now installs `musl-tools`.
- Release run `26128601951` passed and published
  <https://github.com/8007342/tillandsias/releases/tag/v0.2.260519.3>.

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

All exit criteria were met on 2026-05-19.
