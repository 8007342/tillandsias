# macOS VZ guest storage probe: openspec forge-storage tasks 6.3–6.6 (order 2066-395p)

Measured 2026-11-09 on tlatoanis-macbook-air. Installed stable
tillandsias-tray 56.11.7.1 (git 8351a0f3f); the VM had been up since
2026-11-07 17:27.

The probes were read-only: `tillandsias-tray --exec-guest` through the running
tray's relay (nothing booted or stopped), plus host `ls`/`du`/`lsof`/
`diskutil`. The change is `forge-storage-single-root-and-disk-discipline`.

## 6.3 Forge layers on the Virtualization.framework guest

Guest: kernel 6.19.10-300.fc44.aarch64, 8 vCPU, 7907 MiB RAM.

| Guest mount | Backing | Size / free | Host file |
|---|---|---|---|
| `/` (and `/home`, `/var`, the podman overlay store) | `/dev/vda2` btrfs, `compress=zstd:1,discard=async` | 20G / 18G free | `~/Library/Application Support/tillandsias/rootfs.img`, 20 GiB logical, **1.9G allocated** (sparse on APFS) |
| `/tmp`, `/dev/shm` | tmpfs | 3.9G each, RAM | none |
| `/var/lib/tillandsias/identity` | `/dev/vdc` btrfs | 2.0G | `vm-identity.img`, 2 GiB logical, 173M allocated |
| `/home/forge/src` (in the GUEST) | virtio-fs `home-src` | the host APFS volume (927G) | host `~/src` |
| `/root/.cache/tillandsias/models`, `/var/lib/tillandsias/guest-bin`, `/var/lib/tillandsias/provision` | virtio-fs | host APFS | under the host root |

- **L0 (a forge's `/home/forge/src`)** is a per-lane tmpfs volume
  (`ram_workspace_volume`, `tillandsias-source-<sha>`), not the guest's
  virtio-fs `home-src`. It is therefore bounded by the guest's 7.9 GiB RAM,
  which is the cause of the 1.5 GB ceiling in 2065-5vcv / 1866-ubtc. Not
  measured in-forge: no forge was running, see 6.5.
- **Discard is advertised end to end in the guest.** virtio-blk shows
  `DISC-MAX 20G`, `DISC-GRAN 512B`, and btrfs mounts with `discard=async`.
  NOT MEASURED: whether a guest delete punches holes in the host's sparse
  `rootfs.img`. That needs a guest write-then-delete, which is not
  read-only, so it is left for an approved run.
- **Candidates for L1 (per-forge scratch) and L2 (reusable cache).**
  - The guest root disk has 18G free and is the natural home for disk-backed
    worktrees and `.dart_tool` / `build/` caches. But it is shared with the
    image store, and its cap is the fixed 20 GiB of `rootfs.img`.
  - A separate attached sparse image (like `vm-identity.img`) gives L1 its
    own cap, and deleting the file returns the space.
  - virtio-fs to host APFS has the most room, but host file semantics, and
    a per-file round trip, are a poor fit for `.dart_tool`.

## 6.4 Swap

```
/dev/zram0  partition  7.7G  prio 100
/dev/vdb    partition  24G   prio 10   (host vm-swap.img, sparse, recreated each launch, 1377-hcnv)
```

Disk-backed swap exists, so the mandatory-swap ruling (11.4) is met on
macOS.

**Finding (2066-d7g7): the host's `vm-swap.img` has been unlinked while the
VM still uses it.**

```
$ lsof -nP +L1 -p 73842     # com.apple.Virtualization VM, up since Nov 7 17:27
... 7u REG 1,13 25769803776  NLINK 0  110814922 .../tillandsias/vm-swap.img
$ ls ~/Library/Application\ Support/tillandsias/ | grep -i swap
(nothing)
```

The 24 GiB swap file is still allocated, but `ls` and `du` cannot see it,
so any host free-space accounting of the Tillandsias root under-counts it.
It also leaves the next launch's "fresh" image racing a phantom.

Suspect: `impl Drop for VzRuntime` (crates/tillandsias-vm-layer/src/vz.rs)
removes `image_root/vm-swap.img` unconditionally, so a second process that
builds a `VzRuntime` on the same image root and drops it deletes the live
VM's swap file. Not yet confirmed which process did it.

## 6.5 Ramdisk-download check inside a forge

NOT RUN: no forge was running (only `tillandsias-proxy` and
`tillandsias-vault`).

**Finding (2066-fxbh): guest podman is wedged on its database lock.**
`podman ps` timed out at 20 s with `beginning transaction: database is
locked`. The guest showed four defunct `[podman]` children, the oldest
71,698 s old (about 20 h), under a `podman events --format json` running
since boot. Until that clears, any in-forge probe, and any tray podman call,
waits on the lock.

## 6.6 Free-space probe: which number to compare

| Layer | Number that gates it | Measured |
|---|---|---|
| Host APFS (sparse image growth, virtio-fs shares) | `diskutil info /` "Container Free Space" (includes purgeable) | 801.4 GB; `df` avail 746Gi |
| Guest root disk (images, overlay, a future L1/L2 on it) | `df` avail on `/` in the guest, capped by `rootfs.img`'s 20 GiB regardless of host room | 18G |
| Forge L0 src tmpfs | the guest's `MemAvailable` and the tmpfs `size=`; the cgroup counts tmpfs pages | 6927 MiB available |

Worst-case host growth from the sparse images is 20 + 24 + 2 = 46 GiB. A
host-side eviction or warning should use Container Free Space minus the
unallocated part of that 46 GiB. Inside the forge, `df /home/forge/src` is
the number that matters to an agent.
