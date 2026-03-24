## Why

The release pipeline fails on every `workflow_dispatch` run because the tag validation step receives `main` instead of a version tag. Meanwhile, GitHub Actions warns that Node.js 20 actions will be **force-migrated to Node.js 24 on June 2, 2026** — breaking builds if not addressed proactively. Debugging these CI failures burns slow, expensive, rate-limited cloud compute when a local Windows cross-compilation pipeline could catch most issues on the host machine first.

## What Changes

- **`build-windows.sh`**: New script that cross-compiles for Windows using `cargo-xwin` inside a dedicated toolbox. Produces unsigned NSIS/MSI artifacts for local testing and troubleshooting. Follows the same `--flags` convention as `build.sh`.
- **CI Node.js 24 migration**: Set `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24=true` in both CI workflows to opt into Node.js 24 before the June 2026 forced migration. Upgrade `node-version` from 22 to 24 in `setup-node`.
- **CI release workflow fix**: Fix the tag validation step to work correctly with both tag pushes and `workflow_dispatch` triggers.
- **Document macOS build infeasibility**: Apple's EULA prohibits macOS virtualization on non-Apple hardware. No `build-osx.sh` — macOS builds remain CI-only. Document the legal constraints and recommend alternatives (Cirrus Runners/Tart on Apple Silicon) for future self-hosted CI.

## Capabilities

### New Capabilities
- `windows-cross-build`: Local Windows cross-compilation pipeline using cargo-xwin in a dedicated toolbox, producing unsigned Tauri artifacts for testing/troubleshooting

### Modified Capabilities
- `ci-release`: Fix tag validation for workflow_dispatch, migrate to Node.js 24, add FORCE_JAVASCRIPT_ACTIONS_TO_NODE24 env var
- `dev-build`: Document that macOS local builds are not feasible; link to cross-platform build strategy

## Impact

- **New files**: `build-windows.sh`, `docs/cross-platform-builds.md`
- **Modified files**: `.github/workflows/release.yml`, `.github/workflows/ci.yml`
- **New dependencies**: `cargo-xwin` (installed inside toolbox), Windows SDK headers (downloaded by cargo-xwin at build time)
- **New toolbox**: `tillandsias-windows` for cross-compilation isolation
- **No macOS changes**: Legal analysis confirms no viable path for local macOS builds from Linux
