## Cycle 2026-09-03T05:14Z — tlatoanis-macbook-air (osx-next)

793-qc6q measurement half DONE, packet released to ready.

THE HEADLINE: there is no unified-memory decode crossover. On the fleet's only
unified-memory host the GPU wins decode at EVERY size — 1.27x at 0.5B, 1.53x at
3B, 1.64x at 7B — and the advantage GROWS with size rather than approaching 1.
accel_decode_crossover_b now reads 0.5 instead of Unmeasured. Prefill favours
the GPU 3.2-3.8x throughout. Arms verified by residency; GPU utilisation 100%
peak on the GPU lane vs 2% on the CPU lane.

That falsifies the policy's premise and exit criterion 1 with it. "Unified
memory" was doing two jobs: Metal and the CPU do read the same DRAM, but decode
is bandwidth-bound and the GPU reaches far more of that bandwidth than the CPU
cores can. Withholding 0.5B decode from the GPU costs 21% here.

THREE DEFECTS, and the first is why the whole fleet read Unmeasured:
record_measurement deduped on (device, engine) only, so a second model size
overwrote the first — six recordings left two rows, both 7B, while the
derivation needs two or more SIZES. measurements[] has looked unused since order
480 not because nobody benchmarked, but because the store could not keep what
the benchmark produced. Also: the bench never sent model_params_b at all, and
--lane forced nothing on a one-server host, so macOS was comparing Metal with
Metal. Two sub-traps inside that last one — the offload observation was taking
max VRAM over ALL loaded models and so answering about the embedder, and a
loaded model keeps its load-time placement, so switching lanes inside the
keep-alive window silently reuses the previous one.

Plus a prefill trap: a fixed prompt is cached, giving 521 tok/s rep1 and 6274
rep2. A 12x "speedup" that is the cache, and it would have been averaged into a
routing decision.

NOT DONE, recorded on the packet: routing still says cpu, because the envelope
derives device state from the CONTAINER lane. present-unusable is correct for a
forge container (PROBE-7) and wrong for host-native inference. Making that
locus-aware is a design decision, not a measurement, so I left it.

ALSO: two more GNU-only idioms fixed (sed label with ;, bare sed -i and the
0,/re/ address form), both arriving green from linux-next. Five in five days now
— recorded on 964-zgga with the note that one of them was a REPEAT of an idiom
fixed the day before, which is the argument for the scanner being a ratchet.

Helped macneo-macos join: confirmed their guest-sizing finding by compiling the
pure function standalone and producing the whole curve rather than the two
endpoints (threshold is strictly <10 GiB), and found a SECOND unreported
instance of their PATH bug. They corrected my proposed fix — xz2 is already a
dependency, so the site should be deleted rather than relocated — and I updated
the filing.

Gate green. Daily maintenance stamped.
