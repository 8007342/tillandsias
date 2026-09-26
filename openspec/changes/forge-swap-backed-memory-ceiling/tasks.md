## 1. Measurement (blocks the final numbers, not the code shape)

- [ ] 1.1 Forge working-set peak: `memory.peak`, `memory.swap.current` peak, `pids.peak` per `CARGO_BUILD_JOBS` on a fat Linux host and a floor host, recorded as a measurement event.
- [ ] 1.2 Spill benchmark: write/read W ∈ {M/2, M, 2M} into `/home/forge/src` under `memory.max = M`, zram-only vs zram + disk, against the COLD volume as control.
- [ ] 1.3 Controls: `memory.swap.max = 0` OOM at ~M; `cargo build` under the 437 work ref's ceiling.

## 2. Container budget

- [ ] 2.1 `container_spec.rs`: `memory_reservation_mb`, `cgroup_conf(key, bytes)`; `memory_swap_mb` MUST be greater than `memory_mb` (builder refuses equality).
- [ ] 2.2 `preflight.rs`: `ForgeMemoryBudget { max_mb, high_mb, low_mb, swap_max_mb, pids_max }` from tier constants + HOT caps; `compute_memory_ceiling_mb` becomes the swap-allowance term.
- [ ] 2.3 `check_host_ram` compares `MemAvailable` with `high_mb × 1.25`; new `clamp_swap_allowance(swap_free_mb)`; WSL2 reads Windows figures (1337-7jr5).
- [ ] 2.4 Launch builders emit `--memory`, `--memory-swap`, `--memory-reservation`, `--cgroup-conf=memory.high=<bytes>`, `--pids-limit` from the budget; unit test asserts `--memory-swap > --memory`.
- [ ] 2.5 Accountability log carries the budget and the swap clamp decision.

## 3. Host swap provisioning

- [ ] 3.1 Linux: offer script (report target, free space, the `mkswapfile` + `.swap` unit commands); `--diagnose` prints `swap:` line.
- [ ] 3.2 Windows: `install-windows.ps1` writes absent `swap`, `swapFile`, `sparseVhd`, `autoMemoryReclaim` keys idempotently with consent (1339-r9xv).
- [ ] 3.3 macOS: `vz.rs` attaches `vm-swap.img` (sparse, Time Machine excluded); recipe bootstrap formats and enables it, plus guest zram; balloon never inflated while a forge runs.

## 4. Mount classes

- [ ] 4.1 Tag each forge mount with a class in the container profile; derive the swap allowance from HOT.
- [ ] 4.2 `/opt/cheatsheets` and tool trees move to WARM-RO when measured worth it.

## 5. Spec sync

- [ ] 5.1 Sync this delta into `openspec/specs/forge-hot-cold-split/spec.md`; invert `litmus:forge-hot-cold-split-shape`'s equal-values arm.
