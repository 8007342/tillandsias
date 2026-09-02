# The N150 floor baseline — 63 measurements, native podman

Measured by pirria (dedicated solo benchmark agent, self-banked idle
loadavg 0.17 start / re-checked end), 2026-09-02, forge guest at stable
ad4a84773 on CachyOS. CAVEAT carried from the author: the run window
overlaps the tokei brew bootstrap discovered later — treat as
good-quality-with-a-known-hazard, single-run throughout. Regime:
N150/4c/15GiB/zram/btrfs-NVMe/native-podman/cpu-only/no-AVX512.

## Scheduling numbers (act on these)

- **Effective fan-out is 3.0, not 4.** Sustained all-core scaling 3.11x;
  DRAM read scales only 2.20x across 4 cores (13.15 -> 28.94 GiB/s) —
  memory bandwidth is the ceiling; cache-resident work scales, DRAM-bound
  work does not.
- **Sustained clock 2900MHz vs 3600 nameplate** (-19%), NOT thermal
  (holds single-core and across 70s) — nameplate-derived budgets are 19%
  optimistic before parallelism.
- **Cargo cannot saturate cores on small graphs**: 12-crate cold debug
  build -j4 = 6.57s vs -j1 = 12.20s (1.86x). Independently supports the
  959 conclusion: builds never approached pids.max on this class.
- **No fast linker, no sccache**: lld/mold/gold/sccache ALL absent,
  plain GNU ld links everything — the serial link tail is unmitigated on
  the class that feels it most (see packet 961-flnk).
- **zram swap bills the build's own cores**: ~7.6 core-seconds per GiB
  swapped (zstd 135 MiB/s/core compress) with swappiness=150 and no disk
  swap — memory pressure converts directly to CPU loss, a different
  failure shape from disk-swap hosts.
- **Shell costs**: external command = 120x a bash builtin (0.55ms vs
  0.005ms); python3 -c = 14.1ms per invocation — fixtures looping over
  subprocesses pay real time invisible on fast hosts.
- **Page-cache residency dominates I/O feel** (cold reads 3.1x slower
  than warm; read slower than write on this NVMe) — the mechanism behind
  the 15-vs-7.8GiB RAM confound in all cross-host comparisons.

## Non-bottlenecks (do not over-budget these)

git status 21-23ms, git log 3-4ms, rg full-repo 28-42ms — interactive
agent feel is fine on the floor.

## Hazard census for CI authors

Absent from the guest: openssl CLI, zstd CLI, fio, sysbench, stress-ng,
bc. Any step assuming them fails here; run-litmus-test.sh already works
around bc with awk scaled-integer arithmetic (the _lt_l100 trick), so at
least one author knew. AVX-512 absent on BOTH floor hosts — a dependency
gating a fast path on avx512f silently takes the slow path, undetectable
from timing alone.

## Reference micro-numbers

fork+exec /bin/true 0.54-0.59ms | bash -c true 1.39ms | $() 0.82ms |
rustc --version 13.4ms | no-op rebuild 0.02s | leaf-touch incremental
0.26s | 9k-line crate: check 1.44s, debug 3.07s, release 3.78s |
12-crate hello-world debug target = 127MB (why a 256MiB /tmp cannot hold
targets) | btrfs creates 39k/s | seq write 1.1-2.7GB/s, read 0.9-2.9GB/s
| DRAM read 12.99 GiB/s single-core.
