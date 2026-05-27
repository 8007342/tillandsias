# Multi-Host Coordination Loop Status

LastExecutionTime: 2026-05-27T19:05Z

## This Loop

- Updated `/coordinate-multihost-work` from audit-only coordination to active
  orchestration: when sibling branches are ahead it must start or monitor an
  async full runtime litmus instead of only recommending future merge/test.
- Defined the async run protocol using ignored local metadata under
  `plan/localwork/runtime-litmus/<run_id>/` and a fresh worktree under
  `/tmp/tillandsias-runtime-litmus-<run_id>`.
- The long command is now explicitly:
  `./build.sh --ci-full --install && tillandsias --debug --init &&
  tillandsias . --opencode --diagnostics --prompt "$LITMUS_PROMPT"`.
- A first check/test-oriented integration run was started before this
  correction and failed fast on plan-doc conflicts; its ignored local log is
  available under `plan/localwork/integration-runs/`.
- If sibling plan-doc conflicts recur, the runtime-litmus runner should record
  them, reset to `origin/linux-next`, and still run the full installed runtime
  litmus so the next cycle has build/runtime output to inspect.
- Added a required three-host assignment board for every loop so hosts get
  primary and fallback work rather than idling behind stale dependencies.
- Fetched origin, confirmed `linux-next` was clean and up to date at
  `9081212c`, and observed remote heads: `windows-next` `c0a9558b`,
  `osx-next` `deba10d8`, `main` `e22a6853`.
- `main` advanced by PR #5 and now contains the durable `release.yml`
  headless-agent auto-publish leg. `linux-next` advanced by one coordination
  commit; neither sibling platform branch advanced since the 16:24Z fold.
- Reconciled active queues without changing item states: Windows w9 remains
  `in_progress` pending integration-loop merge/test; w7 remains the fallback.
  macOS m8 remains user-attended, with m10/m11 ready as optional no-blocker
  follow-ups.

## Expected Next Loop

- Start or monitor an async full runtime litmus for `origin/windows-next`
  through `c0a9558b`; do not stop at another audit-only recommendation.
- During that merge, preserve `linux-next`'s newer `13cf3af0`
  `images/vm/manifest.toml` repin and newer plan entries if Windows' older
  branch blocks appear.
- Windows can focus on the optional full live-provision dress rehearsal and
  optional wire EnumerateLocalProjects, using w7 diagnostics only if
  merge/test exposes stale branch or manifest state.
- macOS remains on user-attended m8 smoke; release cleanup is now narrowed to
  the manifest-owned `release_tag` accessor.

## Resolved Since Previous Loop

- PR #5 merged `linux-next` to `main` at `e22a6853`; the release workflow now
  carries the headless x86_64/aarch64 publish leg instead of relying on a
  manual upload.

## Current Major Blockers

- Integration-loop merge/test of `origin/windows-next` through `c0a9558b`.
- macOS m8 user-attended interactive smoke.
- Non-blocking release cleanup: manifest-owned `release_tag`.

## Assignment Board

- Linux primary: start/monitor async runtime litmus for `windows-next` ->
  `linux-next`; fallback: implement manifest-owned `release_tag`.
- Windows primary: wait for integration result, then run full live-provision
  dress rehearsal; fallback: w7 diagnostics if merge/test exposes drift.
- macOS primary: user-attended m8 smoke; fallback: m10 project threading, then
  m11 MenuStructure/clippy cleanup.

## Stale Or Pending Pings

- No expired leases found in active queues.
- Windows has unmerged code/docs delta; integration-loop merge/test is the
  pending cross-host action.
- macOS has no cross-host asks and may noop until user smoke feedback or
  release-tag/accessor work lands.

## Validation

- `bash -n codex` passed.
- `git diff --check` passed for touched coordination files.
- `./codex --help` still renders usage after the wait-output change.
- Files changed this pass: coordination skill, integration-loop ledger,
  wrapper wait output, and loop cache.
