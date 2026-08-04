<!-- @trace spec:inference-engine-slots -->
# inference-engine-slots Specification

## Status

status: active
authored-by: order 479 (`heterogeneous-inference-specs`), spec-before-implementation
derived-from: `plan/issues/heterogeneous-inference-cpu-gpu-npu-research-2026-07-24.md`
gates: order 481 (`npu-device-passthrough`), order 482 (`llama-server-engine-slot`),
order 483 (`host-native-sidecar-endpoints`)
answers: the order-478 enclave-boundary question for host-native sidecars (risk 5)

## Purpose

Make the inference *engine* pluggable while the *endpoint* stays frozen.

Forge containers today reach exactly one address, `OLLAMA_HOST=http://inference:11434`,
and one engine, ollama. The order-478 research established that ollama cannot
use any NPU and has no roadmap to, that llama.cpp/llama-server is the correct
default engine on every host class because that is where vendor NPU backends
land upstream, and that NPUs and Apple-Silicon acceleration belong in a
host-native sidecar rather than inside the container at all.

This spec introduces the *slot*: a named, describable engine binding that sits
behind the one stable enclave endpoint. Slots may be container-resident
(ollama, llama-server variants) or host-native (a sidecar process on the host).

The host-native slot is the only construct in the runtime that puts an
inference server outside the container enclave, so this spec states its
boundary in absolute terms: the sidecar is reachable **only** behind the
enclave proxy terminus, and its introduction MUST NOT open any hole in
`spec:enclave-network` or `spec:security-privacy-isolation`.

Nothing in this spec may be implemented in Python.

## Requirements

### Requirement: SLOT-1 — One stable enclave endpoint, selectable engine behind it

Enclave consumers MUST continue to reach local inference at exactly one stable
address. `OLLAMA_HOST=http://inference:11434` MUST remain a valid consumer
contract for forge containers.

The engine bound behind that endpoint MUST be selectable. Selecting a
different engine MUST NOT change the endpoint, MUST NOT require rebuilding the
forge images, and MUST NOT require editing forge entrypoints.

@trace spec:inference-engine-slots

#### Scenario: Engine swap is invisible to forge consumers
- **WHEN** the active slot changes from `ollama` to a `llama-server` variant
- **THEN** forge containers MUST still resolve inference at
  `http://inference:11434`
- **AND** no forge image rebuild may be required for the swap to take effect

#### Scenario: Exactly one endpoint is advertised
- **WHEN** any number of slots are registered
- **THEN** exactly one enclave-facing inference endpoint MUST be advertised to
  forge containers

### Requirement: SLOT-2 — Slot contract: OpenAI-compatible surface plus the existing readiness probe

Every slot MUST present an OpenAI-compatible HTTP surface exposing at minimum
`/v1/models` and `/v1/chat/completions`.

The enclave-facing endpoint MUST additionally answer `GET /api/version`,
because `spec:async-inference-launch` makes inference a soft requirement that
forge entrypoints probe with a bounded `curl -m 1`. Whether that answer comes
from the engine itself or from a compatibility shim at the endpoint terminus
is an implementation choice; that it is answered is not.

Every slot MUST declare a descriptor carrying: slot id, engine kind, bound
device (referencing a device record from `spec:accel-capability-probe`), model
catalogue source, lane (`container` or `host-native`), and readiness URL.

@trace spec:inference-engine-slots

#### Scenario: Readiness probe contract is preserved across engines
- **WHEN** a `llama-server` slot is active and a forge entrypoint runs its
  bounded `curl -m 1` probe against `/api/version`
- **THEN** the probe MUST receive a successful response once the slot is ready
- **AND** the 1-second bound MUST remain sufficient

#### Scenario: Slot descriptor names its device
- **WHEN** a slot is registered
- **THEN** its descriptor MUST reference a device record the capability probe
  emitted
- **AND** a slot referencing a device the probe reports `usable: false` MUST
  be refused

### Requirement: SLOT-3 — Engine registry, default engine, and the NPU integration point

The registry of engine kinds MUST be `ollama`, `llama-server` (with a variant
axis of `vulkan` | `cuda` | `rocm` | `cpu`), and `host-native-sidecar`.

`ollama` MUST remain the default engine until the `llama-server` lane has
recorded smoke evidence. The default MUST be expressed as data, not as a
compiled-in constant, so promoting `llama-server` is a data change.

NPU backends MUST be integrated behind the `llama-server` engine kind or the
`host-native-sidecar` kind. An NPU lane MUST NOT be added to the `ollama`
engine kind: ollama cannot use any NPU, and pretending otherwise would let the
router place work that can never execute.

@trace spec:inference-engine-slots

#### Scenario: Default stays ollama until evidence exists
- **WHEN** no smoke evidence is recorded for the llama-server lane
- **THEN** the default engine MUST resolve to `ollama`

#### Scenario: NPU lane is refused on the ollama kind
- **WHEN** a slot descriptor binds an NPU device to engine kind `ollama`
- **THEN** the registration MUST be refused with a reason

### Requirement: SLOT-4 — Vulkan via /dev/dri is the default Linux GPU lane

For container-resident slots on Linux, the default GPU lane MUST be Vulkan
through `--device /dev/dri` with the Mesa userspace supplied by the inference
image. That lane MUST NOT require a ROCm or CUDA stack installed on the host.

Vendor-specific lanes MAY exist — CUDA through CDI, ROCm through `/dev/kfd`
plus `/dev/dri` — but MUST be selected only when the capability probe reports
that lane usable and container-reachable.

Absence of `/dev/dri` MUST degrade to the CPU lane, not fail the launch.

@trace spec:inference-engine-slots

#### Scenario: GPU acceleration with no host vendor stack
- **WHEN** a Linux host has a DRM render node and no ROCm or CUDA installation
- **THEN** the container-resident slot MUST be able to select the Vulkan lane
- **AND** the image MUST supply the Vulkan userspace

#### Scenario: No render node degrades to CPU
- **WHEN** `/dev/dri` does not exist on the host
- **THEN** the slot MUST start on the CPU lane
- **AND** the launch MUST NOT fail

### Requirement: SLOT-5 — Device passthrough for container-resident slots is graceful and unprivileged

When the capability probe reports a usable NPU and the selected slot is
container-resident, the container run arguments MUST add the device node
(`--device /dev/accel/accelN`), the render group (`--group-add`), and
`--ulimit memlock=-1:-1`.

Missing, absent, or unreadable device nodes MUST be a logged no-op: the
inference container MUST still start and MUST still serve the CPU lane.

Passthrough MUST NOT require running as root and MUST NOT modify host device
node ownership or permissions. The `root:render 0660` udev convention MUST be
documented for operators rather than enforced at runtime, because vendor udev
rules are not guaranteed to be installed by distributions.

@trace spec:inference-engine-slots

#### Scenario: Passthrough on a host with permissions in place
- **WHEN** `/dev/accel/accel0` exists and is group-readable by the render group
- **THEN** the run args MUST include the device, the render `--group-add`, and
  `--ulimit memlock=-1:-1`
- **AND** the device MUST be visible inside the container

#### Scenario: Missing device node is a no-op
- **WHEN** no `/dev/accel` node exists
- **THEN** no NPU run args may be added
- **AND** the container MUST start normally

#### Scenario: Unreadable device node never escalates
- **WHEN** the device node exists but is not readable by the invoking user
- **THEN** the runtime MUST log the condition and continue without the device
- **AND** it MUST NOT chmod, chown, or invoke a privilege escalation to obtain
  access

### Requirement: SLOT-6 — Host-native sidecar slots are reachable only behind the enclave proxy

A host-native sidecar is an inference server running as a host process. It
exists because NPUs are structurally unreachable from WSL2, because AMD and
Intel NPU stacks require host firmware and userspace lockstep, and because
Apple-Silicon acceleration in a container caps materially below native Metal.
Its introduction MUST NOT weaken enclave isolation. All of the following are
absolute:

1. The sidecar MUST bind a loopback-only host address. It MUST NOT bind
   `0.0.0.0`, `::`, or any routable host interface.
2. The `tillandsias-enclave` network MUST remain `--internal`. Registering a
   sidecar MUST NOT attach any enclave container to the default bridge, MUST
   NOT publish a host port into the enclave, and MUST NOT add
   `--network=host` to any container.
3. Enclave containers MUST reach the sidecar only through the enclave's
   existing mediating terminus — the dual-homed proxy container of
   `spec:proxy-container` / `spec:enclave-network`, or the internal reverse
   proxy of `spec:reverse-proxy-internal`. Which of those two terminates the
   route is an implementation choice left open; that the route terminates at
   one of them, and never at a new hole in the enclave, is not.
4. The route MUST be a single explicitly named upstream — one host address,
   one port. It MUST NOT be expressed as a wildcard or a subnet, and adding it
   MUST NOT widen the proxy's egress allowlist for any other destination.
5. The sidecar MUST authenticate its enclave-side caller with an ephemeral,
   per-run credential. That credential MUST NOT be written to a file readable
   by forge containers, MUST NOT appear in process argv, and MUST NOT appear
   in logs.
6. The sidecar MUST NOT receive host credentials, native keyring handles, or
   project secrets. The only data crossing the boundary is inference request
   and response payloads.
7. The sidecar MUST NOT forward, proxy, or relay any request off-host. It is
   an inference terminus, never an egress path.
8. Registration MUST be leased: an entry MUST expire when the sidecar stops
   heartbeating, and MUST be removed on application exit, leaving no listening
   socket and no persistent registration record.

@trace spec:inference-engine-slots

#### Scenario: Enclave stays internal after a sidecar registers
- **WHEN** a host-native sidecar registers and a forge container is launched
- **THEN** `podman network inspect tillandsias-enclave` MUST still report the
  network as internal
- **AND** no enclave container may have a published host port
- **AND** no enclave container may be attached to the default bridge except
  the already-dual-homed proxy

#### Scenario: Forge reaches the sidecar through the unchanged endpoint
- **WHEN** the active slot is a host-native sidecar
- **THEN** a forge container MUST reach it at the same stable inference
  endpoint
- **AND** the forge container MUST NOT be given the sidecar's host address

#### Scenario: Non-loopback sidecar bind is refused
- **WHEN** a sidecar advertises a bind address that is not loopback
- **THEN** registration MUST be refused with a reason
- **AND** no route may be created for it

#### Scenario: Sidecar route does not widen egress
- **WHEN** the sidecar route is installed at the proxy terminus
- **THEN** the only new reachable destination MUST be the single named
  sidecar host and port
- **AND** the external-domain allowlist MUST be byte-identical to what it was
  before the sidecar registered

#### Scenario: Sidecar unavailable does not block the forge
- **WHEN** the registered sidecar stops responding
- **THEN** the route MUST fail closed with an error
- **AND** forge launch MUST be unaffected, per `spec:async-inference-launch`
- **AND** `spec:inference-policy-router` MUST advance to the next candidate in
  the chain

#### Scenario: Registration is ephemeral
- **WHEN** the Tillandsias application exits
- **THEN** the sidecar registration MUST be removed
- **AND** the sidecar's route MUST no longer exist
- **AND** no registration record may survive to the next run

### Requirement: SLOT-7 — The model tier table is data consumed by every engine

The T0–T5 model tier table MUST live in a declarative, non-executable data
file that container-resident and host-native slots both read. It MUST NOT
remain inline shell inside `images/inference/entrypoint.sh`. It MUST NOT be a
Python module and MUST NOT require a Python interpreter to parse.

Each engine kind MUST be able to map a tier row to whatever artifact form it
consumes (an ollama tag, a GGUF file, a graph-compiled NPU artifact) without
the table itself naming an engine-specific format for the shared rows.

@trace spec:inference-engine-slots

#### Scenario: Both engines read one table
- **WHEN** the active slot changes between `ollama` and `llama-server`
- **THEN** both MUST resolve the same tier rows from the same data file
- **AND** neither may carry a divergent inline copy of the table

#### Scenario: Table is not executable
- **WHEN** the tier table file is inspected
- **THEN** it MUST be declarative data
- **AND** it MUST NOT require an interpreter beyond the consuming binary or
  shell's own parser

### Requirement: SLOT-8 — Slot lifecycle is idempotent, ephemeral, and soft-failing

`ensure slot` MUST be idempotent: invoking it twice MUST NOT create a second
engine process or container, MUST NOT re-download an already-cached model, and
MUST converge to the same running state.

All slots MUST be stopped on application exit. Container-resident slots MUST
be stopped per `spec:inference-container`; host-native sidecars MUST be
terminated or de-registered such that no listening socket remains.

A slot that fails readiness MUST NOT block forge launch. It MUST log a
DEGRADED condition and allow `spec:inference-policy-router` to advance the
fallback chain.

@trace spec:inference-engine-slots

#### Scenario: Double ensure is a no-op
- **WHEN** slot readiness is ensured twice in a row
- **THEN** exactly one engine instance MUST be running
- **AND** no model may be re-downloaded

#### Scenario: Exit leaves nothing running
- **WHEN** the application exits
- **THEN** no container-resident slot may remain running
- **AND** no host-native sidecar may remain listening

#### Scenario: Readiness failure is soft
- **WHEN** the selected slot never becomes ready
- **THEN** the forge session MUST still start
- **AND** a DEGRADED line MUST be logged

## Gating for dependent packets

- **Order 481 (`npu-device-passthrough`)** is gated on SLOT-5 in full. It may
  ship passthrough plumbing ahead of any NPU-capable engine, but the graceful
  no-op, the unprivileged constraint, and the render-group/memlock argument
  set are binding, and it MUST NOT add an NPU lane to the `ollama` kind
  (SLOT-3).
- **Order 482 (`llama-server-engine-slot`)** is gated on SLOT-1, SLOT-2,
  SLOT-3, SLOT-4, SLOT-7, and SLOT-8. The endpoint contract is frozen, the
  `/api/version` answer is mandatory, the Vulkan-first variant must not
  require a host vendor stack, the tier table must move out of inline shell,
  and ollama stays default until smoke evidence lands.
- **Order 483 (`host-native-sidecar-endpoints`)** is gated on SLOT-6 in full,
  plus SLOT-2 and SLOT-8. Every one of SLOT-6's eight clauses is a
  pass/fail gate; a lane that cannot satisfy loopback-only binding,
  proxy-terminated routing, single named upstream, ephemeral credential,
  no-egress, and leased registration MUST NOT ship. The FastFlowLM licence
  gate and the XRT/firmware lockstep risk from order 478 are carried into
  that packet as recorded preconditions, not as spec text.

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:inference-engine-slot-boundary-shape` — pins the frozen endpoint, the
  sidecar isolation clauses, the Vulkan-first default, the no-NPU-on-ollama
  rule, and the NPU tier rows in `spec:inference-container`
- `litmus:enclave-isolation` — the enclave remains internal-only with no
  external network access after a sidecar exists

Gating points:
- Exactly one enclave-facing inference endpoint; `OLLAMA_HOST=http://inference:11434`
  still resolves
- `/api/version` answered by whatever engine is bound
- Host-native sidecar binds loopback only; enclave network stays `--internal`;
  no published ports; no `--network=host`
- Sidecar route is a single named upstream at the proxy terminus and widens no
  allowlist
- Sidecar registration is leased and removed on exit
- NPU device args are added only when the probe says usable, and are a no-op
  otherwise
- No Python in any slot implementation or in the tier table

## Sources of Truth

- `plan/issues/heterogeneous-inference-cpu-gpu-npu-research-2026-07-24.md` —
  order 478 research deliverable; engine matrix, sidecar verdict, and the
  enclave-boundary risk this spec answers
- `cheatsheets/runtime/local-inference.md` — Local Inference reference and
  patterns
- `cheatsheets/runtime/container-gpu.md` — Container GPU reference and patterns

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:inference-engine-slots" crates/ scripts/ images/ --include="*.rs" --include="*.sh"
```
