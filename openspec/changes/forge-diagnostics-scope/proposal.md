# Proposal — forge-diagnostics-scope

Row: `1779-sq9g` (desired_release v0.5). Extends `runtime-diagnostics-stream`;
reconciles `external-logs-layer`; carries `log-schema-versioning`'s version on
every event. Related: `1780-jxc3` (the gate note this research produced).

## Why

Operator request (2026-10-18): give agents transparent access to the evidence
that explains their own builds, launches and services, and broadcast curated
operational facts, without exposing Vault internals or credentials. A forge
session's research (row 1779-sq9g) compared Kafka, Flume, NATS JetStream,
Redpanda, Pulsar, RabbitMQ and Redis Streams for transport, and Vector, Fluent
Bit, the OTel Collector, VictoriaLogs, Loki, ClickHouse and SQLite FTS5 for
collection and query.

Two operator rulings (2026-10-18) settle the open questions:

1. **Retention: the current forge session only.** That is already
   `runtime-diagnostics-stream`'s model: session-scoped, never persisted, a
   10K-event ring buffer. The coordinator's review dropped the broker and
   teardown-retention benchmarks: the baseline is that ring, exposed through
   the lane MCP, and a store is added only for a named query the ring cannot
   answer.
2. **Visibility: per forge, never per project or per network.** Each forge
   sees exactly:
   - (a) itself;
   - (b) the containers it started and whose lifecycle it controls (its web
     preview, its browser windows and their forwarders, its toolchain
     containers);
   - (c) curated, broadcastable events from global (shared) containers:
     producer-authored facts with no raw logs, for example a token refresh or
     a garbage-collection reap, which reach ALL concurrent forges.

   Sibling forges are not visible to each other, and neither are their
   children. Several forges run concurrently, each with its own set of web and
   other containers.

## What changes

- **Scope is the lane's, from the listener.** A forge's identity is the lane
  (`project`, `instance`) that accepted its MCP connection (order 505), never
  a caller-supplied id, label, header or query field.
- **Children are named by the host.** Every container the host starts for a
  lane carries a host-set label `tillandsias.lane=<project>/<instance>`. That
  label, set by the host at creation, is the only way a container becomes a
  forge's child.
- **Two lane MCP tools** (names are this change's proposal):
  - `forge_logs {source?, lines?}`: without `source`, the in-scope sources;
    with one, its last lines (the `service_logs` bounds: 500 lines, 64 KiB,
    15 s). A source outside the scope, and a source that does not exist,
    get the same refusal: `refused:diagnostics-scope:not-in-scope:<source>`.
  - `forge_events {cursor?}`: the forge's own lifecycle events and the global
    events published while it lived, from its session ring, with a cursor, a
    `dropped` count and a `gap` flag.
- **Global events are typed facts.** A producer publishes a `GlobalEvent`
  (kind, outcome and a small allowlisted field set); nothing reads a raw log
  to make one. It reaches the ring of every lane live at that moment.
- **Session-only.** A lane's ring is created with the lane and dropped with
  it; a new session starts empty. Overflow and truncation are reported, never
  silent.

## Impact

- `crates/tillandsias-headless`: `mcp_socket.rs` (the two tools), a new
  `forge_diagnostics.rs` (ring, scope check, global fan-out), the container
  launch sites that must set the lane label (`local_web_preview.rs`,
  `browser_open.rs`, `toolchain_exec.rs`), and the global producers
  (`vault_bootstrap.rs` token rotation first).
- `openspec/specs/runtime-diagnostics-stream/spec.md`: three added
  requirements (delta in this change).
- No new service, broker, store, host mount, tray item or UX surface.

## Non-goals

- No Kafka, Flume, JetStream or other broker; no Vector/VictoriaLogs/SQLite
  store. The research stays on the row for the day a named query outgrows the
  ring.
- No persistence across forge sessions or teardown.
- No change to `service_logs`, which keeps serving the WEB preview.
- No reading of Vault audit, entrypoint or debug logs into anything a forge
  can query.
