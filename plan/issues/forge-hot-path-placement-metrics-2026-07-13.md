# Ramdisk/disk placement of forge hot paths is unmeasured — decide with data, not intent

- Date: 2026-07-13
- Class: research + optimization
- Filed by: macos-osx-next meta-orchestration cycle 2026-07-13T22:43Z (operator directive: "we intended the forge's checkout to be in ramdisk … we currently don't have any metrics or way to tell if more pieces would benefit")
- Related: guest-container-metrics-over-control-wire-2026-07-13.md (measurement prerequisite), forge-hot-cold-split spec, images/default/lib-common.sh `_pull_cache_evict_lru_if_over_cap`, order 315
- Pickup: linux (after metrics packet lands)

## Current placement facts (verified 2026-07-13, with provenance)

| Piece | Today | Where stated |
| --- | --- | --- |
| Forge checkout (macOS host) | **virtiofs share of host `~/src` → `/home/forge/src` — host SSD over virtio, NOT ramdisk** | `crates/tillandsias-vm-layer/src/vz.rs:479-491,926-945` |
| Forge checkout (Linux podman) | fresh clone per launch; `~/src` inside the container is tmpfs-backed ("tmpfs is wiped per launch") | `images/default/lib-common.sh:1036` (find_project_dir comment) |
| Cheatsheets hot mount | real tmpfs, 8 MB cap, populated at container start | `images/default/lib-common.sh:1212-1229`, entrypoints |
| Pull cache "tmpfs-overlay lane" | **pure-userspace LRU on DISK (path 1)** — real tmpfs (path 2) explicitly deferred "if profiling shows path 1 is too slow"; that profiling has never existed | `images/default/lib-common.sh:1539-1560` |
| Proxy cache, router state, vault storage, git-mirror storage | guest disk (container volumes); no placement decision recorded | (absence — no tmpfs/ramdisk refs in images/ for these) |

The operator's stated intent (checkout in ramdisk so code reads are fast)
is therefore **not what ships on macOS**: reads traverse virtiofs to the
host SSD. Whether that is a bottleneck is currently unanswerable — that is
this packet's point.

## Budget constraint that any proposal must respect

Guest RAM is **4 GiB** (`vz.rs:941`) on a 16 GiB host (this dev machine).
Every MB of guest tmpfs competes with podman, the forge toolchain, and the
agent harness. A Tillandsias checkout + target/ can exceed several GiB —
blindly moving "the checkout" to ramdisk can OOM the guest. Decisions must
be per-path and measured.

## Ask

1. Land guest-container-metrics-over-control-wire-2026-07-13.md first
   (per-mount I/O counters are the input).
2. Run a standard BigPickle /meta-orchestration cycle on Linux and on a
   macOS guest with metrics on; produce a table: per path — read/write
   bytes, op counts, p95 latency if obtainable, working-set size.
3. For each hot path output one disposition with numbers attached:
   `keep-as-is | move-to-tmpfs(cap=N) | move-to-guest-disk |
   virtiofs-acceptable`. Explicitly answer:
   - is virtiofs `/home/forge/src` a measurable drag on macOS forge cycles
     vs the Linux tmpfs clone?
   - does pull-cache path 1 (disk LRU) need path 2 (real tmpfs)?
   - do proxy/cache/router/git-mirror do enough I/O to matter at all?
4. File implementation child packets only for dispositions the numbers
   justify.

## Verifiable closure

- The placement table exists with measured numbers and provenance for every
  row, and each `move-*` disposition names the packet implementing it.
  Dispositions without measurements are invalid by definition of this
  packet.


## Measured row: pull cache, tmpfs vs disk (pirria, 2026-08-24)

Contributed by the low-end Linux host (Intel N150, 4 Alder Lake-N cores,
16 GiB, NVMe WPBSNM8-512GMP, Silverblue). Answers ONE of this packet's three
explicit questions — *does pull-cache path 1 (disk LRU) need path 2 (real
tmpfs)?* — and nothing else. Harness:
`scripts/`-external, reproduced by the commands below; n=3, alternating
disk/tmpfs so drift would show.

| shape | disk (NVMe) | tmpfs (/dev/shm) | ratio |
| --- | --- | --- | --- |
| 512 MB blob write, `conv=fsync` | 483 / 472 / 487 ms | 181 / 176 / 177 ms | **tmpfs 2.7x faster** |
| 512 MB blob read, warm | 81 / 77 / 80 ms | 82 / 79 / 80 ms | **no difference** |

```bash
dd if=/dev/zero of=$D/blob bs=1M count=512 conv=fsync status=none   # write
dd if=$D/blob of=/dev/null bs=1M status=none                        # warm read
```

**DISPOSITION: `keep-as-is` for the pull cache on this host class.**

The reason is the read row, and it is the row that matters: a pull-cache HIT
is a warm read, and a warm read is served from the page cache whether the
bytes live on tmpfs or on NVMe — 80 ms either way, indistinguishable across
three reps. tmpfs wins only the WRITE path (population, i.e. a cache MISS),
which is the operation the cache exists to make rare. Paying RAM to speed up
the miss path is the wrong trade.

**RAM is the cost, and on this tier it is not abstract.** Measured at the same
moment: 15717 MB total, 12258 MB available; a single 512 MB blob is 4.2% of
available. This host also holds a resident model ladder — qwen2.5:7b alone is
5.06 GB resident when loaded (order 864-dvhk). tmpfs bytes and model bytes
come from the same pool, so on a 16 GiB host "move it to tmpfs" competes
directly with the inference the forge is there to serve. This extends the
packet's existing 4 GiB-guest budget argument to bare-metal low-end hosts,
now with numbers.

**WHAT THIS ROW DOES NOT COVER, stated so it is not read as more than it is:**
- Only the pull-cache shape. Checkout, proxy cache, router state, vault and
  git-mirror storage are untouched — those need a running forge with the
  order-333 control-wire counters, and this host has no forge running (its
  proxy container cannot start: the ephemeral CA under /tmp is wiped on
  reboot).
- The macOS virtiofs-vs-Linux-tmpfs comparison (criterion 3) is not this
  host's to answer.
- A third metric was attempted — create/stat/unlink over 2000 files, as an
  LRU-eviction proxy — and is DISCARDED, not reported: at ~2.1 s on both
  stores it was dominated by ~6000 shell process spawns, not by storage. It
  measured the harness. A real metadata comparison needs the churn inside one
  process (a C or Rust loop), not a bash for-loop.
