---
tags: [event-driven, architecture, async, decoupling, message-bus, eda]
languages: []
since: 2026-04-25
last_verified: 2026-04-25
sources:
  - https://martinfowler.com/articles/201701-event-driven.html
  - https://martinfowler.com/eaaDev/EventCollaboration.html
  - https://en.wikipedia.org/wiki/Event-driven_architecture
authority: medium
status: current
---

# Event-driven architecture (the basics)

@trace spec:agent-cheatsheets
@cheatsheet patterns/gof-observer.md, architecture/reactive-streams-spec.md

## Provenance

- Martin Fowler, "What do you mean by 'Event-Driven'?": <https://martinfowler.com/articles/201701-event-driven.html> — clarifies the four distinct things people mean by EDA
- Martin Fowler, "Event Collaboration": <https://martinfowler.com/eaaDev/EventCollaboration.html>
- Wikipedia, "Event-driven architecture": <https://en.wikipedia.org/wiki/Event-driven_architecture>
- **Last updated:** 2026-04-25

## Use when

Your system has multiple components that react to state changes happening elsewhere, AND coupling them via direct method calls would create a tangle. EDA exchanges direct coupling for **temporal coupling** (everyone sees the event eventually) and **structural coupling** through the event schema.

## Fowler's four meanings of "event-driven"

Per the cited Fowler 2017 article — these are different patterns often conflated:

1. **Event Notification** — a component fires "X happened" events; consumers react. No state in the event beyond the bare minimum to identify what occurred. Consumer pulls detail if needed.
2. **Event-Carried State Transfer** — events carry the new state. Consumers stay in sync without back-querying the source. Trade-off: bigger events, eventual consistency model.
3. **Event Sourcing** — the event log IS the database. Current state is derived by replaying events. Audit trail comes for free.
4. **CQRS (Command-Query Responsibility Segregation)** — separates the write model (commands → events) from the read model (queries against projections). Often paired with event sourcing.

Most projects start with #1 (Event Notification) and consider #2/#3/#4 only when the gain is concrete.

## Quick reference

| Concept | Glossary |
|---|---|
| Event | Immutable fact: "OrderPlaced", "TemperatureExceeded" — past tense, never imperative |
| Command | Imperative ask: "PlaceOrder" — may be rejected; not the same as an event |
| Producer | Component that fires events |
| Consumer | Component that reacts; usually does NOT acknowledge back to producer |
| Broker / bus | The transport (Kafka, RabbitMQ, Redis Pub/Sub, in-memory channel) |
| Topic / channel | Name producers/consumers agree on |
| Schema | Event shape contract — versioned (Avro, Protobuf, JSON Schema) |

## Common patterns

### Pattern 1 — in-process: GoF Observer (the simplest EDA)

When all consumers live in the same process, a plain Observer (`patterns/gof-observer.md`) IS event-driven architecture. No broker needed.

### Pattern 2 — same process, async: Reactive Streams

For streams where backpressure matters, see `architecture/reactive-streams-spec.md`. Still in-process, no broker.

### Pattern 3 — cross-process: message broker

```text
[Service A] --publish--> [topic: order.placed] --subscribe--> [Service B]
                                                            └--> [Service C]
```

Brokers (rough trade-off table):

| Broker | Strengths | Trade-offs |
|---|---|---|
| Apache Kafka | Massive throughput, ordered partitions, replayable log | Operational complexity, JVM stack |
| RabbitMQ | Mature routing, multi-protocol, easy ops | Lower throughput than Kafka |
| Redis Pub/Sub | Tiny, in-memory | No durability, no replay |
| NATS / NATS JetStream | Lightweight, multi-tenant | Smaller ecosystem |
| Cloud-managed (SNS/SQS, EventBridge, Pub/Sub) | Zero-ops | Vendor lock-in, latency |

## Common pitfalls

- **Using events as RPC** — "fire an event and wait for the response event" is RPC with extra steps. Use real RPC (gRPC, HTTP) for synchronous semantics.
- **Event payload becomes a god-object** — every team adds a field; nobody removes one. Version your event schema (Avro/Protobuf evolution rules) and treat the schema like an API.
- **Consumers depend on producer-internal IDs / sequencing** — couples them through implementation. Use stable, public event identifiers.
- **No idempotency** — at-least-once delivery means the same event arrives twice. Consumers MUST be idempotent (deduplicate by event ID, or design operations idempotent).
- **Out-of-order delivery** — most brokers don't guarantee global order across partitions. Either accept it (commutative operations) or partition by entity ID (Kafka style).
- **"Eventual consistency" without measurement** — eventual ≠ never. Add lag metrics, alert when consumers fall behind.
- **Cascading failures** — one slow consumer blocks broker disk → producer back-pressures → upstream stalls. Design DLQ (dead-letter queue) and consumer-side circuit breakers.
- **Mixing event-carried state with event sourcing** — they're orthogonal but often conflated. Event sourcing means events are the source of truth; ECST means events carry state. Pick what you actually need.

## See also

- `patterns/gof-observer.md` — in-process building block
- `architecture/reactive-streams-spec.md` — backpressure for stream consumers
- `web/protobuf.md` (DRAFT) — schema versioning for events
- `data/postgresql-indexing-basics.md` — for projections-as-DB queries (CQRS read side)
