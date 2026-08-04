<!-- @trace spec:accel-capability-probe -->
# accel-capability-probe Specification

## Status

status: active
authored-by: order 479 (`heterogeneous-inference-specs`), spec-before-implementation
derived-from: `plan/issues/heterogeneous-inference-cpu-gpu-npu-research-2026-07-24.md`
gates: order 480 (`accel-capability-probe`), order 481 (`npu-device-passthrough`),
order 483 (`host-native-sidecar-endpoints`), order 484 (`inference-policy-router`)

## Purpose

Replace the single-string inference tier (`detect_inference_tier()` →
`metal|gpu-cuda|gpu-rocm|cpu`) with a structured, versioned, host-side
capability document describing every execution device the host actually has,
which engine lanes can reach each one, and how fast each combination measured.

The document is the sole input surface that `spec:inference-engine-slots` and
`spec:inference-policy-router` are allowed to route on. It exists because the
order-478 research established two facts a string cannot express: (1) a device
being *present* says nothing about it being *usable* — an immature NPU lane
runs 3-10x below roofline and burns an order of magnitude more energy per
token than the same host's Vulkan lane; and (2) decode throughput is
memory-bandwidth-bound, so bandwidth is a first-class routed quantity, while
vendor TOPS is not a routable quantity at all.

Nothing in this spec may be implemented in Python.

## Requirements

### Requirement: PROBE-1 — Structured capability document replaces the string tier

The host MUST emit a machine-readable capability document (`capabilities.json`)
carrying an integer `schema_version`, a device inventory, an engine inventory,
and a measurement section. Consumers MUST read the structured fields; no
consumer may re-derive capability by re-running ad-hoc vendor tool probes.

The document MUST retain a derived `legacy_tier` string field whose value is
exactly what `effective_inference_tier()` returns today
(`metal` | `gpu-cuda` | `gpu-rocm` | `cpu`), so the CDI-absence downgrade
behaviour established by order 392 and the `TILLANDSIAS_INFERENCE_TIER`
container env contract keep working unchanged during and after the migration.

The probe and the document MUST NOT be produced by, or require, a Python
interpreter.

@trace spec:accel-capability-probe

#### Scenario: Probe emits a versioned document
- **WHEN** the capability probe runs on any supported host
- **THEN** it MUST write a `capabilities.json` containing an integer
  `schema_version`, a `devices` array, an `engines` array, and a
  `measurements` section
- **AND** the file MUST parse as JSON with no interpreter beyond the host
  binary itself

#### Scenario: Legacy tier string survives as a derived field
- **WHEN** the document is produced on a host where `nvidia-smi` succeeds and
  the NVIDIA CDI spec is present
- **THEN** `legacy_tier` MUST equal `gpu-cuda`
- **AND** `TILLANDSIAS_INFERENCE_TIER` passed to the inference container MUST
  be derivable from `legacy_tier` without additional probing

#### Scenario: CDI absence still downgrades
- **WHEN** an NVIDIA GPU is present but no CDI spec is installed
- **THEN** the CUDA device record MUST NOT be marked reachable from the
  `container` lane
- **AND** `legacy_tier` MUST downgrade exactly as `effective_inference_tier()`
  downgrades today

### Requirement: PROBE-2 — Device enumeration is explicit and vendor-resolved

The probe MUST enumerate, on Linux:

1. CPU: ISA feature flags relevant to inference kernels (at minimum the
   presence/absence of AVX-512 on x86_64 and of NEON/SVE on aarch64),
   physical and logical core counts, and total system RAM.
2. GPUs: every node under `/sys/class/drm`, plus a Vulkan-availability check
   distinguishing "DRM node present" from "a Vulkan device is actually
   enumerable".
3. NPUs: every node under `/sys/class/accel/accel*`, with the vendor resolved
   from the `DRIVER=` field of the device `uevent` — `amdxdna` MUST resolve to
   AMD XDNA and `intel_vpu` MUST resolve to Intel NPU — recording
   `fw_version` where the driver exposes it.
4. Battery presence (whether the host can ever be on battery power).

The probe MUST NOT infer an NPU's vendor from the node index, from a
marketing/product string, or from CPU model name. A `DRIVER=` value the probe
does not recognise MUST be recorded verbatim with `vendor: "unknown"` rather
than dropped, so a newly merged in-tree accel driver is visible as an unknown
device instead of invisible.

Absence of the accel class MUST be a normal, non-error outcome: hosts whose
kernel lacks `CONFIG_DRM_ACCEL` (notably the WSL2 kernel) MUST yield an empty
NPU list and a successful probe.

@trace spec:accel-capability-probe

#### Scenario: AMD XDNA2 host
- **WHEN** the probe runs on a host exposing `/sys/class/accel/accel0` whose
  `device/uevent` contains `DRIVER=amdxdna`
- **THEN** the document MUST contain one NPU record with vendor resolved to
  AMD XDNA and the device node path recorded
- **AND** the record MUST carry `fw_version` when the driver exposes it

#### Scenario: Intel NPU host
- **WHEN** `device/uevent` contains `DRIVER=intel_vpu`
- **THEN** the vendor MUST resolve to Intel NPU

#### Scenario: Unrecognised accel driver is recorded, not dropped
- **WHEN** an accel node reports a `DRIVER=` value the probe does not know
- **THEN** the record MUST be emitted with the driver string verbatim and
  `vendor: "unknown"`
- **AND** the record MUST carry `usable: false`

#### Scenario: Kernel without the accel class
- **WHEN** the probe runs where `/sys/class/accel` does not exist (e.g. under
  WSL2)
- **THEN** the NPU list MUST be empty
- **AND** the probe MUST exit successfully, not error

### Requirement: PROBE-3 — Engine inventory gates usability

Every device record MUST carry a boolean `usable`. `usable` MUST be `false`
unless the probe can name at least one engine lane that is (a) actually
installed or bundled on this host or in the selected inference image, and
(b) a graph-compiled/mature backend for that device class rather than an
experimental one.

A device that is present but not usable MUST be recorded with `usable: false`
and a machine-readable `unusable_reason` (for example `engine-missing`,
`engine-experimental`, `driver-too-old`, `permission-denied`,
`firmware-mismatch`).

Vendor-published TOPS, marketing throughput figures, or product-tier names
MUST NOT contribute to `usable`, and MUST NOT appear as a routable field
anywhere in the document.

@trace spec:accel-capability-probe

#### Scenario: NPU present but no engine lane installed
- **WHEN** an `amdxdna` accel node is present and no mature engine for it is
  installed
- **THEN** the record MUST be `usable: false` with
  `unusable_reason: "engine-missing"`
- **AND** `spec:inference-policy-router` MUST NOT place work on it

#### Scenario: NPU becomes usable when a mature lane appears
- **WHEN** a graph-compiled engine lane for that device is present and named
  in the engine inventory
- **THEN** the record MAY be `usable: true`
- **AND** the engine that justified it MUST be named in the record

#### Scenario: Vendor TOPS cannot promote a device
- **WHEN** a device advertises a high TOPS figure and has no mature engine
  lane
- **THEN** `usable` MUST remain `false`

### Requirement: PROBE-4 — Memory bandwidth is recorded as a first-class quantity

Because token decode converges toward `memory_bandwidth / model_bytes` on
shared-memory systems, the document MUST record `memory_bandwidth_gbps` with a
`source` field of `soc-table`, `measured`, or `unknown`. The probe SHOULD
refine a table value with a bounded measurement. The probe MUST NOT fabricate
a numeric bandwidth when it is unknown — it MUST record `unknown` and let the
router treat bandwidth as unavailable.

@trace spec:accel-capability-probe

#### Scenario: Unknown bandwidth is recorded as unknown
- **WHEN** the host SoC is not in the bandwidth table and no measurement ran
- **THEN** `memory_bandwidth_gbps` MUST be null with `source: "unknown"`
- **AND** the roofline check of PROBE-6 MUST be skipped rather than computed
  from a guess

### Requirement: PROBE-5 — Microbenchmarks are bounded, one-time, and degrade gracefully

The probe MAY run at most one microbenchmark per (device, engine) pair. Each
microbenchmark MUST be bounded to 60 seconds of wall-clock time, MUST be
abortable, and MUST record `prefill_tps`, `decode_tps`, and
`joules_per_token`.

Energy measurement MUST degrade gracefully: `/sys/class/powercap/**/energy_uj`
is root-only since CVE-2020-8694, so when it is unreadable the probe MUST
record `joules_per_token: null` and continue. The probe MUST NOT escalate
privilege per sample and MUST NOT fail the probe because energy is
unavailable.

@trace spec:accel-capability-probe

#### Scenario: Microbenchmark cannot exceed its budget
- **WHEN** a device/engine microbenchmark is started
- **THEN** it MUST be terminated at or before 60 seconds
- **AND** a truncated run MUST be recorded as incomplete rather than as a
  measured score

#### Scenario: Energy counters unreadable
- **WHEN** RAPL energy counters are not readable by the invoking user
- **THEN** `joules_per_token` MUST be null
- **AND** the throughput fields MUST still be recorded

### Requirement: PROBE-6 — Roofline sanity check flags degraded lanes

When bandwidth is known, the probe MUST compute a roofline decode ceiling of
`memory_bandwidth_bytes_per_second / model_bytes` and compare it against the
measured `decode_tps`. A measured decode below 30% of the roofline MUST set
`degraded: true` on that (device, engine) measurement with a reason.

A lane marked `degraded` MUST NOT be preferred by
`spec:inference-policy-router` over a non-degraded lane, even when the
degraded lane sits on nominally more capable silicon. This encodes the
research counter-example in which an immature NPU backend delivered 4.1 t/s at
16.2 J/token while the same host's Vulkan lane delivered 43.8 t/s at
0.95 J/token.

@trace spec:accel-capability-probe

#### Scenario: Immature backend is flagged
- **WHEN** a lane's measured decode is under 30% of its roofline ceiling
- **THEN** the measurement MUST carry `degraded: true` and a reason
- **AND** the routing table MUST see it as degraded

#### Scenario: Roofline skipped when bandwidth is unknown
- **WHEN** `memory_bandwidth_gbps` has `source: "unknown"`
- **THEN** no `degraded` verdict may be derived from a roofline comparison

### Requirement: PROBE-7 — The probe runs on the host and records per-lane reachability

The capability probe MUST execute on the HOST, not inside a forge or inference
container. For every device the document MUST record which execution lanes can
actually reach it, from the set `container` (the device node is or can be
passed into the inference container), `host-native` (only a host process can
reach it), and `none`.

The probe MUST NOT assume host visibility implies container visibility. A
device visible on the host but not passed through MUST NOT be recorded as
`container`-reachable.

Apple Silicon Metal and the Apple Neural Engine MUST be recorded as
`host-native` only, never `container`, because Linux VMs do not see Metal or
ANE natively and the in-VM Venus path caps materially below native.

@trace spec:accel-capability-probe

#### Scenario: NPU present but not passed through
- **WHEN** a usable NPU exists on the host and the inference container is
  launched without its device node
- **THEN** the device's lanes MUST be `["host-native"]`
- **AND** the router MUST only consider host-native slots for it

#### Scenario: macOS acceleration is host-native only
- **WHEN** the probe runs on macOS
- **THEN** Metal and ANE device records MUST have lanes `["host-native"]`
- **AND** `container` MUST NOT appear in their lane list

### Requirement: PROBE-8 — The capability cache is derived, ephemeral, and self-invalidating

`capabilities.json` is a DERIVED cache, not user data. It MUST live under the
application cache directory. Deleting it MUST be safe and MUST cause a
re-probe on next use. Probing MUST be idempotent: two consecutive probes on
unchanged hardware MUST produce identical device, vendor, `usable`, and lane
fields; only the measurement and timestamp fields may vary.

The cache MUST be invalidated and re-probed when any of the following change:
`schema_version`, kernel release, driver or firmware version of any enumerated
device, the engine inventory, or the device set itself.

The document MUST NOT contain secrets, device serial numbers, or host
identifiers beyond what routing requires.

@trace spec:accel-capability-probe

#### Scenario: Cache deletion is safe
- **WHEN** `capabilities.json` is deleted
- **THEN** the next consumer MUST trigger a fresh probe
- **AND** no consumer may fail because the cache was absent

#### Scenario: Driver upgrade invalidates the cache
- **WHEN** an enumerated device's driver or firmware version changes
- **THEN** the cached document MUST be treated as stale and re-probed

#### Scenario: Repeated probes are idempotent
- **WHEN** the probe runs twice with no hardware, driver, or engine change
- **THEN** the device set, vendors, `usable` flags, and lane lists MUST be
  identical between the two documents

## Gating for dependent packets

- **Order 480 (`accel-capability-probe`)** is gated on PROBE-1 through PROBE-8
  in full. It MUST NOT ship a structured probe that omits `usable`,
  `unusable_reason`, per-device lanes, or the derived `legacy_tier`.
- **Order 481 (`npu-device-passthrough`)** is gated on PROBE-2 (node + vendor
  resolution) and PROBE-7 (lane reachability): passthrough may only be built
  for devices the probe enumerated and MUST flip that device's lane list to
  include `container` once passthrough succeeds.
- **Order 483 (`host-native-sidecar-endpoints`)** is gated on PROBE-3 and
  PROBE-7: a sidecar lane may only be offered for a device the probe reports
  `usable: true` with `host-native` in its lanes.
- **Order 484 (`inference-policy-router`)** is gated on PROBE-3, PROBE-4,
  PROBE-5, and PROBE-6: the router routes on `usable`, bandwidth, measured
  scores, and the `degraded` flag, and on nothing else.

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:accel-capability-probe-contract-shape` — pins the usability gate, the
  vendor-resolution surface, the roofline threshold, the graceful-energy rule,
  and the no-Python constraint against silent weakening

Gating points:
- `capabilities.json` carries `schema_version`, `devices`, `engines`,
  `measurements`, and a derived `legacy_tier`
- Every device record carries `usable`, and `usable: false` carries an
  `unusable_reason`
- NPU vendor comes from `uevent` `DRIVER=`, never from a product string
- A microbenchmark cannot exceed 60 seconds
- Measured decode below 30% of roofline sets `degraded: true`
- Missing `/sys/class/accel` and unreadable RAPL counters are both non-fatal
- No Python in the probe or its outputs

## Sources of Truth

- `plan/issues/heterogeneous-inference-cpu-gpu-npu-research-2026-07-24.md` —
  order 478 research deliverable; NPU vendor landscape table, roofline
  evidence, and the PROBE requirement seeds
- `cheatsheets/runtime/container-gpu.md` — Container GPU reference and patterns
- `cheatsheets/runtime/local-inference.md` — Local Inference reference and
  patterns

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:accel-capability-probe" crates/ scripts/ images/ --include="*.rs" --include="*.sh"
```
