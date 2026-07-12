# OpenCode tray lane: TUI escape-char spill (works from Maintenance shell)

- Date: 2026-07-12
- Class: exploration → partially fixed this cycle (order 306 verifies residual)
- Filed by: linux_mutable meta-orchestration cycle (operator repro)

## Operator repro (2026-07-12, local build, fresh --init)

- Tray → OpenCode: lane launches, OpenCode "finished some updates", then the
  TUI corrupts — even moving the cursor spills escape characters onto the
  screen. Recurring ("the spilling characters thing").
- Maintenance (terminal) lane → run `opencode` from fish minutes later: works
  perfectly, ran a full /meta-orchestration cycle.

## Diagnosis

Both lanes share the same container spec (same TERM inheritance via
`podman run -t`), same entrypoint library, same image — the env hypothesis
(missing TERM) does not distinguish them. What DOES distinguish them is
timing against the backgrounded first-run installers:

1. Agent lanes exec the TUI while `ensure_forge_harnesses` /
   `ensure_forge_prebuilt_tools` still run in the background SHARING THE TTY.
   `npm install` output (stdout was unredirected) lands mid-frame in the TUI.
2. The background updater npm-reinstalls `opencode-ai@latest` — non-atomic
   bin/package rewrite — potentially UNDER the running OpenCode TUI on first
   launch (cadence stamp empty). In the Maintenance lane the updater has
   finished long before the user types `opencode`, which matches the repro
   split exactly.
3. Debug lanes additionally get `trace_lifecycle` lines on the shared stderr.

## Fixed this cycle

- `ensure_forge_harnesses` npm invocations now mute stdout (`>/dev/null`),
  install + rollback paths (lib-common.sh).
- All forge entrypoints redirect the backgrounded installers' stdout to
  `/tmp/forge-lifecycle.log`; stderr stays attached so the order-299 loud
  first-run floor warning still reaches the lane terminal.

## Residual (order 306)

- Verify in the next interactive/local-build e2e that the tray OpenCode lane
  no longer corrupts (cursor movement clean during and after the background
  update window).
- If corruption persists, next suspects in order:
  a. live npm rewrite of the running `opencode-ai` install (skip the ACTIVE
     harness package in `ensure_forge_harnesses`, or stage+atomic-rename);
  b. `OPENCODE_INIT_PROMPT_FILE` synthetic-prompt injection (set only in the
     tray/agent lane, absent in the Maintenance flow);
  c. debug-mode `trace_lifecycle` stderr sharing the TUI display.

## Exit criteria

- Operator (or e2e smoke) confirms a tray OpenCode session stays clean for
  ≥5 minutes on a first-launch (cold cache) run.
- If (a) is implicated: updater never rewrites the package backing a
  currently-executing lane binary; fixture added to
  scripts/test-harness-rollback.sh.
