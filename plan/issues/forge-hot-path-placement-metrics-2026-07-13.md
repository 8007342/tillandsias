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
