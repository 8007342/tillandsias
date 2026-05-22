# Step 19 — Launcher Terminal Litmus

Status: completed

## Goal

Make the installed user runtime pass the real terminal launch ladder:

```bash
./build.sh --ci-full --install
tillandsias --init --debug
tillandsias --opencode . --debug
tillandsias --codex . --debug
tillandsias --claude . --debug
tillandsias --bash . --debug
```

The terminal checks must use real attached PTYs where possible, then verify
that no idle proxy/git/inference stack remains after all forge containers exit.

## Findings

- The OpenCode forge entrypoint attempted to remove
  `/home/forge/src/<project>` even when that path was the live host checkout
  bind mount. This is now guarded by `TILLANDSIAS_PROJECT_HOST_MOUNT=1`.
- Static `--ip 10.0.42.x` assignments caused Podman IPAM collisions. Stack
  launches now rely on network aliases and dynamic IPAM.
- Debug failures were too verbose but not actionable. Observed launch helpers
  now emit compact `event:container_launch` state lines plus a `next:` hint.
- Runtime litmus assertions for `forge-as-only-runtime` were stale: the
  commands succeeded but emitted output patterns the generic matcher could not
  recognize. The litmus now emits explicit success tokens.

## Implementation Checklist

- [x] Protect mounted project worktrees from entrypoint wipes.
- [x] Route OpenCode Web through the shared clone/mount routine.
- [x] Add direct `--codex`, `--claude`, and `--bash` foreground launch flags.
- [x] Add observed launch helpers for status, router, OpenCode, OpenCode Web,
  and forge-agent stack stages.
- [x] Remove static IP launch args from proxy/git/inference/router paths.
- [x] Probe Chromium `--no-sandbox` support instead of appending it blindly.
- [x] Clean status-check and foreground terminal stacks when no forge remains.
- [x] Refresh affected specs, cheatsheets, litmus tests, and trace indexes.

## Verification Log

- `cargo test -p tillandsias-podman` passed.
- `cargo test -p tillandsias-headless --bin tillandsias --features tray` passed.
- `bash -n` over touched entrypoint and Chromium scripts passed.
- `./build.sh --ci-full --install` passed and installed `Tillandsias v0.2.260520.7`.
- `tillandsias --init --debug` built all runtime images for `0.2.260520.7`.
- `scripts/local-ci.sh --phase runtime` passed after litmus expectation repair.
- `tillandsias --bash . --debug` reached the forge welcome and fish shell,
  executed `TILLANDSIAS_BASH_OK`, exited status 0, and left no
  `tillandsias-*` containers.
- `tillandsias --codex . --debug` reached the Codex sign-in TUI, exited status
  0 on interrupt, and left no `tillandsias-*` containers.
- `tillandsias --claude . --debug` reached Claude Code; Claude exited status 1
  because it could not connect to Anthropic services. The launcher reported the
  attached command exit with a concise `next:` hint and left no
  `tillandsias-*` containers.
- `tillandsias --opencode . --debug` reached the OpenCode TUI for
  `~/src/tillandsias:main`, exited status 0 on interrupt, and left no
  `tillandsias-*` containers.

## Remaining

- Claude full-agent success is blocked by provider connectivity/auth rather
  than launcher, Podman, or forge startup.
