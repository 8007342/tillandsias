## 1. Fix filesystem-scanner spec

- [x] 1.1 In `openspec/specs/filesystem-scanner/spec.md`, change "kqueue" to "FSEvents" in the macOS scenario and requirement text. Reference `RecommendedWatcher` as the selection mechanism.
- [x] 1.2 In the debounced event batching requirement, change "default: 2000ms" to "project default: 2000ms" and add clarifying text that this is a project choice, not a crate default.

## 2. Fix tray-app spec

- [x] 2.1 In `openspec/specs/tray-app/spec.md`, change the Linux tray scenario from "StatusNotifier/libappindicator" to "DBus StatusNotifierItem (libayatana-appindicator)".

## 3. Fix podman-orchestration spec

- [x] 3.1 In `openspec/specs/podman-orchestration/spec.md`, add explanatory text to the volume mount requirement that `--security-opt=label=disable` makes `:z`/`:Z` unnecessary.
- [x] 3.2 Add a new scenario "SELinux relabeling not required" to the volume mount requirement.

## 4. Fix nix-builder spec

- [x] 4.1 In `openspec/specs/nix-builder/spec.md`, add a new requirement "Git-tracked files for flake builds" with scenarios covering untracked file exclusion and staged file inclusion.

## 5. Fix ci-release spec

- [x] 5.1 In `openspec/specs/ci-release/spec.md`, add a validation caveat to the Node.js 24 requirement noting that `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24` is not documented in the verified knowledge base.
- [x] 5.2 Add a new "Upstream validation" scenario for periodic verification of the env var.

## 6. Verify convergence (warnings)

- [x] 6.1 Run `/opsx:verify` to confirm all warning-level delta specs apply cleanly and no new warnings are introduced.

## 7. Fix podman-orchestration spec — add --init flag

- [x] 7.1 In `openspec/specs/podman-orchestration/spec.md`, add `--init` to the "Default container launch" scenario's flag list in the security-hardened container defaults requirement.
- [x] 7.2 Add a new scenario "Seccomp profile compatibility" documenting that the default seccomp profile blocks ~130 syscalls and that some profiles may block `close_range()`.

## 8. Fix podman-orchestration spec — document pasta networking

- [x] 8.1 In `openspec/specs/podman-orchestration/spec.md`, add a new requirement "Rootless networking backend" documenting that Podman 5.0+ defaults to pasta instead of slirp4netns.

## 9. Fix filesystem-scanner spec — inotify watch limits

- [x] 9.1 In `openspec/specs/filesystem-scanner/spec.md`, add a scenario "inotify watch limit exhausted on Linux" to the OS-native event-driven watching requirement, documenting behavior when `fs.inotify.max_user_watches` is reached.

## 10. Fix update-system spec — APPIMAGE_EXTRACT_AND_RUN

- [x] 10.1 In `openspec/specs/update-system/spec.md`, add a scenario "AppImage on immutable OS without FUSE" documenting that `APPIMAGE_EXTRACT_AND_RUN=1` should be set when FUSE is unavailable.

## 11. Fix environment-runtime spec — Windows config path

- [x] 11.1 In `openspec/specs/environment-runtime/spec.md`, add a scenario "Platform-specific config paths (Windows)" documenting the `%APPDATA%\tillandsias\config.toml` path.
- [x] 11.2 Add a scenario "Platform-specific config paths (Linux)" explicitly documenting the `~/.config/tillandsias/config.toml` path for completeness.

## 12. Fix binary-signing spec — standardize file extensions

- [x] 12.1 In `openspec/specs/binary-signing/spec.md`, change `.cosign.sig`/`.cosign.cert` to `.sig`/`.cert` in the "Cosign signing produces verifiable signatures" requirement to match the "Signature and certificate artifacts" requirement.

## 13. Fix nix-builder spec — copyToRoot preference

- [x] 13.1 In `openspec/specs/nix-builder/spec.md`, add a new requirement "Preferred dockerTools API usage" noting that `copyToRoot` is the preferred attribute over the legacy `contents` alias in `dockerTools.buildLayeredImage`.

## 14. Verify convergence (all)

- [x] 14.1 Run `/opsx:verify` to confirm all delta specs (warnings + suggestions) apply cleanly and no new issues are introduced.
