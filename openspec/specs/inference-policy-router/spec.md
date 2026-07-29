<!-- @trace spec:inference-policy-router -->
# inference-policy-router Specification

## Status

status: active
authored-by: order 479 (`heterogeneous-inference-specs`), spec-before-implementation
derived-from: `plan/issues/heterogeneous-inference-cpu-gpu-npu-research-2026-07-24.md`
gates: order 484 (`inference-policy-router`)

## Purpose

Decide, transparently and without operator configuration, which device, which
engine slot, and which model tier serve a given inference request — and revise
that decision when the machine's power and thermal situation changes.

The operator intent behind order 478 was "auto-detect and run what's best for
every scenario (long-running low-energy vs quick interactions vs max results)
and support CPU/GPU/NPU transparently out of the box." This spec is that
layer. It routes only on measured facts from `spec:accel-capability-probe`, it
places work only on slots declared by `spec:inference-engine-slots`, and it
carries the research's non-goals as binding prohibitions rather than as advice.

Nothing in this spec may be implemented in Python — neither the router nor its
routing table nor its test fixtures.

## Requirements

### Requirement: CLASS-1 — Four workload classes with declared objectives

The router MUST recognise exactly four workload classes, each with a single
declared objective:

| Class | Objective | Preemptible |
|---|---|---|
| `background` | minimise joules per token | yes |
| `interactive` | minimise time to first token | no |
| `quality` | maximise capability of the largest model that fits | no |
| `sustained` | maximise steady-state tokens/second under thermal load | no |

Every routed request MUST carry exactly one class. A request that does not
declare a class MUST be routed as `interactive`. Additional classes MUST NOT
be introduced without a change to this spec.

@trace spec:inference-policy-router

#### Scenario: Unclassified request defaults to interactive
- **WHEN** a request arrives with no declared workload class
- **THEN** the router MUST route it as `interactive`

#### Scenario: Background prefers energy over speed
- **WHEN** a `background` request has two viable placements, one faster and
  one with lower measured joules per token
- **THEN** the router MUST select the lower-energy placement
- **AND** the decision reason MUST name the energy measurement it used

#### Scenario: Sustained prefers throttle-resistant placement
- **WHEN** a `sustained` request has a placement whose measured throughput is
  stable under load and one whose throughput degrades
- **THEN** the router MUST select the stable placement

### Requirement: ROUTE-1 — The routing table is data and route() is a pure function

The routing table MUST be a declarative data file (TOML), not code. Adding,
reordering, or removing a placement preference MUST NOT require recompiling
the runtime.

The routing decision MUST be expressed as a pure function of (capability
document, current power/thermal signals, workload class, model catalogue).
It MUST perform no I/O, so it is exhaustively testable over serialized
fixtures.

Neither the table nor the decision function may be Python, and neither may
require a Python interpreter.

@trace spec:inference-policy-router

#### Scenario: Routing is testable over fixtures
- **WHEN** a serialized capability document and a serialized signal snapshot
  are supplied to the decision function
- **THEN** it MUST produce a placement with no filesystem, D-Bus, or network
  access
- **AND** the same inputs MUST always produce the same placement

#### Scenario: Preference change is a data change
- **WHEN** an operator reorders a preference in the routing table
- **THEN** the new order MUST take effect without recompiling

### Requirement: ROUTE-2 — Placements are ordered fallback chains terminating in CPU tier-S

Every placement MUST be an ordered list of candidate (device, slot,
model-tier) triples.

Every chain MUST terminate in the **CPU tier-S terminal**: execution of the
T0 model on the CPU lane, as defined by `spec:inference-container`. Tier-S is
always available on every host and MUST NOT be removed from, or reordered out
of, any chain.

A chain that does not terminate in tier-S MUST be rejected when the routing
table is loaded — a configuration error at load time, never a surprise at
request time.

@trace spec:inference-policy-router

#### Scenario: Every chain ends at tier-S
- **WHEN** the routing table is loaded
- **THEN** every chain MUST have the CPU tier-S terminal as its final
  candidate

#### Scenario: A chain without tier-S is rejected at load
- **WHEN** a routing table contains a chain whose last candidate is not the
  CPU tier-S terminal
- **THEN** loading MUST fail with a configuration error
- **AND** the previously valid table MUST remain in effect

#### Scenario: Total accelerator failure still serves
- **WHEN** every accelerator candidate in a chain fails
- **THEN** the request MUST still be served by CPU tier-S

### Requirement: ROUTE-3 — Failures advance the chain; three strikes quarantine the device

A placement failure — engine error, out-of-memory, device unavailable, or
readiness timeout — MUST advance the request to the next candidate in its
chain.

Three consecutive failures on the same (device, slot) pair MUST quarantine
that pair until the next capability re-probe. Quarantine MUST be observable
through the status surface of ADAPT-4 and MUST NOT be silent. A quarantined
pair MUST NOT be retried by later requests in the same session.

@trace spec:inference-policy-router

#### Scenario: Single failure advances
- **WHEN** the preferred candidate returns an engine error
- **THEN** the router MUST retry on the next candidate in the chain
- **AND** the request MUST still be served if any candidate succeeds

#### Scenario: Third consecutive failure quarantines
- **WHEN** the same (device, slot) pair fails three times consecutively
- **THEN** it MUST be quarantined until the next re-probe
- **AND** the quarantine and its reason MUST appear in the status surface

#### Scenario: Quarantine survives until re-probe
- **WHEN** a later request in the same session would prefer a quarantined pair
- **THEN** the router MUST skip it without attempting it

### Requirement: ROUTE-4 — A model must fit device-visible memory with at least 10% headroom

The router MUST NOT place a model whose resident size exceeds 90% of the
memory the chosen device can actually address — dedicated VRAM for a discrete
GPU, and the probe's device-visible pool for unified-memory systems.

NPU placements MUST additionally respect the engine's declared parameter and
context ceilings; a model or context exceeding them MUST NOT be placed on that
NPU.

A headroom or ceiling violation MUST advance the chain rather than attempt the
placement and fail on out-of-memory.

@trace spec:inference-policy-router

#### Scenario: Model too large for the device is skipped, not attempted
- **WHEN** the preferred model's resident size exceeds 90% of the candidate
  device's addressable memory
- **THEN** the router MUST advance to the next candidate
- **AND** MUST NOT start a load that would out-of-memory

#### Scenario: NPU context ceiling is respected
- **WHEN** a request's context exceeds the NPU engine's declared context
  ceiling
- **THEN** the NPU candidate MUST be skipped

### Requirement: ROUTE-5 — First request is served from a resident small model while the preferred model loads

When the preferred placement requires loading a model that is not yet
resident, the router MUST serve the first request from an already-resident
small model (tier-S, T0, or T1) and MUST switch to the preferred placement
only once it is ready.

The switch MUST NOT interrupt an in-flight response. Which model actually
answered MUST be observable to the caller.

@trace spec:inference-policy-router

#### Scenario: Cold preferred model does not stall the first answer
- **WHEN** the preferred placement's model is not yet loaded
- **THEN** the first request MUST be answered by a resident small model
- **AND** the preferred model MUST load concurrently

#### Scenario: Switch does not truncate a response
- **WHEN** the preferred model becomes ready while a response is streaming
- **THEN** the in-flight response MUST complete on the model that started it

### Requirement: ADAPT-1 — Power and thermal signals are subscribed, not polled-only

On Linux the router MUST subscribe to UPower and PowerProfiles D-Bus
`PropertiesChanged` signals, and the subscription MUST work with both
`power-profiles-daemon` and Fedora's `tuned-ppd`.

On macOS it MUST use `NSProcessInfo` power and thermal notifications; on
Windows it MUST use `EffectivePowerMode`.

Polled sources — battery state, thermal trip points, GPU busy percentage —
MAY supplement the subscription but MUST NOT be the only source of truth.

When no signal source is available the router MUST degrade to "on AC, thermal
nominal" defaults with a logged warning. Missing signals MUST NOT be a hard
failure and MUST NOT suspend work.

@trace spec:inference-policy-router

#### Scenario: Both power daemons are supported
- **WHEN** the host runs `tuned-ppd` instead of `power-profiles-daemon`
- **THEN** profile changes MUST still reach the router

#### Scenario: No signal source degrades safely
- **WHEN** neither power daemon nor battery information is available
- **THEN** the router MUST assume AC power and nominal thermals
- **AND** MUST log a warning rather than fail

### Requirement: ADAPT-2 — On battery or power-saver, background work suspends within 5 seconds

On a transition to battery power or to a power-saver profile, the router MUST,
within 5 seconds of receiving the signal:

1. Checkpoint and suspend all `background`-class work, losing no completed
   work;
2. Downgrade `interactive` placements to a smaller model tier or a
   lower-power device;
3. Cap context lengths.

Background engine processes MUST self-tag as low priority: `SCHED_IDLE` on
Linux, EcoQoS on Windows, background QoS on macOS.

@trace spec:inference-policy-router

#### Scenario: Unplugging suspends background work promptly
- **WHEN** the host transitions from AC to battery
- **THEN** background-class work MUST be checkpointed and suspended within
  5 seconds
- **AND** no completed background work may be lost

#### Scenario: Interactive degrades rather than stops
- **WHEN** the host is on battery
- **THEN** interactive requests MUST still be served, at a smaller tier or on
  a lower-power device

#### Scenario: Background engines run at idle priority
- **WHEN** a background-class engine process is started on Linux
- **THEN** it MUST self-tag `SCHED_IDLE`

### Requirement: ADAPT-3 — Background work resumes only on AC and thermal-nominal and idle

Suspended background work MUST resume only when all three of the following
hold simultaneously: the host is on AC power, thermals are nominal, and there
has been no interactive request for at least 60 seconds.

Any one condition failing MUST keep background work suspended.

@trace spec:inference-policy-router

#### Scenario: AC alone does not resume
- **WHEN** the host returns to AC power but an interactive request arrived
  10 seconds ago
- **THEN** background work MUST remain suspended

#### Scenario: All three conditions resume
- **WHEN** the host is on AC, thermals are nominal, and no interactive request
  has arrived for 60 seconds
- **THEN** background work MUST resume from its checkpoint

### Requirement: ADAPT-4 — Status surface and pin override with auto-release

The router MUST expose a `policy status` surface reporting, at minimum: the
current placement per workload class with the reason it was chosen, all
quarantined (device, slot) pairs with their reasons, the current power and
thermal signal values, and any active pin.

An operator MUST be able to pin a placement. A pin MUST have auto-release hold
semantics — it expires — and MUST NOT survive an application restart. A pin
MUST NOT be able to select a device the capability probe reports
`usable: false`.

@trace spec:inference-policy-router

#### Scenario: Status explains the choice
- **WHEN** an operator queries `policy status`
- **THEN** the output MUST name the chosen device, slot, and model tier per
  class, and the reason each was chosen

#### Scenario: Pin expires on its own
- **WHEN** an operator pins a placement and then takes no further action
- **THEN** the pin MUST auto-release after its hold expires

#### Scenario: Pin cannot select an unusable device
- **WHEN** an operator pins a device whose capability record is
  `usable: false`
- **THEN** the pin MUST be refused with the device's `unusable_reason`

#### Scenario: Pin does not survive restart
- **WHEN** the application restarts with a pin previously active
- **THEN** no pin may be in effect after restart

### Requirement: NEG-1 — Non-goals are binding prohibitions

The following are prohibited, not merely deprioritised:

1. **No per-operator graph splitting across devices.** Splitting an inference
   graph operator-by-operator between CPU, GPU, and NPU belongs inside
   engines, is research-grade today, and MUST NOT be implemented in the
   router.
2. **No vendor-TOPS-based routing.** Vendor-published TOPS figures and
   marketing throughput numbers MUST NOT be routing inputs. Independent
   measurement showed vendor multiples are not reproduced in practice. Only
   measured values from `spec:accel-capability-probe` may be routed on.
3. **No idle model residency on battery.** A model MUST NOT be kept resident
   on an accelerator while idle and on battery power.

Additionally, hybrid phase-splitting (NPU prefill handed to iGPU decode) ships
only on Windows vendor stacks. The router MUST NOT assume phase-split
availability on Linux, where NPU-only flows are the supported shape.

@trace spec:inference-policy-router

#### Scenario: TOPS is not a routing input
- **WHEN** a device advertises a large TOPS figure and has no measured score
- **THEN** the router MUST NOT prefer it over a device with a measured score

#### Scenario: Idle on battery evicts residency
- **WHEN** the host is on battery and no request has been routed for the idle
  threshold
- **THEN** any accelerator-resident model MUST be released

#### Scenario: No phase-split assumption on Linux
- **WHEN** routing on a Linux host with both an NPU and an iGPU
- **THEN** the router MUST place the whole request on one device
- **AND** MUST NOT attempt to run prefill and decode on different devices

### Requirement: NEG-2 — Degraded lanes never outrank healthy ones

A (device, engine) lane the capability probe marked `degraded: true` — a
measured decode below 30% of its bandwidth roofline — MUST NOT be preferred
over a non-degraded lane, regardless of the nominal capability of the
underlying silicon.

@trace spec:inference-policy-router

#### Scenario: Immature NPU loses to healthy Vulkan
- **WHEN** an NPU lane is marked degraded and a Vulkan GPU lane is not
- **THEN** the router MUST prefer the Vulkan lane for every workload class,
  including `background`

## Gating for dependent packets

- **Order 484 (`inference-policy-router`)** is gated on this spec in full.
  Its separable checkpoints map as follows: classes and table → CLASS-1,
  ROUTE-1, ROUTE-2; signal watcher → ADAPT-1; preemption → ADAPT-2, ADAPT-3;
  observability surface → ADAPT-4. ROUTE-3, ROUTE-4, and ROUTE-5 are
  required before the router may be made the default decision path. NEG-1 and
  NEG-2 are pass/fail scope guards on every checkpoint.
- Order 484 additionally depends on `spec:accel-capability-probe` (it may
  route only on that document) and on `spec:inference-engine-slots` (it may
  place work only on declared slots).

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:inference-policy-router-invariants-shape` — pins the CPU tier-S
  terminal, the 10% headroom rule, the three-strike quarantine, the 5-second
  suspend and 60-second resume thresholds, the three NEG prohibitions, and the
  no-Python constraint

Gating points:
- Exactly four workload classes; unclassified requests route as `interactive`
- Routing table is TOML data; `route()` is pure and fixture-testable
- Every chain terminates in the CPU tier-S terminal or the table fails to load
- Failures advance the chain; three strikes quarantine until re-probe
- Models fit device-visible memory with at least 10% headroom
- Background suspends within 5 s of a battery/power-saver signal and resumes
  only on AC and thermal-nominal and 60 s interactive idle
- No per-op splitting, no vendor-TOPS routing, no idle residency on battery
- No Python in the router, the table, or the fixtures

## Sources of Truth

- `plan/issues/heterogeneous-inference-cpu-gpu-npu-research-2026-07-24.md` —
  order 478 research deliverable; policy prior art, energy measurements, and
  the CLASS/ROUTE/ADAPT/NEG requirement seeds
- `cheatsheets/runtime/local-inference.md` — Local Inference reference and
  patterns
- `cheatsheets/runtime/async-patterns-rust.md` — task lifecycle and
  fire-and-forget patterns for the signal watcher

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:inference-policy-router" crates/ scripts/ images/ --include="*.rs" --include="*.sh"
```
