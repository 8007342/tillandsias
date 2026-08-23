## Cycle 2026-08-23T05:41:23Z (macos tlatoanis-macbook-air — meta-orchestration full; 2-hourly loop iteration 2: directed checks + 317 drain slice)

### DIRECTED CHECKS: ALL THREE SETTLED IN MINUTES
(1) capability row: `ok:capability-row-reported:tlatoanis-macbook-air` — the
self-serve path merged back with BOTH concurrent fixes kept (this host's BSD
sed + yoga's --fresh; the file comment names it concurrent_correct_fixes).
(2) 851-28b5: done (closed last iteration, evidence 31225929b). (3) 856-s56y:
yoga's cycle driver landed (scripts/tillandsias-cycle-driver.sh, header says
the launchd child wraps it) but NO launchd child row exists yet — this host
remains the standing launchd verifier, checked 2-hourly.

### WORKER DRAIN: 317 brew-aarch64-harness-strategy, criteria 1+3 of 3
Batch (seed macos-m5-apple-tlatoanis-macbook-air): epic
harness-mcp-expert-validation, urgent=628-c7qd. 628-c7qd found NOT executable
— both 2026-08-17 measurements refute it as written and 628-w9sm (drift
ruling) is still pending; recorded as its next_action so the selector's next
reader stops re-deriving it. Claimed 317 instead:
- INVENTORY (criterion 1) in plan/issues/brew-aarch64-harness-strategy-
  2026-07-12.md, dual provenance. Headline: NO harness installs via brew and
  none should — Claude Code and Codex document brew only as macOS-only CASKS,
  OpenCode's own tap cannot run on aarch64 Linux, Gemini CLI is not even
  installed (provider credential only), Antigravity documents no brew. The
  image already conforms: vendor curl / npm channels, runtime arch-detect
  (Containerfile.base:43-48 records this as the deliberate aarch64 strategy).
- SHIM (criterion 3): brew-shim-exec.sh owns the aarch64 Tier-2 policy in ONE
  line, install-path only — scripts/test-brew-shim-tier2-warning.sh 8/8
  (per-arch AND per-path negative controls, cmp-verified mutant), new step in
  litmus:brew-ondemand-tools-shape.
- Claim released back to ready with next_action = criterion 2 (in-guest
  verification on a pristine aarch64 guest, owned by an e2e cycle).

### E2E DECISION, STATED NOT SILENT
scripts/e2e-preflight.sh says `eligible`, and 317's criterion 2 wants the
pristine-guest run — but the macOS local-build e2e destroys and re-provisions
the Virtualization.framework VM, which does not fit inside an unattended
2-hourly tick. Deferred deliberately; a dedicated cycle (operator-directed or
a loop iteration with the interval to spare) should take 317's next_action
and the e2e gate together.
