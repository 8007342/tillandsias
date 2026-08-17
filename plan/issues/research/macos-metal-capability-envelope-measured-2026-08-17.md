# The Metal lane's capability envelope, measured — and why it reads `cpu-only` on an M5

- **Host**: macOS / this MacBook Air. **Filed by**: `macos-opus5-metal-20260817`, 2026-08-17.
- **Branch**: `osx-next`. **Probe binary**: built at `7e73b3de5` from
  `crates/tillandsias-headless/src/accel_probe.rs`.
- **Orders**: 803-rbqf (envelope is wrong for a host-native accelerator),
  803-r8u4 (probe host facts are Linux-only), 803-825k (`enumerate_engines`
  is a literal).
- Cross-references: 397, 392, 495, 522, 769-w3ma, 599-3b9h, 793-qr4t, 793-qc6q,
  and `plan/issues/research/accel-capability-envelope-and-routing-2026-08-16.md`
  (the windows/Yolanda envelope redesign this report is the macOS counterpart of).

The operator's directive for this cycle: *"run the capability probe and commit
its envelope + capabilities.json. You are the Metal lane and the fleet has no
HIGH/MID/LOW matrix to route against."* This is that row.

---

## 1. The host

Measured, not assumed:

| Fact | Value | Source |
|---|---|---|
| Model | MacBook Air, `Mac17,3` | `system_profiler SPHardwareDataType` |
| Chip | Apple M5 | `sysctl -n machdep.cpu.brand_string` |
| CPU cores | 10 — **4 performance + 6 efficiency** | `system_profiler SPHardwareDataType` |
| GPU cores | 10 | `system_profiler SPDisplaysDataType` |
| Metal | Metal 4 | `system_profiler SPDisplaysDataType` |
| Memory | 16 GB, **unified** | `sysctl -n hw.memsize` = 17179869184 |
| Battery | **present**, charged, on AC | `pmset -g batt` → `present: true` |
| Kernel | Darwin 25.6.0, arm64 | `uname -r`, `uname -m` |

## 2. The envelope this host emits — and the one production actually uses

**Read §2.1 before using any number in this report.** There are *two* macOS
envelopes, they disagree, and the one measured below is not the one the fleet
routes on.

```
accel_class=cpu-only accel_gpu=present-unusable accel_gpu_name=Apple_Metal_GPU \
accel_npu=none accel_npu_name=- accel_reason=- accel_cpu_cores=10 accel_ram_gb=-
```

### 2.1 This is the host-native envelope, which nothing in production runs

The line above comes from `target/release/tillandsias`, a **Mach-O arm64** binary
built on this host. It is not installed (`command -v tillandsias` → not found)
and it is not what launches the enclave.

What actually runs on macOS: the tray boots a Linux VM and stages a
**cross-compiled `aarch64-unknown-linux-musl`** headless binary into it
(`crates/tillandsias-macos-tray/src/guest_binary.rs:22-26`;
`scripts/build-macos-tray.sh:128`). Under that target the
`#[cfg(target_os = "macos")]` arms of `accel_probe.rs` and
`detect_inference_tier()` (`main.rs:3655-3658`) **are not compiled at all**.

Confirmed at the artifact level, not inferred from source:

```
$ strings -a target-guest/tillandsias-headless-aarch64-unknown-linux-musl | grep -i metal
    # 10 hits, all the word "bare-metal" from embedded docs. Zero "Apple Metal GPU".
$ strings -a target/release/tillandsias | grep -m2 "Apple Metal GPU"
    Apple Metal GPUuname-r
```

So the **production** macOS envelope is the Linux one, measured in-lane
2026-08-10 and recorded at `plan/index.yaml:31437`:

```
accel_class=cpu-only accel_gpu=none accel_gpu_name=- accel_npu=none \
accel_npu_name=- accel_reason=- accel_cpu_cores=4 accel_ram_gb=4
```

`accel_cpu_cores=4` is the VM's vCPU count
(`crates/tillandsias-vm-layer/src/vz.rs:1420-1422`,
`available_parallelism().min(4)`) and `accel_ram_gb=4` is the guest's RAM
(`vz.rs:1423`, a hardcoded 4 GiB). **Neither describes the Mac.** This host has
10 cores and 16 GB; the fleet is told 4 and 4.

That makes the defect set below *more* serious rather than less, and reorders it:

- §3.1 and §3.2 (`cpu-only`, bare reason) are real on **both** paths — the
  production path reaches `cpu-only` by an even blunter route (`accel_gpu=none`,
  because the Linux arm finds no `/dev/dri` and no `nvidia-smi` in the guest).
- §3.3's `accel_ram_gb=-` is the host-native symptom. In production the field is
  *populated and wrong*: `4`, the guest's allocation. A populated wrong number is
  worse than `-` for 522, because `-` at least fails visibly.
- §3.4's battery bug is host-native-only in effect, since the guest genuinely has
  no battery — but the *type* defect that produces it is unchanged.

The plan already names the compiled-but-never-executed macOS arms a structural
fiction: `plan/index.yaml:39248` (order 657-zm2n) — *"detect_inference_tier()'s
'metal' arm … never executes in production because headless is cross-compiled to
linux-aarch64 and runs inside the VZ guest, reporting 'cpu'"*.

I did not know this when I ran the probe. The measurement stands; its
interpretation needed this correction, and the correction is the more useful
finding.

Reproduce:

```bash
cargo build --release -p tillandsias-headless
TILLANDSIAS_CACHE_DIR="$(mktemp -d)" ./target/release/tillandsias --capabilities
```

`capabilities.json` (verbatim, `schema_version: 1`, probed
2026-08-17T21:03:59Z) is reproduced in §7. It is **not** committed as a live
file: order 495 (`preflight-evidence-dirties-forge-gate`) forbids generated
evidence in the worktree, and `capabilities_cache_path()`
(`accel_probe.rs:80-101`) deliberately homes it under
`$HOME/.cache/tillandsias/`. The content belongs in a dated report; the artifact
does not belong in the tree.

## 3. Six defects, in descending order of consequence

### 3.1 `accel_class=cpu-only` on a 10-GPU-core M5 — the routing false negative

This is the same shape as the windows/Yolanda finding (793-qr4t, §A.1), reached
by a different route, and it is arguably worse here: on Yolanda the GPU was
merely unenumerated. Here the probe **finds the GPU, records it correctly**, and
then the envelope throws the finding away.

The mechanism is exact (`accel_probe.rs:544-575`). `state()` returns `usable`
only when `lanes` contains `"container"`. The macOS GPU record is
`usable: true, unusable_reason: null, lanes: ["host-native"]` — correct, and
required by PROBE-7, which mandates Metal container isolation because a Linux
guest VM cannot reach Metal. So `state()` yields `present-unusable`, and

```rust
let class = match (gpu_state, npu_state) {
    ("usable", "usable") => "hybrid-gpu-npu",
    ("usable", _)        => "workstation-gpu",
    (_, "usable")        => "mobile-npu",
    _                    => "cpu-only",
};
```

falls to `cpu-only`.

**The conflict is in what `accel_class` means.** Its own doc comment
(`accel_probe.rs:531-535`) calls it "the TWO-TIER ROUTING SIGNAL … An agent picks
model size from the class without probing hardware it cannot see." But the value
is computed from container-deliverability. Those two questions have the same
answer on Linux and **permanently different answers on macOS**, because
host-native-only is macOS's designed steady state, not a misconfiguration.

So a Mac reports the one thing that is certainly false — *this node cannot do
accelerated work* — to a consumer asking what the node can do. This is the
`unobservable-from-this-side` gap the Yolanda report named (793-qr4t §A.3): the
vocabulary has no term for "reachable, just not from the lane you asked about".
macOS needs the mirror term, e.g. `accel_gpu=host-native-only` and a class that
distinguishes it, so that `cpu-only` keeps meaning "there is no accelerator".

### 3.2 `accel_reason=-` — a bare `cpu-only`, which the contract forbids

`accel_probe.rs:571` comments the reason field: *"The first named obstruction, so
`cpu-only` is never a bare verdict."* On this host it is exactly that.

Structural, not incidental: `reason` is sourced only from `unusable_reason`, but
the macOS GPU is **not** excluded by `unusable_reason` — it is `null`. It is
excluded by the `lanes` test one line earlier. A device rejected by lane
therefore carries no reason, so the envelope has nothing to name and prints `-`.
Any device excluded by lane rather than by usability hits this; macOS is simply
the host where that path is always taken.

The honest value here is something like
`accel_reason=metal-not-container-deliverable`.

### 3.3 `accel_ram_gb=-` on a 16 GiB host — RAM is read only on Linux

`system_ram_gb` is populated solely inside `#[cfg(target_os = "linux")]` from
`/proc/meminfo` (`accel_probe.rs:205-211`). The macOS arm
(`accel_probe.rs:216-223`) sets vendor, name, cores and `neon`, and never touches
`ram_gb`, which stays at its `None` initializer (`accel_probe.rs:166`).

522 (`expert-slots-vram-aware`) sizes expert slots off this number. `-` sizes them
wrong. `sysctl -n hw.memsize` is one call away and is the obvious fix.

This also blocks the unified-memory rule the Yolanda report argues for
(793-qr4t §A.4): on Apple silicon the GPU and CPU draw on **one** 16 GiB budget
and must never be summed. Apple silicon is the canonical unified-memory node, and
the envelope currently carries neither the budget nor the model.

### 3.4 `is_battery_present: false` on a MacBook Air — `bool` cannot say "unmeasured"

`pmset -g batt` reports `-InternalBattery-0 … present: true`. The probe reports
`false`.

The code names its own limit (`accel_probe.rs:435-437`):

```rust
// Only the Linux power-supply scan can flip this; other hosts keep false.
#[cfg_attr(not(target_os = "linux"), allow(unused_mut))]
let mut battery = false;
```

The comment is accurate; the **type** is the defect. `is_battery_present: bool`
has no way to express "not measured", so an unmeasured value is serialised as a
confident negative. On a laptop that is a false negative, and battery presence is
precisely the signal a routing policy would use to decline sustained accelerator
load.

The struct already contains the right idiom one field away:
`memory_bandwidth_source: "unknown"` (`accel_probe.rs:252-253`) handles exactly
this problem for bandwidth. Battery should follow it — `Option<bool>`, or a
paired `battery_source: measured|unmeasured`.

### 3.5 `enumerate_engines()` returns a hard-coded literal on every host

```rust
// accel_probe.rs:468-474
fn enumerate_engines() -> Vec<EngineRecord> {
    vec![EngineRecord {
        name: "ollama".to_string(),
        backend: "llama-server".to_string(),
        supported_device_classes: vec!["cpu".to_string(), "gpu".to_string()],
    }]
}
```

It takes no arguments, inspects nothing, and returns the same record on every
host in the fleet. `capabilities.json` therefore asserts that ollama with a
llama-server backend is available here — an assertion no code checked, and which
on this host is unverified.

This inverts the Yolanda report's central lesson (793-qr4t §A.3): *"Enumeration,
not file existence, is the test"* and *"a probe that reports hardware without
reporting engine readiness reports a capability we cannot exercise."* The engine
half of the envelope does not even reach file existence. It is the single field
most likely to be believed and least likely to be true, and it is what makes
"the fleet has no matrix to route against" concretely correct: the engine column
is a constant.

### 3.6 `accel_cpu_cores=10` hides a 4+6 split

`physical_cores = logical_cores` on macOS (`accel_probe.rs:219`) is *correct* —
Apple silicon has no SMT. But 10 reads as ten interchangeable cores, and this
part is 4 performance + 6 efficiency. Anything sizing a thread pool off
`accel_cpu_cores` over-commits by 2.5x on the only cores that matter for prefill.
Lower severity than the above; recorded so the number is not trusted beyond what
it measures.

## 4. What this means for 397 (tiered inference backends)

397's exit criteria are:

> - same expert query set passes on GPU tier (this host) and one non-GPU tier
>   (macOS llama.cpp or CPU)
> - tier switch requires zero agent-side config change (transparency litmus)

The Metal rung cannot be signed off, and the blocker is one level below the
envelope: **there is no macOS Metal lane to characterise.** Not "an unmeasured
one" — none.

- The inference image is a Fedora container
  (`images/inference/Containerfile:9`), and its engine payload URL is
  `ollama-linux-${ARCH}.tar.zst` (`images/inference/entrypoint.sh:293`).
- `_engine_wanted_backends()` (`entrypoint.sh:226-258`) has arms for `gpu-cuda`,
  `gpu-rocm`, `gpu-vulkan`, and `*) echo ""`. **There is no `metal` arm.**
  `engine-tuning.sh:88-94` places `metal` explicitly in the conservative `*)`
  bucket: *"cpu / metal / anything unrecognised: conservative, and NEVER a
  GPU-shaped claim."*
- Every Tillandsias container on macOS lives inside the Linux VM, and PROBE-7
  makes Metal host-native-only precisely because a guest cannot reach it. So the
  container lane can never carry Metal by construction.
- Order 401 already recorded the live guest reading: *"`tillandsias-headless
  --inference-tier` on the VZ guest emits `tier:cpu`"* (`plan/index.yaml:17662`).
- The lane decision is on record:
  `plan/issues/experts-construction-decision-2026-07-17.md:75-79` — *"Lane
  decision (macOS): cpu-ollama. It is the only backend present in the aarch64
  inference image today — `llama-server`/`llama-cli` are absent."*

So macOS is silently running **CPU ollama inside an aarch64 Linux guest capped at
4 vCPUs and 4 GiB**, on a 10-core / 16 GB M5 whose GPU the product never touches.
That is the honest state of the Metal rung, and it means the envelope work in
§3.1-§3.2 is necessary but nowhere near sufficient: fixing the envelope would let
the fleet *describe* a Metal lane it still does not have.

The real prerequisite is a **host-native sidecar** — already filed as order 483
(`host-native-sidecar-endpoints`) and 657-s6g8 (`macos-metal-sidecar-bringup`),
both `ready`/v0.5. Metal cannot arrive through the container seam at all; it needs
the host-native route those packets build. `accel_class` cannot honestly report a
usable GPU until then, which is exactly what 657-zm2n
(`macos-accel-probe-truthfulness`, ready/v0.6) says: the present-unusable
rendering is *"correct exactly until 483's proxied route exists"*.

The narrow, falsifiable next rung, in dependency order:

1. Teach the envelope `host-native-only` (§3.1) and a named reason (§3.2), so a
   Mac stops advertising `cpu-only`. Falsifiable by a unit test asserting the
   macOS device set does not render `accel_class=cpu-only`.
2. Populate `system_ram_gb` from `hw.memsize` and add `accel_mem_model=unified`
   (§3.3). Falsifiable by `accel_ram_gb=16` on this host.
3. Make `enumerate_engines()` enumerate (§3.5). Falsifiable by asserting an
   absent engine is reported absent.
4. Only then measure prefill/decode on Metal and populate `measurements`, which
   has never been non-empty on any host in the fleet.

Steps 1-3 are prerequisites for a *meaningful* step 4: measuring a tier the
envelope cannot express would produce numbers nothing can route on.

## 5. `measurements: []` — still empty everywhere

`measurements: Vec<MeasurementRecord>` exists, is serialised, and has never been
populated on any host (Yolanda observed the same, 793-qr4t §B.2). The Yolanda
report proposes a bounded microbenchmark at first run, cached in
`capabilities.json`, as the home for per-host thresholds — because the measured
prefill/decode crossover is a property of the host, not a constant. This report
adds one datum: the field is empty on the Metal lane too, so the gap is fleet-wide
rather than a Windows-side omission.

## 6. Honest limits of this report

- No Metal inference was benchmarked this cycle. Nothing here claims a
  throughput number for the M5; §4 says why measurement is premature.
- The probe was run on one Mac. `Mac17,3` is a 10-core M5 Air; an M5 Pro/Max or
  a Mac Studio would change core counts and the battery answer, and this report
  should not be read as characterising all Apple silicon.
- Defects 3.1-3.6 are read from source and confirmed against this host's actual
  output. The *fix shapes* proposed are arguments, not landed code.

## 7. `capabilities.json`, verbatim

Probed 2026-08-17T21:03:59.182207+00:00 on `Mac17,3`, schema_version 1.

```json
{
  "schema_version": 1,
  "legacy_tier": "metal",
  "devices": [
    {
      "device_class": "cpu",
      "vendor": "apple",
      "name": "Apple Silicon CPU",
      "device_node": null,
      "fw_version": null,
      "driver": null,
      "usable": true,
      "unusable_reason": null,
      "lanes": ["container", "host-native"],
      "memory_bandwidth_gbps": null,
      "memory_bandwidth_source": "unknown",
      "cpu_flags": ["neon"],
      "cpu_cores": { "physical": 10, "logical": 10 },
      "system_ram_gb": null
    },
    {
      "device_class": "gpu",
      "vendor": "apple",
      "name": "Apple Metal GPU",
      "device_node": null,
      "fw_version": null,
      "driver": null,
      "usable": true,
      "unusable_reason": null,
      "lanes": ["host-native"],
      "memory_bandwidth_gbps": null,
      "memory_bandwidth_source": "unknown",
      "cpu_flags": null,
      "cpu_cores": null,
      "system_ram_gb": null
    }
  ],
  "engines": [
    {
      "name": "ollama",
      "backend": "llama-server",
      "supported_device_classes": ["cpu", "gpu"]
    }
  ],
  "measurements": [],
  "host": {
    "is_battery_present": false,
    "kernel_release": "25.6.0"
  },
  "timestamp": "2026-08-17T21:03:59.182207+00:00"
}
```

Note for readers diffing this against a future run: `legacy_tier: "metal"` is
correct and matches `scripts/inference-tier-probe.sh` (`tier:metal`). The tier
string is the one part of this envelope that has always been right on macOS —
which is why the regression is invisible to `litmus:inference-tier-probe` and had
to be found by reading the envelope instead.
