# Smart App Control intermittently removes this host's ONLY way to verify Windows-only code

Filed 2026-08-13 (windows host, meta-orchestration cycle 10). Captured because
it changes what this host can honestly claim, not because it is new.

## The two facts, together

1. `crates/tillandsias-windows-tray/src/{wsl_lifecycle,notify_icon,hvsocket,
   installation_uuid}.rs` are `#[cfg(target_os = "windows")]`, and `main.rs`
   substitutes `src/stubs/*.rs` on Linux. A `cargo check`/`cargo test` inside
   the `tillandsias-build` WSL distro therefore compiles the STUB and reports
   success **without ever parsing the changed file**.

2. Smart App Control on this host blocks freshly built unsigned binaries with
   `An Application Control policy has blocked this file. (os error 4551)`. It is
   intermittent: the native `cargo test -p tillandsias-windows-tray` ran clean at
   ~01:00 (85 passed, 32s) and was blocked at every attempt from ~03:10 onward.

Individually each is a known nuisance. Together they mean that when SAC is
active, this host has **no way at all** to compile-check Windows-only code — and
the failure is silent in the direction that matters, because the WSL run goes
green.

## What was tried this cycle

| Route | Result |
|---|---|
| native `cargo test -p tillandsias-windows-tray` | `os error 4551`, repeatedly |
| WSL `cargo check -p tillandsias-windows-tray` | green — but compiles the Linux stub, proves nothing |
| WSL `cargo check --target x86_64-pc-windows-msvc` | fails in `cc-rs`: no `lib.exe`; then `ring`'s build script fails |

A `x86_64-pc-windows-gnu` cross-check was not attempted; the distro has no
mingw-w64 and installing it mid-cycle was out of scope.

## Why this is worth a packet rather than a shrug

Order 624-cf9f's whole point this cycle was that a check which cannot fail is
not a check. This is the same shape one level up: an agent on this host can edit
Windows-only code, run the tests it has, see green, and push — with the changed
file never compiled by anything. That is not hypothetical; it is what the first
cargo invocation of cycle 7 did, and only a deliberate second look caught it.

Candidate directions, none decided here:

- **Sign the dev binaries.** SAC's objection is reputation, not content. A local
  code-signing certificate trusted by the machine would end the whole class.
- **Cross-check with `x86_64-pc-windows-gnu`** in the builder distro, accepting
  that it type-checks rather than links. Cheap, and it would have caught every
  Windows-only mistake this session.
- **Make the stub substitution loud.** `main.rs` could `compile_error!` — or the
  gate could refuse — when a Windows-only source is newer than the last native
  check, so "I compiled the stub" stops looking like "I compiled the code".

The third is the one that matches this project's habits: it converts a silent
substitution into a falsifiable statement.

## Interim rule for this host

A cycle that touches `crates/tillandsias-windows-tray/src/*` and cannot run the
native toolchain must say so in its packet event and must not record the change
as verified. Cycle 10 (order 664-frz0) is the first to do this explicitly.
