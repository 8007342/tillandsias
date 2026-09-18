# The NPU `usable` field is a literal, not a measurement (yoga, 2026-09-18)

## What was asked

Re-probe yoga's NPU after the 2026-09-18 BigPickle toolkit layering and compare
field-by-field against trunk's row (npu / AMD XDNA / /dev/accel/accel0 /
amdxdna / fw 1.1.2.64 / usable: false / unusable_reason: engine-missing,
measured before the layering). Routing for orders 543 and 546 was framed as
conditional on "IF the NPU re-probe flips usable".

## What the probe says

`scripts/host-capability-probe.sh`, rc=0, on 7f0fac037.

- timestamp 2026-09-18T20:13:02Z, probe_identity `56.9.13+c4d11b5d7fdb1f11`,
  hardware_fingerprint `hw2-e94acbd479cb8b80`, `enumeration_gaps: []`.
- Filed verbatim (generator-produced, never hand-assembled) as
  `plan/index.d/20260918t201302z-capability-row-yoga.yaml`.

Every field of the NPU row is identical to the pre-layering row. The host side
is present and healthy: `amdxdna` loaded (311296, with `amd_pmf` and
`gpu_sched` bound to it), `/dev/accel/accel0` present `crw-rw---- root:render`,
node re-created 12:59/13:01 the same day.

## The finding

The comparison cannot come out any other way, on any host, after any layering.

`enumerate_npus()` in `crates/tillandsias-headless/src/accel_probe.rs`
constructs every NPU `DeviceRecord` with the literals
`usable: false` and `unusable_reason: Some("engine-missing".to_string())`,
marked `PROBE-3` at the push site. The value is not derived from the device,
not derived from `doc.engines`, and not derived from any host state.
`enumerate_npus()` has exactly one push site and returns its vector unmodified.
No site in the file sets an NPU record usable: every `usable = false` mutation
in the file is test code over `gpu` records.

So "the NPU re-probe flips usable" was not a satisfiable condition. The probe
is structurally incapable of reporting an NPU as usable. What the re-probe does
establish is the other half: driver, device node and firmware are present and
sane, so the absent thing is a shipped engine — which is exactly what the word
means.

That reading is the file's own, in the doc comment on `gpu_engine()`: `none` means there is no hardware
(buy hardware); `engine-missing` means the hardware is here and we ship nothing
that can drive it (ship a lane). That comment cites the NPU record as the
reference case for the distinction. Corroborating from the same run,
`engines[]` holds exactly one entry — ollama / llama-server, with
`supported_device_classes: ["cpu","gpu"]`. Nothing declares `npu`.

## What is left

The NPU-usable precondition is two gates, and neither is hardware.

1. Order 542 (optional-component-registry) — `status=ready`, unclaimed,
   unimplemented. 543 `depends_on` it; 546 cascades through 543. Already the
   known blocker.
2. Something must make the NPU row's `usable` derive from the engine registry,
   and something must declare an NPU-capable engine. Until both, the row reads
   `false` even with 542 landed.

`gpu_engine()` is the worked example of the shape gate 2 needs: it
reads `doc.engines` and falls to `engine-missing` only when no engine claims the
class. Order 793-qr4t exists precisely because `accel_envelope` never read
`doc.engines` for the GPU. The NPU side still does not read it at all.

Gate 2 has no packet. It is not filed here as one: it wants to be written
against 542 rather than as a parallel order, and that is the coordinator's call
(raised to macuahuitl-fedora 2026-09-18).

## Falsifier

Land a change making `enumerate_npus()` consult `doc.engines`, and add an
engine declaring `npu` in `supported_device_classes`. If yoga's row still reads
`usable: false` afterwards with the driver loaded and the node present, this
note is wrong about where the constraint lives.
