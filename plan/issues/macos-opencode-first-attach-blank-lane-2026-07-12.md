# Bug: macOS first OpenCode attach on pristine substrate — lane terminal receives ZERO bytes, never recovers

- Date: 2026-07-12
- Class: bug (P1, macOS lane launch path)
- discovered_by: operator attended m8 smoke (macOS arm64, osx-next `374cb0b8`,
  tray git `374cb0b8`, fresh destructive reprovision minutes earlier)
- Filed by: macos meta-orchestration cycle attending the smoke
- Related: `windows-attach-silent-forge-base-build-2026-07-12.md` (silent
  first-attach, but Windows at least printed the cleanup line),
  `opencode-tray-tui-escape-spill-2026-07-12.md` (macOS OpenCode lane defects
  AFTER render — this one never renders at all).

## Symptom / timeline (all times local, 2026-07-12)

- 15:09 cold provision completed (`{"status":"provisioned"}`); tray launched.
- ~15:10–15:16 `--github-login` flow succeeded (screen session ended cleanly).
- 15:17 operator clicks OpenCode lane on the tillandsias project → Terminal
  opens with `screen /dev/ttys001` → **completely blank**. Screen hardcopy at
  15:21 confirms ZERO bytes ever written to the PTY (empty dump, not even the
  `[tillandsias] … cleaning project + shared stack` line every other lane
  prints first). Lane never produced output; operator eventually closed the
  window.
- 15:19 operator launches Maintenance terminal (`screen /dev/ttys002`) → gets
  the cleanup line immediately, then (slowly, see parity note in the Windows
  issue) the full shared-stack bring-up, forge welcome banner, and a working
  `forge@forge-tillandsias ~/s/tillandsias (osx-next)>` fish prompt by ~15:27.

Host-side during the blank window: tray held BOTH PTY slave fds
(`/dev/ttys001`, `/dev/ttys002` in lsof), vsock wire demonstrably alive
(maintenance lane streaming), tray at sustained 0% CPU (no guest build
running while the OpenCode lane sat blank).

## What this distinguishes

- NOT the Windows silent-build UX gap: that lane printed the cleanup line
  first; this one printed nothing at all.
- NOT the TUI escape-spill bug: that happens after OpenCode renders.
- The maintenance lane launched 2 minutes later on the SAME wire worked, so
  the vsock transport, PTY→screen→Terminal plumbing, and guest lane machinery
  are all functional. The defect is specific to the OpenCode lane's launch or
  output-wiring path on macOS, OR the OpenCode lane wedged pre-first-write and
  the maintenance lane's `cleaning project + shared stack` at 15:19 destroyed
  its in-flight state out from under it (cleanup-before-ensure racing a
  concurrent lane — order 298 territory).

## Open forensic questions (for the fix packet)

1. Does the guest keep a per-lane launch log that shows whether the OpenCode
   lane's entrypoint ever started? (If not: that absence is itself an
   idiomatic-layer gap to extend — no ssh forensics.)
2. Is `cleanup-before-ensure` guarded against a sibling lane's in-flight
   ensure? Two lanes 2 minutes apart on a pristine substrate is the normal
   attended first-run sequence, not an edge case.
3. Tray stderr (with `vm-status:` lines) is unrecoverable when launched via
   `open` — nothing under `~/Library/Logs/tillandsias`, nothing in unified
   log. Persistent tray-side lane-launch logging is a prerequisite for
   diagnosing any one-shot attended failure like this one.

## Repro

Destructive reprovision (rm VM dir + cache, `--provision`), launch tray,
`--github-login`, then click OpenCode on a project as the FIRST lane attach.
Observed once (attended); rate unknown.

## Update (same session, ~15:30): retry succeeded — first-attach-only race confirmed

The operator relaunched the OpenCode lane after the shared stack was warm
and it came up fully (ran a complete in-forge meta-orchestration cycle).
This narrows the defect to the first-attach window while the shared-stack
ensure/cleanup is in flight — strengthening hypothesis (2): the sibling
lane's `cleaning project + shared stack` racing the OpenCode lane's ensure.
Subsequent distinct defects from the same session are filed separately:
`macos-opencode-pty-resize-not-propagated-2026-07-12.md`,
`macos-lane-launch-dead-after-opencode-close-2026-07-12.md`.
