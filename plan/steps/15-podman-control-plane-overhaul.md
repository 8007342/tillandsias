# Step 15: Podman Control-Plane Overhaul

## Status

in_progress

## Intent

Replace the split Rust/shell Podman surface with one Rust-owned control plane,
then migrate runtime, build, test, and litmus callers onto it in waves.

## Evidence landed

- Added `PodmanBackend` with `RealBackend`, `FakeBackend`, and `ReplayBackend`.
- Added lossless `CommandOutput` / `CommandFailure` facts and retry classes.
- Added `ContainerDiagnostics` plus failed-launch snapshot rendering.
- Added the dedicated `tillandsias-podman-cli` crate and thin shell facade.
- Codified the local/small/large/full ladder as executable wrappers.

## Remaining waves

1. Move residual runtime-adjacent direct calls onto the backend seam.
2. Migrate build.sh and shell litmuses to `tillandsias-podman-cli`.
3. Enforce the no-direct-Podman audit repo-wide after the remaining legacy
   orchestration scripts are retired.

## Verification

```bash
cargo test -p tillandsias-podman -p tillandsias-podman-cli
```
