# macOS storage, cache and snapshot strategy — exploration (2026-09-29)

Exploration note on branch `exploration/raw-xz-rootfs`, written at the
operator's request. It is not a ruling: each proposal below needs a row before
anything lands. Items marked **UNVERIFIED** come from general macOS knowledge
and were not measured on this fleet. Citations name files and symbols, never
line numbers.

## What the operator asked for

> "We also want all downloaded files to be in a ~/.tillandsias/ folder, we're
> going to download lots of random files and create lots of massive files,
> removing the folder should just wipe everything. Can we locate that inside the
> Tillandsias.app folder? Is there some ASSETS/RESOURCES policy from MacOS we
> could leverage? like LRU policy for eviction, caching, temporary dirs, and our
> almighty SWAP ON policy?"
>
> "Document those layered disk images for a free 'pristine' image, we might want
> to snapshot a freshly installed AND LAUNCHED forge, to have an immediate launch
> next time … osx27 sounds like might leave some users behind so let's not make
> that a requirement yet."

## Today's layout (measured on tlatoanis-macbook-air)

| Path | Holds | Size seen |
|---|---|---|
| `~/Library/Application Support/tillandsias/` | `rootfs.img` (250 GiB sparse), `rootfs.qcow2` (the download, kept), `vm-swap.img` (24 GiB sparse), `nvram.bin`, `cidata.iso`, `console.log`, `provision/` | 7.8 GB allocated before the 2026-09-29 wipe |
| `~/Library/Caches/tillandsias/` | `models/` | 698 MB |
| `~/.local/state/tillandsias/` | `guest-bin/` (the staged headless binary, shared into the guest) | 13 MB |
| `~/Library/Logs/Tillandsias/` | `tray.log` | small |

So a full wipe today touches four roots. `scripts/e2e-step2-macos.sh` removes
two of them. The operator's rule, "removing the folder should wipe everything",
is not true today.

## 1. One root: `~/.tillandsias/`

**Recommendation: yes, one root, with purpose-named subfolders.**

```
~/.tillandsias/
  vm/          rootfs.img, vm-swap.img, nvram.bin, cidata.iso, provision/   (the VM)
  snapshots/   pristine.img, forge-ready.img, *.vzstate                      (see §3)
  downloads/   Fedora images, model files: content-addressed by sha256        (§2)
  cache/       anything re-derivable, LRU-evicted by us                      (§2)
  guest-bin/   staged headless binary (today ~/.local/state/tillandsias)
  logs/        tray.log, console.log
  tmp/         in-flight .partial files; cleared on every launch
```

- `rm -rf ~/.tillandsias` is then the whole reset, and `e2e-step2-macos.sh`,
  the uninstaller and `--reset-state` shrink to one path.
- Keep the path in ONE constant (`image_root` and `guest_bin_path` already
  centralise theirs; `tillandsias_core::guest_bin_path::GUEST_BIN_MOUNT` is the
  guest-side twin) and derive every subpath from it.
- Migration: on first launch of a build with the new root, MOVE (same volume,
  so `rename(2)` is instant) the four old roots into it. Never copy a 250 GiB
  sparse file, because a copy can de-sparsify it.
- A dot-folder is hidden in Finder. That suits a data root, but the tray should
  offer "Reveal Tillandsias data in Finder" (Finder can show it with ⌘⇧.).

**Inside `Tillandsias.app`? No, for four reasons:**
1. The bundle is code-signed with sealed resources. Writing into it after
   install invalidates the seal, and Gatekeeper and the virtualization
   entitlement check can then refuse to launch it. (The general rule is Apple's
   documented guidance that apps must not write into their bundle; the
   entitlement consequence is UNVERIFIED for our exact signing.)
2. `/Applications` is not writable by a standard (non-admin) user.
3. Every update REPLACES the bundle, so the VM, downloads and snapshots would
   be deleted by an upgrade.
4. Time Machine and Spotlight treat apps specially, and a 250 GiB file inside
   an app is surprising to every tool that scans `/Applications`.

The bundle stays read-only resources: the tray binary, the bundled guest binary
(`Contents/Resources/guest`), icons.

## 2. macOS facilities we can lean on

| Facility | What it gives us | Notes |
|---|---|---|
| **Time Machine exclusion**: `NSURLIsExcludedFromBackupKey` on the folder, or `tmutil addexclusion ~/.tillandsias` | Backups do not copy 250 GiB of re-derivable VM disk | High value, one call at root creation. Without it a backup can DE-SPARSIFY the image (UNVERIFIED on current Time Machine, which is APFS snapshot-based and may preserve holes) |
| **Spotlight exclusion**: an empty `~/.tillandsias/.metadata_never_index` | `mds` does not index model and disk files | Cheap, and avoids CPU spikes during large writes (UNVERIFIED that `.metadata_never_index` is still honoured on macOS 15+; `mdutil` has no per-folder switch) |
| **APFS sparse files** | `set_len` makes holes; the 250 GiB disk costs its written bytes | Already relied on (`crate::qcow2`, `crate::rawxz`) |
| **APFS clones**: `clonefile(2)`, `cp -c` | O(1) copy-on-write copy of a file | The basis for pristine snapshots without macOS 27 (§3). macOS 10.13+, same volume only |
| **`~/Library/Caches`** | The conventional purgeable location | macOS does NOT promise LRU eviction here: iOS purges app caches under pressure, macOS generally does not (UNVERIFIED for 15/26). Do not rely on it; run our own LRU (below) |
| **`$TMPDIR`** (`/var/folders/…/T`) | Per-user temp, cleaned by the system (reboot, and `dirhelper` after a few days) | Wrong for multi-GB work: it may be on the same volume, but its cleanup is not ours to control. Prefer `~/.tillandsias/tmp` cleared at launch |
| **`statfs` free space** | What `boot::first_provision_space_refusal` already reads | Keep requiring the bytes that will actually be written (4 GiB today), never the sparse target |

**Our own LRU**: `~/.tillandsias/downloads` and `cache/` hold content-addressed
files (`<sha256>.<ext>`) plus a small index recording `last_used` on each use
(APFS `atime` is not a reliable signal). A budget (for example "keep downloads
and cache under 20 GiB, or 10% of free space") evicts least-recently-used
entries at tray launch. The Fedora image and the current models are pinned. This
is a few dozen lines and entirely ours, so it behaves the same on every macOS.

**Swap ("SWAP ON")**: keep guest swap on a sparse host file (`vm-swap.img`,
sized by `swap_image_size_follows_the_free_space_tiers`) under
`~/.tillandsias/vm/`. The host's own swap is macOS's business; ours stays sparse
and is re-created, never snapshotted (§3).

## 3. Pristine and "instantly launched forge" snapshots WITHOUT macOS 27

The research brief (2026-09-29) found layered images arrive with DiskImageKit
in macOS 27 (WWDC26 session 224). Two older facilities give most of the benefit
on the macOS 14 floor we already have:

**(a) Pristine disk, via APFS `clonefile` (macOS 10.13+).**
After a successful first provision, `clonefile(vm/rootfs.img ->
snapshots/pristine.img)`. It costs no space until the live disk diverges. A reset
to pristine is `clonefile` back (O(1)), with no 500 MB download and no 5 GiB
decode: the same as the operator's wipe-and-reprovision cycle, in seconds.
Constraint: same APFS volume, which holds when both live under
`~/.tillandsias/`.

**(b) Launched forge, via Virtualization.framework save/restore (macOS 14).**
`VZVirtualMachine.saveMachineStateTo(url:)` and
`restoreMachineStateFrom(url:)` checkpoint a RUNNING VM's memory and device
state; `validateSaveRestoreSupport()` says whether the configuration qualifies.
Pairing a clone of the disk with the saved state taken right after a forge
finished launching gives "click, and the forge is already up". Constraints:
- restore only on the same Mac, with the same configuration;
- the brief notes Virtio GPU was excluded on 14.0 (we are headless, so this
  should not matter);
- virtio-fs shares and vsock in a saved state are **UNVERIFIED**. This is the
  first thing to measure, with `validateSaveRestoreSupport()` on our exact
  config.
- The in-guest clock jumps on restore (NTP must resync); and anything bound to
  a host-side socket must reconnect, as the control wire already does after a
  guest restart.

**(c) macOS 27 later, not a requirement.** DiskImageKit base, cache and overlay
layers would make (a) a first-class layered image, shared read-only across
forges. Adopt it behind a version check once 27 ships, with (a) and (b) as the
floor path, so no user on 14 to 26 is left behind.

## Proposed rows (not filed; for the coordinator)

1. One `~/.tillandsias/` root with migration of the four current roots, plus
   Time Machine and Spotlight exclusion at creation.
2. A content-addressed downloads and cache directory with an LRU budget,
   evicted at launch.
3. A pristine `clonefile` after first provision, and a tray "Reset VM to
   pristine" action (seconds, no download).
4. A measurement spike: `validateSaveRestoreSupport()` on the real config, then
   save and restore a launched forge and time the resume.

## Measured on this branch, 2026-09-29 (tlatoanis-macbook-air, M5)

| What | Result |
|---|---|
| Download | Fedora-Cloud-Base-AmazonEC2-44-1.7.aarch64.raw.xz, 513,786,992 B, SHA-256 matches Fedora's CHECKSUM (qcow2 was 528,154,624 B) |
| Decode, `crate::rawxz` (single-threaded xz2) | 5 GiB in 20.4 to 22.4 s. For comparison, the `xz -dc` CLI is 16.2 s single-threaded and 2.5 s multithreaded (the stream has 214 blocks, so a parallel decoder is possible) |
| cloud-init on the EC2 image | Used OUR seed: `Datasource DataSourceNoCloud [seed=/dev/vdc]`; provision `phase complete` (tray first boot 80 s) |
| Disk allocation | The first build allocated 4.7 GB. APFS zero-fills seeked gaps under about 32 MiB (measured: 1-16 MiB gaps fully allocated, 32 MiB gaps stay holes). With the zero runs punched (`F_PUNCHHOLE`): **803 MB**, content identical to `xz -dc` |
| Initial disk | 20 GiB logical (it was 250 GiB); the guest grew `vda2` and btrfs to the full 20 GiB on first boot (5% used) |
| Growth | File extended to 30 GiB with the VM stopped. On the next boot the guest showed `vda` and `vda2` at 30 GiB and btrfs at 30 GiB (3% used); the host file allocated 972 MB. So `next_guest_disk_size` plus cloud-init growpart and resizefs grows end to end |

The qcow2 path writes the same way and very likely allocates the same ~4.7 GB
at first provision. If the raw.xz path is not adopted, port the zero-run
punching to `crate::qcow2::expand_to_raw` anyway.
