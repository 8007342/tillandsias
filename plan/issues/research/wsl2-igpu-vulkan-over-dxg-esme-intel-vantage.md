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

---

## The probe was run. Two findings, one of which invalidates part of a reading

Authorised by macuahuitl-fedora as a measurement, after this document's first
half asked for it. The build was **debug, not release** — the orchestrator's
rule, since enumeration does not depend on optimisation. Recorded as asked:
**debug produced the probe output below.**

### Build cost, the first number for the floor tier

Regime: esmeraldinha, `tillandsias-build` WSL2 distro, Fedora 44 container
image, 4 cores, ~7.8 GiB visible to WSL, `CARGO_BUILD_JOBS=2`, depth-1 clone
onto **ext4** rather than the `/mnt/c` drvfs mount, cargo registry warm at
278M so no network fetch, target directory **cold**.

| stage | wall |
|---|---|
| cold clone + deps to the `build.rs` panic | 149s |
| `scripts/build-sidecar.sh` | 64s |
| `cargo build -p tillandsias-headless` after staging | 27s |

A cold clone hit a fail-loud guard worth naming, because most of this
document is about instruments that lie and this one did the opposite:
`build.rs` panicked with `required runtime asset missing:
images/router/tillandsias-router-sidecar`, explained that it is a build
artifact never committed (order 710-w9kc), said a fresh clone will not have
it, and gave the exact remedy. It cost one cycle to diagnose rather than an
hour.

### FINDING A — `--capabilities` serves a cached envelope indistinguishably from a live one

**This is the more serious of the two and it invalidated my own first
reading.** The command returns the contents of
`~/.cache/tillandsias/capabilities.json` when that file exists, with nothing
in the output saying so.

How it was established, because the first inference was unsound and the
correction matters. Two consecutive runs produced byte-identical envelopes
including a nanosecond-precision `timestamp` of
`2026-09-12T03:29:40.356539631+00:00`, ~20h behind the wall clock. Identical
output alone proves nothing — both runs landed inside the same second. The
nanoseconds are what cannot be coincidence: a real `chrono::Utc::now()` does
not reproduce `.356539631` twice. The decisive test was to move the cache
aside and re-run:

| cache present | `timestamp` = `2026-09-12T03:29:40.356539631+00:00` |
| cache aside   | `timestamp` = `2026-09-13T00:06:19.927717658+00:00`, matching wall clock |

The cache file was restored afterwards, unmodified, with its original mtime.

Consequence for this row and beyond: **any host that has read
`--capabilities` may have been reading a replay**, and nothing in the envelope
distinguishes the two. A stale provisioning state can therefore propagate as
a current measurement across the fleet, which is exactly the failure this
packet exists to correct, one layer up from where it was looking. The envelope
already carries `probe_identity` and `hardware_fingerprint`; it does not carry
a served-from-cache flag or a cache age.

I am not filing a fix. This is a second row, it belongs to whoever owns the
probe's caching, and it wants a decision — bypass flag, staleness bound, or an
explicit `source=cache|measured` field — rather than my guess at one.

### FINDING B — the WSL2 reason is a hardcoded constant, not a detection

Everything below is a **live** measurement, taken with the cache bypassed.

```
accel_class=cpu-only accel_gpu=present-unusable
accel_gpu_name=WSL2_paravirtual_GPU_dev_dxg
accel_reason=engine-missing_no-vulkan-icd
accel_proof=unknown accel_side=wsl2-guest accel_gpu_path=dxg-d3d12
accel_gpu_engine=engine-missing accel_cpu_cores=4 accel_ram_gb=8
accel_prefill_dev=cpu accel_decode_dev=cpu accel_decode_crossover_b=unmeasured
```

```
"render_nodes": []          "engines": []
"enumeration_gaps": ["container-lane"]
"probe_identity": "56.9.12+27c4c20d14e70a9e"
"hardware_fingerprint": "hw2-956e80f459c25b53"

{ "device_class": "gpu", "vendor": "unknown",
  "name": "WSL2 paravirtual GPU (/dev/dxg)", "device_node": "/dev/dxg",
  "usable": false, "unusable_reason": "engine-missing:no-vulkan-icd",
  "lanes": [] }
```

`render_nodes` is empty, as this host's `/dev/dri` absence predicts, and
`accel_proof=unknown`. The packet's criterion-1 work has partly landed: the
envelope no longer says `accel_gpu=none`, it names `/dev/dxg`, and it gives a
reason.

**The reason is false on this host.** `accel_reason=engine-missing_no-vulkan-icd`
asserts no Vulkan ICD is installed. There is one, and it enumerates
`PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU` — the first half of this document is
that measurement.

By symbol, this is not a detection that failed. `wsl2_paravirtual_gpu_reason()`
returns the string literal `"engine-missing:no-vulkan-icd"` unconditionally,
and `enumerate_gpus` assigns it to every WSL2 dxg device. Nothing reads
`/usr/share/vulkan/icd.d`, `libvulkan.so`, or an enumeration result. The
value was correct for the host it was derived from — yolanda, measured with
no loader present — and was baked in as universal.

Criterion 2 requires that detection be **by enumeration, not file existence**.
The current code does neither: it is a constant. And the packet's own context
section warns about precisely this shape, where 599-3b9h's expectation "was
derived from the same blind rubric it was checking, so the observation
confirmed the implementation rather than the hardware". The fix reproduced the
defect it was written to remove, one layer in — and it was invisible until a
host with the loader installed ran the probe, which had never happened before.

The verdict itself I am NOT calling wrong. `usable: false` and `cpu-only` may
well be right here: I ran no inference, measured no throughput, and an N100
iGPU may be a loss exactly as yoga measured for gfx1152. What is wrong is the
**reason**, which states a provisioning fact that is not true of this host.

### Unexplained, recorded rather than resolved

Between two `date -u` reads separated by `sleep 5` in one shell, the distro's
clock returned the same second. I did not pursue it and I am not asserting a
clock defect — the live envelope's timestamp agreed with the wall clock to one
second in the test above, which argues against one. Noted because it is the
kind of thing that corrupts a measurement quietly, and because I would rather
record an anomaly I cannot explain than leave it out.

### The independence caveat, restated as ordered

The Vulkan ICD package on this host reports installed 2026-08-17, one day after
yolanda's 2026-08-16 experiment. **Nobody should invent a link.** I have no
evidence connecting them. If it was a deliberate follow-up install rather than
routine image provisioning, this host is less independent of that experiment
than everything above assumes, and Finding B's force is unchanged but its
framing as "a host nobody provisioned" is not. Whoever owns the builder image
can settle it.
