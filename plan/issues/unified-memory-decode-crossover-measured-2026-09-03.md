# The unified-memory decode crossover, measured: there isn't one — Metal wins decode at every size, including 0.5B

- classification: research
- filed: 2026-09-03 (macos/tlatoanis-macbook-air, Mac17,3 / M5, 10 cores, 16 GiB unified)
- packet: 793-qc6q (per-phase-accelerator-routing-policy)
- routed here by lenovinha, on the grounds that Apple silicon is the fleet's
  only unified-memory node and a discrete 3070 cannot test the claim the
  policy rests on

## The claim under test

The policy's premise, in its own words: on unified memory the integrated GPU
reads the same DRAM as the CPU, so **decode gains nothing below a parameter
threshold** while prefill still wins. `decode_crossover_b` exists to find that
threshold, and exit criterion 1 asks that "a 0.5B-class model's decode is NOT
sent to the iGPU on a unified-memory host."

## The measurement

`scripts/bench-accel-lane.sh`, suite `802-2536-v1`, 3 reps, real corpus chunks.
Every arm verified by residency, not by intent — CPU rows report
`cpu-resident:0/<size>`, GPU rows `gpu-resident:<n>/<n>` with n == total, i.e.
fully offloaded. GPU device utilisation sampled from `ioreg AGXAccelerator`
during a 7B run: **100% peak on the GPU lane, 2% on the CPU lane** (independent
confirmation that the lanes are genuinely different and not merely relabelled).

decode tok/s (server's own `eval_count / eval_duration`):

| model | CPU | Metal | Metal/CPU |
|---|---:|---:|---:|
| qwen2.5:0.5b | 162.78 | 206.21 | **1.27x** |
| qwen2.5:3b | 38.03 | 58.23 | **1.53x** |
| qwen2.5:7b | 16.81 | 27.52 | **1.64x** |

prefill tok/s (`prompt_eval_count / prompt_eval_duration`):

| model | CPU | Metal | Metal/CPU |
|---|---:|---:|---:|
| qwen2.5:0.5b | 734.80 | 2825.18 | 3.84x |
| qwen2.5:3b | 199.01 | 634.07 | 3.19x |
| qwen2.5:7b | 82.98 | 303.02 | 3.65x |

## The finding

**There is no crossover on this host. The GPU wins decode at every size
measured, and its advantage GROWS with model size (1.27x → 1.53x → 1.64x) — it
never approaches 1 from above.** The derived threshold is therefore at or below
the smallest model measured; the envelope now reports
`accel_decode_crossover_b=0.5` rather than `Unmeasured`.

**Exit criterion 1 is wrong on this hardware.** Withholding decode from the GPU
for a 0.5B model costs 21% of decode throughput, not zero. The criterion should
be rewritten as a consequence of the per-host measurement rather than as a fixed
rule about 0.5B-class models.

**Why the premise fails here, and it is a real distinction rather than a
quibble:** "unified memory" was doing two jobs in the argument. It is true that
the Metal GPU and the CPU read the same DRAM, so there is no PCIe copy and no
separate VRAM budget. It does not follow that decode gains nothing — decode is
bandwidth-bound, and the GPU reaches far more of the shared bandwidth than the
CPU cores can. Apple silicon is not the x86 iGPU the premise was formed on, and
"shares DRAM with the CPU" does not imply "is limited to what the CPU could
achieve". A host-class rule would have got this backwards; the per-host
measurement is what the packet asked for and it is why.

## Three defects found while producing the number

Recorded because each one made a measurement that LOOKED fine and was not.

**1. `record_measurement` could not store a crossover, on any host.** It deduped
on `(device, engine)` only, so benchmarking a second model size OVERWROTE the
first. Six recordings (3 sizes x 2 lanes) left two rows, both 7B, while
`decode_crossover_b` needs two or more SIZES per device to find anything. **That
is why the field has looked unused since order 480 and why every host reads
`Unmeasured` — not because nobody ran the benchmark, but because the store could
not keep what the benchmark produced.** The key now includes `model_params_b`.

**2. The bench never sent the parameter axis.** `decode_crossover_b` skips any
record whose `model_params_b` is `None`, so every measurement recorded before
this cycle was invisible to routing even where it survived. The size is now
parsed from the model tag (`qwen2.5:0.5b` → 0.5), with `--model-params-b` to
override; absent stays absent rather than becoming 0, which would sort below
every real size.

**3. `--lane` did not mean anything on a one-server host.** On Linux+Vulkan the
lanes are separate servers, so the label distinguished them. On macOS there is
one server and Metal is always on, so `--lane cpu` and `--lane gpu` produced
byte-identical GPU-resident runs — two samples of one lane, reported as a
comparison. `--force-lane` now sends `num_gpu:0` for the CPU arm. Two further
traps inside that:

- **The observation confirmed the label instead of checking it.** It took `max`
  size_vram over ALL loaded models, which on one server answers about the
  *embedder* (nomic-embed-text, GPU-resident regardless of the arm). A genuine
  CPU run reported `gpu-resident:370031984`. It now selects by the generate
  model's name, and distinguishes cpu-resident / gpu-partial / gpu-resident /
  unloaded — a partial offload is neither device's number.
- **A loaded model keeps the configuration it was loaded with.** Switching lanes
  inside the keep-alive window silently reuses the previous placement. Measured:
  after a `num_gpu:0` run, a default request still reported `size_vram=0`;
  evicting first, the same request reported `479954205 == size`. Same server,
  same request, opposite conclusions, decided by what was cached. `--force-lane`
  now evicts before measuring.

**And one methodology trap in prefill.** With a fixed prompt the server caches
the processed prompt, so rep 2 skips prefill almost entirely: 521 tok/s on rep 1
against 6274 on rep 2, a 12x "speedup" that is the cache, not the hardware, and
it would have been averaged into a routing decision. Each rep now varies the
prompt. Decode was unaffected — nothing caches generated tokens — which is why
only that half needed changing.

## What this does NOT settle, and it blocks exit criterion 1

`accel_prefill_dev` and `accel_decode_dev` both still read `cpu` on this host,
because the envelope derives device state from the **container lane**:
`accel_gpu=present-unusable` is *correct* for the question "can a forge
container get this GPU" — macOS Metal is host-native only by spec (PROBE-7) —
but it is the wrong question for host-native inference, which is where the
numbers above come from.

So routing would send both phases to the CPU on a host where the GPU wins
decode by 1.27-1.64x and prefill by 3.2-3.8x. **Fixing that is a locus-aware
routing decision, not a measurement**, and `MeasurementRecord.locus` is already
the axis it needs. Left for the packet rather than changed here, because
conflating "deliverable to a container" with "usable by this process" is a
design question the policy's author should answer.

## Reproducing

```bash
for m in qwen2.5:0.5b qwen2.5:3b qwen2.5:7b; do
  for lane in cpu gpu; do
    scripts/bench-accel-lane.sh --lane $lane --force-lane --record \
      --gen-model "$m" --chunks <chunks.jsonl> --n 3 --reps 3
  done
done
tillandsias --capabilities | head -1   # accel_decode_crossover_b
```

Note the binary must be REBUILT before recording: a `target/release/tillandsias`
predating `model_params_b` accepts the payload and silently drops the field
(serde ignores unknown keys), so the measurement records with no parameter axis
and the crossover stays `Unmeasured`. Cost me one full matrix run.
