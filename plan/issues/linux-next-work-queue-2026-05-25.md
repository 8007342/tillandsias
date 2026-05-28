# Linux-next work queue — 2026-05-25 onwards

trace: methodology/distributed-work.yaml (worker_agent_protocol),
       skills/advance-work-from-plan/SKILL.md (§6 ledger),
       plan/issues/multi-host-integration-loop-2026-05-24.md (the 2h cron)

The linux equivalent of `osx-next-work-queue-*.md` and
`windows-next-work-queue-*.md`. Each entry is the one-line outcome the
`/advance-work-from-plan` skill writes at §6 after shipping (or
no-op-ing) a slice. Reverse-chronological, keep the latest 30 verbatim
and collapse older into a summary block.

For the WHY of each commit, see `plan/issues/linux-headless-spec-gaps-2026-05-27.md`
(diagnostics chain, gap-3 phase log) and the commit body itself.
This file is the cross-host advertisement — terse, dated, SHA-anchored.

## Recent entries (reverse chronological)

- 2026-05-28T19:51Z  (no-op)   defer — integration cron at 19:43Z (8 min ago, inside 10-min defer window). No slice taken; cron writes need to settle. Agent `linux-tlatoani-fedora-claude-opus-2026-05-28T19:51Z`.
- 2026-05-28T19:29Z  `2b589f13`  distill: surface all 5 gap-3 typed-event arms in summaries (counts + sample lines for exit/signal/resource + top-5 noisiest by stderr volume) + defensive fix for empty-log abort. Verified against the first production gap-3 phase-2g capture at 19:02Z (115 `event:container_stderr` lines).
- 2026-05-28T19:24Z  `9683b11e`  canonical `skills/advance-work-from-plan/SKILL.md` + symlinks into all 5 agent-runtime `skills/` dirs (Claude, OpenCode, Codex, Gemini, GitHub) + slash-command shims in `.claude/commands/` + `.opencode/commands/` + registry entries in `methodology.yaml` + `plan/index.yaml`. Superseded by Tlatoāni's more structured `c1a57f47` later that hour; the canonical body is now the formal worker-protocol variant.
- 2026-05-28T17:24Z  `ce257f39`  gap-5 phase-2 bounded ring buffer (10K) + `BackpressureMeter` rising-edge warn at depth > 100 per spec:runtime-diagnostics-stream "Event rate limit" + "Terminal blocked".
- 2026-05-28T16:53Z  `758e2e46`  litmus: pin gap-3 phase-2 emitter-layer surfaces (spawn helper, EmitterState, signal helper, routing arms, typed stderr tail, run_opencode_mode wiring).
- 2026-05-28T16:24Z  `c21ebfd4`  gap-3 phase-2g typed `event:container_stderr` stream — `DiagnosticsHandle::start_typed_event_stream` + run_opencode_mode wiring on the 4 SUPPORT containers. **6-arm gap-3 chain COMPLETE.**

(Older entries — pre-2026-05-28T16:00Z — collapse into the headless spec-gaps backlog at `plan/issues/linux-headless-spec-gaps-2026-05-27.md`.)
