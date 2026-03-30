## Why

A knowledge audit against the spec corpus found 6 WARNING-level inaccuracies and 8 SUGGESTION-level gaps where specs omit relevant operational details. Left unfixed, warnings cause implementation drift — developers trusting the spec will make wrong decisions about platform backends, library names, SELinux interactions, Nix build behavior, and CI environment variables. Suggestions address missing documentation for security flags, platform behaviors, and API preferences that, while not incorrect, leave the spec incomplete.

## What Changes

- **filesystem-scanner**: Correct macOS backend from "kqueue" to "FSEvents" (per `knowledge/cheatsheets/frameworks/notify-fs-events.md`: `RecommendedWatcher` uses FSEvents by default on macOS, not kqueue). Clarify that the 2000ms debounce is a project-chosen default, not a crate default.
- **tray-app**: Correct Linux tray integration from "StatusNotifier/libappindicator" to "DBus StatusNotifierItem (libayatana-appindicator)" (per `knowledge/cheatsheets/frameworks/tauri-v2-tray.md`: libayatana-appindicator is the preferred library, and the protocol is DBus StatusNotifierItem).
- **podman-orchestration**: Add explanatory note to the volume mount requirement that `--security-opt=label=disable` (already a non-negotiable security default) eliminates the need for `:z`/`:Z` SELinux relabeling suffixes (per `knowledge/cheatsheets/infra/podman-security.md`).
- **nix-builder**: Add scenario covering the git-tracking caveat — flake builds only see git-tracked files, so new files must be `git add`ed before building (per `knowledge/cheatsheets/packaging/nix-flakes.md`).
- **ci-release**: Add version caveat to the `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24` requirement noting this env var is not documented in the GitHub Actions knowledge base and should be validated against upstream docs periodically.
- **podman-orchestration**: Add `--init` to non-negotiable security defaults. The code already uses it (launch.rs:40) for proper signal handling and zombie reaping, but the spec omits it.
- **podman-orchestration**: Document that rootless networking defaults to pasta (Podman 5.0+), replacing slirp4netns. Spec should note the backend.
- **podman-orchestration**: Add seccomp profile consideration. Default seccomp blocks ~130 syscalls; some profiles block `close_range()` which crun uses for FD cleanup.
- **filesystem-scanner**: Document behavior when `fs.inotify.max_user_watches` is exhausted. Depth-2 scanning mitigates this but the limit scenario should be explicit.
- **update-system**: Add scenario for `APPIMAGE_EXTRACT_AND_RUN` on immutable OSes where FUSE may be unavailable for AppImage execution.
- **environment-runtime**: Document Windows global config path (`%APPDATA%\tillandsias\config.toml`), completing the platform-specific config path coverage.
- **binary-signing**: Standardize signature file naming — one requirement says `.sig`/`.cert`, another says `.cosign.sig`/`.cosign.cert`. Use `.sig`/`.cert` consistently.
- **nix-builder**: Note that `contents` is a legacy alias for `copyToRoot` in `dockerTools`. Spec should reference the preferred API.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `filesystem-scanner`: Correct macOS backend name; clarify debounce default provenance; add inotify watch limit scenario
- `tray-app`: Correct Linux tray library and protocol name
- `podman-orchestration`: Add SELinux label=disable note explaining why `:z`/`:Z` is unnecessary; add `--init` to security defaults; add pasta networking note; add seccomp consideration
- `nix-builder`: Add git-tracking requirement scenario for flake builds; note `copyToRoot` as preferred API over legacy `contents`
- `ci-release`: Add validation caveat for FORCE_JAVASCRIPT_ACTIONS_TO_NODE24
- `update-system`: Add APPIMAGE_EXTRACT_AND_RUN scenario for immutable OS FUSE unavailability
- `environment-runtime`: Add Windows platform-specific config path
- `binary-signing`: Standardize signature file naming to `.sig`/`.cert`

## Impact

- Spec files only — no code, config, or dependency changes
- 8 existing spec files receive targeted wording corrections and gap fills
- No breaking changes; all corrections align specs with existing implementation behavior
