# Step 27 — Release v0.3.0 Milestone

Status: ready
Owner: multi-host
Depends on: [diagnostics-stream-activation, multi-host-ux-parity, forge-toolchain-expansion]

## Goal
Finalize the codebase for the v0.3.0 release, ensuring 100% convergence across Linux, Windows, and macOS, and updating all public-facing documentation and verification paths.

## Tasks
- [ ] **Final Multi-Host Audit**: Perform a zero-drift check across `linux-next`, `windows-next`, and `osx-next`.
- [ ] **Documentation Refresh**: Update `README.md`, `VERIFICATION.md`, and `UPDATING.md` for the v0.3.0 "Fedora Pivot" model.
- [ ] **Release Recovery Test**: Run `./build.sh --ci-full --install` and verify a clean musl release can be published.
- [ ] **Version Bump**: Increment VERSION to `0.3.0` and tag the release.
- [ ] **Release Notes**: Distill the recent work (Fedora Pivot, Diagnostics Stream, Tray Parity) into the `RELEASE-NOTES.md`.

## Exit Criteria
- Release v0.3.0 published with all 22+ signed assets.
- Fedora Silverblue, Windows WSL2, and macOS VZ installers all verified green.
- `plan/index.yaml` shows 100% completion of the v0.3.0 wave.
