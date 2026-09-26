---
tags: [forge, memory, tmpfs, swap, zram, cgroup-v2, podman, wsl2, virtualization-framework, silverblue]
languages: [bash]
since: 2026-09-26
last_verified: 2026-09-26
sources:
  - https://docs.kernel.org/admin-guide/cgroup-v2.html
  - https://docs.kernel.org/filesystems/tmpfs.html
  - https://docs.podman.io/en/latest/markdown/podman-run.1.html
  - https://btrfs.readthedocs.io/en/latest/Swapfile.html
  - https://github.com/systemd/zram-generator/blob/main/man/zram-generator.conf.md
  - https://fedoraproject.org/wiki/Changes/SwapOnZRAM
  - https://learn.microsoft.com/en-us/windows/wsl/wsl-config
  - https://developer.apple.com/documentation/virtualization/vzvirtiotraditionalmemoryballoondevice
  - https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/managing_storage_devices/getting-started-with-swap_managing-storage-devices
authority: high
status: draft
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: true
---
# Forge memory, tmpfs and swap

@trace spec:forge-hot-cold-split

**Version baseline**: podman 5.8, crun, cgroup v2, kernel ≥ 6.1 (btrfs
`mkswapfile`), WSL 2.x, macOS 14+ Virtualization.framework.
**Use when**: a forge OOMs, a tmpfs fills, a host has only zram, or you are
sizing `--memory` / `--memory-swap` / `--pids-limit` for a container that
compiles.

Design: `plan/issues/forge-memory-swap-architecture-design-2026-09-26.md`.
Platform commands below marked **verified** were run on macuahuitl (Fedora
44, rootless podman) on 2026-09-26; the others are transcribed from the
upstream sources and await a run on their platform.

## The model in one table

| Layer | Where | Knob |
|---|---|---|
| Swap device | host kernel (Linux), WSL2 utility VM, macOS guest VM | zram, `swapfile`, `.wslconfig swap=`, guest swap image |
| Per-forge budget | cgroup v2 | `memory.max` (`--memory`), `memory.high` (`--cgroup-conf`), `memory.low` (`--memory-reservation`), `memory.swap.max` (`--memory-swap − --memory`), `pids.max` |
| Hot data | tmpfs (`--tmpfs path:size=Nm`) | charged as `shmem`; spills to swap when over `memory.high` |
| Cold data | named volumes | page cache; reclaimed by writeback, no swap needed |

A container can never `swapon` (needs `CAP_SYS_ADMIN` in the initial
namespace; **verified**: `swapon: Operation not permitted` rootless). Swap
is provisioned on the host; the container gets an allowance.

## Quick reference: reading a forge's budget

```bash
# host side: the container's cgroup
cg=$(podman inspect --format '{{.State.CgroupPath}}' <container>)
cat /sys/fs/cgroup$cg/memory.{max,high,low,swap.max,current,swap.current,peak}
grep -E '^(shmem|file|anon) ' /sys/fs/cgroup$cg/memory.stat
cat /sys/fs/cgroup$cg/memory.events        # high / max / oom / oom_kill counters
cat /sys/fs/cgroup$cg/pids.{max,current,peak}

# inside the container (cgroup namespace makes it /sys/fs/cgroup)
cat /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory.swap.max /sys/fs/cgroup/pids.max
```

`memory.events oom_kill > 0` means the hard limit killed something;
`high` counts throttle episodes and is normal under a spilling tmpfs.

## Launching with a budget (verified, rootless, Fedora)

```bash
# 64 MiB hard, 48 MiB throttle, 32 MiB protected, 448 MiB of swap allowed
podman run --rm \
  --memory=64m --memory-swap=512m --memory-reservation=32m \
  --cgroup-conf=memory.high=50331648 \
  --pids-limit=256 \
  --tmpfs /x:size=256m,mode=1777 \
  registry.fedoraproject.org/fedora-toolbox:44 \
  bash -c 'dd if=/dev/urandom of=/x/probe bs=1M count=192 status=none; echo rc=$?;
           cat /sys/fs/cgroup/memory.swap.current; grep oom_kill /sys/fs/cgroup/memory.events'
# rc=0, ~150 MiB on swap, oom_kill 0.  With --memory-swap=64m (equal): the writer is killed.
```

Pitfalls:
- `--memory-swap` is memory **plus** swap; podman writes the difference to
  `memory.swap.max`. Equal values mean zero swap.
- `--cgroup-conf=memory.high=` takes **bytes** only; crun refuses `48m`.
- `--memory-swappiness` is cgroup v1 rootful only; on v2 swappiness is
  host-global (`/proc/sys/vm/swappiness`; kernel default 60).
- Rootless limits need `memory` and `pids` in
  `/sys/fs/cgroup/user.slice/user-$(id -u).slice/cgroup.controllers`
  (**verified** present on Fedora 44). Without them podman silently runs
  unlimited.
- `--memory-reservation` maps to `memory.low` (protection), not to a
  second ceiling.

## tmpfs spills: proving it without podman (verified)

```bash
systemd-run --user --scope -q -p MemoryMax=64M -p MemoryHigh=48M -p MemorySwapMax=512M \
  bash -c 'dd if=/dev/urandom of=/dev/shm/probe bs=1M count=192 status=none; echo rc=$?;
           cg=/sys/fs/cgroup$(cut -d: -f3 /proc/self/cgroup);
           grep -E "^shmem " $cg/memory.stat; cat $cg/memory.swap.current; cat $cg/memory.events'
rm -f /dev/shm/probe
```

## Linux host swap

### Inspect (verified)

```bash
swapon --show --bytes
cat /sys/block/zram0/disksize /sys/block/zram0/comp_algorithm /sys/block/zram0/mm_stat
cat /usr/lib/systemd/zram-generator.conf /etc/systemd/zram-generator.conf 2>/dev/null
cat /sys/module/zswap/parameters/enabled   # N here
```

Fedora 44 ships `zram-size = min(ram, 8192)` (the generator's own default is
`min(ram / 2, 4096)`). zram pages live in RAM compressed; incompressible
data (the urandom probe) gets no saving. zram is the fast first tier, not
capacity for a spilling tmpfs.

### Add a disk swapfile behind zram (btrfs, Silverblue-safe; not yet run on a Silverblue host)

```bash
sudo mkdir -p /var/swap
sudo btrfs filesystem mkswapfile --size 16g /var/swap/tillandsias.swap   # btrfs-progs >= 6.1, sets NODATACOW
sudo tee /etc/systemd/system/var-swap-tillandsias.swap >/dev/null <<'EOF'
[Unit]
Description=Tillandsias forge spill swap (disk, behind zram)
[Swap]
What=/var/swap/tillandsias.swap
Options=pri=10
[Install]
WantedBy=swap.target
EOF
sudo systemctl daemon-reload && sudo systemctl enable --now var-swap-tillandsias.swap
swapon --show     # zram0 prio 100, the file prio 10
```

Older btrfs-progs: `truncate -s 0 f; chattr +C f; fallocate -l 16G f;
chmod 600 f; mkswap f`. Rules: single-device filesystem, no compression on
the file (NODATACOW implies it), the holding subvolume cannot be
snapshotted while the swap is active — `/var` on Silverblue is not
snapshotted and persists across deployments; `/home` here is a separate
subvolume and would be the wrong place if snapshots are ever taken there.
Do not put the file on `/` of an ostree system (read-only bind).

## WSL2 (`%UserProfile%\.wslconfig`; apply with `wsl --shutdown`)

Defaults: `memory` 50 % of Windows RAM; `swap` 25 % of that memory rounded
up to a GB; `swapFile` `%Temp%\swap.vhdx`; `autoMemoryReclaim` `dropCache`;
`sparseVhd` `false`.

```ini
[wsl2]
memory=8GB
processors=<all logical CPUs>
swap=8GB
swapFile=C:\\Users\\<you>\\AppData\\Local\\tillandsias\\wsl-swap.vhdx

[experimental]
autoMemoryReclaim=gradual
sparseVhd=true
```

Only add keys that are absent; never overwrite a user's `memory`, `swap`,
`swapFile` or `processors`. Inside the guest `free -m` shows the VM's swap
(= `swap=`), not the Windows state that reaps the VM (1337-7jr5).
Inspect: `wsl -e sh -c 'cat /proc/swaps; cat /sys/fs/cgroup/cgroup.controllers'`.

## macOS Virtualization.framework guest

The guest boots with no swap. Recommended shape (not yet run on a Mac):

```bash
# host: a sparse raw image, excluded from Time Machine, as a second virtio block device
truncate -s 8G "$HOME/Library/Application Support/tillandsias/vm-swap.img"
tmutil addexclusion "$HOME/Library/Application Support/tillandsias/vm-swap.img"
xattr -l "$HOME/Library/Application Support/tillandsias/vm-swap.img"   # com_apple_backup_excludeItem

# guest (recipe bootstrap): format once, activate every boot; zram 2 GiB in front
mkswap /dev/vdb
printf '[Swap]\nWhat=/dev/vdb\nOptions=pri=10\n[Install]\nWantedBy=swap.target\n' > /etc/systemd/system/dev-vdb.swap
printf '[zram0]\nzram-size = 2048\n' > /etc/systemd/zram-generator.conf
```

Balloon: `VZVirtioTraditionalMemoryBalloonDevice.targetVirtualMachineMemorySize`
is a request to the guest, not a cap; do not inflate it while a forge runs.

## Sizing rule (replaces "2 × RAM")

```
host_swap (disk)  = 4 GiB + Σ_concurrent_forges(memory.swap.max)
memory.swap.max   = Σ(HOT tmpfs caps that can fill) + 1 GiB
memory.max        = measured working-set peak + resident HOT share
memory.high       = 0.85 × memory.max
memory.low        = working-set baseline
pids.max          = clamp(512 × nproc, 4096, 16384)
```

Red Hat: 8–64 GiB hosts "at least 4 GB", above that "a function of system
memory workload, not system memory". Chris Down: size swap to observed peak
plus buffer; swap exists so anonymous and file pages reclaim equally.

## Common pitfalls

- `--memory == --memory-swap` (the pre-2026-09-26 spec) turns a full
  tmpfs into an OOM kill instead of ENOSPC-or-spill.
- A cgroup's dirty page cache from `cargo` writes to a volume is charged
  before writeback; `memory.high` must sit well above the tmpfs sum or a
  build throttles on its own output.
- zram-only hosts: the "spill" still consumes RAM at the compression
  ratio; add the disk file.
- `fork: retry: Resource temporarily unavailable` can be `RLIMIT_NPROC`
  (`ulimit -u`) rather than `pids.max`; read `pids.peak` before raising the
  limit (1372-igkr).
- Do not loop-mount squashfs/erofs rootless; use
  `--mount type=image,src=<img>,dst=<path>,rw=false` or a `:ro` bind for
  read-only tool trees.
