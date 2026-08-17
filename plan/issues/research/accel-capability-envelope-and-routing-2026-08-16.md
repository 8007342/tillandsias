# A capability envelope that is correct on every side, and a routing policy argued from measurements

- **Host**: windows/Yolanda. **Filed by**: `windows-opus5-accel-20260816`, 2026-08-16.
- **Orders**: 793-qr4t (probe redesign), 793-qc6q (routing policy). Evidence:
  `plan/issues/research/wsl2-igpu-vulkan-over-dxg-measured-2026-08-16.md` (793-zumy)
  and `plan/issues/research/npu-windows-side-inference-path-2026-08-16.md` (793-ee2g).
- Cross-references: 520, 522, 409, 518, 397, 620-ca7g, 718-rtnh, 718-ja7g, 718-nkm2.

---

## Part A — Why the current probe is wrong, and what replaces it

### A.1 The concrete failure, measured

`crates/tillandsias-headless/src/accel_probe.rs::enumerate_gpus` decides a Linux
host has a GPU if and only if `nvidia-smi -L` succeeds **or** `/dev/dri` exists.
On windows/Yolanda inside `tillandsias-build`, neither holds. `enumerate_npus`
returns an empty vector because `/sys/class/accel` is absent — a case the code
names explicitly:

```rust
// PROBE-2: Kernel without accel class (e.g. WSL2) yields empty list and succeeds
```

So the envelope reads `accel_class=cpu-only accel_gpu=none accel_npu=none`.

Every one of those three fields is **wrong on this host**:

- The GPU exists and is *reachable from the guest* through `/dev/dxg`. Once a
  Vulkan loader and Mesa's `dzn` ICD were installed, ollama ran qwen2.5:3b at
  `100% GPU` with **~2.0x the prefill throughput of the CPU**.
- The NPU exists, is healthy, and has a current AMD driver — it is simply not
  observable from inside WSL2.
- `cpu-only` was therefore not merely pessimistic. It was a **false negative
  that suppressed a 2x speedup**, and it named no obstruction, in violation of
  the envelope's own stated contract that "`cpu-only` is never a bare verdict".

This is also why 599-3b9h's criterion-2 expectation of `cpu-only` was accepted
as correct at the time: the expectation was derived from the same blind rubric
it was checking. The observation matched the implementation, not the hardware.
A note event on 599-3b9h and on 769-w3ma (whose grammar carries `accel_class`)
records this so the closed packet is not later read as evidence the host has no
accelerator.

### A.2 The root defect is conceptual, not a missing `if`

Adding a `/dev/dxg` check would fix this host and leave the design broken. Four
distinct facts are currently collapsed into one boolean:

1. **Does the device exist?**
2. **On which side of which boundary is it visible?** WSL2 has three: the Linux
   guest, the Windows host, and the forge container inside the guest. A device
   can be usable from one and invisible from another.
3. **Is there an engine that can drive it?** On this host the *hardware* was
   unchanged before and after the experiment; installing `vulkan-loader` +
   `mesa-vulkan-drivers` is what turned an unusable GPU into a usable one. A
   probe that reports hardware without reporting engine readiness reports a
   capability we cannot exercise.
4. **For which workload is it actually faster?** Measured: the *same* device on
   the *same* model is 1.86x faster for prefill and 0.81x *slower* for decode.
   No single `accel_class` token can carry that.

`lanes: ["container", "host-native"]` was an attempt at (2), but its vocabulary
has no term for "exists on the other side of a VM boundary", so WSL2's NPU is
forced to render as `none` — the one answer that is certainly false.

### A.3 Proposed envelope: additive, side-qualified, engine-qualified

Keep every existing key and its meaning so 769-w3ma's consumers and the
`litmus:accel-envelope-reaches-the-forge` wire test keep passing. **Add** the
following, and **widen exactly one existing value set**:

```
accel_side=<native-linux|wsl2-guest|windows-host|macos-host|container>
accel_gpu_path=<drm|dxg-d3d12|metal|cuda|none>
accel_gpu_engine=<vulkan-radv|vulkan-dozen|rocm|cuda|metal|none|engine-missing>
accel_mem_model=<unified|discrete>
accel_mem_budget_gb=<n|->
accel_prefill_dev=<gpu|npu|cpu>
accel_decode_dev=<gpu|npu|cpu>
```

Widened, and this is the important one:

```
accel_npu=<usable|present-unusable|unobservable-from-this-side|none>
accel_gpu=<usable|present-unusable|unobservable-from-this-side|none>
```

`unobservable-from-this-side` is the term the vocabulary is missing. It is the
honest answer for the XDNA2 NPU seen from a WSL2 guest, and it is *categorically
different* from `none`: `none` invites "this machine cannot do NPU work",
which on this host is false and would mis-plan a whole tier.

Per-platform detection rules the probe must implement:

| Side | GPU detection | NPU detection | Notes |
|---|---|---|---|
| native Linux | `/dev/dri/renderD*` + a Vulkan/ROCm ICD that enumerates | `/sys/class/accel` + `amdxdna`/`intel_vpu` | today's rubric, kept |
| **WSL2 guest** | **`/dev/dxg` + an ICD that enumerates a non-CPU device** | always `unobservable-from-this-side` | `/dev/dri` is absent by design |
| Windows host | DXCore / `Get-PnpDevice -Class Display` | `Get-PnpDevice -Class ComputeAccelerator` | where the NPU actually lives |
| macOS | Metal, `host-native` lane only | `none` | unchanged (PROBE-7) |

Two hard requirements learned the hard way:

- **Enumeration, not file existence, is the test.** `/dev/dxg` present with no
  Vulkan loader installed is a GPU we cannot use; that is exactly the state this
  host was in. The probe must attempt device enumeration and report
  `engine-missing` when the node fails, naming the obstruction.
- **A CPU rasterizer must never satisfy a GPU check.** With all Mesa ICDs
  installed, the loader also offers `lavapipe`/`llvmpipe` — a *software* device
  that will happily report itself as a Vulkan GPU. Selecting it would be the
  silent wrong-stack fallback the design forbids, dressed as a success. The
  probe must reject `PHYSICAL_DEVICE_TYPE_CPU` and any `DRIVER_ID_MESA_LLVMPIPE`
  device outright.

### A.4 Memory reporting is currently double-counting (feeds 522)

On this host the probe would report `accel_ram_gb=7` (the guest's RAM) while
`dzn` advertises a 7.58 GiB `DEVICE_LOCAL` heap. These are **the same physical
DRAM counted twice**, and neither is the host's 15.2 GB. 522
(expert-slots-vram-aware) sizing slots off either number sizes them wrong.

Hence `accel_mem_model=unified` and a single `accel_mem_budget_gb` that is
explicitly *the ceiling for this side*, with the rule: **on a unified-memory
node, GPU allocations and CPU allocations draw on one budget and must never be
summed.** This is the same class of error as 409's fedora-vm-image GPU
awareness and should be fixed once, in the probe, not per consumer.

---

## Part B — Routing policy, argued from the numbers

### B.1 What the measurements actually say

From 793-zumy (medians, ollama 0.32.9, same GGUF, same host, `/dev/dxg` via
Mesa `dzn`):

| Workload | CPU (Zen 5, AVX-512) | iGPU (dzn) | Verdict |
|---|---|---|---|
| qwen2.5:0.5b prefill | 397.5 t/s | 737.8 t/s | **GPU 1.86x** |
| qwen2.5:0.5b decode | 78.68 t/s | 63.75 t/s | **CPU 1.23x** |
| qwen2.5:3b prefill | 92.2 t/s | 188.3 t/s | **GPU 2.04x** |
| qwen2.5:3b decode | 19.64 t/s | 26.96 t/s | **GPU 1.37x** |
| nomic-embed-text (short input) | 8.8 ms | 10.2 ms | **CPU 1.16x** |

Two crossovers, both explicable and both actionable:

1. **Prefill always favours the iGPU.** Prefill is a batched GEMM — compute
   bound. The 860M has far more FLOPs than eight Zen 5 cores, and the win holds
   at both model sizes.
2. **Decode favours whichever device amortises dispatch overhead.** Decode is
   memory-bandwidth bound, and on unified memory the iGPU has *no bandwidth
   advantage* — it reads the same DRAM. At 0.5B the per-token dispatch cost
   through D3D12 exceeds the compute saved, so the CPU wins. At 3B the arithmetic
   per token is large enough to absorb that overhead, so the GPU wins.

The crossover sits between 0.5B and 3B. **This refines rather than confirms the
starting hypothesis** ("iGPU for generative decode and prefill of small-to-mid
LLMs"): for the *smallest* models the iGPU is a decode pessimisation, and
shipping "GPU if present" would have made our own semantic-layer floor slower.

3. **Embeddings do not belong on this iGPU.** Short fixed-shape inputs are pure
   dispatch overhead. This is consistent with the sibling's finding on
   esmeraldinha that the lane dominates the engine.

Independently, AMD's shipping design agrees on the axis that matters: in
Lemonade's hybrid mode "the NPU handles prompt processing, the GPU handles token
generation" ([Lemonade FAQ](https://lemonade-server.ai/docs/guide/faq/),
2026-08-16). Both AMD and our measurements split **prefill from decode**, not
model from model. The envelope must therefore carry a *per-phase* device, which
is why `accel_prefill_dev` / `accel_decode_dev` are proposed above rather than a
single richer `accel_class`.

### B.2 The policy

```
prefill  -> NPU if usable, else GPU if usable, else CPU
decode   -> GPU if usable AND model_params >= ~1.5B, else CPU
embed    -> NPU if an NPU embedding engine is usable (FLM), else CPU.
            Never the iGPU on a unified-memory node.
rerank   -> CPU until measured (unverified on NPU)
```

with three non-negotiable guards:

- **CPU is the floor and is always available.** Never a hard GPU/NPU requirement.
  This preserves 620-ca7g's low-end gate and keeps esmeraldinha's behaviour
  unchanged.
- **Opt-in / auto-detect, never silent.** A node that routes to an accelerator
  must say so in its envelope; a node that falls back must name the reason. The
  failure mode observed in this experiment was a **silent hang**, not an error
  (§B.3) — so "it did not crash" is not evidence the stack is healthy.
- **Thresholds are measured per host, not hard-coded.** The 1.5B crossover is
  *this* host's. The probe's `measurements: Vec<MeasurementRecord>` field already
  exists for exactly this and has never been populated; a bounded microbenchmark
  at first run, cached in `capabilities.json`, is the correct home for it.

### B.3 The stability caveat that must ride with any enablement

During the experiment, the 3B model on the `dzn` path **hung silently** on its
first cold GPU load: prompt processing stopped at 40% (2048/5093 tokens) and the
process sat there for >9 minutes with no error, no assertion, and no device-lost
message. A re-run of the same shape completed normally in ~25 s, and three clean
repetitions afterwards showed no assertion or device-lost lines. So the fault is
**intermittent and cold-load-associated, not a hard capability limit** — but it
is real, and it is the worst possible failure mode for an unattended host.

Consequences for any rollout:
- GPU routing needs a **watchdog with a deadline**, and the deadline must fall
  back to CPU rather than wait.
- `dzn` self-reports `"dzn is not a conformant Vulkan implementation, testing use
  only"`. Treat this lane as experimental and opt-in on WSL2 hosts specifically.

---

## Part C — What an end user's install gets from this

The same probe runs on a customer device, and the value is that **the decision
stops being made at packaging time**. Concretely:

1. **The best available stack, chosen on the device.** A Ryzen AI laptop gets
   iGPU prefill; a machine with a discrete NVIDIA card gets CUDA; a Mac gets
   Metal; a four-core office laptop gets the CPU floor and is not asked to
   pretend otherwise. This is the same code path we run — the sibling host
   esmeraldinha is the low-end member of the same matrix, not a special case.
2. **A safe floor, always.** Every routing rule in §B.2 terminates at CPU. An
   install can never end up with *no* working path, which is what a
   hard accelerator requirement risks on the long tail of consumer hardware.
3. **Never a silent wrong-stack fallback.** Three specific silent failures are
   now known and each gets an explicit named state rather than a plausible
   wrong answer:
   - hardware present but the driver stack is missing -> `engine-missing`,
     not `none`;
   - hardware present but on the other side of a VM boundary ->
     `unobservable-from-this-side`, not `none`;
   - a *software* rasterizer masquerading as a GPU -> rejected outright, never
     reported as `accel_gpu=usable`.
4. **Support becomes tractable.** `capabilities.json` plus the one-line envelope
   is a complete, side-qualified statement of what the machine offered and what
   we chose. A user reporting "it is slow" can be answered from that record
   instead of from guesswork.

The honest limitation to state up front: on a unified-memory device the
accelerator does not multiply memory, and for the smallest models it does not
even multiply speed. The envelope's job is to let us **decline** acceleration as
confidently as we accept it.
