# Event and log design (blind)

Scope: logs and events for a tray-launched set of podman containers on
Linux, in a macOS VM, and in Windows WSL2. Designed from the promise and the
stated rulings only. Component names here ("hub", "feed") are mine; the real
system's names are unknown (Q12).

## 1. Core decisions

| # | Decision | Reason |
|---|---|---|
| D1 | Two separate planes: **logs** (free text, stay inside their scope, tmpfs) and **events** (typed, closed field set, the only thing that crosses a boundary) | The ephemerality and PII rulings apply to free text. Typed events can be made safe by construction; free text cannot be made safe by filtering |
| D2 | One **hub** per podman instance, co-located with podman (host on Linux, guest on macOS/Windows) | Fan-in happens where the containers are; exactly one stream crosses the VM boundary |
| D3 | Identity comes from **which socket** a peer connected on, never from message content | A forge cannot claim to be another forge |
| D4 | State is **level-triggered and snapshot-able**; events are deltas with hub-assigned sequence numbers | Lets every consumer recover from loss by re-reading state; removes the need for reliable delivery |
| D5 | Producers **never block** on observability; loss is allowed, **silent** loss is not | Overhead and failure isolation |
| D6 | Agents **pull** with a cursor and a token budget; nothing is pushed into a model's context | Token cost is the consumer's decision |
| D7 | Global stream is an **allowlist of event types with closed-vocabulary fields** | Curation by construction; no free text reaches other tenants |
| D8 | No periodic heartbeats or status polling anywhere; liveness comes from socket EOF and podman's own event stream | Polling ruling |
| D9 | Audit is a third, tiny, typed stream with its own retention | Reconciles "ephemeral" with "auditor" (pending Q3) |

## 2. Event model

### 2.1 Envelope

The envelope follows CloudEvents 1.0 attribute names where they fit [R1] and
takes severity numbering from the OpenTelemetry log data model [R2], so an
operator who later wants to export to standard tooling can map 1:1. It is not
a claim to implement either in full.

```
{
  "v":    1,                         // envelope version
  "seq":  48211,                     // hub-assigned, monotonically increasing per hub boot
  "boot": "b7f3",                    // hub boot id; (boot, seq) is the total order
  "time": "2026-11-11T10:20:31Z",    // advisory; never used for ordering
  "type": "service.state",           // registered type; CloudEvents `type`
  "source": "service:proxy",         // scope of the producer; stamped by the hub from the socket (D3)
  "subject": "service:proxy",        // what the event is about; CloudEvents `subject`
  "sev":  9,                         // OTel SeverityNumber: 5 debug, 9 info, 13 warn, 17 error, 21 fatal
  "vis":  "global",                  // own | parent | host | global | audit  (computed by hub from type registry)
  "key":  "service.state/proxy",     // coalescing key; latest value wins for state-class events
  "corr": "op-91c2",                 // optional correlation id of the operation that caused this
  "data": { "state": "ready" }       // schema fixed per type
}
```

Rules:

- `source`, `seq`, `boot`, `vis` are set by the hub. A producer-supplied value
  for any of them is discarded.
- `data` is validated against the type's schema at the hub. Unknown type or
  unknown field: the event is dropped and counted (`hub.rejected`), not
  forwarded "best effort".
- Maximum encoded size 1 KiB. Larger is rejected. An event is a fact, not a
  payload.
- `corr` is an opaque id minted by the hub or tray when an operation starts.
  It is not a W3C trace id [R8]; full tracing is a non-goal. It only lets a
  consumer ask "what happened to the thing I started".

### 2.2 Field type discipline

Every field in every schema is one of:

| Kind | Example | May appear in `global` | May appear in `own`/`parent` |
|---|---|---|---|
| enum | `state: ready` | yes | yes |
| bounded int / duration / size | `retry_after_s: 90` | yes | yes |
| registered name | `service: inference` | yes | yes |
| opaque id minted by the system | `corr`, `forge_id` | no (except the subscriber's own) | yes |
| digest | image digest | yes | yes |
| constrained text (charset `[a-z0-9._-]`, ≤64) | model name, branch name | no (Q13) | yes |
| free text | error message | **never** | no; free text lives in logs only |

There is no free-text field in any event. Where a human-readable sentence is
needed, the consumer renders it from the enum via a table. This is the single
most important rule in the design: it is what makes redaction, curation,
plain-language status and prompt-injection resistance the same mechanism.

### 2.3 Type registry (initial)

Classes: **S** state (coalesced, latest wins, included in snapshots),
**T** transition/occurrence (not coalesced), **A** audit.

| Type | Class | vis | data |
|---|---|---|---|
| `substrate.state` | S | host | `component`(podman,vm,distro), `state`, `reason` enum |
| `substrate.pressure` | S | host, global(coarse) | `resource`(disk,memory), `level`(ok,low,critical) |
| `image.progress` | S | host | `image` name, `phase`(pull,build,verify), `step` n/m, `attempt` n/m, `retry_after_s` |
| `service.state` | S | host, global | `service`, `state`(absent,starting,ready,degraded,stopping,failed), `reason` enum, `retry_after_s` |
| `service.exit` | T | host | `service`, `exit_class`(clean,error,oom,signal,timeout), `code` |
| `forge.state` | S | host, own | `forge_id`, `state`(creating,ready,working,waiting_operator,idle,stopping,removed) |
| `child.state` | S | parent | `child_id`, `kind` enum, `state`, `exit_class`, `code` |
| `child.log_available` | T | parent | `child_id`, `stream`(out,err), `bytes_since` bucketed |
| `egress.denied` | T | own, audit | `reason`(not_allowlisted,method,size,tls,rate), `dest_class`(registry,vcs,model_hub,other) ; exact host only in `own` copy (Q6) |
| `egress.policy_changed` | T | host, audit | `change` enum |
| `cred.granted` / `cred.denied` / `cred.expired` / `cred.revoked` | T | own, audit | `capability` name, `ttl_s`, `reason` enum. Never a value, never a prefix or suffix of a value |
| `vault.state` | S | host, global(coarse: `login_required` yes/no) | `state`(sealed,ready,login_required,failed) |
| `git.push` | T | own | `result`(accepted,refused), `reason` enum, `ref_kind`(branch,tag) |
| `git.relay` | T | own, host | `result`, `reason` enum, `lag_class` |
| `route.state` | S | own | `route_id`, `state`, `reason` enum |
| `inference.state` | S | global | `backend`(cpu,gpu,npu), `state`(loading,ready,saturated,lost), `retry_after_s` |
| `op.done` | T | own | `corr`, `kind` enum, `result`(ok,failed,cancelled), `reason` enum |
| `approval.requested` / `approval.resolved` | T | host, own(outcome), audit | `action_class` enum, `outcome` |
| `hub.gap` | T | to the affected subscriber | `from_seq`, `to_seq`, `dropped` count, `classes` |
| `hub.health` | S | host | `subscribers`, `rejected`, `scrub_hits`, `audit_sink`(ok,failed) |
| `notice` | T | global | `code` enum (planned_restart, update_available, shutting_down), `in_s` |

Adding a type or field is a schema change reviewed like an API change. That
review is the curation step (§6).

### 2.4 Logs

A log line is `{stream, bytes}` plus the hub-known scope. No parsing, no
levels inferred, no promotion of log lines into events. If a service wants
something to be visible outside itself, it emits an event; a regex over its
log output is not an acceptable event source (it re-imports free text across
the boundary).

## 3. Transport

### 3.1 Inside the podman instance

```
 container ──stdout/stderr──► podman log file on tmpfs (per container, size-capped)
 container ──event socket───► hub         (one bind-mounted Unix socket per container)
 podman    ──events stream──► hub         (lifecycle: start, died, oom, health_status, remove) [R5]
 hub       ──subscriber sock► forge agent (the same per-container socket, bidirectional)
 hub       ──uplink──────────► tray       (one connection)
```

- **Event socket**: the hub creates one Unix stream socket per container in a
  per-container directory and that directory is bind-mounted read-write into
  only that container. The scope of anything arriving on it is fixed at
  creation. Peer credentials (`SO_PEERCRED` [R11]) are not relied on because
  uid mapping in rootless user namespaces makes them ambiguous; the path is
  the identity. Framing: newline-delimited JSON, one event per line, max
  1 KiB. NDJSON is chosen over a binary encoding because producers span many
  languages and a shell `printf` must be able to emit an event; at the
  budgeted rates the encoding cost is irrelevant.
- **Lifecycle from podman, not from containers**: `podman events --stream
  --format json` (or the equivalent API stream) gives create/start/died/oom/
  health_status/remove with exit codes [R5]. A container cannot be trusted to
  report its own death, and this needs no polling. The hub translates these
  into `service.state`, `service.exit`, `child.state`.
- **Readiness**: a service announces `ready` by emitting `service.state` on
  its socket once (the sd_notify pattern [R7], carried on our socket). The
  hub does not probe ports. A container-defined podman healthcheck may exist
  for services that can wedge silently, with an interval of minutes and a
  written justification per service (Q14).
- **Logs**: podman's file log driver with `--log-opt max-size` and a path on
  tmpfs [R6]. Not the journald driver: journald has its own retention and on
  most distributions persists to disk under `/var/log/journal`, which breaks
  "dies with the forge" unless the whole journal is volatile [R4]. Reading a
  log is `tail`-follow of that file by the hub on behalf of an authorised
  subscriber; nobody else reads it.

### 3.2 Host ⇄ guest

Exactly one bidirectional stream between tray and hub. The tray is a
subscriber with scope `host`.

| Platform | Uplink | Notes |
|---|---|---|
| Linux | Unix socket under `$XDG_RUNTIME_DIR`, mode 0600 | tmpfs, per-user, gone at logout |
| macOS | virtio-vsock: guest hub listens on a vsock port; the host app connects through the VM's socket device [R9] | No TCP port, no network stack involved, not reachable by other hosts. Falls back to the VM's serial/console channel if vsock is not available (Q9) |
| Windows | stdio of one long-lived helper process inside the distro, started by the tray (`wsl.exe -d <distro> -- <helper>`), or a Hyper-V socket [R10] | The helper pipe is simplest and needs no admin registration; cost is that it holds the distro awake. To honour "near-zero", the tray closes the uplink when no forge and no service is running and lets WSL idle out (Q11) |

A loopback TCP port is rejected as an uplink on all three: any local process
of any user could connect, and on WSL2 loopback forwarding has a history of
surprising exposure.

Uplink protocol: on connect the hub sends `snapshot` (all class-S events at
their latest value, for the subscriber's visibility), then `live` deltas.
Reconnect always starts with a snapshot. The tray therefore keeps no
persistent state and has no replay logic.

### 3.3 Before the hub exists

First run, VM boot, distro import, hub image pull: the tray itself emits the
same event types (`substrate.state`, `image.progress`) into its own in-memory
reducer. The status line has one code path whether the source is local or
the hub.

## 4. Propagation: fan-in and fan-out

```
producers (N containers + podman + tray-local)
      │  rate-limit per producer ─► validate schema ─► stamp source/seq ─► scrub ─► classify vis
      ▼
   hub core:  state table (latest per key)  +  ring buffer per scope (bounded)
      │
      ├─► host subscriber (tray): vis ∈ {host, global, approval.*}, coalesced
      ├─► forge:<id> subscriber: vis=own where scope==forge:<id>
      │                         + vis=parent where scope is a descendant of forge:<id>
      │                         + vis=global
      └─► audit sink: vis=audit, append-only
```

- **Fan-in rate limit**: token bucket per producer socket, 5 events/s
  sustained, burst 50. Excess is dropped at ingress and summarised as one
  `hub.gap` per second for that producer's scope. A misbehaving forge can
  degrade only its own feed.
- **Scope tree**: `forge:<id>/child:<cid>` is established when the forge asks
  the hub (or the tray, via the hub) to create a child; the hub records the
  parent. Parentage is never inferred from names or labels the forge can set.
- **Visibility is computed from (type registry, scope tree, subscriber
  scope)**. There is no per-event ACL field a producer can set.
- **One event, several projections**: `egress.denied` is delivered to the
  owning forge with the destination host, to audit with the destination
  class, and contributes to a count in the tray's `hub.health`. Projection
  functions are part of the type registry.
- **Sibling non-interference**: the global projection of any type contains no
  forge id, no count of forges, and no field whose value varies with another
  forge's activity beyond the shared-resource state itself (`inference.state:
  saturated` is allowed; "saturated by forge X" is not). Timing remains a
  residual channel (security.md §7).

## 5. Forge agent subscription and consumption

### 5.1 Interface

Exposed inside the forge as (a) a small CLI and (b) the same operations as
tools over the Model Context Protocol [R12], since coding agents commonly
speak it (Q15). Both talk to the forge's own socket.

| Operation | Returns |
|---|---|
| `state` | Current snapshot, compact form, own + children + global. Bounded size by construction (one line per key) |
| `events since=<cursor> max_tokens=<n> min_sev=<s> types=<glob>` | Header + events + new cursor |
| `wait corr=<id> \| types=<glob> timeout=<dur>` | Blocks until a matching event or timeout; returns that event only |
| `logs scope=<self\|child-id> tail=<lines> since=<cursor> grep=<fixed string> max_tokens=<n>` | Raw lines, clearly delimited as untrusted data |

Nothing is ever injected into the agent's context unasked. The agent, or its
harness, decides when to look.

### 5.2 Replacing polling with `wait`

The pattern the design wants agents to use:

```
corr = start_build(...)            # any async operation returns a corr id
ev   = wait(corr=corr, timeout=20m)  # one tool call, zero tokens while waiting
```

`wait` is a blocked read on the socket. It costs no CPU and no tokens while
pending, and it is the answer to "prefer events over polls" for an LLM
consumer, where each poll is a full tool-call round trip. The timeout is
mandatory and capped so a lost event cannot hang an agent; on timeout the
reply says so and includes the current state of the subject.

### 5.3 Backpressure

- Per-subscriber ring buffer in the hub, bounded by count and bytes
  (default 512 events / 256 KiB).
- Class-S events are coalesced by `key` in the buffer: a service flapping 200
  times while the agent thinks occupies one slot holding the latest state and
  a flap count.
- Class-T events are dropped oldest-first when full; the next read begins
  with a `hub.gap` giving the dropped count by type.
- The hub never waits on a subscriber. A subscriber that does not read
  cannot slow producers or other subscribers.
- A cursor older than the buffer returns `gap` + a fresh snapshot rather than
  an error.

### 5.4 Token cost

Events are rendered for the model in a compact line form, not JSON:

```
# cursor b7f3:48211  gap:0  shown 6 of 41 (35 info coalesced)  ~140 tok
10:20:31 W service.state inference saturated retry_after=90s
10:20:40 E egress.denied reason=not_allowlisted dest=files.example.org  x3
10:21:02 I op.done corr=op-91c2 kind=image_build result=ok
```

Rules:

- `max_tokens` defaults to 400 and is hard-capped (2 000). The hub estimates
  at 4 bytes/token and truncates at an event boundary; the header always
  says how many were not shown and how to get them.
- Selection under budget: highest severity first, then newest; identical
  consecutive events collapse to `xN`.
- The header line is always present and always under 40 tokens, so "nothing
  happened" costs one line.
- Default `min_sev` is warn for the global stream and info for own scope.
- `state` output is designed to be stable between calls when nothing changed
  so that it sits in a prompt cache prefix rather than invalidating it; no
  timestamps or counters in the snapshot body.
- Logs have the same `max_tokens` cap and return the tail, with a line
  saying how many bytes were skipped. The agent is expected to `grep`
  server-side (fixed string, not regex, to bound hub CPU) rather than page.

Expected steady-state cost for an agent that checks once per task step:
one header line (~30 tokens) when quiet.

### 5.5 Trust marking

Everything returned by `logs` is wrapped and labelled as untrusted process
output. Event lines contain only enum values, numbers, registered names and
ids; they cannot carry an instruction (security.md §6).

## 6. Curation and redaction

Layered, cheapest and most reliable first:

1. **Schema is the curation.** A type reaches `global` only if listed in the
   registry with a global projection whose fields are all enum/int/registered
   name/digest. The list is short (§2.3: `service.state`, `inference.state`,
   `substrate.pressure` coarse, `vault.state` coarse, `notice`).
2. **Projection per audience** (§4): the same occurrence carries different
   detail for owner, tray, audit.
3. **No free text in events** (§2.2), so there is nothing to redact in the
   common path.
4. **Scrubber at hub ingress** for constrained-text fields and for logs at
   read time: pattern rules for well-known credential formats and
   high-entropy runs; a hit replaces the value with `[redacted:<rule>]` and
   increments `hub.health.scrub_hits`. A scrub hit in an *event* is treated
   as a producer bug: the whole event is dropped, not forwarded redacted.
5. **Exact-match denylist** for live secrets, if the vault can cooperate
   (Q16): the vault hands the hub a keyed digest of each issued credential
   and the scrubber checks sliding windows of log output against it. This is
   the only layer that catches a secret with no recognisable shape.
6. **The status line** is rendered by the tray from a finite table keyed by
   enum values. No event field is ever interpolated into it except a
   registered name and a bounded number.

Redaction at read time (not write time) for logs is deliberate: raw logs sit
only in the producing scope's tmpfs, and every path out goes through the hub.

## 7. Retention

| Data | Where | Lifetime | Bound |
|---|---|---|---|
| Container logs | tmpfs file per container | Removed with the container; forge removal removes all its children's logs | 8 MiB per container, rotate-truncate (Q17) |
| Hub ring buffers | hub memory | Scope removal frees its buffer; hub restart loses all | 256 KiB per subscriber, 4 MiB total |
| Hub state table | hub memory | Entry removed when subject is removed | One row per key |
| Tray | process memory | Last snapshot only; optional session event list capped at 200 | — |
| Audit | host-side append-only file (Q3) | Assumed 30 days or 4 MiB, whichever first | No free text, no PII by schema |
| Diagnostic bundle | file the operator explicitly creates | Operator's responsibility | Events + state + versions; logs only if the operator ticks a box per forge |

Hazards that silently extend retention, each needing an explicit control:
journald capture of container output (avoid the driver), core dumps (disable
or route to tmpfs in forges), swap (logs in tmpfs can be swapped to disk; Q18),
guest disk images and VM snapshots (keep tmpfs truly in RAM-backed mounts
inside the guest), shell history and agent transcripts inside the forge's own
workspace (outside this design; Q19), editor/terminal scrollback on the host
if the operator attaches.

"Dies with the forge" is implemented as a removal hook the hub runs on the
podman `remove` event for a forge scope: delete log directory, free buffers,
close and unlink sockets, drop state rows, then emit `forge.state: removed`
to the host scope only. A hub that was down when the forge was removed
reconciles on start by deleting any log directory with no live container.

## 8. Tray status line

A pure function `reduce(snapshot) -> (sentence_id, params)` evaluated on each
received delta; the tray repaints only if the result changed.

Priority order (first match wins): cannot reach cloud → needs operator →
failed → retrying (with next attempt time) → starting/working (step name) →
degraded → ready (n projects open) → stopped.

At most one registered name and one number per sentence. Debounce 1 s on
repaint so a flapping service does not flicker; this is a one-shot timer
armed by an event, not a poll.

## 9. Overhead budget

| Item | Budget | How it is met |
|---|---|---|
| Tray CPU when idle | 0 wakeups/min from observability | Blocked read on one socket; no timers |
| Tray memory for observability | < 1 MiB | One snapshot, no history |
| Hub RSS | < 10 MiB with 10 forges | Fixed-size rings, no indexes, no storage engine |
| Hub CPU idle | 0 wakeups/min | Blocked on sockets and the podman events stream |
| Hub CPU under load | < 1% of one core at 100 events/s | NDJSON validate + memcpy |
| Per-event producer cost | One non-blocking `send`; drop on `EAGAIN` | D5 |
| Uplink bytes steady state | 0 | No heartbeats (D8) |
| Periodic timers | None by default | Each exception is listed below |
| Log disk/RAM | ≤ 8 MiB × containers, tmpfs | size-capped driver option |

Timer inventory (the complete list):

| Timer | Period | Justification |
|---|---|---|
| Status repaint debounce | 1 s one-shot after an event | Not a poll |
| `wait` timeout | per call, capped 30 min | Bounds a blocked agent |
| Uplink reconnect backoff | 1 s doubling to 5 min, only while disconnected | No event can announce that a dead link is back on macOS/Windows; stops when the tray knows the substrate is intentionally down |
| Disk headroom check | 5 min, only while a forge is running | Filesystem fullness has no cheap event source (Q20) |
| Audit retention sweep | on append, not timed | — |

Liveness without heartbeats: socket EOF is immediate for process death;
podman emits `died`; VM/distro death is an EOF on the uplink. The one
undetectable case is a wedged-but-connected hub; the tray detects it lazily,
because any operator interaction (opening the menu) sends a `state` request
with a 2 s deadline.

## 10. Failure semantics

| Failure | Behaviour | What consumers see |
|---|---|---|
| Producer floods | Ingress rate limit drops | `hub.gap` for that scope |
| Subscriber slow or absent | Its ring overwrites | `hub.gap` on its next read |
| Producer emits invalid/unknown event | Dropped, counted | `hub.health.rejected` rises; the producer gets an error line back on its socket |
| Hub crashes | Producers' sends fail; they drop and continue. Supervisor restarts hub; new `boot` id | All subscribers get EOF, reconnect, receive snapshot rebuilt from podman's current container list + services re-announcing state when they see the socket reappear. Cursors from the old boot return gap + snapshot |
| Hub down at forge removal | Reconcile on start (§7) | — |
| Uplink lost (VM paused, host sleep, WSL shutdown) | Tray shows "reconnecting", never the last good status | On reconnect: snapshot |
| Clock step in guest | Ordering unaffected (seq) | `time` may jump; consumers must not sort by it |
| Audit sink unwritable | `hub.health.audit_sink: failed`, tray shows degraded. Whether credential grants fail closed is an operator decision (Q4); assumed: grants continue, the gap is itself recorded when the sink returns | — |
| Scrubber rule crashes or times out | Fail closed: the line/event is withheld and replaced by `[withheld]` | Counted |
| tmpfs log cap reached | Oldest truncated | First line of the next `logs` read says bytes lost |
| Hub buffer memory cap reached | Largest subscriber ring is trimmed first | `hub.gap` |

Delivery guarantee, stated once: **events are at-most-once with loss
detection; state is eventually exact.** Any consumer that needs certainty
re-reads `state`. No consumer may act irreversibly on an event alone.

## 11. What I would test first

1. Canary-credential and canary-PII sweeps (obligations O1, O2, O7) on all
   three platforms, including after forge removal and after hub crash.
2. Sibling probing: forge A enumerating scopes, cursors, child ids, and
   timing of `global` events while forge B works.
3. Idle wakeup count of tray and hub over 10 minutes: expected zero.
4. Host sleep/resume on macOS and Windows: status line passes through
   "reconnecting" and lands on truth.
5. An agent loop with 1 000 flapping state events between reads: reply stays
   under `max_tokens` and reports the coalescing.

## References

Cited from prior knowledge; none were fetched during this exercise (see
learnings.md §4). URLs are the canonical homes of each document.

- [R1] CloudEvents Specification v1.0.2 — https://github.com/cloudevents/spec/blob/v1.0.2/cloudevents/spec.md
- [R2] OpenTelemetry Logs Data Model (SeverityNumber, Body, Attributes, Resource) — https://opentelemetry.io/docs/specs/otel/logs/data-model/
- [R3] OpenTelemetry semantic conventions for events — https://opentelemetry.io/docs/specs/semconv/general/events/
- [R4] systemd `journald.conf(5)` (`Storage=volatile`, rate limiting) and `systemd.journal-fields(7)` — https://www.freedesktop.org/software/systemd/man/latest/journald.conf.html
- [R5] `podman-events(1)` — https://docs.podman.io/en/latest/markdown/podman-events.1.html
- [R6] `podman-run(1)` (`--log-driver`, `--log-opt max-size/path`, `--sdnotify`, `--health-*`) — https://docs.podman.io/en/latest/markdown/podman-run.1.html
- [R7] `sd_notify(3)` readiness protocol — https://www.freedesktop.org/software/systemd/man/latest/sd_notify.html
- [R8] W3C Trace Context — https://www.w3.org/TR/trace-context/
- [R9] Apple Virtualization framework, `VZVirtioSocketDevice` — https://developer.apple.com/documentation/virtualization/vzvirtiosocketdevice
- [R10] Microsoft, Hyper-V sockets (integration services) — https://learn.microsoft.com/en-us/virtualization/hyper-v-on-windows/user-guide/make-integration-service
- [R11] `unix(7)`, `SO_PEERCRED` — https://man7.org/linux/man-pages/man7/unix.7.html
- [R12] Model Context Protocol specification — https://modelcontextprotocol.io/specification
- [R13] OWASP Logging Cheat Sheet — https://cheatsheetseries.owasp.org/cheatsheets/Logging_Cheat_Sheet.html
- [R14] CWE-532: Insertion of Sensitive Information into Log File — https://cwe.mitre.org/data/definitions/532.html
- [R15] OWASP Top 10 for LLM Applications, LLM01 Prompt Injection — https://genai.owasp.org/llmrisk/llm01-prompt-injection/
- [R16] `core(5)` — https://man7.org/linux/man-pages/man5/core.5.html
