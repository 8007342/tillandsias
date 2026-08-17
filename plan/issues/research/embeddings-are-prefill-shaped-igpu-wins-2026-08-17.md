# Embeddings are prefill-shaped work, so the iGPU wins them — correcting two earlier "GPU is slower for embeddings" results, including my own

- classification: research
- filed: 2026-08-17 (windows/ESMERALDINHA, cycle 12)
- status: measured; **corrects this host's cycle-1 claim** and qualifies
  793-zumy's embedding row
- related: **793-zumy** (Yolanda's AMD dzn measurement — its embedding row is
  qualified here, not contradicted), 552 (re-embed cost),
  `intel-igpu-dzn-in-wsl2-measured-2026-08-17.md`,
  `esmeraldinha-lower-bound-inference-floor-2026-08-16.md` (corrected),
  `accel-capability-envelope-and-routing-2026-08-16.md` (routing consumer)

## Result

`nomic-embed-text`, 40 **real** corpus chunks (p50 254 chars), in
`tillandsias-build`, three interleaved repetitions per lane so both arms share
any drift, offload verified per arm rather than assumed:

| lane | offload | per-chunk ms (3 reps) | median |
|---|---|---|---:|
| CPU | `vram=0` (0%) | 593.0 / 586.6 / 584.4 | **586.6** |
| dzn iGPU | `vram=323150151 = size` (100%) | 543.2 / 449.9 / 460.3 | **460.3** |

**The iGPU is ~22% faster for embeddings.** (rep1 on the dzn arm at 543.2 is the
cold-dispatch tail still settling — the same effect measured in cycle 9, where
the first prefill after load reads near CPU speed.)

## Why this is the expected answer, not a surprise

An embedding is **one forward pass over the input and no decode phase at all**.
That is prefill-shaped work: batched GEMM, compute-bound, high arithmetic per
byte moved. It is exactly the shape the iGPU wins — cycle 9 measured prefill at
**2.16x** on this same device.

So the earlier "GPU is slower for embeddings" results were the anomaly, and the
unified rule is simpler than the two exceptions it replaces:

> **Route by workload shape.** Prefill-shaped work (prompt processing,
> embeddings) to the iGPU; decode-shaped work (token generation) to the CPU on
> this class of part.

## Correcting my own cycle-1 claim

`esmeraldinha-lower-bound-inference-floor-2026-08-16.md` reported:

> `nomic-embed-text` (137M) was **worse** on Vulkan: 4287 ms/chunk vs ~2714
> ms/chunk on CPU (**-58%**)

and that figure was then used to argue an embedding-specific exception, and
survived as "the one genuine loss stands" even after the crossover claim around
it was withdrawn in cycle 5.

**It does not stand.** Two defects in that measurement, both of which this loop
only learned about later:

1. **No warm-up discipline.** It was taken before cycle 9 established that the
   first dispatch on a Vulkan/dzn path pays pipeline compilation and reads at
   roughly CPU speed. A short run dominated by cold dispatch produces exactly
   the "GPU is slower" shape observed.
2. **Synthetic input ~8x the real chunk size.** It used a ~2,000-char synthetic
   chunk against a real corpus p50 of **254 chars**, so it was not measuring the
   workload it was being used to reason about.

The corrected figure is the table above. The lesson is the one this host keeps
re-learning in different clothes: **a number carried forward from a superseded
methodology stays wrong even when the conclusion around it gets fixed.** Cycle 5
withdrew the crossover claim and explicitly preserved the embedding exception —
preserving, it turns out, the part that was actually measurement error.

## Qualifying 793-zumy rather than contradicting it

Yolanda measured, on AMD 860M via dzn, embeddings **1.16x slower** on the GPU
(8.7 ms vs 10.2 ms wall per request) — and attached the right caveat
themselves:

> Caveat: absolute values are small enough that HTTP and tokenizer overhead are a
> meaningful share, so treat these as a *relative* comparison only.

At ~9 ms per request, per-request fixed cost plausibly dominates. This host's
chunks take **~500 ms**, so fixed overhead is under 2% and the compute
difference is visible. **Both results can be true**: at a few milliseconds the
overhead decides, at half a second the compute decides. That is a threshold
about *request size*, not a disagreement about hardware — and it is worth
recording because a routing policy derived from either number alone would be
wrong for the other regime.

## Consequence for order 552

Re-embed cost on the dzn lane is ~22% lower. Applied to the corpus figures:

| | CPU | dzn |
|---|---:|---:|
| per chunk | ~586 ms | ~460 ms |
| full rebuild (9,909 chunks) | ~115 min | ~90 min |
| a 4%-of-commits delta (21-63 chunks) | ~15-45 s | ~12-35 s |

**This does not change the design conclusion.** The cost stays bimodal — free on
96% of commits, tens of seconds on the other 4% — and 12-35 s is still in the
operator's "unusable" band. Async remains required for the tail. A 22% saving on
a number that must move off the commit path anyway is not the lever.

It does mean that **if** the re-embed runs on this host, it should run on the dzn
lane. That is a routing input, not a reason to change 552's shape.

## Method note

This measurement was invalidated twice before it was trusted, and both catches
came from checks rather than from noticing:

1. A first run reported dzn 14% faster — but `offload=0` on **both** arms. The
   dzn server had failed to start (`bind: address already in use`, the previous
   arm still holding the port), so "dzn" was measured against the still-running
   CPU server. Fixed by giving each arm a **distinct port** instead of relying on
   teardown.
2. The corrected single-rep run showed only ~6%, small enough to be variance.
   Three interleaved reps per arm resolved it to ~22% and exposed the cold rep.

Neither error was visible in the numbers themselves — both were plausible.
`offload` read back from `/api/ps` is what caught the first; repetition is what
caught the second.
