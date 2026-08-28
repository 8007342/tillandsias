---
tags: [macos, virtualization-framework, vz, guest-boot, vm-sizing, boot-latency, performance-baseline]
languages: []
since: 2026-08-18
last_verified: 2026-08-28
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

# macOS VZ guest: boot baseline and host-proportional sizing

@trace order:689-eux9, order:919-jii2, spec:vsock-transport

What a Virtualization.framework guest boot actually costs on this project's
macOS lane, and the measurement behind the host-headroom-aware guest sizing
that replaced the pinned 4 GiB / 4-vCPU default.

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

## The sizing decision: HOST-HEADROOM-AWARE (919-jii2, 2026-08-28)

`crates/tillandsias-vm-layer/src/vz.rs` derives the size from the host with the
pure function `guest_sizing(host_cores, host_memory)`, fed by
`available_parallelism()` and `sysctl -n hw.memsize`:

| | policy | 10c / 16 GiB (the 919-jii2 host) |
|---|---|---|
| vCPU | 80% of logical cores, never below 4 (or the host's count if smaller) | 8 |
| memory | `min(host/2, host - 6 GiB)`, clamped to `[4 GiB, 32 GiB]`, rounded down to a whole GiB | 8 GiB |

Worked cases: an 8 GiB host gets the 4 GiB floor (half is 4, but the 6 GiB host
reserve allows only 2); a 12 GiB host gets 6 GiB; a 128 GiB host is capped at
32 GiB, since past that the fraction buys nothing a forge uses.

### Why the pin was right and is now wrong

689-eux9's idle swap figure still stands *for the workload it measured*. The
workload changed. 919-jii2 records, on that same M5 host: qwen2.5:0.5b and 1.5b
load but fabricate on 6/6 spec queries; 3b has under 1 GiB of headroom for OS +
KV cache; 7b — the size sibling GPU hosts report as the accuracy sweet spot —
cannot load at all. The pin did not make the guest slow; it made a whole class
of work impossible.

### What the prior pinned rationale still buys

1. **Cross-host comparability** (798-q4m9, 807-bjjv) is preserved without
   re-pinning: `guest_sizing` is *pure*, so a measurement that names the host's
   cores and RAM is reproducible from those two numbers, and
   `TILLANDSIAS_VZ_CPU_COUNT_FOR_MEASUREMENT` still constrains the guest to a
   fixed vCPU count for any benchmark that demands one (it can only ever
   constrain, never grow past the host-derived count).
2. **The floor is what keeps a small host working** — the policy never hands
   out less than the 4 GiB / 4 vCPU every macOS host already ran.
3. **80% CPU, not 100%**, and a 6 GiB host memory reserve — a VM that boots by
   swapping its host is worse than a smaller VM.

### Honest limit

The 8 GiB figure comes from model arithmetic (a 7B quantized model + OS + forge
stack), **not** from a loaded measurement of this guest at 8 GiB — every memory
number on this page is still idle. 919-jii2's closure asks for that loaded
measurement; this is the allocation it will be measured at.

## Gotchas worth knowing before you measure

- **80% of host cores, not 100%.** On a 10-core Mac this yields 8 vCPU. The
  remaining 20% keeps the host OS, tray app, and macOS compositor responsive.
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
