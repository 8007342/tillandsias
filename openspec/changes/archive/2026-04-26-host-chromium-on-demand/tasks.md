# Tasks — host-chromium-on-demand

## 1. Pin authoring: scripts/refresh-chromium-pin.sh

- [ ] 1.1 Create `scripts/refresh-chromium-pin.sh` that:
  - Fetches `https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json`
    and reads `channels.Stable.version` (using `jq` — already in the dev toolbox).
  - For each platform in `linux64 mac-arm64 mac-x64 win64`, downloads the
    `chrome-<platform>.zip` from
    `https://storage.googleapis.com/chrome-for-testing-public/<version>/<platform>/chrome-<platform>.zip`
    into a temporary scratch directory.
  - Runs `sha256sum` on each ZIP and captures the hex digest.
  - In-place edits `scripts/install.sh` to set `CHROMIUM_VERSION="…"`,
    `CHROMIUM_SHA256_LINUX64="…"`, `CHROMIUM_SHA256_MAC_ARM64="…"`,
    `CHROMIUM_SHA256_MAC_X64="…"`, and `CHROMIUM_SHA256_WIN64="…"`.
  - Removes the scratch directory on completion.
  - Supports a `--print-pinned` flag that prints only the current
    pinned version + digests to stdout (for scripted assertions in
    tests and for the `Pinned Chromium version + per-platform SHA-256`
    spec scenario).
- [ ] 1.2 Add `# @trace spec:host-chromium-on-demand` and
  `# @cheatsheet security/owasp-top-10-2021.md` headers to the script.
- [ ] 1.3 Add a `--release-cut` mode that fails the script if the JSON
  Stable channel version is older than the currently-pinned version
  (paranoia check against accidental downgrade).
- [ ] 1.4 Document the script in `docs/cheatsheets/secrets-management.md`
  under a new "release-cut sweeps" section (the script handles binary
  pinning, parallel to other release-cut sweeps).

## 2. Installer changes: scripts/install.sh

- [ ] 2.1 Add the four `CHROMIUM_SHA256_*` and `CHROMIUM_VERSION` shell
  variables near the top of `scripts/install.sh` with placeholder
  values (overwritten by `refresh-chromium-pin.sh` at release-cut
  time; first-ship values come from running the refresh script as
  part of this change's apply phase).
- [ ] 2.2 Implement `install_chromium()` shell function:
  1. Detect platform (`uname` for linux64 / mac-arm64 / mac-x64;
     PowerShell branch for win64).
  2. Compute install root per platform per the `Userspace install
     location under XDG_DATA_HOME` requirement.
  3. If `<root>/<CHROMIUM_VERSION>/chrome-<platform>/chrome` already
     exists with the right binary, skip (idempotent).
  4. Otherwise download
     `https://storage.googleapis.com/chrome-for-testing-public/$CHROMIUM_VERSION/<platform>/chrome-<platform>.zip`
     via `curl -fL --retry 3` with an `User-Agent: tillandsias-installer/<version>` header.
  5. Compute SHA-256 (`sha256sum` / `shasum -a 256` / `certutil`)
     and compare against the platform's `CHROMIUM_SHA256_*`. Abort
     non-zero on mismatch with the message in the
     `SHA-256 verification before extraction` requirement.
  6. Extract via `unzip` (Linux / macOS) or `Expand-Archive`
     (Windows) into `<root>/<CHROMIUM_VERSION>/`.
  7. macOS branch: `xattr -dr com.apple.quarantine "$BUNDLE" 2>/dev/null || true`.
  8. Atomically repoint `<root>/current` → `<CHROMIUM_VERSION>` via
     `ln -snf` (Unix) or `mklink /J` (Windows; remove old junction
     first if present).
  9. GC pass: enumerate sibling version directories under `<root>/`,
     keep the new version and the immediately-previous version,
     remove anything older. Conform to the `Rolling-window garbage
     collection of old versions` requirement.
- [ ] 2.3 Add the `SKIP_CHROMIUM_DOWNLOAD=1` env-var guard at the top
  of `install_chromium()`. If set, print one stderr advisory line
  and return success without doing anything.
- [ ] 2.4 Wire `install_chromium` into the install.sh main flow
  (after the Tillandsias binary placement, before the desktop-entry /
  systemd-user-unit step on Linux).
- [ ] 2.5 Add the platform-appropriate uninstall hint to install.sh's
  success epilogue per the `Uninstall path is documented one-liner`
  requirement.
- [ ] 2.6 Add `# @trace spec:host-chromium-on-demand` and
  `# @cheatsheet runtime/forge-paths-ephemeral-vs-persistent.md`
  comments to `install_chromium`.

## 3. Tray subcommand: tillandsias --install-chromium

- [ ] 3.1 Add a new clap subcommand under `src-tauri/src/cli.rs`:
  `tillandsias --install-chromium [--from-zip <path>]`. Both
  variants share the verify+extract+xattr+repoint sequence; the
  `--from-zip` variant skips the curl fetch.
- [ ] 3.2 Implement `src-tauri/src/chromium_runtime.rs` (new module)
  with public functions:
  - `install_from_url(version: &str, expected_sha256: &str) -> Result<PathBuf>`
  - `install_from_zip(zip_path: &Path, expected_sha256: &str) -> Result<PathBuf>`
  - `current_install_path() -> Option<PathBuf>` (reads the
    `current` symlink target)
  - `gc_old_versions() -> Result<Vec<PathBuf>>` (returns the
    directories removed)
- [ ] 3.3 The `expected_sha256` and `version` arguments are sourced
  from compile-time constants embedded in the tray binary by the
  build script (which reads the same values from
  `scripts/install.sh` so both paths share one source of truth).
  See task 6 below for the embedding mechanism.
- [ ] 3.4 Add `// @trace spec:host-chromium-on-demand` and
  `// @cheatsheet runtime/forge-paths-ephemeral-vs-persistent.md`
  on every public item in `chromium_runtime.rs`.
- [ ] 3.5 Unit tests in `src-tauri/src/chromium_runtime.rs::tests`:
  - 3.5.1 `verify_sha256_matches_known_good` against a small fixture
    archive checked into `src-tauri/tests/fixtures/`.
  - 3.5.2 `verify_sha256_rejects_corrupt_archive` (bit-flipped
    fixture).
  - 3.5.3 `gc_keeps_two_versions` with a fake on-disk layout under
    `tempfile::TempDir`.
  - 3.5.4 `current_symlink_repoint_is_atomic` (write a file via the
    symlink, repoint, read via the symlink, assert the new target's
    file content).

## 4. Browser detection rewrite: src-tauri/src/browser.rs

- [ ] 4.1 Replace `detect_browser()` with the userspace-first / system-
  fallback / hard-error logic per the `Detection priority` requirement.
  The new return type is `Result<BrowserKind, String>` (hard error
  becomes an `Err`).
- [ ] 4.2 Tombstone `BrowserKind::Safari`, `BrowserKind::Firefox`, and
  `BrowserKind::OsDefault` variants and their launch arms with
  `// @tombstone superseded:host-chromium-on-demand` headers naming
  the release the change ships in and the release after which the
  block is safe to delete (three-release window per project
  convention).
- [ ] 4.3 Update `launch_for_project` to:
  1. Resolve the binary via the new detection.
  2. Allocate an ephemeral `--user-data-dir` under
     `$XDG_RUNTIME_DIR/tillandsias/browser/` per the
     `Per-launch CDP and ephemeral profile flags` requirement.
  3. Allocate a random ephemeral CDP port (`49152..=65535`).
  4. Spawn Chromium with the full flag set:
     `--app=<url> --user-data-dir=<tmpdir> --incognito --no-first-run --no-default-browser-check --remote-debugging-port=<port>`
     plus the existing dark-mode flags (`--force-dark-mode`,
     `--enable-features=WebContentsForceDark`, and the
     `GTK_THEME=Adwaita:dark` env on Linux).
  5. Return the chosen CDP port to the caller so capability
     `opencode-web-session-otp`'s CDP client can attach.
- [ ] 4.4 Add cleanup logic: when the spawned Child exits, remove
  the per-launch tmpdir. Cover the tray-crash recovery case by
  scanning `$XDG_RUNTIME_DIR/tillandsias/browser/` at tray startup
  and removing any directories whose timestamp is older than the
  tray's start time.
- [ ] 4.5 Add `// @trace spec:host-chromium-on-demand,
  spec:opencode-web-session, spec:opencode-web-session-otp` on every
  modified function.
- [ ] 4.6 Update tests in `src-tauri/src/browser.rs::tests`:
  - 4.6.1 New: `detect_prefers_userspace_install_over_system_path`
    using a `tempfile::TempDir` posing as `XDG_DATA_HOME` and a
    second tmpdir posing as a system-PATH directory holding a stub
    `chromium` shell script.
  - 4.6.2 New: `detect_falls_back_to_system_when_userspace_missing`.
  - 4.6.3 New: `detect_returns_hard_error_when_nothing_resolves`.
  - 4.6.4 Keep the URL-builder tests intact (they don't depend on
    detection).

## 5. Embedded version + digests in the tray binary

- [ ] 5.1 Add `src-tauri/build.rs` logic that reads `CHROMIUM_VERSION`
  and the four `CHROMIUM_SHA256_*` values from `scripts/install.sh`
  at compile time and exposes them via `env!` macros. Layer this on
  top of the existing `embedded.rs` build-time embed pattern (per
  `feedback_embedded_image_sources`).
- [ ] 5.2 Expose them in `src-tauri/src/chromium_runtime.rs` as
  `pub const CHROMIUM_VERSION: &str = env!("TILLANDSIAS_CHROMIUM_VERSION");`
  and four `pub const CHROMIUM_SHA256_<PLAT>: &str = env!("TILLANDSIAS_CHROMIUM_SHA256_<PLAT>");`.
- [ ] 5.3 Acceptance assertion in `chromium_runtime.rs::tests`:
  `embedded_pin_matches_install_sh` — read `scripts/install.sh` at
  test time, parse the variables, assert the embedded constants are
  identical. Catches drift if a developer edits one path without the
  other.

## 6. Uninstall integration

- [ ] 6.1 Modify `src-tauri/src/cli.rs --uninstall --wipe` to also
  remove the platform-appropriate `tillandsias/chromium/` directory
  per the `Uninstall path is documented one-liner` requirement.
- [ ] 6.2 Add a `--help` epilogue line documenting the manual
  `rm -rf …/tillandsias/chromium/` form for users who want to remove
  Chromium without uninstalling Tillandsias entirely.

## 7. Documentation: cheatsheets and provenance

- [ ] 7.1 Update `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md`
  to add a row covering the host-side bundled Chromium binary tree
  (XDG_DATA_HOME category, regenerable only by re-running the
  installer, never auto-cleaned). Bump the cheatsheet's
  `Last updated:` date and revalidate cited URLs.
- [ ] 7.2 Update `cheatsheets/security/owasp-top-10-2021.md` if it
  doesn't already explicitly cover the SHA-256-pinned-binary pattern
  under A08 (Software and Data Integrity Failures); add a one-line
  example pointing at the install.sh implementation.
- [ ] 7.3 Update `cheatsheets/web/http.md` if needed to cover the
  curl semantics used by `install_chromium` (`-fL --retry 3`,
  custom User-Agent, `Range`-resumable downloads against
  `storage.googleapis.com`).
- [ ] 7.4 Verify all three updated cheatsheets retain their
  `## Provenance` section per the project rule
  (`feedback_cheatsheets_require_provenance`).

## 8. Audit logging

- [ ] 8.1 Emit accountability log entries for every install_chromium
  invocation (success + failure) with `category = "download"`,
  `source = "host-installer"`,
  `target = "<root>/<version>/chrome-<platform>"`,
  `spec = "host-chromium-on-demand"`,
  `cheatsheet = "runtime/forge-paths-ephemeral-vs-persistent.md"`,
  and the SHA-256 verify outcome.
- [ ] 8.2 Emit a one-time accountability log entry at tray startup
  when `detect_browser()` falls back to the system PATH, naming the
  binary chosen (per the detection-fallback scenario in the spec).
- [ ] 8.3 Emit accountability entries on `current` symlink repointing
  (success + failure) so the GC and rollover history is auditable.

## 9. Integration tests

- [ ] 9.1 Add a host-side integration test under
  `src-tauri/tests/install_chromium.rs` that:
  - Creates a tempdir as a fake XDG_DATA_HOME.
  - Stubs the network fetch by serving a fixture archive over a
    local `tiny_http` server bound to a loopback ephemeral port.
  - Runs the equivalent of `install_chromium` (via the
    `chromium_runtime::install_from_url` API) against the local
    server and asserts the on-disk layout, the symlink target, and
    the SHA-256 verify path.
  - Repeats with a corrupted archive and asserts the failure mode.
- [ ] 9.2 Add a release-blocking smoke test that, given a Tillandsias
  build artefact, asserts the embedded `CHROMIUM_VERSION` resolves
  to a live URL on `storage.googleapis.com` (HEAD request returns
  200 / `Content-Length` matches the recorded size on the
  refresh-pin scratch run).

## 10. Versioning and commit

- [ ] 10.1 After `/opsx:archive`, run
  `./scripts/bump-version.sh --bump-changes`.
- [ ] 10.2 Commit with the trace URL footer per project convention:
  `https://github.com/8007342/tillandsias/search?q=%40trace+spec%3Ahost-chromium-on-demand&type=code`.
- [ ] 10.3 Run `scripts/refresh-chromium-pin.sh` once before tagging
  the release to lock in the actual first-ship pinned version (today
  the design.md and spec.md both name `148.0.7778.56`; that may
  drift before this change ships — the refresh script is the single
  source of truth at tag time).
