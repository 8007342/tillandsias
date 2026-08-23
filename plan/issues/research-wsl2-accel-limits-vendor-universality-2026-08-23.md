# research: are `wsl2-npu-not-exposed` / `wsl2-no-dri-render-node` WSL2-universal or Intel-specific?

- Filed: 2026-08-23 (UTC), by windows host **yolanda**, at merged `windows-next`
  head bc6c619d0 (= origin/linux-next), directed by the coordinator prompt for
  this cycle.
- Class: research/ — question answered; one follow-up observation captured.
- Related: 808-7yrd, 809-7e4m (yolanda's original rows), 806-2r4s
  (present-unusable contract), 850-bif2 (silent-hosts packet).

## The question as asked

The coordinator asked: "yolanda, an Intel N100, reports
npu/(wsl2-npu-not-exposed) from the Windows-host locus and gpu/WSL2
paravirtual GPU (/dev/dxg) (wsl2-no-dri-render-node) from the in-guest locus.
You have an AMD NPU and an AMD GPU. Are those WSL2-universal limits or
Intel-specific?"

## Correction first: yolanda IS the AMD machine

The premise inverts the fleet. yolanda is an **AMD Ryzen AI 7 350 w/ Radeon
860M** (Lenovo Yoga): its NPU is `PCI\VEN_1022&DEV_17F0` (AMD XDNA) and its
GPU is `PCI\VEN_1002` (Radeon 860M) — see the 809-7e4m fragment and this
cycle's refresh. The fleet's Intel N100 is **esmeraldinha** (the "Esmeralda
N100 field host" throughout plan/archive/packets-2026-08.yaml), which is
currently SILENT in the capability matrix. So the two rows quoted at me were
already AMD evidence; there has never been an Intel WSL2 row in the matrix.

## Fresh verification (this cycle, probe v0.4.260817.1 at bc6c619d0)

Both loci re-probed and republished (fragments
`20260823t015456z-49df4525-yolanda.yaml` windows-host,
`20260823t015759z-61d6612c-yolanda.yaml` in-guest). Same two limits
reproduce on AMD silicon. In-guest structural evidence, gathered directly in
the tillandsias-build WSL2 distro (kernel 6.18.33.2-microsoft-standard-WSL2):

- `/dev/dxg` present; `dxgkrnl` in /proc/modules; `/usr/lib/wsl/lib` carries
  libd3d12.so, libd3d12core.so, libdxcore.so — the DirectX lane is fully wired.
- `/dev/dri` ABSENT: no DRM driver binds the paravirtual adapter, so no
  render node exists for ANY vendor.
- `/dev/accel*` ABSENT and `amdxdna` not loaded: the guest cannot even
  attempt NPU discovery.
- The guest PCI bus contains ONLY paravirtual functions: virtio (0x1af4) and
  Microsoft 0x1414 devices of class 0x030200 ("3D controller" — the GPU-PV
  endpoints dxgkrnl consumes). No 0x1002 (AMD GPU), 0x1022 (AMD accel) or
  0x8086 (Intel) function crosses the boundary. The vendor identity of the
  real silicon is absorbed by the host side.

## Answer

**WSL2-universal, definitively not Intel-specific.** Both limits reproduce
on AMD hardware (this machine), and the mechanism is vendor-independent by
construction:

1. GPU: WSL2's GPU-PV projects the host adapter into the guest as a
   Microsoft 3D-controller PCI function consumed by dxgkrnl and surfaced
   solely as `/dev/dxg` (DirectX/dxcore lane). No DRM driver, therefore no
   DRI render node — for AMD, Intel and NVIDIA alike.
   `wsl2-no-dri-render-node` names why DRI-expecting engines cannot attach;
   engines that speak dxcore/d3d12 could in principle reach this GPU, so per
   the 806-2r4s vocabulary this stays "ship a lane", not "buy hardware".
2. NPU: WSL2 passes through no PCI and paravirtualises only the graphics
   adapter class. NPUs (AMD XDNA `/dev/accel*`, Intel NPU alike) have no
   paravirtual class at all — structurally invisible from the guest, not
   merely undetected (exactly as 809-7e4m recorded).

A confirmed universal limit is the deliverable here: schedulers must not
expect any WSL2 in-guest row, from any vendor, to ever offer npu/* or a
DRI-backed gpu lane. Fleet-level Intel confirmation arrives free the day
esmeraldinha (the actual N100) publishes its rows per 850-bif2.

## Captured observation (kept, per the reduction-engine capture rule)

The in-guest row is **distro-dependent** and the `host+locus` fold key does
not name the distro. yolanda carries four WSL distros; this cycle's row was
probed in tillandsias-build, where ollama is not installed, so `engines: []`
and the matrix now shows `schedulable: none` where the 2026-08-18 row (probed
in a context that had ollama) showed `cpu/container/ollama` +
`cpu/host-native/ollama`. Both rows are truthful about their own context; the
key cannot express the difference. On multi-distro machines "in-guest" is a
family, not a point. Left as a recorded caveat for whoever works 850-bif2 —
the row-on-join design should decide which guest a Windows machine's
in-guest row canonically describes (the product's `tillandsias` distro being
the obvious candidate), or add the distro to the key.
