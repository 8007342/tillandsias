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

---

## Intel confirmation — esmeraldinha, 2026-08-23 (closes the question)

- Added by windows host **esmeraldinha** (Intel N100, the fleet's declared
  lower bound), at `windows-next` head `fb80c579a` (= `origin/linux-next`,
  fast-forwarded this cycle from a 6-day-stale `6d3648424`).
- Rows published this cycle:
  `plan/index.d/20260823t042922z-capability-row-esmeraldinha-windows-host.yaml`
  (locus `windows-host`) and the `in-guest` row filed alongside it.
- Verdict: **AGREES with yolanda. No correction is owed.** The claim
  reproduces on Intel silicon, and one scoping caveat below is a limit on
  what THIS machine can witness, not a defect in the claim.

### The GPU limit reproduces exactly

The Windows-host locus sees one accelerator, `Intel(R) UHD Graphics`
(`PCI\VEN_8086&DEV_46D1`, Alder Lake-N 24EU, driver 32.0.101.7088,
`os_status: OK`) and adjudicates it `usable: false` /
`unusable_reason: wsl2-no-dri-render-node` — the same reason string yolanda's
Radeon 860M carries. Structural evidence gathered in the runtime `tillandsias`
WSL2 distro (kernel 6.18.33.2-microsoft-standard-WSL2, the same kernel yolanda
probed):

- `/dev/dxg` present (`crw-rw-rw- 10, 258`); `/usr/lib/wsl/lib` carries
  `libd3d12.so`, `libd3d12core.so`, `libdxcore.so` — DirectX lane fully wired.
- `/dev/dri` **ABSENT** — no DRM driver binds the paravirtual adapter.
- `/dev/accel*` **ABSENT**; no `amdxdna`, `ivpu` or `intel_vpu` in
  `/proc/modules`.
- Guest PCI bus carries exactly three functions, all paravirtual:
  `0x1af4:0x105a` (class `0x088000`), `0x1af4:0x1043` (class `0x010000`), and
  `0x1414:0x008e` class **`0x030200`** — the Microsoft 3D-controller GPU-PV
  endpoint. `grep -l 0x8086 /sys/bus/pci/devices/*/vendor` returns **nothing**:
  no Intel function crosses the boundary, exactly as no AMD function crossed
  yolanda's.

One immaterial packaging difference, recorded so a future reader does not
mistake it for a discrepancy: yolanda found `dxgkrnl` in `/proc/modules`; here
it is **built into the kernel** (`kernel/drivers/hv/dxgkrnl/dxgkrnl.ko` appears
in `modules.builtin`, and `/proc/modules` holds 23 unrelated entries). Same
driver, same lane, different packaging.

### A detail that strengthens the mechanism argument

The guest is *not* vendor-blind in general: `/proc/cpuinfo` reports
`model name: Intel(R) N100`, and `kvm_intel`, `intel_rapl_msr` and
`intel_rapl_common` are all loaded. The CPU's vendor identity crosses the
boundary intact because the CPU is not paravirtualised. What is absorbed
host-side is specifically the **graphics adapter**, which is projected as a
Microsoft `0x1414` class-`0x030200` function. That is a sharper statement of
yolanda's mechanism than "the vendor identity is absorbed", and it is what
makes the limit structural rather than a driver-packaging accident.

### Scoping caveat, stated loudly because the prompt assumed otherwise

The coordinator's framing was that esmeraldinha's "Intel UHD row confirms the
Intel half for free". That is true for **`wsl2-no-dri-render-node`** and false
for **`wsl2-npu-not-exposed`**, for a reason that has nothing to do with WSL2:

**The N100 has no NPU at all.** The Windows-host probe enumerated exactly one
accelerator device on this machine, the UHD iGPU. There is no Intel NPU here to
be unexposed, so this host cannot witness `wsl2-npu-not-exposed` on Intel
silicon — its absence from the row is "no such device", not "device hidden".

The NPU conclusion still holds here, but by **mechanism rather than by direct
observation**: the structural premise it rests on — no PCI passthrough, only
paravirtual functions on the guest bus, therefore no `/dev/accel*` possible for
any vendor — IS directly confirmed on Intel above. What remains unwitnessed is
the specific pairing (Intel NPU + WSL2 guest). Closing that would need an Intel
Core Ultra / Meteor Lake-or-later part running WSL2. The fleet's only Intel NPU
today is macuahuitl's (`present-unusable: npu/Intel NPU (engine-missing)`), and
it is bare-metal Linux, so it cannot close it either.

This does not weaken the deliverable — schedulers must still not expect any
WSL2 in-guest row from any vendor to offer `npu/*` or a DRI-backed GPU lane —
but the evidence grade differs between the two halves and the record should say
so rather than round both up to "measured".

### Follow-up: the distro-dependency caveat is now demonstrated, not just predicted

yolanda left a caveat that in-guest rows are distro-dependent and that the
`host+locus` fold key cannot express which guest was probed. This cycle
demonstrates it with a concrete divergence: esmeraldinha's in-guest row was
deliberately taken in the **runtime `tillandsias` distro** (yolanda's was taken
in `tillandsias-build`), where ollama 0.32.14 and podman are both installed and
`qwen2.5:0.5b`, `phi3.5:3.8b` and `nomic-embed-text` are resident. The two
machines' in-guest rows therefore differ in `engines`/`schedulable` for reasons
that are pure probe-context, not hardware. Recommend the row-on-join design
adopt the product's `tillandsias` distro as the canonical in-guest locus, or
add the distro to the fold key.
