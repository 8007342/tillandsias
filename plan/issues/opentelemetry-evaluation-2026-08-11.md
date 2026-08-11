# OpenTelemetry Evaluation for Loop Telemetry (682-x8df)

**Status:** `done` — decision record
**Kind:** research / decision-record (v0.6)
**Order:** 682-x8df
**Host:** linux-mutable
**Date:** 2026-08-11
**Trace:** `spec:methodology-accountability`
**Milestone:** local-telemetry-for-bottleneck-finding (682-u3si)
**Sibling rungs already shipped:** 682-m8ek (per-server MCP usage JSONL),
682-epud (per-cycle `flow:` + overhead_ratio), 682-emvg (build/test `timing:`),
distillation packet 682-43mi.

## Decision (TL;DR)

**OpenTelemetry is DECLINED for v0.6, and DEFERRED as a future-only option
gated on a concrete need the homegrown model cannot meet.** No SDK, no
collector, no OTLP endpoint is added. The milestone (682-u3si) and the
distillation packet (682-43mi) proceed on the homegrown append-then-distill
JSONL model (682-m8ek / 682-epud / 682-emvg). This is a decision record, not an
adoption — it removes OTel as a phantom dependency from the milestone.

---

## What "the loop's telemetry" is today

Three per-host, best-effort, append-only JSONL side-channels, each written by a
tiny bash function that wraps its whole append in `{ … } 2>/dev/null || true`
and always exits 0, and each read back by `scripts/cycle-metrics.sh` with `jq`
and surfaced as one pinned `key=value` line in the meta-orchestration handoff:

| rung | writer | record | reporter line |
|---|---|---|---|
| MCP usage (682-m8ek) | `images/default/config-overlay/mcp/mcp-usage-log.sh` | `{ts,server,tool,outcome,latency_ms?,confidence?,citations?}` | `mcp:` / `experts:` |
| cycle flow (682-epud) | `cycle-metrics.sh --emit-flow` | `{ts,host,batch_epic,batch_seed,batch_size,budget,claimed,completed,filed,commits,plan_open,plan_total}` | `flow:` (`overhead_ratio`) |
| build/test timing (682-emvg) | `cycle-metrics.sh --emit-timing` (+ `scripts/timing-log.sh`) | `{ts,host,step,phase,duration_ms,exit}` | `timing:` |

Invariants that any telemetry stack must honor here, taken from these files'
own headers:

1. **Best-effort by construction** — "a metric that can break what it measures
   is worse than none." Every append is fail-soft and exit-transparent.
2. **No python for committed automation** — every reader repeats
   `tlatoani_hard_no_python`; `jq` is the only parser permitted anywhere in the
   telemetry path.
3. **Append-only, per-host, non-aggregatable, CRDT-mergeable** — the milestone
   framing (682-u3si): "local-only, CRDT-append, non-aggregatable telemetry,
   distilled during multihost-orchestration, collapsed into buckets," folded
   like `plan/index.d/` fragments (G-Set / LWW; order-independent fold).
4. **Enclave forbids arbitrary egress** — the forge sits behind a squid proxy
   with an explicit `images/proxy/allowlist.txt`; only allowlisted domains
   leave (606/654 git-mirror egress work; `agent-services-egress-allowlist`).
   A live network sink is not free — it is a policy change.

These four are the lens for every question below.

---

## Q1 — Can OTel's model run LOCAL-ONLY with no live collector inside the enclave?

**Partially, in principle; poorly, in practice.**

- **OTLP + collector is a network sink and does not fit.** The OTLP exporter's
  native transports are gRPC / HTTP to a collector endpoint. Inside the enclave
  that endpoint would have to be an allowlisted host, i.e. a new standing
  service (a sidecar collector container) plus a proxy-policy change. That is
  exactly the "arbitrary egress" the enclave forbids and the opposite of the
  "local-only, no live collector" milestone. **Declined on architecture.**
- **File / stdout exporters do exist** and are the only OTel egress model that
  respects the enclave. The OTel spec defines a stdout ("console") exporter in
  every SDK, and a **File Exporter** exists but is documented as
  *development/experimental* in most language SDKs (needs verification per
  language; it is not a stability-guaranteed surface). It writes OTLP-JSON
  (protobuf-JSON encoding of `ExportTraceServiceRequest` etc.), one wrapped
  envelope per export batch — **not** a flat append-per-event JSONL. So the
  on-disk shape is OTLP resource/scope/span nesting, not our one-line-per-fact
  record. A `jq` distiller *could* walk it, but it is markedly heavier than the
  flat records we distill today.
- **Do spans/metrics map onto our records?** Loosely:
  - our `timing:` records (`step`,`duration_ms`,`exit`) are essentially
    **spans** (a span is start+duration+status+attributes) — the cleanest fit;
  - our `flow:` per-cycle counters (`completed`,`commits`,`overhead_ratio`) are
    **metrics** (counters / gauges);
  - our `mcp:` `outcome` vocabulary is **span status + attributes** or
    **log records**.
  The concepts map, but the mapping *adds* an envelope (Resource, InstrumentationScope,
  trace/span IDs, temporality) around facts we currently store as one flat line.

**Verdict Q1:** OTel can be coerced into local-only file output, but only via
an experimental exporter, and the resulting on-disk format is strictly more
complex than the flat JSONL we already distill. The one thing OTel is actually
good at — shipping to a collector — is the one thing the enclave forbids.

## Q2 — Cost of the OTel SDK in the forge images

**High and largely wasted, and it collides with a hard methodology rule.**

- **Language runtime.** OTel has no bash SDK — its "bash story is essentially
  nonexistent" is correct. Instrumenting our bash+jq loop with OTel means
  introducing a host language: Python, Node/TypeScript, Go, or Rust.
  - **Python is FORBIDDEN for committed automation** (`tlatoani_hard_no_python`,
    repeated verbatim across `cycle-metrics.sh`, `mcp-usage-log.sh`,
    `timing-log.sh`). OTel's most mature SDK is therefore off the table by rule.
  - Node/Go/Rust SDKs exist but would drag a runtime + a dependency tree into
    the forge image purely to emit telemetry the loop currently emits with
    `printf`. Image-size and build-time cost is real (SDK + exporter + protobuf
    deps); exact MB/seconds **needs verification**, but it is unambiguously
    larger than zero — today's cost is `date` + `printf` + `jq`, all already
    present.
- **Runtime deps & fail-soft.** Our appenders cannot fail the step they
  measure. An SDK with a batch processor, background export thread, and a
  network exporter is a new failure surface (export timeouts, queue backpressure)
  that we would have to defensively neuter back down to "write a line and never
  throw" — reimplementing our own constraint on top of a much larger dependency.

**Verdict Q2:** OTel forces a language runtime the forge does not want, its
best-supported SDK is forbidden by methodology, and it replaces a `printf` with
a dependency tree to produce a *superset envelope* around the same facts. Cost
is high; the marginal capability bought is near zero for this use case.

## Q3 — Does OTel's data model give us anything JSONL+jq+distill doesn't (for finding bottlenecks)?

**For THIS use case — finding orchestration bottlenecks across cycles/hosts — no.**

What OTel's model would add, and whether we need it:

- **Distributed trace context (trace/span IDs, parent links).** OTel's headline
  value is stitching one causal trace across process/service boundaries. Our
  loop is not a distributed request path; it is a sequence of per-host cycles.
  The "join" we actually want is *per-host append → coordinator distill*, which
  is a fold, not a trace. Trace context is overhead we would not query.
- **Standardized semantic conventions.** Real value *if* we intended to feed a
  third-party backend (Jaeger/Prometheus/Grafana). Inside the enclave there is
  no such backend and none is wanted. Convention without a consumer is cost.
- **Metric temporality / exemplars / aggregation.** See Q5 — this actively
  fights our CRDT model rather than helping.

What the homegrown model already gives us that OTel would not improve:

- **Pinned `key=value` grammar** that agents and CI branch on directly, with
  named anti-gaming semantics (answer_rate, overhead_ratio) tuned to *these*
  questions. This is domain telemetry, not generic telemetry.
- **Distillation into buckets during multihost-orchestration** (682-43mi) reads
  flat lines with `jq -R 'fromjson?'` — malformed rows dropped, never fatal.
  The distiller is already the "collector," offline, in-repo, python-free.

**Verdict Q3:** The bottleneck-finding job is already served better by the
purpose-built flat records than by a generic observability envelope. OTel's
differentiators (cross-service tracing, backend interop, semantic conventions)
have no consumer here.

## Q4 — If adopted: smallest first rung. If not: record why.

**NOT adopted for v0.6.** Recorded plainly so 682-43mi proceeds on the
homegrown model and the milestone carries no phantom OTel dependency.

Should a future need force reconsideration, the *smallest viable first rung*
(documented here so it need not be rediscovered) would be:

- **Scope:** the `timing:` rung only (spans are the cleanest concept-fit), one
  non-bash host binary, **file/stdout exporter only, never OTLP/collector**.
- **Version:** pin to a released OTel spec line (1.x) with a **stable** file
  exporter in the chosen non-python SDK — today that stability does not exist
  (file exporter is dev/experimental), which is itself a reason to defer.
- **Coexistence:** OTel would run *beside* the JSONL logs, not replace them —
  emit both, distill both, compare, and only retire a homegrown rung once the
  OTel path demonstrably answers the same bottleneck question fail-soft. The
  homegrown logs remain the source of truth during any such trial.

**The trigger that would justify revisiting** (none currently true): we need to
export loop telemetry to an *external* observability backend that a consumer
outside the enclave will actually read, AND the enclave grows a sanctioned
egress path for it, AND a non-python SDK ships a stable file/OTLP-file exporter.
Absent all three, homegrown wins.

## Q5 — CRDT fit: does OTel's aggregation model compose with per-host-append + coordinator-distill?

**It fights it more than it composes.**

- Our model is a **G-Set / LWW fold** of immutable per-host records
  (`plan/index.d/` semantics): merge is commutative, associative, idempotent by
  construction because nothing is ever mutated in place and every record is
  self-describing (`host`, `ts`). Re-running a distill over the same union of
  files yields the same buckets — the "favorite CRDT fashion."
- OTel's metric pipeline is built around **temporality** (delta vs cumulative)
  and **stateful aggregation in the SDK/collector**:
  - **Cumulative** metrics carry running totals with start-time semantics;
    naively unioning cumulative points from N hosts is *not* idempotent and not
    commutative under restart (counter resets, start-time realignment). This is
    the classic Prometheus staleness/reset problem — it needs a stateful
    reader, exactly what a CRDT fold avoids.
  - **Delta** temporality is closer to our append model (each record is an
    independent increment), and *could* be summed commutatively — but OTel's
    delta handling still assumes a collector doing temporal aggregation, and
    **exemplars** attach sampled trace context that has no meaning in an
    order-independent fold.
- Net: to make OTel metrics CRDT-mergeable we would restrict ourselves to delta
  temporality, discard exemplars, discard cumulative aggregation, and do the
  merge in our own distiller anyway — i.e. keep our CRDT fold and use OTel only
  as a heavier record envelope. That is all cost, no gain.

**Verdict Q5:** The homegrown append-immutable-record + coordinator-fold model
*is* a CRDT; OTel's aggregation model is stateful-collector-shaped and must be
deliberately defeated to become one. They fight.

---

## RECOMMENDATION

OpenTelemetry is DECLINED for v0.6 and deferred as a future-only option, so the
local-telemetry milestone (682-u3si) and the distillation packet (682-43mi)
proceed unblocked on the homegrown append-then-distill model shipped in 682-m8ek
/ 682-epud / 682-emvg. OTel buys this loop nothing its purpose-built flat JSONL
records do not already provide for finding orchestration bottlenecks: its one
strength — exporting to a live collector — is precisely the arbitrary network
egress the enclave forbids, its file/stdout exporters are experimental and
produce a heavier OTLP envelope around facts we already store one-line-per-event,
its only mature SDK (Python) is forbidden by the `tlatoani_hard_no_python`
methodology rule while every other SDK drags an unwanted language runtime and
dependency tree into the forge image to replace a `printf`, and its
temporality/cumulative aggregation model fights the per-host-append +
coordinator-distill CRDT fold rather than composing with it. Should a future
need ever force reconsideration, the smallest viable first rung is the `timing:`
(span) channel only, file/stdout exporter only — never OTLP or a collector —
pinned to a released 1.x spec with a *stable* non-python file exporter (which
does not exist today), run strictly beside the existing JSONL logs during any
migration and never replacing them until it demonstrably answers the same
bottleneck question fail-soft; this rung stays gated behind three triggers that
are all currently false: a real external consumer for the telemetry, a
sanctioned enclave egress path, and a stable non-python file exporter.

## Smallest first rung (recorded, not built)

`timing:`/span channel only · one non-python SDK · **file/stdout exporter only,
no OTLP, no collector** · emitted *beside* the homegrown JSONL, never replacing
it · gated on all three triggers above being true (none are today).
