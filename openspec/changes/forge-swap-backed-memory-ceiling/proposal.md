## Why

`forge-hot-cold-split` Requirement "--memory ceiling pairs with tmpfs caps" mandates `--memory == --memory-swap` at `sum(tmpfs caps) + 256 MB`. Implemented on `origin/work/437-forge-src-tmpfs-topology`, that caps an agent forge at roughly 850 MB with zero swap; a `cargo build` inside the forge cannot complete under it (437 review note, 2026-09-25), and a tmpfs that fills is answered by an OOM kill rather than ENOSPC or a spill. Measured 2026-09-26 on macuahuitl: 192 MiB written into tmpfs under a 64 MiB `memory.max` succeeds with swap allowed (spill to zram, zero OOM) and kills the writer with `memory.swap.max = 0`.

Operator ruling (437 decision event, 2026-09-26): the WSL2 and macOS VMs get generous swap, the native Linux host gets file-backed swap, and forges use swap-backed tmpfs as a transparent RAM-disk extension, sized in advance for a workload that will hammer it.

## What Changes

- **MODIFIED** `forge-hot-cold-split` Requirement "--memory ceiling pairs with tmpfs caps": the container budget becomes `memory.max` (hard), `memory.high` (throttle), `memory.low` (protected working set) and a positive `memory.swap.max` ≥ the sum of HOT tmpfs caps. `--memory-swap` MUST exceed `--memory`; the equal-values scenario is inverted.
- **MODIFIED** `forge-hot-cold-split` Requirement "Pre-flight RAM check refuses launch on insufficient host RAM": the RAM threshold is measured against `memory.high`, not the tmpfs sum; a swap shortfall clamps the allowance and warns rather than refusing; on WSL2 the figures come from Windows.
- **ADDED** Requirement "Host swap is provisioned for the tier": Linux disk swapfile behind zram (Silverblue-safe, under `/var`), `.wslconfig` `swap=` written idempotently, a dedicated sparse swap image plus zram in the macOS guest.
- **ADDED** Requirement "Forge mounts carry a class": HOT / QUARANTINE / WARM-RO / COLD, with the swap allowance derived from HOT only.
- `compute_memory_ceiling_mb` is retained as the swap-allowance formula; `FORGE_WORKING_SET_BASELINE_MB` becomes the `memory.low` floor.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `forge-hot-cold-split`: memory budget, preflight thresholds, host swap provisioning, mount classes.

## Impact

- `crates/tillandsias-core/src/preflight.rs` (`check_host_ram`, `compute_memory_ceiling_mb`, new budget struct), `crates/tillandsias-podman/src/container_spec.rs` (`memory_mb`, `memory_swap_mb`, `memory_reservation_mb`, `cgroup_conf`), `crates/tillandsias-headless/src/main.rs` (`build_forge_agent_run_args_with_vault`, `build_opencode_forge_args`), `crates/tillandsias-core/src/container_profile.rs` (`pids_limit` per tier).
- `scripts/install-windows.ps1` (idempotent `.wslconfig` swap keys, 1339-r9xv), `images/vm/bootstrap/` and `crates/tillandsias-vm-layer/src/vz.rs` (guest swap device), a Linux host-swap offer script.
- Litmus `litmus:forge-hot-cold-split-shape` and the `forge_launch_emits_equal_memory_and_memory_swap_ceiling` test on the 437 work ref invert: equal values become the refused shape.
- Design: `plan/issues/forge-memory-swap-architecture-design-2026-09-26.md`. Cheatsheet: `cheatsheets/runtime/forge-memory-tmpfs-swap.md`.
