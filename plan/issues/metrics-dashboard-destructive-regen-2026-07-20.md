# build --check regenerates plan/metrics-dashboard.md DESTRUCTIVELY on hosts without telemetry history

- Date: 2026-07-20
- Class: enhancement / build-byproduct hygiene (same family as the VERSION
  byproduct commits that keep breaking the release PR)
- Filed by: linux coordinator cycle (v0.4 stabilization)

## Observed

Running `./build.sh --check` on the coordinator host (no forge-image builds
this session, so no local telemetry) rewrote `plan/metrics-dashboard.md` from
six builds of history (`line [10,12,93,105,65,20]`, sizes ~2.9GB series) to
EMPTY series (`x-axis 1 -> 1`, `line []`, `bar [0]`). Committing that
byproduct would silently erase the tracked dashboard history; it was restored
via `git checkout --` this cycle and not committed.

## Why it matters

- A TRACKED file whose content depends on which host last ran a CHECK gate is
  a foot-gun: every cycle either commits data loss or leaves the worktree
  dirty (violating the meta-orchestration clean-exit contract).
- Same root pattern as `skills/merge-to-main-and-release/SKILL.md:234`'s
  violated "NEVER bump VERSION on linux-next" guardrail: build byproducts
  landing in tracked files on the wrong branch/host.

## Smallest fix (exit_criteria)

1. The dashboard generator must MERGE, not replace: if the local telemetry
   store has fewer data points than the committed dashboard, keep the
   committed series (or skip regeneration entirely with a note).
2. Alternatively move the dashboard to a generated-artifacts location that is
   gitignored, leaving a committed pointer.
- Exit: `./build.sh --check` on a fresh host leaves `git status` clean and
  the committed dashboard history intact.
