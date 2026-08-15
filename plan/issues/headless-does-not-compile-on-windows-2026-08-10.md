# `tillandsias-headless` does not compile on Windows (653-7rag)

- Date: 2026-08-10
- Host: windows (windows-next), meta-orchestration cycle 10
- Class: `optimization/` — a cross-platform build break no lane's gate catches
- Found: incidentally, while running `cargo build --workspace --tests` after an
  unrelated shared-crate change

## The break

```
error[E0381]: used binding `physical_cores` isn't initialized
   --> crates/tillandsias-headless/src/accel_probe.rs:239:23
161 |     let physical_cores;          <- declared, never assigned on this target
error[E0381]: used binding `logical_cores` isn't initialized
```

`enumerate_cpu()` declares both bindings uninitialized and assigns them inside
`#[cfg(target_os = "linux")]` and a macOS arm. **There is no arm for any other
target**, so on Windows the bindings are read before assignment and the crate
fails to compile.

## Why it survived

Introduced by `bd8a47d1` — *"fix(accel): the 8 macOS-only lints linux could not
enumerate — cfg-gated facts"*. The commit message states the condition that
produced the defect: a Linux host was repairing platform-gated code it cannot
itself compile. Fixing the macOS arm while leaving no fallback arm is invisible
from both Linux and macOS.

It also survives the gate. **`./build.sh --check` passes on this tree** — the
check gate validates the plan ledger, traces and YAML, and does not build the
workspace. So nothing in the normal push path on any host would report this.

## Scope question, stated rather than assumed

`tillandsias-headless` runs **in the guest** (Linux) and is injected into the WSL
distro as a prebuilt binary, so it is fair to ask whether Windows is required to
build it at all. That is a real question and this report does not presume the
answer.

What is not in question: the crate is a workspace member, so
`cargo build --workspace` and `cargo test --workspace` both fail on a Windows
checkout. A Windows contributor running either — the two most ordinary commands
in a Rust repo — hits a hard error in a crate they did not touch.

Two defensible resolutions:

1. **Give `enumerate_cpu` a fallback arm** for targets that are neither Linux nor
   macOS (`physical_cores = None; logical_cores = num_cpus();` or equivalent).
   Smallest fix, keeps the workspace buildable everywhere.
2. **Exclude the crate from the Windows workspace build** deliberately and say so,
   so the failure becomes a documented boundary rather than a surprise.

Option 1 is the better reduction: it removes the failure mode rather than
documenting it, and a probe that cannot describe an unknown platform is arguably
wrong on its own terms.

## Not fixed here

Left for a lane that can verify the accel probe's behaviour rather than just its
compilation. This host can confirm the crate builds; it cannot confirm the CPU
enumeration is still correct on Linux and macOS, and a probe that compiles while
reporting wrong hardware would be a worse outcome than a build error.
