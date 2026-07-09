# Event Push Architecture — Container & Git Lifecycle Events to Tray

**Date:** 2026-07-09
**Classification:** design+enhancement
**Host:** any
**Observed by:** linux-big-pickle-20260709

## Observation

The tray currently shows a status line and menu, but there is no mechanism to push
notifications about container lifecycle events (creation, startup, health changes),
git operations (clone, commit, push), or build events to the user. The user must
either poll or dig through logs.

The observable-streams refactor (orders 152-158) added `VmStatusPush`,
`LoginStatePush`, and `CloudProjectsPush` to the control wire protocol, but:
1. These are VM-level aggregates, not per-container or per-git-operation events.
2. There is no priority system to determine WHICH event is "most important" when
   multiple events arrive in quick succession.
3. The tray status line shows the latest phase string, not the most relevant
   recent event.

## Impact

Users (especially on Windows/macOS VM-based hosts) have no visibility into what
the system is doing during long operations (forge launch, git clone, image build).
The tray status may be stale or irrelevant while important events happen unseen.

## Required Agents

At least 3 agents must verify this packet as complete:
- `opencode-bigpickle`
- `antigravity-gemini`
- `codex-gpt55-highthink`

## Deliverable

1. **Event Taxonomy**: Define event types (container_launch, container_health,
   git_clone, git_push, git_commit, build_start, build_complete, auth_success,
   auth_failure, error) with priority levels (CRITICAL, IMPORTANT, NORMAL, INFO).

2. **Priority-Based Display Rule**: In the last 20-60 seconds, show the highest-
   priority event. A release push supersedes recent commits. An auth failure
   supersedes a successful clone. The event must be "sticky" until seen or
   superseded by a higher-priority event.

3. **Push Channel**: Extend the control wire protocol (or use the existing
   push variants from order 152) to carry typed lifecycle events.

4. **Tray Status Integration**: Map events to the 37-char curated status line.
   Events that fit naturally are shown directly; longer events are summarized
   with a concise prefix.

5. **Event Deduplication**: Same-type events within N seconds are coalesced.
   E.g., "Cloned 3 projects" instead of three separate "Cloned project X" events.

6. **Spec/Cheatsheet**: New or updated specs in `openspec/specs/` for the event
   taxonomy and push protocol.
