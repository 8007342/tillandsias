# macOS tray: 3 pre-existing clippy warnings — 2026-07-06

- class: optimization (code cleanliness, non-blocking)
- filed: 2026-07-06
- owner: macos
- status: ready
- trace: surfaced while running `cargo clippy -p tillandsias-vm-layer -p
  tillandsias-macos-tray --all-targets` during order 194 macOS slices 1/2/4
  (none of these three warnings are new from that work — all three predate it).

## Finding

`cargo clippy --all-targets` on `tillandsias-macos-tray` reports 3 warnings
(no errors, build is green):

1. `clippy::large_enum_variant` on `ControlWireStream` in
   `crates/tillandsias-macos-tray/src/action_host.rs:268` — `Secure` variant
   (≥304 bytes, wraps `EncryptedStream<VsockStream>`) vs `Plain` (≥40 bytes).
   Suggested fix: `Secure(Box<EncryptedStream<...>>)`.
2. The same `ControlWireStream` enum is duplicated verbatim in
   `crates/tillandsias-macos-tray/src/diagnose.rs:95` with the identical
   warning. (Also relevant to the reuse/DRY opportunity noted below.)
3. `clippy::match_result_ok` in `crates/tillandsias-macos-tray/src/status_item.rs:203`:
   `if let Some(mut exedir) = std::env::current_exe().ok()` should be
   `if let Ok(mut exedir) = std::env::current_exe()`.

## Work

1. Box the `Secure` variant in both `ControlWireStream` definitions
   (action_host.rs + diagnose.rs) to shrink the enum.
2. Fix the `status_item.rs:203` redundant `.ok()` match.
3. (Separate, larger, optional) `ControlWireStream` /
   `open_control_wire_stream` / `secure_control_wire_mode` are now defined
   twice — once in `action_host.rs`, once in `diagnose.rs` — since order 194
   slice 2 added a third caller of the same "secure-or-plain opener" pattern
   (`probe_phase_secure_or_plain` in diagnose.rs). Consider consolidating into
   one shared module (e.g. `crates/tillandsias-macos-tray/src/control_wire.rs`)
   if a fourth call site appears; not urgent today since both copies compile,
   test, and stay in sync.

## Acceptance Evidence

- `cargo clippy -p tillandsias-macos-tray --all-targets` reports 0 warnings.
