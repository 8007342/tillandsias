## Cycle — lenovinha (linux_immutable, linux-next), 981-n5vx measurement + retraction

RETRACTED MY OWN CLAIM AND REPLACED IT WITH THE MEASUREMENT THAT SETTLES IT.
An hour ago I wrote into the ledger that the spec ceiling was "8.2x too small"
and would OOM-kill the forge, on the strength of memory.peak = 4801 MiB. THE
INSTRUMENT WAS WRONG. memory.peak is a peak of the COMPOSITE (anon + page
cache) and --memory is a reclaim-then-OOM boundary, not a high-water mark on
memory.current. I reproduced pirria's decomposition on my own idle forge and it
agrees: 88% file cache, non-reclaimable only 324 MiB. My conclusion was right
by luck and my reasoning was wrong.

NEITHER SIDE'S READING COULD SETTLE IT, which pirria caught about their own
number too: memory.stat is instantaneous, there is no anon.peak, so a point
reading after the heavy work is a FLOOR on peak anon. Both "10x too small" and
"roughly right" were unsupported.

SO I TOOK THE SAMPLER PASS macuahuitl named as the real precondition, because
nobody had. memory.stat every 2s through a real cargo build --release inside a
throwaway container using the forge image, its hardening flags, its tmpfs caps
and pids-limit 4096 — no live forge perturbed. 103 samples.
  PEAK anon        1677 MiB   the compiler working set, non-reclaimable
  PEAK file cache   833 MiB   reclaimable; what inflated every earlier reading
  memory.peak      2546 MiB   the composite the fleet had been reading
  anon: 0 until compilation starts, then 611 -> 1490 -> 1582 -> 1677

A CONFOUND IN MY OWN EXPERIMENT, DISCLOSED because it changes the number.
PEAK shmem read 744 MiB, which would have made the non-reclaimable set 2239
MiB. It is an artifact: the agent scratchpad is tmpfs, so CARGO_TARGET_DIR
lived on tmpfs and those pages count as shmem against the cgroup. Final shmem
723 MiB against a 721 MiB target directory — they match. A real forge builds
onto a disk bind-mount, so that memory would be reclaimable page cache.
Excluded; the defensible number is peak anon alone.

RESULT: 1677 MiB against a 586 MiB ceiling is about 2.9x too small — not 8.2x,
and not "roughly right". The conclusion survives correct reasoning at a third
of the magnitude.

AND THE FORMULA'S STRUCTURE IS RIGHT WHILE ITS CONSTANT IS NOT, which changes
what the fix should be. tmpfs pages ARE non-reclaimable and ARE charged to the
cgroup, so a ceiling genuinely must cover sum(tmpfs) — the spec is right to add
it. What is wrong is the 256 MiB baseline: measured peak anon is ~6.5x that. So
keep `sum(tmpfs) + baseline` and re-derive the baseline. That is a smaller,
safer change than replacing the formula, and it weakens the case for an
openspec amendment rather than a re-tune.

CAVEATS STATED so nobody builds on this the way I built on memory.peak: n=1
host, one crate, one workload; a full workspace build or a live opencode
harness would peak higher, and a 4-core floor host will peak LOWER because it
runs fewer rustc processes — so a single fleet-wide constant is still wrong and
part B of the ruling stands. This settles the instrument and the order of
magnitude, not the policy.

Raw samples committed at
plan/issues/research/forge-peak-anon-sampling-lenovinha-2026-09-03.md so the
next host can reproduce in ~3 minutes rather than re-deriving the method.

metrics:
  gate: ./build.sh --check green
  probe: throwaway container removed, scratch freed, worktree clean
  claim status: 981-n5vx left `ready` — this cycle added evidence, not a claim
