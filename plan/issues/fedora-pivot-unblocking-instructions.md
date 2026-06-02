# Fedora Pivot — Cross-Host Unblocking Instructions

**Date**: 2026-06-02
**Status**: Windows slice COMPLETE; macOS/Linux slices READY.
**Trace**: `plan/issues/rootfs-removal-fedora-wsl-pivot-2026-06-02.md`, Step 23.

The project is currently in an architectural transition ("Fedora Pivot"). The Windows host has successfully moved to official Fedora-44 WSL images and fixed its fetch timeouts. To fully converge and exit the `DEGRADED` status, the following actions are required on sibling hosts:

## 1. macOS Host (m9 packet)
**Action**: Pivot the tray from custom rootfs `.img.xz` to official Fedora Cloud aarch64 images.

- **Files to touch**: 
    - `crates/tillandsias-macos-tray/src/action_host.rs`
    - `crates/tillandsias-macos-tray/src/diagnose.rs`
- **Steps**:
    1.  Update the fetcher to use the `aarch64.qcow2` URL template from `images/vm/manifest.toml`.
    2.  Implement conversion from `.qcow2` to raw `.img` (or similar) for `Virtualization.framework`.
    3.  Reuse the `fetch-headless.sh` and systemd unit injection pattern established in Windows `wsl_lifecycle.rs` to bootstrap the `tillandsias-headless` agent.
    4.  Update `diagnose.rs` to report `fedora-44` and track the `.qcow2` manifest pin.

## 2. Linux Host (l10 packet)
**Action**: Decommission the obsolete rootfs publishing workflow.

- **Files to touch**:
    - `.github/workflows/recipe-publish.yml`
    - `openspec/litmus-tests/litmus-recipe-release-tag-symmetric.yaml`
    - `images/vm/manifest.toml` (remove dead comments/OCI references)
- **Steps**:
    1.  Delete the `recipe-publish.yml` workflow (we now use official Fedora upstream).
    2.  Remove the `litmus-recipe-release-tag-symmetric.yaml` test (it tracks the obsolete `RECIPE_RELEASE_TAG`).
    3.  Perform a cleanup of `images/vm/` to remove any buildah/Containerfile logic that was only used for the custom rootfs.

## 3. Coordination (All Hosts)
- **Branch Strategy**:
    - All hosts should merge `origin/windows-next` (commit `c39e22b7` or later) to get the fixed `tillandsias-vm-layer::fetch` timeouts and the updated `manifest.toml`.
    - Once `m9` and `l10` are complete, the `Rootfs Removal / Fedora Pivot` step in `plan/index.yaml` can be marked as `completed`.

---
**Windows Readiness Evidence**:
- `cargo test -p tillandsias-windows-tray -p tillandsias-vm-layer` is **100% green**.
- Windows tray provisions correctly from stock Fedora .tar.xz via `wsl --import`.
- Diagnostics correctly report the Fedora-44 baseline.
