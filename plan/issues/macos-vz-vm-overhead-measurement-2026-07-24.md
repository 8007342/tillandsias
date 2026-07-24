# Measurement: macOS Virtualization.framework VM overhead (vs Linux-native / WSL2)

- **Date:** 2026-07-24
- **Class:** measurement / research (performance overhead)
- **Area:** macOS VZ runtime efficiency — the near-zero-overhead-guest invariant on Apple Virtualization.framework
- **Status:** first live host-side measurement captured; the clean IDLE decomposition + guest-side container breakdown are follow-ups (see below).
- **Context:** measured live while an attended OpenCode forge (BigPickle) was actively running (VM uptime 01:41). Host: 10-core Apple Silicon, 16 GB RAM.

## What runs where (topology)

- **`com.apple.Virtualization.VirtualMachine.xpc` (pid 68612)** — the VZ VM itself (Fedora guest + rootful podman + the forge stack). This is where ~all overhead lives.
- **`tillandsias-tray` (pid 68602)** — the menubar app that owns the VM handle. **57 MB RSS, ~0% CPU — negligible.** The VM's memory/CPU is NOT in the tray process (VZ runs the guest in the framework XPC helper).

## Measured overhead (live, BigPickle active)

| Metric | Value | Notes |
| --- | --- | --- |
| Guest RAM (configured) | **4 GiB, 4 vCPU** | `vz.rs:981-982` (`cpu_count = host_cores.clamp(1,4)`, `memory_bytes = 4 GiB`) |
| Host RSS (VM process) | **~5.72 GB** | 4 GiB guest RAM + ~1.7 GB host-side virtualization structures; ~36% of a 16 GB Mac |
| VM CPU (active use) | **~0.55–0.90 of ONE core** | sustained during BigPickle's active work; NOT idle |
| Overall system | **~88% idle** | the VM used <1 of 10 cores; the Mac was not saturated |

## Assessment (preliminary)

- **Compute efficiency looks good.** Apple's hypervisor is hardware-accelerated; the VM used <1 core while the system stayed ~88% idle. No sign of a runaway.
- **The structural cost is memory, not CPU.** The VZ model commits a **~4 GiB guest RAM footprint** (~5.7 GB total host RSS). This is a real tax that **Linux-native does not pay (0 VM) and WSL2 mitigates** with dynamic/ballooning memory that returns RAM to the host. On a 16 GB Mac this is significant (~36%).
- **The CPU number is NOT an idle-overhead number.** The ~0.8-core reading was taken while BigPickle was actively working, so it cannot be attributed to virtualization overhead. The operator's real question — *is macOS:virtualization "near-zero CPU when idle" like WSL2?* — requires a controlled IDLE measurement.

## Follow-ups (to answer the operator's actual question)

1. **Clean IDLE CPU measurement** — during the pending fresh-forge test (a VM this cycle controls), launch the forge, let it sit with nothing running, and sample the VZ XPC process CPU. That is the apples-to-apples comparison to WSL2's "near-zero idle." **This is the load-bearing number and is still open.**
2. **Guest-side container breakdown** — `podman stats --no-stream` + guest `top` to split the footprint across the forge stack (forge / git-mirror / proxy / vault / inference). **Do this only on a VM this cycle owns** — `--exec-guest` against the LIVE BigPickle VM risks booting a second VM against the same provisioned disk (corruption); do not probe the live VM.
3. **Memory-tax mitigation** — check whether the VZ VirtioMem balloon is enabled / whether 4 GiB is right-sized, and whether the guest returns unused RAM to the host (WSL2 parity).

## Cross-references

- `plan/issues/research-near-zero-overhead-guest-invariant-2026-07-23.md` — the invariant this measures against (WSL2/Linux parity).
- `crates/tillandsias-vm-layer/src/vz.rs:960-982` — the VM CPU/RAM config.
