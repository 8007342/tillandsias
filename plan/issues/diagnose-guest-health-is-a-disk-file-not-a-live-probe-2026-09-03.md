# `--diagnose` reports `Guest health: healthy` with no VM running — it reads a state file, not a guest

- classification: research
- filed: 2026-09-03 (macos/tlatoanis-macbook-air, Mac17,3, 16 GiB)
- found while: producing 16 GiB reference numbers for macneo-macos's guest-sizing
  investigation, which had cited this field as corroboration for VM liveness

## Measured

`./target/release/tillandsias-tray --diagnose --with-metrics`, on a host with
**no VM running at all** — sampled `ps` for
`com.apple.Virtualization.VirtualMachine` every 5 s for 70 s and it never
appeared — printed:

```
Guest health: healthy
Status: PROVISIONED — first-launch materialization complete.
```

## Why

`diagnose.rs` `guest_health_verdict` loads `crashloop.state` from the image root
and returns that detector's verdict. It never contacts a guest. On this host the
file was last written **2026-08-30** carrying `ever_ready 1, last_phase ready`,
so the field reported "healthy" five days later about a VM that was not running
and had not run since.

The verdict grammar (`^(healthy|starting|crash-loop:[a-z0-9-]+)$`) is pinned by
a test, so the FIELD is well-formed. What is not pinned is what it means.

## The defect

**"healthy" means "the last recorded phase was not a crash loop". It does not
mean "a guest is alive", and it cannot distinguish the two.** A reader who has
just been told the process is missing will read "healthy" as contradicting that,
which is exactly backwards: the field is silent about liveness.

This is not hypothetical. macneo-macos's first-launch forensics cited
`--diagnose` reporting healthy while investigating a VM they believed dead. The
VM was in fact alive, so the field's output happened to be right — but it was
not evidence, and had the VM genuinely been dead the field would have said the
same thing. A signal that reads identically in both states cannot corroborate
either.

Same family as the instrument defects found across the fleet on 2026-09-02/03:
the tool answers truthfully about a smaller universe (crash-loop history) than
the question assumes (current guest health).

## Also observed in the same run

- **`--with-metrics` did not boot a VM.** Its documented contract is "boot the
  VM, read the guest metrics snapshot over the control wire, print it in the
  report, then stop the VM". It returned in seconds having booted nothing,
  warning "running outside .app". Whether that is the intended non-bundled
  behaviour or a silent skip of the whole verb is worth deciding — as written,
  the flag's promise and its behaviour disagree.
- **A bare `target/release/tillandsias-tray` cannot start a VM at all:**
  `start: validate: Invalid virtual machine configuration. The process doesn't
  have the "com.apple.security.virtualization" entitlement.` The entitlement is
  applied to the `.app` bundle, so any guest work must run
  `dist/Tillandsias.app/Contents/MacOS/tillandsias-tray`. This presents as a VM
  boot failure and is really a launch-path failure.

## Candidate fixes, not decided here

1. Rename the field to what it measures — `Crash-loop state: healthy` — which
   costs nothing and removes the misreading entirely.
2. Report liveness separately and honestly, e.g. `Guest process: absent` from a
   `ps`/`launchd` check, keeping the crash-loop verdict beside it.
3. Say when the state was recorded: `Guest health: healthy (as of
   2026-08-30T18:41Z)`. A five-day-old verdict labelled with its age is no
   longer capable of being misread as current.

Option 1 alone would have prevented the misreading that produced this file, and
3 is nearly free on top of it. The `--diagnose` surface is operator-facing, so
the naming is the substance rather than a cosmetic.

## Reference numbers gathered in the same session (16 GiB tier)

Recorded here because the fleet has only two macOS hosts and the other is 8 GiB:

- `guest sizing: 8 vCPU / 8 GiB (host: 10 cores / 16 GiB)`
- guest at idle Ready, from inside: `total 7906  used 877  free 6807
  buff/cache 377  available 7029`, 8 cores
- host-side XPC helper RSS at the same moment: ~2384 MB, steady

Note the ~1.5 GiB disagreement between the guest's own "used" and the host's
RSS: host RSS counts mapped and cached pages the guest does not call used.
**Do not compare a host-side footprint against a guest-side allocation** — that
mismatch makes a healthy guest look near-exhausted.
