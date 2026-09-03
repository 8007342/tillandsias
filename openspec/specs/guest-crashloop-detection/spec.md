# guest-crashloop-detection Specification

@trace spec:guest-crashloop-detection

## Status

active

## Purpose

The host tier must tell a guest that is LOOPING — restarting over and over,
never converging — apart from one that is merely progressing slowly, and say
so in a pinned, regex-testable grammar. One pure-Rust state machine
(`tillandsias-control-wire::crashloop`) is consumed by every tray (Windows
NotifyIcon, macOS AppKit, Linux), so the platforms cannot drift on what
"crash loop" means. Registry-asserted (litmus:guest-crashloop-detection)
before this file existed — order 877 closed that ghost.

## Requirements

### Requirement: A loop is detected within the window
<!-- req-id: c46003b9 -->

A driven stop→start series (repeated Ready→Provisioning transitions, or a
sealed-vault restart loop) MUST flip `--diagnose`'s verdict to
`crash-loop:<subsystem>` within the detection window, naming the looping
subsystem.

#### Scenario: Sealed-vault loop flips the verdict

- **WHEN** the guest restarts repeatedly against a sealed vault
- **THEN** `--diagnose` reports `crash-loop:<subsystem>` within the window
  (litmus:guest-crashloop-detection, positive arm)

### Requirement: Slow progress is never a crash loop
<!-- req-id: 4f54ca71 -->

A normal, slow, monotonically-progressing provision MUST NEVER flip the
verdict — no false positive on slow starts. This negative arm is an explicit
exit criterion, not a nice-to-have: a detector that cries wolf on cold
first-provisions (multi-GB rootfs downloads) trains operators to ignore it.

#### Scenario: Cold provision stays quiet

- **WHEN** provisioning advances monotonically, however slowly
- **THEN** the verdict never reads `crash-loop:*`
  (litmus:guest-crashloop-detection, negative arm)

### Requirement: The detector is proven where it ships
<!-- req-id: aaab9ee9 -->

The faithful proof is the Rust unit suite of `tillandsias-control-wire` — the
code every tray actually consumes — not a shell re-implementation that could
pass while the shipped state machine is broken.

#### Scenario: The litmus compiles the shipped crate

- **WHEN** `scripts/test-guest-crashloop-detection.sh` runs
- **THEN** it drives the real `crashloop` module's tests and fails if they do

## Sources of Truth

- `crates/tillandsias-control-wire/` — the `crashloop` state machine
- `scripts/test-guest-crashloop-detection.sh`
- `plan/issues/guest-crashloop-detection-and-ephemeral-reset-2026-07-17.md`
- `openspec/litmus-bindings.yaml` (spec_id `guest-crashloop-detection`)
