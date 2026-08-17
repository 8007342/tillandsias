# Mesa `dzn` is vendor-general: the Intel iGPU is reachable from inside WSL2 too — with the numbers, the cold-dispatch trap, and the D3D12 translation cost

- classification: research
- filed: 2026-08-17 (windows/ESMERALDINHA, cycle 9)
- status: measured; **corrects this host's own cycle-7 conclusion** and answers
  794-kmqe's WL-EXPOSURE from the opposite direction
- related: **793-zumy** (Yolanda's AMD dzn measurement — this generalises it),
  793-a8e7 (three-package enablement), 793-ee2g (NPU unreachable),
  522 (expert-slots-vram-aware), 620-ca7g (low-end floor),
  794-kmqe (the windows-lane sharing packet this answers),
  `plan/issues/optimization/mirrored-networking-reverted-redundant-ollama-removed-2026-08-17.md` (corrected)

## The correction first

Cycle 7 of this loop concluded, after removing the bare-metal Windows ollama:

> `/dev/dri` is ABSENT in WSL2 ... **the Intel iGPU is not reachable from either
> sanctioned runtime on this host** ... Realising the measured ~3.3x prefill win
> here would require GPU passthrough into WSL2 (Mesa `dzn` or equivalent), which
> is separate, unbuilt work.

**It is not unbuilt, and it is not separate.** Yolanda had already measured the
same path on AMD the previous day (793-zumy) and reduced the enablement to three
Fedora packages. `/dev/dri` is indeed absent and always will be — that part
stands — but it was never the only route. WSL2 exposes `/dev/dxg`, and Mesa's
`dzn` maps Vulkan onto D3D12 over it.

The conclusion was wrong because it inferred "unreachable" from one missing
device node rather than asking what the present one affords. **Absence of the
expected interface is not absence of the capability.**

## The new fact: `dzn` is vendor-general

Yolanda proved the path on an **AMD** Radeon 860M. Whether it generalised was
unmeasured, and it matters: if `dzn` were AMD-specific, the three-package
enablement would be a per-vendor special case rather than a fleet option.

Installing Yolanda's exact package set into `tillandsias-build` and pinning the
ICD reproduces it on **Intel**:

```
GPU0:
  apiVersion = 1.2.354       driverVersion = 26.1.6
  vendorID   = 0x8086        deviceID      = 0x46d1     <- Alder Lake-N, matches host PCI
  deviceType = PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU
  deviceName = Microsoft Direct3D12 (Intel(R) UHD Graphics)
  driverID   = DRIVER_ID_MESA_DOZEN
```

and ollama binds it for real, verified by offload rather than by flag:

```
llama_prepare_model_devices: using device Vulkan0
  (Microsoft Direct3D12 (Intel(R) UHD Graphics)) - 7357 MiB free
/api/ps: size_vram == size  ->  pct_on_gpu = 100%
```

**So the enablement is fleet-general across the two GPU vendors the fleet
actually has.**

Per Yolanda's warning, that "7357 MiB free" is the guest's RAM re-labelled, not
separate VRAM — on unified memory GPU and CPU budgets must never be summed
(relevant to 522).

## Numbers — `qwen2.5:0.5b` Q4_K_M, inside `tillandsias-build`

Method follows 793-zumy: unique prompt per repetition (a reused prompt measures
ollama's prompt cache), prefill isolated with `num_predict=1`, decode with a
short prompt and `num_predict=128`, `VK_DRIVER_FILES` pinned to the dzn ICD.
The dev-inference server on 11434 was never touched; every arm ran a second
server on 11435 and 11434 was verified alive after.

| lane | prefill tok/s | decode tok/s |
|---|---|---|
| CPU (in-guest) | 85.58 / **88.31** / 88.98 | 27.90 / **28.67** / 29.25 |
| dzn iGPU (warm) | 190.25 / 191.04 / **190.62** / 190.37 / 191.07 | 14.42 / **15.26** / 15.95 |
| ratio | **GPU 2.16x** | **CPU 1.88x** |

### The cold-dispatch trap — worth more than the ratio

The first two prefill requests after model load were **86.00** and 189.03 tok/s;
the following five sat inside a 0.8 tok/s band at ~190.6.

**The first prefill on the dzn path costs pipeline compilation and reads as
CPU-speed.** A benchmark that does not discard cold repetitions understates dzn
by ~2.2x — and, worse, produces a number that looks like a *plausible* CPU
result rather than an obvious outlier. An earlier run in this cycle reported
`87.89` and `193.21` as two samples of the same configuration for exactly this
reason.

This is the mirror image of the cache trap 793-zumy already documented: reusing a
prompt makes the GPU look impossibly fast; failing to warm makes it look exactly
like the CPU. Both directions need controls.

## The D3D12 translation cost, isolated

This host is the only one able to measure this, because it ran the **same
physical device** through both a native-Windows Vulkan driver (cycles 5-6,
before the bare-metal ollama was removed) and dzn-in-WSL2:

| Intel UHD, `qwen2.5:0.5b` | prefill tok/s | decode tok/s |
|---|---:|---:|
| native Windows Vulkan | ~296 | ~20 |
| dzn in WSL2 (D3D12 translation) | ~190.6 | ~15.3 |
| **retained** | **~64%** | **~77%** |

So the translation layer costs roughly **a third of prefill throughput and a
quarter of decode** versus reaching the same silicon natively.

**Stated as indicative, not rigorous**: the native figures were taken on a
different day, through a different server (the Windows ollama, since
uninstalled), with a shorter prompt. Same device, same model, different harness
generation. A rigorous version would need both paths measured back-to-back with
one harness, which is no longer possible here without reinstalling the component
the operator removed — and that is not worth doing for a refinement.

## Cross-host comparison with 793-zumy

| `qwen2.5:0.5b`, dzn | Yolanda — AMD 860M (RDNA 3.5) | ESMERALDINHA — Intel UHD (24 EU) |
|---|---|---|
| prefill | 397.5 -> 737.8 (**GPU 1.86x**) | 88.3 -> 190.6 (**GPU 2.16x**) |
| decode | 78.7 -> 63.8 (**CPU 1.23x**) | 28.7 -> 15.3 (**CPU 1.88x**) |
| embeddings | GPU 1.16x slower | GPU 1.58x slower (measured natively) |

**Same direction on both, on different vendors, through the same translation
layer.** The pattern — GPU wins prefill, CPU wins decode at 0.5B, GPU loses
embeddings — is a property of the workload shape, not of a vendor.

**The decode penalty is markedly worse on the weaker iGPU** (1.88x vs 1.23x),
which is what the fixed-per-dispatch-cost model predicts: less compute to
amortise the same overhead. 793-zumy found decode crosses over in the GPU's
favour by 3B. On this host, the Windows-native measurement at 3.8B still had CPU
ahead on decode (5.96 vs 4.74 tok/s), so **on 24 EUs the decode crossover may not
occur anywhere in the usable model range.** That is the floor host's specific
contribution: the crossover 793-zumy found is not universal, and a routing policy
keyed on model size alone would be wrong here.

## Two of Yolanda's warnings, re-tested here

- **`lavapipe` trap — CONFIRMED.** With the ICD unpinned the loader offers both
  `DRIVER_ID_MESA_DOZEN` and `llvmpipe / DRIVER_ID_MESA_LLVMPIPE`, a CPU software
  rasterizer presenting as a Vulkan device. Pinning `VK_DRIVER_FILES` is
  load-bearing, not tidiness.
- **"Installing the loader silently flips every host to GPU decode" — DOES NOT
  reproduce here.** After installing the three packages, the running
  dev-inference server stayed at `pct_on_gpu=0%`, and a **fresh** server started
  with no `VK_DRIVER_FILES` and no `OLLAMA_VULKAN` still selected
  `library=cpu`. Yolanda's server had `OLLAMA_VULKAN:true` in its config and runs
  ollama 0.32.9; this host runs 0.32.14. **So the silent-flip risk is
  config/version-dependent, not universal** — which makes 793-a8e7's enablement
  decision safer than it looked, but only if the config is pinned rather than
  assumed. It should still be opt-in: on THIS host an accidental flip would cost
  1.88x on decode, worse than the 1.23x that motivated the warning.

## Consequence for this host

The Vulkan lane **is** reachable from the sanctioned development runtime after
all, at ~2.16x prefill and ~0.53x decode. Whether to enable it is a routing
question, not a capability one, and the routing argument lives in
`accel-capability-envelope-and-routing-2026-08-16.md`. Given that the semantic
layer on this host is recommended OFF entirely (no model meets the 1500 ms
budget — see `semantic-layer-sub-1b-floor-2026-08-16.md`) and that embeddings are
*slower* on the iGPU, the workload that would actually benefit here is
prefill-heavy RAG synthesis, which this host does not currently run.

**Not proposed**: enabling it. The measurement is the deliverable.

## Reversal

`dnf remove vulkan-loader vulkan-tools mesa-vulkan-drivers` (~200 MiB installed).
Left in place because it is inert unless `VK_DRIVER_FILES` and `OLLAMA_VULKAN`
are both set — verified above — and because it lets the next cycle re-measure
without a reinstall.
