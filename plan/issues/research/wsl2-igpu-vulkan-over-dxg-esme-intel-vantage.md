# A second WSL2 vantage for 793-zumy: Intel iGPU over /dev/dxg, esme

Evidence for `793-zumy` (accel-probe-blind-to-wsl2-paravirtualised-gpu), a row
this host does not own and did not claim. Produced by esme-windows during a
scheduled drain. **Nothing was installed, configured or provisioned to produce
any of it** — every command below is read-only, which is the whole point given
that the packet's one open item is operator-gated.

Companion to `wsl2-igpu-vulkan-over-dxg-measured-2026-08-16.md`, which measured
yolanda's AMD Radeon 860M. This is the same mechanism on a different vendor.

## Why this host is worth a row

The packet's remaining criterion 1 and the WSL2 half of criterion 3 are blocked
on a Vulkan ICD being installed on the operator machine. Yolanda declined to
install one and the packet records that as the right call — provisioning a host
to make a criterion pass is not evidence.

**Esme does not need the install.** Its builder distro already carries a Vulkan
loader and the full Mesa ICD set, from the stock distribution package, and it
enumerates a real non-CPU device over `/dev/dxg` today. The criterion can be
satisfied by observation on this host instead of by provisioning on that one.

## Measured

Regime: esmeraldinha, Windows 11 host, WSL2, two distros, read-only commands
issued from the Windows side via `wsl.exe -d <distro>`. No inference was run
and no model was loaded — this is enumeration only, not a throughput claim.

Both distros, identically, confirm the packet's core mechanism on a second host:

| distro              | `/dev/dxg` | `/dev/dri` | Vulkan loader | ICD manifests |
|---------------------|-----------|-----------|---------------|---------------|
| `tillandsias-build` | present   | **absent** | `libvulkan.so.1` | 12, incl. `dzn_icd` |
| `tillandsias`       | present   | **absent** | absent        | none |

`/dev/dri` is absent in both. The probe's Linux rubric — GPU iff `nvidia-smi -L`
succeeds or `/dev/dri` exists — therefore answers `none` on this host too, for
the same reason it did on yolanda, with different silicon underneath.

`vulkaninfo --summary` in `tillandsias-build` enumerates two physical devices:

```
GPU0:  vendorID    = 0x8086
       deviceID    = 0x46d1
       deviceType  = PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU
       deviceName  = Microsoft Direct3D12 (Intel(R) UHD Graphics)
       driverID    = DRIVER_ID_MESA_DOZEN
       driverName  = Dozen            driverInfo = Mesa 26.1.6

GPU1:  vendorID    = 0x10005
       deviceID    = 0x0000
       deviceType  = PHYSICAL_DEVICE_TYPE_CPU
       deviceName  = llvmpipe (LLVM 22.1.8, 256 bits)
       driverID    = DRIVER_ID_MESA_LLVMPIPE
```

GPU0 is the real host part (Alder Lake-N iGPU) reached over `/dev/dxg` through
Mesa's Dozen D3D12 layer, with no DRM render node anywhere in the picture.

## What this gives each open criterion

**Criterion 1** — a WSL2 guest with `/dev/dxg` present and an ICD enumerating a
non-CPU physical device exists, unprovisioned, on esme. `tillandsias-build`
is that guest. The criterion no longer requires an install on yolanda; it
requires the probe to be run here.

**Criterion 2, the rejection half** — the packet asks that
`PHYSICAL_DEVICE_TYPE_CPU` / `DRIVER_ID_MESA_LLVMPIPE` be rejected. On yolanda
there was nothing to reject, since nothing enumerated at all. Here GPU1 *is*
that device, sitting beside a genuine GPU0 in the same enumeration. This is the
discriminating case: a correct implementation must return the Intel part and
must not return llvmpipe, and a rubric that merely counts enumerated devices
passes wrongly with a count of two.

**Criterion 2, the `engine-missing` half** — the `tillandsias` distro is
`/dev/dxg` present with no loader installed, which is the exact prior state the
packet describes on yolanda. It is live on this machine right now, beside the
working case. Both arms of criterion 2 are observable on one host without
touching either distro.

## A schema hazard in the hwfp-v2 field list

**Corrected by yolanda after review; my first statement of this was wrong in
its mechanism, and the correction is sharper than the claim it replaces.** I
wrote that `vendor_id: u16` truncates llvmpipe's `0x10005` to `0x0005`. It does
not.

By symbol: `DrmRenderNode.vendor_id` is `u16`, filled only by
`assemble_render_node`, which gets it from `parse_pci_id` — whose body is
`u16::from_str_radix(hex, 16).ok()`. `from_str_radix` REFUSES the overflow and
returns `None`, and `assemble_render_node` takes that with `?`. The value is
not truncated; **the entire node is dropped.**

That is worse in exactly the direction this row cares about. A truncated
`0x0005` is at least a row someone can look at and question. A dropped row is
indistinguishable from a device that never enumerated — so "rejected" and
"never seen" collapse into a single observation, and criterion 2 requires the
software rasterizer to be *rejected*. A rubric cannot reject what never reached
it. That collapse is the exact condition this host was supposed to cure, since
on yolanda nothing enumerates at all.

The second correction is why the first is currently unreachable, and it narrows
the ask. Nothing builds a `DrmRenderNode` from a Vulkan source: the only
production constructor is fed from `/sys/class/drm/card<N>/vendor` via
`drm_cards()` — PCI ids, which genuinely are 16-bit, so `u16` is correct for
the source it actually has. Every other construction site is a test fixture. My
`0x10005` came from `vulkaninfo`, and Vulkan's `vendorID` is a different
namespace: `uint32_t`, Khronos-assigned, with the software ids placed above
`0xFFFF` deliberately so they cannot collide with PCI. And `/dev/dri` is absent
in both distros here, so `drm_cards()` enumerates nothing on this host anyway.

So the accurate warning is not "the field wants u32". It is: **do not carry a
Vulkan vendorID through the PCI path.** If hwfp-v2 records what `vulkaninfo`
reports, it needs its own `u32` field and its own parser, because reusing
`parse_pci_id` will silently drop every software-rasterizer row — the one row
criterion 2 exists to reject. If hwfp-v2 only ever records PCI ids, the current
`u16` is right and nothing should change. That is a design question for the
schema's owner, worth asking before it lands rather than after.

## Provenance of the ICDs, stated rather than assumed

The manifests belong to `mesa-vulkan-drivers-26.1.6-1.fc44.x86_64`, a stock
Fedora 44 package; the distro is `Fedora Linux 44 (Container Image)`. `rpm`
reports it installed on 2026-08-17, which is weeks before this cycle and rules
out its having been put there for this measurement.

I am recording one thing I could not establish: that install date is one day
after the yolanda experiment the companion document describes. I have no
evidence connecting the two and I am not going to invent one — it may be
routine image provisioning, or it may be a deliberate follow-up nobody wrote
down. Whoever owns the builder image can settle it; I am flagging the
coincidence rather than resolving it, because if it *was* a deliberate install
then this host is less independent of that experiment than the rest of this
document assumes.

## What this document does NOT establish

- **The probe was not run.** No `tillandsias-headless` binary exists in either
  distro and building one is outside this lane's compile budget. Everything
  above is the *input* the probe would see, not its output. The claim "the
  envelope reports a usable GPU on esme" remains unmade.
- **No throughput was measured.** The companion document's 2.04x on yolanda has
  no counterpart here. Nothing was inferred; an N100 iGPU may well be a loss,
  as yoga measured for gfx1152.
- **Placement is unverified**, exactly as the packet's verification debt says.

`unscoreable: unpinnable-until-the-guard-exists` — the enumeration facts above
have no gate that observes them; they are host state, not a scored assertion.

## Ask

For yolanda, who owns the row: the smallest next action named in the packet was
"a deliberate, recorded ICD install on yolanda". This host suggests a cheaper
one that needs no provisioning — run the probe inside `tillandsias-build` on
esme and read `accel_proof=` and the `render_nodes` rows. I can host that run;
I did not do it this cycle because it needs a build I am not budgeted for. If
you want it, say so and I will ask the operator for the build rather than
assume it.

For yoga, who owns the schema: decide whether hwfp-v2 records Vulkan-reported
ids at all. If it does, they need their own `u32` field and parser rather than
`parse_pci_id`, which drops every software-rasterizer row. If it records only
PCI ids, `u16` is correct and nothing should change. Worth settling before the
schema lands.

trace: plan/issues/research/wsl2-igpu-vulkan-over-dxg-measured-2026-08-16.md
       crates/tillandsias-headless/src/accel_probe.rs
