## Context

The Tillandsias release pipeline (`.github/workflows/release.yml`) builds for Linux, macOS (aarch64 + x86_64), and Windows using GitHub Actions matrix runners. The most recent release runs all fail at the "Validate tag matches VERSION file" step because the workflow is triggered via `workflow_dispatch` from the `main` branch — `GITHUB_REF_NAME` resolves to `main` instead of a version tag like `v0.0.25.21`.

Additionally, GitHub Actions has announced that Node.js 20 actions will be force-migrated to Node.js 24 on June 2, 2026. The current workflows use actions that still run on Node.js 20 internally (`actions/checkout@v4`, `actions/setup-node@v4`, `actions/upload-artifact@v4`).

The user wants to debug Windows builds locally instead of burning CI minutes. Research reveals that Windows containers cannot run on Linux (requires Windows kernel), but Rust cross-compilation to Windows is feasible via `cargo-xwin`. macOS cross-compilation is not possible for Tauri apps (requires native WebKit frameworks) and is prohibited by Apple's EULA on non-Apple hardware.

## Goals / Non-Goals

**Goals:**
- Enable local Windows cross-compilation for testing/troubleshooting (unsigned artifacts)
- Fix the CI release workflow tag validation for `workflow_dispatch` triggers
- Migrate CI to Node.js 24 before the June 2026 deadline
- Document why macOS local builds are infeasible

**Non-Goals:**
- Producing signed Windows artifacts locally (code signing requires CI secrets)
- Running Windows containers on Linux (technically impossible with podman/Linux kernel)
- Local macOS builds (Apple EULA prohibits, Tauri needs native frameworks)
- Replacing CI — local builds supplement CI for troubleshooting, not replace it

## Decisions

### Decision 1: cargo-xwin for Windows cross-compilation

**Choice**: Use `cargo-xwin` to cross-compile the Rust workspace for `x86_64-pc-windows-msvc` from Linux.

**Alternatives considered**:
- *Windows containers (podman/docker)*: Not possible on Linux — Windows containers need a Windows kernel. Podman issue #8136 is open with no volunteers.
- *QEMU/KVM Windows VM in container*: Works via `dockur/windows` but requires a Windows license, is extremely heavy (~40GB disk, 8GB+ RAM), and defeats the purpose of fast local iteration.
- *MinGW (gnu target)*: Produces `x86_64-pc-windows-gnu` artifacts, but Tauri officially targets MSVC and the NSIS installer requires MSVC.
- *cross-rs*: Good for pure Rust but doesn't support Tauri's native dependencies well.

**Rationale**: `cargo-xwin` downloads Microsoft's CRT and Windows SDK headers automatically (accepting their license terms), uses Clang as the cross-linker, and is the tool Tauri's own documentation references for experimental cross-compilation. The SDK download is free and legally clear for development use.

**Limitation**: Cross-compiled builds cannot be Windows Authenticode signed. Tauri's Ed25519 update signing also won't work locally (needs `TAURI_SIGNING_PRIVATE_KEY`). Local artifacts are for testing only.

### Decision 2: Dedicated `tillandsias-windows` toolbox

**Choice**: Create a separate toolbox for Windows cross-compilation dependencies rather than polluting the main `tillandsias` toolbox.

**Rationale**: The main toolbox has Linux-specific deps (webkit, GTK, appindicator). The Windows cross-compilation needs different deps (clang, lld, NSIS). Keeping them separate follows the existing toolbox-per-purpose convention and allows `toolbox rm tillandsias-windows` for clean removal.

### Decision 3: Fix tag validation with workflow_dispatch input

**Choice**: Add an optional `version` input to `workflow_dispatch` that overrides `GITHUB_REF_NAME` for tag validation. When triggered from a tag, use the tag. When triggered manually, require the version input.

**Alternatives considered**:
- *Skip validation for workflow_dispatch*: Defeats the purpose of version consistency checks.
- *Only allow tag triggers*: Too restrictive during development — manual triggers are valuable for testing the pipeline.

### Decision 4: Node.js 24 opt-in via environment variable

**Choice**: Set `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24=true` as a workflow-level env var in both `ci.yml` and `release.yml`. Also bump `setup-node` to `node-version: 24`.

**Rationale**: GitHub's migration path is explicit — set the env var to opt in early. This catches compatibility issues now rather than June 2026. The `punycode` deprecation warning (`DEP0040`) in the logs is a Node.js internal issue in the GitHub Actions runtime, not in our code — it will resolve when actions update their internal dependencies.

### Decision 5: No build-osx.sh

**Choice**: Do not create a macOS cross-compilation script. Document why in `docs/cross-platform-builds.md`.

**Rationale**:
- Apple's EULA Section 2B: macOS may only be installed on "Apple-branded hardware"
- Tauri requires native WebKit/AppKit frameworks that don't exist on Linux
- `osxcross` extracts the macOS SDK, violating the Xcode license agreement
- The existing CI macOS runners (free for public repos) are the correct solution
- Future alternative: Cirrus Runners with Tart on self-hosted Apple Silicon

## Risks / Trade-offs

- **[cargo-xwin Tauri compatibility]** → Tauri cross-compilation is labeled "experimental." The NSIS installer generation may fail. Mitigation: `build-windows.sh` catches and reports errors clearly; user falls back to CI for the full pipeline.
- **[Microsoft SDK license acceptance]** → `cargo-xwin` downloads the Windows SDK on first run. Mitigation: Script prints a notice about the license terms before proceeding.
- **[Node.js 24 breakage]** → Opting into Node.js 24 early could expose bugs in action runtimes. Mitigation: The `punycode` deprecation is harmless; test CI after the change and revert if needed.
- **[workflow_dispatch version input]** → Manual triggers require remembering to pass the version. Mitigation: Clear error message if omitted, and the common case (tag push) remains automatic.
