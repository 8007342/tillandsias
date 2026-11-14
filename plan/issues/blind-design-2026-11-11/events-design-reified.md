# reified.md — the events and logs design on the real constraints

The same design as `design.md`: two planes (free-text logs that stay in their
scope; typed events that alone cross boundaries), one hub beside podman,
identity by socket, snapshot plus deltas, pull with a token budget. Sections
not mentioned are unchanged. Every change is marked `[R:<reason>]`: an
operator ruling (memory name), an answer in `answers.md` (E-n), or an open
operator question (OQ-n in ../../operator-questions.md). Nothing is taken from
the existing implementation unless a ruling forces it.

## 0. Status of the blind assumptions

| Blind assumption | After answers |
|---|---|
| Operator is a non-expert end user | CONFIRMED `[R:installer-is-for-end-users-no-prompts]` |
| One status line plus an opt-in session event list | CHANGED, §8 |
| Audit stream kept 30 days / 4 MiB | HELD: OQ-6, OQ-7, OQ-8 — see D9 |
| Egress host is sensitive | HELD: OQ-9; the design's projection (exact host to owner only) stays as the restrictive default |
| No constrained text in global | HELD: OQ-10; restrictive default stays |
| Hub supervised independently of the tray | KEPT (E-8: no ruling either way) |
| vsock on macOS, `wsl.exe` child on Windows | KEPT (E-9: vsock is available on both; the choice is not ruled) |
| Uplink closes when idle | KEPT; depends on OQ-2 |
| 8 MiB log cap | CHANGED, §7 |
| 5-minute disk check | HELD: OQ-12 — see §9 |
| Swap unknown | CHANGED: swap is mandatory; encryption HELD: OQ-11 |
| Transcripts out of scope | CHANGED, §7 |
| Children: visibility upward only, depth unbounded | KEPT as the restrictive default; HELD: OQ-13 |
| Single user, single host | HELD: OQ-4 |

## 1. Core decisions

D1–D8 unchanged.

- **D2/hub.** The hub is in-memory rings and a state table only: no durable
  queue, no storage engine, no second collector. It never ingests agent
  session transcripts. `[R:forge-log-visibility-ruling — "ring buffer, not a broker"]`
  `[R:forge-logs-die-with-the-forge — no second collector]`
- **D9/audit.** Not built until OQ-6 is answered. If the answer is "nothing
  survives", D9, the audit sink, its failure row and the `audit` visibility
  are deleted and the `audit` projections of `egress.*`, `cred.*` and
  `approval.*` go with them. If a record is allowed, it is the design's typed,
  no-free-text stream with opaque ids only (OQ-8) and the fail-open or
  fail-closed choice of OQ-7. Independently of the hub, a cloud-cost approval
  is recorded on the commit or push it authorised.
  `[R:forge-logs-die-with-the-forge — only non-PII aggregates may outlive, ask first]`
  `[R:operator-approval-and-ux-rulings — approval recorded on the commit or push]`

## 2. Event model

Envelope and field discipline: unchanged.

Type registry changes:

| Type | Change |
|---|---|
| `image.progress` | `attempt` and `retry_after_s` stay in the event for agents; the tray's renderer ignores them (the user is never told about attempts). `[R:image-build-retry-and-tray-feedback-ruling]` |
| `service.state`, `inference.state` | `retry_after_s` is the agent-facing "busy, try again in N minutes". `[R:image-build-retry-and-tray-feedback-ruling]` |
| `approval.requested` / `approval.resolved` | `action_class` is the approved set of nine kinds (workflow dispatch, push to integration, merge to integration, open pull request, promote stable, extra build, remote worker, hosted resource, hosted deploy); every approval carries the forge-instance scope it is namespaced to. `[R:operator-approval-and-ux-rulings 2026-10-26]` |
| `vault.state` | global projection `login_required` unchanged; the event never offers the agent a way to start a sign-in. `[R:agents-never-start-a-sign-in]` |
| `git.peer_pushed` (new) | Class T, visibility **project**: delivered to the other forge instances of the same project when one of them pushes. Data: `ref_kind` enum only. This is the one sanctioned sibling-visible fact and it adds a `project` visibility level between `own` and `global`. `[R:operator-approval-and-ux-rulings 2026-11-01 — concurrent forges are notified of each other's pushes]` |
| `substrate.pressure` | adds `resource: swap`; `substrate.state` adds reason `swap_missing`. `[R:operator-approval-and-ux-rulings — swap is mandatory]` |
| `child.state` | `kind` enum is the on-demand appliance catalogue (web container, browser, studio). `[R:operator-approval-and-ux-rulings 2026-11-02]` |

## 3. Transport

Unchanged, with one clarification on languages: NDJSON stays, but the
justification "a shell `printf` must be able to emit an event" is dropped.
Producers use a small emitter library (Rust, Go, Lua); the forge-side CLI is a
Rust binary. No bash, Python or jq helper is shipped.
`[R:operator direction — Lua/Rust/Go, minimise bash and python, no jq]`

Per-service podman healthchecks: none by default, as designed; adding one is a
new cadence that goes to the operator with its wakeups per hour.
`[R:polling-cadence-needs-operator-approval]`

## 4. Propagation

Unchanged, plus the `project` visibility used only by `git.peer_pushed`.
Sibling non-interference otherwise stands exactly as designed.
`[R:forge-log-visibility-ruling]`

## 5. Agent subscription

Unchanged (CLI and MCP tools over the forge's own socket; pull with cursor
and token budget; `wait`).

## 6. Curation and redaction

Unchanged. The tray's sentence table is written for an end user: honest, never
alarming, no internal names. `[R:operator-approval-and-ux-rulings — messages are curated]`

## 7. Retention

| Data | Change |
|---|---|
| Container logs | No fixed 8 MiB cap: a live forge's logs are not size-limited. They sit in memory-backed storage that may spill to the mandatory swap, and are bounded only by the forge's own memory-plus-swap budget; on pressure the hub emits `substrate.pressure`, it does not truncate silently. Removed with the forge. `[R:forge-logs-die-with-the-forge — no practical size limits]` `[R:media-studio-and-storage-direction — tmpfs overflows to swap]` |
| Hub rings, state table | unchanged |
| Tray | last snapshot only; the capped session event list is removed from the tray (§8) |
| Audit | HELD (D9) |
| Diagnostic bundle | events, state and versions only. Raw log text is never written to a bundle, ticked box or not. `[R:forge-logs-die-with-the-forge — never persist, ship or archive raw logs]` |
| Agent transcripts and shell history | now in scope: they are forge logs and must not outlive the forge. The forge's writable paths that hold them are per-instance and removed with it. `[R:forge-logs-die-with-the-forge]` |
| Host terminal scrollback | HELD: OQ-14 |
| Swap | logs may reach disk through swap; whether that needs encrypted swap is HELD: OQ-11 |

Session-only retention holds: nothing in the hub outlives the forge session.
`[R:forge-log-visibility-ruling]`

## 8. Tray status line

- The reducer and priority order: unchanged. Output is the tray's **only**
  progress surface: one non-interactive line, "step n of m" or a percentage
  when known. `[R:image-build-retry-and-tray-feedback-ruling]`
- The "retrying (with next attempt time)" rung is removed from the user-facing
  order; while automatic retries run the line stays on the step in progress,
  and after they are exhausted it shows "failed". `[R:image-build-retry-and-tray-feedback-ruling]`
- The opt-in session event list and any per-forge rows are removed from the
  tray; the same information is reachable from the command line.
  `[R:image-build-retry-and-tray-feedback-ruling — no tray rows for progress or retry]`
- The reducer also drives the icon: progressive blush while containers are
  created, pups when done, plain again on the first menu open; and it can
  drive a start/stop splash whose animation stalls when events stall.
  `[R:image-build-retry-and-tray-feedback-ruling]` `[R:operator-approval-and-ux-rulings — splash driven by the log facilities]`
- 1 s repaint debounce: unchanged (one-shot, armed by an event).

## 9. Overhead budget and timers

Budgets unchanged; each is reported per platform with its own verdict.
`[R:obligations-hold-per-platform]`

Timer inventory after reification:

| Timer | Status |
|---|---|
| Repaint debounce, 1 s one-shot | kept; not a poll |
| `wait` timeout, per call | kept |
| Uplink reconnect backoff, 1 s doubling to 5 min, only while disconnected | kept, listed for approval with its wakeups per hour; an OS resume notification triggers an immediate attempt `[R:polling-cadence-needs-operator-approval]` |
| Disk headroom check, 5 min | **not armed** until OQ-12 is answered. Until then disk is checked at events only: forge start, appliance start, download start, working-copy creation; a full disk is otherwise found on failure and reported as `substrate.pressure: critical`. `[R:polling-cadence-needs-operator-approval]` `[R:media-studio-and-storage-direction — check disk before creating a worktree]` |

## 10. Failure semantics

Unchanged, except: the "audit sink unwritable" row is HELD with D9; the "tmpfs
log cap reached" row becomes "forge memory-plus-swap budget reached → pressure
event, oldest log data dropped with a stated byte count".

## 11. Platform notes

Linux, macOS and Windows each carry every obligation separately; a pass on one
is not evidence for another. `[R:obligations-hold-per-platform]` Linux adds: the
tray refuses to start without disk swap, emitted as `substrate.state` with
reason `swap_missing` before any hub exists (§3.3 path).
`[R:operator-approval-and-ux-rulings — swap is mandatory]`

## Languages

Hub and forge CLI in Rust (or Go for the hub); renderer tables and scrub rules
as Lua data; no bash, Python or jq. `[R:operator direction]`
