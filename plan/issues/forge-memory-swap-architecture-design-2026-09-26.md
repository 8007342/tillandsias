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
| 1380-zmpi | every installer ends with a PENDING ACTIONS banner (Linux: the one-time sudo command; Windows: restart required; macOS: none) | any | p1 | any; Windows arm on yolanda, macOS arm on macbookair |

Events (no new rows): 1376-8zdz carries the second ruling (decision) and the per-launch closure (amendment); 1339-r9xv carries the `.wslconfig` swap keys and the per-VM-boot variant
(windows, yolanda); 1337-7jr5 carries the host-side swap read on WSL2;
1372-igkr carries the pids sizing rule and the `pids.peak` / `ulimit -u`
measurement; 437 carries the operator ruling (decision) and this packet
list (note).

Dependency order: 1378-7w2p (numbers) → 1375-xxzj (can land with the
provisional constants, then retune) → 1376-8zdz, 1377-hcnv and the
1339-r9xv swap keys (independent of each other) → 1379-vvct.

## 9. Per-launch ephemeral swap (operator rulings of 2026-09-26, second and addendum)

Ruling (decision event on 1376-8zdz): consent to a swapfile, but "a new
swapfile every launch … thrown away and deleted on shutdown"; the installer
prints the one-time command and a big pending-actions banner. Addendum: the
one-time step may create a group with the right permissions so every future
tray launch starts and stops its own swap; 8 GiB floor growing to 16/24 GiB
on generous disks; does this need SELinux, and does it force an RPM?

Section 4.1's persistent `/var/swap/tillandsias.swap` is superseded by this
section. Sections 4.2 and 4.3 keep their sizes; their lifetime becomes
per VM boot, as stated below.

### 9.1 Linux native: a root-owned template service, started per launch

What was verified on macuahuitl (Fedora 44, systemd 259, polkit 127,
SELinux enforcing) and what was not, is marked.

**Mechanism.** One-time, printed by the installer:
`sudo tillandsias-install-swap-service` (a bundled script; the tray never
runs sudo itself). It installs:

- `/etc/systemd/system/tillandsias-swap@.service` — `Type=oneshot`,
  `RemainAfterExit=yes`, `EnvironmentFile=/etc/tillandsias/swap.conf`,
  `ExecStartPre=<helper> reap`, `ExecStart=<helper> start %i`,
  `ExecStop=<helper> stop %i`, `TimeoutStopSec=5min`, `ProtectHome=yes`,
  `NoNewPrivileges=yes`. *Verified*: `systemd-analyze verify` accepts the
  template, the gc service and the timer as drafted (with a stand-in helper
  path).
- `/usr/local/libexec/tillandsias-swap` (root-owned, 0755; on ostree hosts
  `/usr/local` is `/var/usrlocal`, writable and persistent — ostree docs).
  The instance string is opaque: the helper refuses anything outside
  `[A-Za-z0-9-]{1,64}`; size, directory and priority come from the
  root-owned `/etc/tillandsias/swap.conf` (or are computed by the helper,
  §9.6), never from `%i`, so there is no path or size injection.
  `start`: `btrfs filesystem mkswapfile --size <N> /var/swap/tillandsias-<id>`
  on btrfs (*verified* on a fresh file: NODATACOW set, fully allocated —
  `du` equals apparent size), else `fallocate` + `chmod 600` + `mkswap`
  (*verified* `fallocate` allocates fully on btrfs); `chcon -t swapfile_t`
  (§9.7); `swapon -p 10` (below zram's 100). `stop`: `swapoff` + `rm`.
  `reap`: delete `/var/swap/tillandsias-*` that `/proc/swaps` does not list
  (crash or reboot leftovers; nothing re-activates them at boot because no
  instance is enabled).
- `/etc/polkit-1/rules.d/50-tillandsias-swap.rules` — grants
  `org.freedesktop.systemd1.manage-units` only when
  `action.lookup("unit")` matches `^tillandsias-swap@[A-Za-z0-9-]{1,64}\.service$`
  and `action.lookup("verb")` is `start` or `stop`, to
  `subject.isInGroup("tillandsias")` or the installing `subject.user`.
  *Verified*: systemd builds the polkit details as
  `{"unit", id, "verb", verb}` in `bus_verify_manage_units_async_impl`
  (`src/core/dbus-util.c`) and `StartUnit`/`StopUnit` pass the job type
  (`start`/`stop`); polkit 127's JS API (`action.lookup`,
  `subject.isInGroup`) is the one Fedora's own `50-libvirt.rules` uses; the
  rule's logic was exercised under node with fixture subjects (YES for
  start/stop of a matching unit, NO otherwise). *Not verified*: polkitd
  evaluating the installed file (needs root to install).
- `tillandsias-swap-gc.timer` (every 2 min) → `gc`: for each active
  instance, `flock -n` on the tray's lease
  `/run/user/<uid>/tillandsias/swap-<id>.lease`; if the lock is acquirable
  the tray is gone, so `systemctl stop tillandsias-swap@<id>`. *Verified*:
  `flock -n` is refused while the holder lives and succeeds after it exits.
  A user-manager `BindsTo=`/`StopWhenUnneeded=` cannot reach a system unit,
  which is why the lease exists.

**Per launch.** The tray: open and `flock` the lease → `systemctl start
tillandsias-swap@<launch-id>` (no password, via the rule) → `podman run`
with `memory.swap.max` set → on stop: `podman rm` → `systemctl stop
tillandsias-swap@<launch-id>` → close the lease.

**swapoff cost.** `swapoff` must page back into RAM everything still on the
device. The order above removes the forge first; *verified* here that swap
use returned to zero once the probe's tmpfs and cgroup were gone, so the
file is normally empty at `stop` and `swapoff` is O(ms). If another tenant
spilled onto it (possible: the kernel fills higher-priority zram first and
only then this file), `swapoff` reads those pages back — bounded by the file
size and RAM; `TimeoutStopSec=5min` is the backstop. Wall time with a
loaded file is a measurement for 1376-8zdz (needs root).

**Silverblue.** `/etc` is per-deployment with a three-way merge that keeps
local files; `/var` is persistent and shared across deployments; `/usr` is
read-only (ostree and rpm-ostree docs). Everything above lives in `/etc`,
`/var/swap` and `/var/usrlocal`, so it survives upgrades without layering.

### 9.2 WSL2: per VM boot, not per forge launch

WSL creates the swap VHD at VM start when the configured `swapFile` is
absent (default `%UserProfile%\AppData\Local\Temp\swap.vhdx`; microsoft/WSL
discussion 10885). The swap belongs to the utility VM, so "per launch" is
per VM boot: the tray points `swapFile` at
`%LocalAppData%\tillandsias\wsl-swap.vhdx`; on exit, when `wsl --list
--running` shows only its own distro, it runs `wsl --shutdown` and deletes
the VHDX; the next start recreates it. Per-forge is refused on this
platform (it would restart the user's other distros). Measurement for
yolanda (event on 1339-r9xv): is the VHDX recreated or reused across
`--shutdown`; can it be deleted afterwards; is `swap=` honoured with
`sparseVhd=true` and does the file start small and grow on spill; does the
tray ever find another running distro.

### 9.3 macOS: created at VM start, deleted after VM stop

Seams in `crates/tillandsias-vm-layer/src/vz.rs`: `VzBootConfig` gains
`swap_disk: Option<PathBuf>`; `build_vm_configuration` appends a second
`VZVirtioBlockDeviceConfiguration` after `root_disk` (guest `/dev/vdb`);
`VzRuntime::start` creates `vm-swap-<launch>.img` under
`provision_state_dir()` with `File::set_len` (sparse on APFS — unverified)
and excludes it with `tmutil addexclusion`; `VzRuntime::stop` removes it
after the VM reaches `Stopped`, where it already removes the cidata ISO
(*verified* in the source). Guest recipe `40-swap.sh`:
`tillandsias-guest-swap.service` with `ConditionPathExists=/dev/vdb`,
`mkswap` then `swapon -p 10` every boot (fresh image each boot), plus
`zram-size = 2048`. Lifetime = the VM session; forges inside share it via
their cgroup allowance. Balloon target untouched while a forge runs.

### 9.4 Installer banner (1380-zmpi)

Each installer ends, after its "launch the tray" line, with a large
`PENDING ACTIONS` block: Linux — the exact `sudo` command above (or
`PENDING: none` once the unit exists); Windows — `RESTART REQUIRED` when
`install-windows.ps1` classified the WSL enable as `reboot-pending`
(VirtualMachinePlatform enabled, DISM 3010 — the state it already
computes and turns into `NoLaunchReason`); macOS — `PENDING: none` (nothing
is pending today), printed rather than omitted because silence and "nothing
pending" produce the same bytes.

### 9.5 Group versus user in the polkit rule

Yes: the one-time step runs `groupadd -f tillandsias` and `usermod -aG
tillandsias <user>`, and the rule grants the GROUP. Re-login: polkit does
not read the calling process's supplementary groups; it resolves the
subject's groups with `getgrouplist(passwd->pw_name, …)` at check time
(*verified* in `src/polkitbackend/polkitbackendduktapeauthority.c`), so a
freshly added member is authorised on the next `systemctl start` without
logging out. What DOES need a re-login is anything that reads the process
credentials (a `sudoers` group, file-group permissions on the lease
directory), which this design avoids. The rule also matches the installing
`subject.user` so the first launch works even on an NSS setup that caches
group membership; trade-off: the username is baked into a root-owned file,
so a renamed account needs the one-time step again — acceptable, and the
group path covers every other user of the host.

### 9.6 Size policy (all platforms)

Computed at launch from free space where the swap lives (`statvfs` on
`/var/swap`, the WSL swap directory, the macOS provision dir):

```
free_after = free − size
size = 24 GiB if free > 200 GiB, else 16 GiB if free > 100 GiB, else 8 GiB
while free_after < 32 GiB: step down (24 → 16 → 8); below 8 GiB: refuse the
launch with the free-space figure (the forge-fit floor the WSL and vz code
already pin at 32 GiB — MIN_GUEST_ROOT_AVAIL_GIB).
```

Linux swapfiles cannot have holes, so the per-launch file consumes its full
size while alive (*verified*: `mkswapfile` and `fallocate` both allocate
fully) and is returned at stop. The macOS image is sparse and the WSL VHDX
is dynamic: they consume disk only as spilled (unverified on those hosts;
the yolanda measurement covers the VHDX). On Linux the helper computes the
size from `/etc/tillandsias/swap.conf` (`SWAP_TIERS=8:16:24
SWAP_FREE_FLOOR_GIB=32` or an override `SWAP_SIZE_GIB=`) and the measured
free space; nothing about size crosses the D-Bus call.

### 9.7 SELinux

On this host (enforcing, `selinux-policy` 44.10) the type `swapfile_t`
exists in the loaded policy (*verified*: `chcon -t swapfile_t` on a test
file succeeds; a nonexistent type is refused with `Invalid argument`), and
Fedora's policy grants the swapping domain
`allow fsadm_t swapfile_t:file { rw_file_perms swapon }`
(`policy/modules/system/fstools.te`). `/var/swap/*` carries no file-context
rule and defaults to `var_t` (*verified* with `matchpathcon`), which lacks
the `swapon` file permission, so the helper labels the file: `chcon -t
swapfile_t "$f"` right after creation. `chcon` is in coreutils on every
Fedora variant; a persistent `semanage fcontext -a -t swapfile_t
'/var/swap/tillandsias-.*'` is optional (it only matters for `restorecon`
runs, and the file lives minutes), and `semanage` may be absent on
Silverblue. **No custom policy module is needed**: the type and the allow
rule are stock. Unverified: an actual `swapon` under enforcing mode from the
unit (needs root); the live arm of 1376-8zdz covers it and any AVC shows in
`ausearch -m avc -ts recent`.

### 9.8 Does this force an RPM?

No. The one-time step writes only `/etc` (unit, polkit rule, config) and
`/var` (`/var/usrlocal` helper, `/var/swap`), all persistent on Silverblue
without layering (§9.1); no SELinux module, no `/usr` content. An RPM
would mean `rpm-ostree install` (offline by default: takes effect on
reboot; `apply-live` is the exception with caveats — rpm-ostree
administrator handbook) for a payload that needs neither. An RPM or COPR
becomes worth it when (a) a custom SELinux module is required (it is not),
(b) the helper must live in `/usr/libexec` with a policy-defined context,
(c) the fleet wants `rpm -V`-style integrity and automatic updates of the
root-owned parts rather than the curl installer re-running the sudo step,
or (d) other people install Tillandsias on Fedora and expect a package.
Until then the curl install prints the sudo command and the sudo step is
idempotent.

## 10. Sources

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
- systemd polkit details `unit`/`verb` for manage-units
  (`bus_verify_manage_units_async_impl`):
  https://github.com/systemd/systemd/blob/main/src/core/dbus-util.c
- polkit JS authority: subject groups via `getgrouplist` (NSS at check
  time): https://github.com/polkit-org/polkit/blob/main/src/polkitbackend/polkitbackendduktapeauthority.c
  and https://github.com/polkit-org/polkit/blob/main/src/polkitbackend/init.js
- Fedora selinux-policy `swapfile_t` and `allow fsadm_t swapfile_t:file { rw_file_perms swapon }`:
  https://github.com/fedora-selinux/selinux-policy/blob/rawhide/policy/modules/system/fstools.te
- rpm-ostree administrator handbook (offline layering, `apply-live`, only
  `/etc` and `/var` writable):
  https://coreos.github.io/rpm-ostree/administrator-handbook/
- ostree `/etc` three-way merge and `/var` persistence:
  https://ostreedev.github.io/ostree/atomic-upgrades/ and
  https://ostreedev.github.io/ostree/var/ ; `/usr/local → /var/usrlocal`:
  https://ostreedev.github.io/ostree/adapting-existing/
- WSL recreates `swap.vhdx` when absent; default under `%Temp%`:
  https://github.com/microsoft/WSL/discussions/10885
