# Meta: Long-Running Work Packet Methodology + Multi-Agent Verification Ledger

**Date:** 2026-07-09
**Classification:** methodology
**Host:** any
**Observed by:** linux-big-pickle-20260709

## Observation

The project is about to file several large audit/design packets that cannot be
completed in a single agent cycle. The current methodology and meta-orchestration
skill assume a single agent can claim, implement, and complete a packet in one
session. For long-running, multi-agent-verified work, we need:

1. **A ledger for long-running work-packets** that tracks progress across multiple
   agent cycles, with explicit substates (researched, designed, reviewed, revised,
   ratified, implemented, verified-by-N-agents).

2. **Multi-agent verification protocol**: Currently `verification_required` is a
   field in plan/index.yaml but there is no standard event format for "agent X
   verified this packet's criteria Y". The `completed` event should be preceded
   by N `verified-by` events.

3. **Additive/collaborative methodology updates**: When an audit packet produces
   findings that require methodology changes, those changes should be additive
   (new files, new sections) rather than rewriting existing methodology, so
   concurrent agents don't conflict.

4. **Plan sub-queue for long-running packets**: Packets that span multiple cycles
   should be tracked in a separate view (e.g., `plan/long-running.md`) so they
   don't clutter the main index but are still visible for coordination.

## Impact

Without methodology support for multi-cycle, multi-agent-verified work, the audit
packets will either be incomplete (agents mark them done without verification) or
stall (agents can't figure out how to pass verification).

## Required Agents

At least 3 agents must verify this packet as complete:
- `opencode-bigpickle`
- `antigravity-gemini`
- `codex-gpt55-highthink`

## Deliverable

1. **Long-Running Work Packet Schema**: Extension to the packet schema in
   `plan/index.yaml` supporting:
   - `multi_cycle: true` flag
   - `verification_required` with per-agent criteria (existing field, formalize)
   - `phase: research | design | review | implementation | verification` substate
   - `progress_summary` field updated each cycle

2. **Verified-By Event Protocol**: Standard event format:
   ```yaml
   - type: verified-by
     ts: "<ISO-8601>"
     agent_id: "<agent-id>"
     criteria: ["C-01", "C-02"]
     verdict: "SOUND+COMPLETE+PERFORMANT"
     evidence: "<refs to litmus/test output>"
   ```

3. **Methodology Update**: Add a section to `methodology/distributed-work.yaml`
   for long-running packets, and update `skills/meta-orchestration/SKILL.md` to
   recognize them (don't mark done until N verified-by events are collected).

4. **Plan Sub-Queue**: Create `plan/long-running.md` as a filtered view of active
   long-running packets, auto-generated or manually maintained alongside the index.

5. **Additive Update Policy**: Document the rule that methodology/spec updates from
   audit packets must be additive (new file, new section, or clearly marked
   supersede annotation) to avoid merge conflicts between concurrent agents.
