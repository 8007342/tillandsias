# Forge memory, tmpfs and swap: architecture design (2026-09-26)

Filed by linux-macuahuitl-claude-20260926t004459z at the operator's request.
Ruling recorded verbatim as a `decision` event on order 437. Spec delta:
`openspec/changes/forge-swap-backed-memory-ceiling/`. Cheatsheet:
`cheatsheets/runtime/forge-memory-tmpfs-swap.md`.

## 1. The question

Order 437 (forge-src-tmpfs-topology) requires the forge launch builders to
emit `--memory == --memory-swap` derived from `compute_memory_ceiling_mb`
(sum of tmpfs caps + `FORGE_WORKING_SET_BASELINE_MB`, 256 MB). The commit on
`origin/work/437-forge-src-tmpfs-topology` does exactly that and the
coordinator held it (437 note, 2026-09-25): a forge capped at roughly 850 MB
with zero swap cannot run `cargo build`. 1372-igkr (rustc panics under
`pids.max=4096` on a 16-core host), 1349-53h6 (the 256 MB `/home/forge/src`
tmpfs exhausted by preflight scratch) and 1339-r9xv / 1337-7jr5 (WSL2 guest
shape and the gate reading the wrong machine's meminfo) are the same finding
seen from four sides: the forge's resource ceilings were set by formula, not
measured, and the formula has no headroom.

The operator asked for generous swap on the WSL2 and macOS VMs, file-backed
swap for the native Linux forge, and — if podman can do it — swap-backed
mounts that behave as a transparent RAM-disk extension, partitioned by
content class (cheatsheets, specs, tools).

## 2. What was measured on macuahuitl (read-only, 2026-09-26)

Host: Fedora 44, kernel 7.2.7, 20 cores, 62.4 GiB, btrfs (`compress=zstd:1`),
podman 5.8.7, cgroup v2, crun, systemd cgroup manager.

- Delegation: `user-1000.slice/cgroup.controllers` = `cpu io memory pids`,
  and `cgroup.subtree_control` carries the same four. Rootless podman on this
  host can set `memory.max`, `memory.high`, `memory.low`, `memory.swap.max`
  and `pids.max` on a container. (Fedora delegates these by default through
  `systemd`'s user-session slice; a host without `memory` in that file cannot
  enforce any of this rootless, and the launch must say so rather than
  pretend.)
- Swap: one device, `/dev/zram0`, 8 GiB, `lzo-rle`, priority 100, 0 used.
  `/usr/lib/systemd/zram-generator.conf` reads `zram-size = min(ram, 8192)`.
  No disk swap. `zswap` disabled. `vm.swappiness` = 10 (kernel default is 60,
  so this is a local tuning, not stock).
- tmpfs pages are charged to the writer's cgroup and are swappable. Probe A:
  `systemd-run --user --scope -p MemoryMax=64M -p MemoryHigh=48M
  -p MemorySwapMax=512M` writing 192 MiB into `/dev/shm`: `dd` rc=0,
  `memory.current` 47.8 MiB (`shmem` 44.5 MiB), `memory.swap.current`
  147.6 MiB on zram, `memory.events`: high=296, max=0, oom=0. Probe B, the
  same with `MemorySwapMax=0`: the writer was OOM-killed after 62.5 MiB.
  B is the shape the 437 work ref ships (`--memory-swap == --memory`).
- The same through rootless podman: `podman run --memory=64m
  --memory-swap=512m --memory-reservation=32m
  --cgroup-conf=memory.high=50331648 --pids-limit=256 --tmpfs
  /x:size=256m` gives `memory.max` 64 MiB, `memory.high` 48 MiB, `memory.low`
  32 MiB, `memory.swap.max` 448 MiB (podman writes `memory-swap − memory`,
  the cgroup v2 meaning), `pids.max` 256. 192 MiB written to `/x`: rc=0,
  149.8 MiB on swap, `oom_kill` 0, 326 throttle events. `--cgroup-conf`
  wants bytes: crun refuses `memory.high=48m`.
- A container cannot bring its own swap: `swapon` on a file in the
  container's tmpfs fails with `Operation not permitted`; the rootless
  effective capability set has no `cap_sys_admin`, and `swapon` needs it in
  the initial user namespace regardless. The operator's "podman mounts
  something as SWAP" is therefore realised one level up: swap is a host
  (or guest-VM) device, and what a container gets is a per-cgroup swap
  allowance.

## 3. The model

1. **Swap lives in the kernel that runs podman**: the Linux host natively,
   the WSL2 utility VM on Windows (`.wslconfig` `swap=`), the guest Linux VM
   on macOS (a swap device inside the guest). It is never per-container.
2. **A forge is a cgroup budget, not a ceiling**: `memory.max` (hard, OOM
   backstop), `memory.high` (throttle-and-reclaim, the kernel's stated main
   control), `memory.low` via `--memory-reservation` (protect the working
   set), `memory.swap.max` (how much of the host's swap this forge may
   occupy), `pids.max`.
3. **tmpfs is already the swap-backed mount the operator describes.**
   Every tmpfs page is `shmem`, charged to the container, kept in RAM while
   hot and spilled to swap when the cgroup is over `memory.high`. The
   "transparent RAM-disk extension" is `memory.swap.max > 0` on a host with
   swap — nothing else has to be mounted.
4. **Cold state stays on disk volumes**; its page cache is also charged to
   the container but is reclaimable without swap (writeback, then drop).
5. **The host RAM gate checks RAM against the working set and swap against
   the spill**, and degrades (clamps the swap allowance) rather than refusing
   when only swap is short.

### What the operator's partitioning idea can and cannot do

You cannot pin a mount to swap. The kernel's LRU chooses which pages of
which tmpfs spill; a "swap mount" as a filesystem class does not exist. What
does exist, and is enough:

- **Per-class tmpfs with its own cap** (already the pattern: `/home/forge/src`,
  `/tmp`, `/run/user/1000`, `/opt/cheatsheets`): the cap bounds how much of
  each class can ever be resident-or-swapped; the container's
  `memory.swap.max` bounds the total spill.
- **Read-only content that never needs swap** (tools, cheatsheets, specs):
  serve it from an image layer or a read-only bind; it is file-backed page
  cache, evicted for free and re-read from disk. Loop-mounting a squashfs or
  erofs image is not available rootless (it needs `CAP_SYS_ADMIN` for the
  mount), so the rootless spelling is `--mount type=image,src=<img>,dst=<path>,rw=false`
  or a `:ro` bind of an image-extracted directory. The forge already ships
  `/opt/cheatsheets-image` in the image and copies it into an 8 MB tmpfs;
  the tmpfs copy costs nothing measurable and stays for now.
- **Per-container `memory.high`** is the graceful-throttle knob the operator
  wants instead of OOM.

## 4. Platform designs

### 4.1 Linux native (macuahuitl, lenovinha, yoga, pirria)

- **Backing**: keep the distro zram (Fedora default, `min(ram, 8192)` MiB on
  F44 per `zram-generator.conf`; the upstream generator default is
  `min(ram / 2, 4096)`), and add a **disk swapfile at lower priority** for
  the spill. zram pages still occupy RAM (compressed; the probe's urandom
  pages compressed 1:1, source text and object files typically 2–3:1), so
  zram alone does not add capacity for a tmpfs that spills; it only makes
  the first gigabytes of spill fast. Fedora's SwapOnZRAM change documents
  the two coexisting with zram favoured by priority.
- **Silverblue-safe swapfile**: `/var` is a persistent, writable btrfs
  subvolume shared by every deployment, so `/var/swap/tillandsias.swap`
  survives `rpm-ostree` upgrades. Create with
  `btrfs filesystem mkswapfile --size <N>g` (btrfs-progs ≥ 6.1; it sets
  NODATACOW, which also disables the `zstd:1` compression and checksums the
  mount option would otherwise apply; the older spelling is `truncate -s 0`,
  `chattr +C`, `fallocate`, `mkswap`). Activate through a systemd `.swap`
  unit with `Options=pri=10`, below zram's 100. Constraint: the subvolume
  holding an active swapfile cannot be snapshotted; `/var` is not snapshotted
  by Silverblue, and `/home` (a separate subvolume here) would be the wrong
  place for exactly that reason. `zswap` is not layered in front (it is
  redundant with zram and this fleet has not measured it).
- **Consent**: swap provisioning needs root and changes the host; the tray
  reports the tier's target and offers the commands (the 1339-r9xv
  discipline: report and offer, never write silently). `--diagnose` prints
  `swap:<total> zram:<n> disk:<n> target:<tier>`.

### 4.2 Windows / WSL2 (yolanda, esmeraldinha)

- WSL2 defaults: `memory` = 50 % of host RAM, `swap` = 25 % of that memory
  rounded up to a GB, `swapFile` = `%Temp%\swap.vhdx`, `autoMemoryReclaim`
  = `dropCache`, `sparseVhd` = `false`. With `memory=8GB` the default swap is
  2 GB — below a single forge's spill allowance.
- Target `[wsl2]`: `memory=8GB` (unchanged), `swap=8GB`,
  `swapFile=%LocalAppData%\\tillandsias\\wsl-swap.vhdx` (a path we own, not
  `%Temp%`, which cleanup tools purge); `[experimental]`:
  `autoMemoryReclaim=gradual`, `sparseVhd=true`. The swap VHD is not backed
  up by anything Windows does by default; `sparseVhd` keeps the distro VHD
  from holding freed blocks.
- **Idempotent write, respecting the user's file**: parse the existing
  `.wslconfig` as INI; only add keys that are absent; never overwrite a
  present `memory`, `swap`, `swapFile` or `processors`; write a
  `# tillandsias:` comment above each key we add; if the file has a key we
  would change, report the diff and offer, as the installer's wsl-shape block
  already does for `memory`/`processors`/`autoMemoryReclaim`. Requires
  `wsl --shutdown` to apply (the 8-second rule).
- The gate's memory read must come from Windows, not the guest
  (1337-7jr5); the same applies to swap: the guest's `SwapTotal` is the
  `.wslconfig` value, the host's committed memory is what reaps the VM.

### 4.3 macOS / Virtualization.framework (macbookair, macneo)

- Today `guest_sizing` gives the VM half the host RAM, less
  `HOST_RESERVED_MEMORY_BYTES` (4 GiB), capped at `GUEST_MAX_MEMORY_BYTES`
  (8 GiB): 8 GiB on the 16 GiB MacBook Air. The configuration attaches a
  `VZVirtioTraditionalMemoryBalloonDeviceConfiguration`; the guest has no
  swap (the recipe's bootstrap scripts create none).
- Options weighed:
  - *swapfile on the guest root image*: simplest; the root `.img` is a
    250 GiB sparse raw file; a swapfile inside ext4 works, but the blocks
    it touches un-sparsify the root image permanently and travel with it.
  - *dedicated sparse raw disk image as a second `VZVirtioBlockDevice`*:
    a separate `swap.img`, created sparse on APFS, sized to the tier,
    `mkswap` once in the guest, `swapon` by the recipe's systemd unit.
    Excluded from Time Machine with `tmutil addexclusion` (the sticky
    `com.apple.metadata:com_apple_backup_excludeItem` attribute), so the
    swap never enters a backup; deleted and recreated freely with the VM.
    **Recommended.**
  - *zram in the guest*: cheap first tier (2 GiB, priority 100) in front of
    the disk device, same shape as Linux native. Include it.
- **Balloon**: `targetVirtualMachineMemorySize` is a request to the guest,
  not a limit; inflating it under a spilling forge takes RAM from the guest
  and increases swap. The tray must not inflate the balloon while a forge is
  running; use it only when no forge is active. The guest's own swap is what
  keeps a forge alive when the host is short.

## 5. Mount-class taxonomy for the forge

Enumerated from `build_forge_agent_run_args_with_vault` (agent lanes) and
`build_opencode_forge_args` on origin/linux-next.

| Class | Backing | Charged as | Reclaim | Mounts today |
|---|---|---|---|---|
| HOT | tmpfs, swap allowed | shmem | swap | `/home/forge/src` (`forge_hot_src_tmpfs`, 256–4096 MB), `/tmp` 256 MB, `/run/user/1000` 64 MB, `/dev/shm` (podman default 64 MB) |
| QUARANTINE | tmpfs, tiny | shmem | n/a | `/home/forge/.ssh` 1 MB, `/home/forge/.config/gh` 1 MB (security, not performance) |
| WARM-RO | image layer / read-only bind | file page cache | drop | `/opt/cheatsheets` (8 MB tmpfs copy of `/opt/cheatsheets-image`; class target is the image layer), `/opt/agents` tool trees, `/home/forge/.gitconfig` and known_hosts `:ro` |
| COLD | named volume on disk | file page cache (dirty → writeback) | writeback then drop | `forge_tool_cache_volume` (`$CARGO_HOME`, `CARGO_TARGET_DIR`, npm prefix), `forge_spec_index_volume`, the mirror volume |

Rules: only HOT counts against the swap allowance; `memory.swap.max` ≥ the
sum of HOT caps that can fill (so a full tmpfs alone can never OOM the
forge); COLD writers (cargo) are the reason `memory.high` must sit well
above the tmpfs sum, because dirty page cache is charged before writeback.

## 6. Sizing

RAM from the capability matrix (`system_ram_gb`): macuahuitl 62.4,
lenovinha 13.5 (16 threads), yoga 14.8 (12 threads), pirria 15.3 (4 cores),
esmeraldinha 15.8 host / 7.8 guest (4 cores), yolanda 15.2 host / 7.3 guest
(16 threads), macbookair 16 (10 cores), macneo unknown (6 cores).

Replace "2.25 × RAM". Red Hat's current table says swap for 8–64 GiB hosts
is "at least 4 GB" and, for larger hosts, "a function of system memory
workload, not system memory". Our workload is known: a forge deliberately
spills up to its HOT caps. So:

```
host_swap        = 4 GiB + Σ_concurrent_forges(memory.swap.max)     (disk-backed; zram is extra)
memory.swap.max  = Σ(HOT caps that can fill) + 1 GiB slack          (per forge)
memory.max       = working_set_peak(measured) + resident_hot_share  (per forge)
memory.high      = 0.85 × memory.max
memory.low       = working_set_baseline (the RSS a forge needs to stay responsive)
pids.max         = clamp(512 × nproc, 4096, 16384)                  (until 1372-igkr measures pids.peak)
```

Provisional numbers, to be replaced by the measurement packet:

| Tier | Hosts | Concurrent forges | Host swap (disk + zram) | memory.max / high / low | memory.swap.max | pids.max | cargo jobs |
|---|---|---|---|---|---|---|---|
| floor (~4 cores, 8–16 GiB; also every 8 GiB VM guest) | pirria, esmeraldinha, yolanda guest, macOS guest | 1 | 8 GiB + zram (2–8) | 3 / 2.5 / 1 GiB | 4 GiB | 4096 | 2–4 |
| fat Linux (12–16 threads, 13–15 GiB) | lenovinha, yoga | 2 | 16 GiB + zram 8 | 6 / 5 / 2 GiB | 8 GiB | 8192 | 8 |
| coordinator desktop (20 cores, 62 GiB) | macuahuitl | 4 | 16 GiB + zram 8 | 12 / 10 / 4 GiB | 12 GiB | 8192 | 16 |
| macOS VM (guest 8 GiB of 16) | macbookair | 1 | guest: 8 GiB sparse image + zram 2 | 3 / 2.5 / 1 GiB | 4 GiB | 4096 | 4 |
| Windows WSL2 (guest 8 GiB of 15–16) | yolanda, esmeraldinha | 1 | `swap=8GB` | 3 / 2.5 / 1 GiB | 4 GiB | 4096 (8192 on 16 threads) | 4 |

The 437 work ref's `FORGE_WORKING_SET_BASELINE_MB` = 256 becomes
`memory.low`'s floor, not the whole budget. `compute_memory_ceiling_mb`
survives as the swap-allowance formula (tmpfs sum + slack), which is what it
actually computes.

### Host RAM gate

`check_host_ram` today compares `MemAvailable` with `(tmpfs sum + 256) ×
1.25`: too strict when the tmpfs will not fill, too lax for a cargo build.
Redesign: refuse only when `MemAvailable < memory.high × 1.25`; when
`SwapFree < memory.swap.max`, clamp the allowance to `SwapFree` and warn
(the tmpfs caps are then clamped to fit, ENOSPC being recoverable and OOM
not). On WSL2 read the Windows figures (1337-7jr5). The refusal keeps the
accountability log the spec already requires.

## 7. What to measure before committing numbers

Packet: forge peak-RSS and tmpfs-spill benchmark (linux, lenovinha then
yoga; the coordinator desktop is the operator's and is never dispatched).

1. **Working-set peak.** Launch a forge with generous limits
   (`--memory=12g --memory-swap=24g`), inside it run `./build.sh --check`
   at `CARGO_BUILD_JOBS` ∈ {nproc, nproc/2, 4}; from the host poll the
   container's cgroup (`podman inspect --format '{{.State.CgroupPath}}'`)
   once a second for `memory.current`, `memory.swap.current`, `pids.current`;
   record `memory.peak`, `pids.peak`, `memory.events` at the end, and
   `ulimit -u` inside (EAGAIN on fork can be RLIMIT_NPROC, not the cgroup).
   Output per host: the three peaks per jobs setting.
2. **Spill benchmark.** In a forge with `memory.max = M`, write W ∈ {M/2, M,
   2M} MiB of files into `/home/forge/src`, then re-read them in a shuffled
   order; record wall time, `memory.events high`, `memory.swap.current`
   peak. Run once on a zram-only host and once after the disk swapfile is
   added; run the same write/read against the COLD volume. The falsifiable
   claim is "tmpfs + swap beats the disk volume for this working set at
   2M"; if it does not, the HOT budget should be sized to stay resident and
   the spill allowance is only an OOM guard.
3. **Controls**: the same write with `memory.swap.max = 0` (must OOM at
   ~M: the pre-fix shape), and one `cargo build` under the 437 work ref's
   ~850 MB ceiling (expected OOM, closes the review's estimate with a fact).

## 8. Packets (filed 2026-09-26; orders minted with `next-order`)

| Order | Packet | Role | Priority | Suggested host |
|---|---|---|---|---|
| 1375-xxzj | launch builders emit a cgroup budget with a swap allowance (replaces 437's equal ceiling) | linux | p1 | lenovinha, then yoga |
| 1378-7w2p | measure the forge's peak RSS, swap, pids.peak per jobs setting; tmpfs spill benchmark | linux | p1 | lenovinha (fat), then a floor host |
| 1376-8zdz | Linux host with only zram is offered a Silverblue-safe disk swapfile | linux | p1 | lenovinha, then yoga |
| 1377-hcnv | macOS guest VM gets a sparse swap image (Time Machine excluded) plus zram | macos | p2 | tlatoanis-macbook-air |
| 1379-vvct | every forge mount carries a class; swap allowance from HOT only | any | p3 | any |

Events (no new rows): 1339-r9xv carries the `.wslconfig` swap keys
(windows, yolanda); 1337-7jr5 carries the host-side swap read on WSL2;
1372-igkr carries the pids sizing rule and the `pids.peak` / `ulimit -u`
measurement; 437 carries the operator ruling (decision) and this packet
list (note).

Dependency order: 1378-7w2p (numbers) → 1375-xxzj (can land with the
provisional constants, then retune) → 1376-8zdz, 1377-hcnv and the
1339-r9xv swap keys (independent of each other) → 1379-vvct.

## 9. Sources

- cgroup v2 memory controller (`memory.high`, `memory.max`,
  `memory.swap.max`, `memory.low`, shmem accounting):
  https://docs.kernel.org/admin-guide/cgroup-v2.html
- tmpfs lives in page cache and swap; `noswap` option; `size=`:
  https://docs.kernel.org/filesystems/tmpfs.html
- zswap: https://docs.kernel.org/admin-guide/mm/zswap.html
- zram-generator defaults (`min(ram / 2, 4096)`, priority 100,
  `writeback-device`):
  https://github.com/systemd/zram-generator/blob/main/man/zram-generator.conf.md
- Fedora SwapOnZRAM change (zram + disk swap coexist, zram favoured by
  priority; eviction caveat): https://fedoraproject.org/wiki/Changes/SwapOnZRAM
- Red Hat swap sizing table ("at least 4 GB" for 8–64 GiB; workload, not
  RAM, above that):
  https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/managing_storage_devices/getting-started-with-swap_managing-storage-devices
- Chris Down, "In defence of swap" (swap is for equal reclaim, not
  emergency memory; size to observed peak plus buffer; cgroup v2
  `memory.low`): https://chrisdown.name/2018/01/02/in-defence-of-swap.html
- btrfs swapfile rules (`mkswapfile`, NODATACOW, no compression, no
  snapshot of the holding subvolume):
  https://btrfs.readthedocs.io/en/latest/Swapfile.html
- podman run `--memory`, `--memory-swap`, `--memory-reservation`,
  `--pids-limit`, `--cgroup-conf`, rootless cgroup v2 requirement:
  https://docs.podman.io/en/latest/markdown/podman-run.1.html
- `.wslconfig` `memory`, `swap`, `swapFile`, `autoMemoryReclaim`,
  `sparseVhd` and defaults:
  https://learn.microsoft.com/en-us/windows/wsl/wsl-config
- Apple `VZVirtioTraditionalMemoryBalloonDevice` /
  `targetVirtualMachineMemorySize`:
  https://developer.apple.com/documentation/virtualization/vzvirtiotraditionalmemoryballoondevice
- Time Machine exclusion (`tmutil addexclusion`, sticky xattr):
  https://ss64.com/mac/tmutil.html
