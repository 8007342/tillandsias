## Why

Tillandsias uses bash scripts as middleware between Rust code and podman/gh CLI calls on the host. This worked well on Linux where bash is a first-class citizen, but it creates a fundamental problem on Windows: Git Bash (MSYS2) does not initialize properly when `bash.exe` is launched from a native Windows process. The project has accumulated workarounds (drive-letter-to-MSYS2-path conversion in `embedded::bash_path`, environment sanitization, etc.), but these are fragile and mask the real issue.

The real fix is to stop depending on bash for host-side operations entirely. The `build-image.sh` script has already been bypassed on Windows with a direct `podman build` call in `handlers.rs` (gated behind `#[cfg(target_os = "windows")]`). This proves the pattern works. The next step is to apply the same approach to `gh-auth-login.sh`, and then to unify all platforms so Linux and macOS also use direct Rust calls instead of shelling out to bash.

This does NOT affect container entrypoints. Bash runs perfectly inside Linux containers -- the problem is only with bash as a host-side process launcher.

**Key observations:**
- `build-image.sh` on Windows: already bypassed with direct `podman build` (working)
- `gh-auth-login.sh` on Windows: still goes through bash, which fails without manual Git Bash setup
- `build-image.sh` on Linux/macOS: works via bash but could be simplified to direct podman calls
- Container entrypoints (e.g., `entrypoint.sh`): run inside containers, unaffected

## What Changes

- Replace `gh-auth-login.sh` invocation with direct `gh` / `podman run` calls from Rust (Phase 1, Windows first, then all platforms)
- Replace `build-image.sh` invocation with direct podman calls from Rust on all platforms (Phase 2)
- Keep bash scripts in the repository as documentation and for manual developer use, but the runtime binary no longer depends on them
- Remove the `embedded::bash_path` workaround and related MSYS2 path conversion code once all scripts are bypassed

## Capabilities

### New Capabilities
- `direct-podman-calls`: Host-side operations (image builds, GitHub auth) use direct podman/gh CLI invocations from Rust instead of bash script wrappers

### Modified Capabilities
- `gh-auth-script`: The `gh-auth-login.sh` script remains for manual use but is no longer invoked by the binary at runtime
- `default-image`: Image builds use direct `podman build` on all platforms (currently only Windows)
- `embedded-scripts`: Reduced scope -- container entrypoints and image sources are still embedded, but host-side bash scripts are no longer extracted and executed

## Impact

- **Windows**: GitHub Login menu item will work without requiring Git Bash to be installed or configured
- **Linux/macOS**: No user-visible change -- same operations, fewer moving parts
- **Binary size**: Slightly smaller (no longer embedding `gh-auth-login.sh` and `build-image.sh` as string constants)
- **Security**: Reduced attack surface -- no temp script extraction, no shell injection vectors from path handling
- **Maintainability**: One implementation path per operation instead of bash + Rust with platform-specific branching
