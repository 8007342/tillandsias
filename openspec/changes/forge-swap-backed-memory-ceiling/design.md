## Context

A rootless podman container cannot own a swap device (`swapon` needs `CAP_SYS_ADMIN` in the initial user namespace; verified refused on macuahuitl). Swap therefore lives in the kernel that runs podman — the Linux host, the WSL2 utility VM, the macOS guest VM — and a container receives a per-cgroup allowance through cgroup v2 `memory.swap.max`. tmpfs pages are `shmem`, charged to the writer's cgroup and swappable, so a tmpfs with a swap allowance already behaves as the transparent RAM-disk extension the operator asked for; nothing new needs mounting. Fedora delegates `cpu io memory pids` to the user slice, so rootless podman can set every knob below.

## Goals / Non-Goals

**Goals**
- A forge survives a full tmpfs (ENOSPC or spill, never OOM) and a `cargo build` (measured working set, not a formula).
- Graceful degradation under pressure (`memory.high` throttling) before the hard limit.
- One sizing rule per host tier, derived from the workload, replacing "2 × RAM".
- Host swap provisioned on all three platforms with the operator's consent, never silently.

**Non-Goals**
- Pinning a mount to swap (the kernel's LRU chooses; no such mount class exists).
- Per-container swappiness (cgroup v1 rootful only).
- zswap (redundant with zram here; unmeasured).
- Loop-mounted squashfs/erofs images (not available rootless).

## Decisions

1. **Budget, not ceiling.** `--memory = memory.max`, `--memory-swap = memory.max + memory.swap.max`, `--memory-reservation = memory.low`, `--cgroup-conf memory.high=<bytes>` at 0.85 × `memory.max`. `memory.swap.max ≥ Σ(HOT caps) + 1 GiB` so a full tmpfs alone cannot reach `memory.max`.
2. **Host swap = disk behind zram.** zram stays (fast first tier); a disk swapfile at `pri=10` gives real capacity. Linux: `btrfs filesystem mkswapfile` under `/var/swap` (persistent across ostree deployments, never snapshotted), activated by a systemd `.swap` unit. WSL2: `swap=8GB`, `swapFile` under `%LocalAppData%\tillandsias`, `sparseVhd=true`, `autoMemoryReclaim=gradual`. macOS: a sparse raw `vm-swap.img` excluded from Time Machine as a second virtio block device, `mkswap`ed once in the guest, plus a 2 GiB guest zram.
3. **Sizing rule.** `host_swap = 4 GiB + Σ_concurrent(memory.swap.max)`; per-forge `memory.max = measured working-set peak + resident HOT share`; `pids.max = clamp(512 × nproc, 4096, 16384)` until `pids.peak` is measured. Provisional tier numbers live in the design doc and are constants until the measurement packet replaces them.
4. **Preflight.** Refuse when `MemAvailable < memory.high × 1.25`. When `SwapFree < memory.swap.max`, clamp the allowance to `SwapFree` and clamp HOT caps to fit, warn, and launch. On WSL2 measure Windows, not the guest.
5. **Mount classes.** HOT (tmpfs, swap allowed): `/home/forge/src`, `/tmp`, `/run/user/1000`, `/dev/shm`. QUARANTINE (tiny tmpfs): `.ssh`, `.config/gh`. WARM-RO (image layer or `:ro` bind): cheatsheets, tools, gitconfig. COLD (named volume): tool cache, spec index, mirror. Only HOT feeds the swap allowance.
6. **Balloon.** The macOS tray never inflates the balloon while a forge runs.

## Risks / Trade-offs

- `memory.high` can hold a cgroup in prolonged throttling; `memory.max` remains the backstop and `memory.events high` is logged.
- zram-only hosts spill into RAM at the compression ratio; the disk file is the fix, and it needs root, so the tray offers, the operator runs.
- A swapfile under `/var` on a nearly full disk fails at creation; the offer script checks free space first.
- Dirty page cache from cold-volume writes is charged to the forge; `memory.high` sits above the tmpfs sum by the measured working set.

## Migration Plan

1. Land the measurement packet's numbers (or provisional constants) in `tillandsias-core`.
2. Invert the equal-values test on the 437 work ref, rebase it onto this delta, relay.
3. Per-platform swap provisioning packets land independently.
4. Sync this delta into `openspec/specs/forge-hot-cold-split/spec.md` and archive.

## Open Questions

- Whether tmpfs + swap beats the cold volume for a working set at 2 × `memory.max` (the spill benchmark decides whether the HOT budget should be sized to stay resident).
- `pids.peak` on a 16-thread cargo build (1372-igkr): pids cgroup or `RLIMIT_NPROC`.
