//! Shared materializer driver (`vm-recipe-provisioning §3`). Linux owns the
//! buildah-orchestration core (`run`, layer cache, .tar export); macOS owns
//! the `.img` converter (`materialize::macos::tar_to_vfr_img`, §3.7.1);
//! Windows owns the WSL importer (`materialize::wsl::tar_to_wsl_import`,
//! §3.7.2). All three platforms parse the same `images/vm/Recipefile` via
//! `tillandsias-vm-layer::recipe`.
//!
//! Module skeleton — opened to unblock per-OS converters even before the
//! `run()` driver lands. Once the Linux materializer driver is in, callers
//! invoke `materialize::run(recipe, manifest, arch)` to get a `.tar` and
//! then pipe that through the per-OS converter.
//!
//! @trace openspec/changes/vm-recipe-provisioning §3, §D6

/// Per-OS converters that turn a materialized rootfs `.tar` into the
/// VM-native format. Each lives behind its own feature/cfg gate; the
/// converters are intentionally Linux-runnable (per D6) so CI can produce
/// all formats in one job rather than spawning a per-OS runner.
pub mod macos;
