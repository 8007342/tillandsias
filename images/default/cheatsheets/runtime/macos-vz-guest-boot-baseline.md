---
tags: [macos, virtualization-framework, vz, guest-boot, vm-sizing, boot-latency, performance-baseline]
languages: []
since: 2026-08-18
last_verified: 2026-08-18
sources:
  - https://developer.apple.com/documentation/virtualization/vzvirtualmachineconfiguration
  - https://developer.apple.com/documentation/virtualization/vzvirtualmachineconfiguration/3656714-cpucount
  - https://developer.apple.com/documentation/virtualization/vzvirtualmachineconfiguration/3656718-memorysize
  - crates/tillandsias-vm-layer/src/vz.rs
authority: high
status: current
# bundled, following the crdt-ledger-fragments precedent: this is a
# PROJECT-LOCAL measurement record, not an upstream tool sheet, so there is
# nothing to pull on demand — the content IS the artifact. developer.apple.com
# is absent from license-allowlist.toml, which per TEMPLATE.md is exactly the
# case that needs an explicit `tier: bundled`.
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: true
---

# macOS VZ guest: boot baseline and why the sizing is pinned

@trace order:689-eux9, spec:vsock-transport

What a Virtualization.framework guest boot actually costs on this project's
macOS lane, and the measurement behind the hardcoded 4 GiB / 4-vCPU guest.

**Provenance note**: the Apple URLs above are the authority for what
`cpuCount` / `memorySize` MEAN. The NUMBERS below are project-local
measurement, not upstream documentation, and are labelled as such per
`methodology/cheatsheets.yaml` → `provenance.rule` — project-local inference is
not provenance. Cite the measurement, not the vendor, for anything in the
tables.

## The measurement

Host: `Mac17,3`, Apple M5, 10 logical cores, 16 GiB, macOS Darwin 25.6.0.
Date: 2026-08-18. Two **cold** runs (VM stopped ~21 h, well outside the
near-teardown hazard window of 663-69kp). Driven by
`dist/Tillandsias.app/Contents/MacOS/tillandsias-tray --exec-guest … < /dev/null`,
each output line timestamped with `perl -MTime::HiRes`.

| Phase | Run 1 | Run 2 |
|---|---:|---:|
| `starting VM…` (stage + VZ config) | +0.021 s | +0.008 s |
| `waiting for VM phase Ready…` (VZ start returned) | +0.329 s | +0.315 s |
| phase **Ready** (guest booted, control wire up) | **+8.454 s** | **+8.444 s** |
| guest command executing | +8.534 s | +8.515 s |
| result returned, VM stopped | +9.556 s | +9.550 s |
| **total wall** | **9.573 s** | **9.562 s** |

Variance between samples is ~10 ms on every phase. This independently confirms
the "~9 seconds end to end" figure recorded when 689-eux9 was filed.

**Read the shape, not just the total**: VZ itself starts in ~0.3 s. Essentially
all of the ~9.5 s is *guest kernel + systemd reaching Ready*. Host-side work is
noise. Anything that appears to make "boot" slow is therefore either in the
guest's own startup or is not boot at all — which is exactly what 689-stig
found when apparent slowness turned out to be two unbounded waits during which
**no VM process existed**.

## In-guest state at idle

```
nproc  → 4
Mem:   3889 MiB total,  648 used, 2993 free, 3240 available
Swap:  3888 MiB total,     0 used
/      250G total, 7.2G used (3%)
load   0.00 0.00 0.00
```

**Swap used = 0 is the number that answers the sizing question.** The guest has
never touched swap, so it has never been under memory pressure. The operator
question of 2026-08-11 — *is the 4 GiB ceiling behind the slowness; would 8 GiB
help?* — is answered **no** on both halves: no pressure, and the slowness had a
different cause entirely.

## The sizing decision: PINNED

`crates/tillandsias-vm-layer/src/vz.rs` sets `cpu_count:
available_parallelism().min(4)` and `memory_bytes: 4 GiB`. Both stay pinned.

1. **No measured pressure to relieve** — the swap figure above.
2. **Scaling to the host would make every cross-host measurement
   incomparable.** This is the reason that is easy to miss and is the stronger
   one. "The guest" has to mean the same thing on every machine, or the fleet
   cannot compare numbers taken on different ones. Concretely: 798-q4m9's exit
   criteria demand a bind-latency measurement on a guest constrained to **one**
   vCPU and explicitly refuse a multi-vCPU pass as evidence; 807-bjjv exists
   because a shared benchmark is worthless when hosts do not run the same
   workload. A host-derived guest size silently reintroduces that variance into
   every future measurement.

### Honest limit

Every memory figure here is **idle**. Nothing measures the guest under a full
forge + container-stack load. This justifies keeping the default; it is **not**
a claim that 4 GiB suffices for every workload. Revisit with a loaded
measurement, not an opinion.

## Gotchas worth knowing before you measure

- **`.min(4)` caps a 10-core host at 4 vCPU.** That is why the guest's
  capability envelope reports `accel_cpu_cores=4` on a 10-core Mac — the
  envelope describes the VM, not the machine.
- **Boot from `dist/`, not `target/release` or `/Applications`.**
  `target/release/tillandsias-tray` lacks the
  `com.apple.security.virtualization` entitlement and cannot start a VM at all
  (811-j9fc); `/Applications` may carry an older embedded guest binary.
- **Redirect stdin.** `--exec-guest` reads piped stdin; without `< /dev/null`
  an inherited-but-never-closed stdin costs the bounded forward timeout
  (689-stig / 663-69kp).
- **Do not boot straight after a teardown.** Boots near a previous teardown
  were the 663-69kp hazard; leave a gap.
- **BSD `date` has no `%N`.** For sub-second timestamps on macOS use
  `perl -MTime::HiRes=time`, not `date +%s.%N`.
