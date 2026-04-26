## ADDED Requirements

### Requirement: Pinned Chromium version + per-platform SHA-256

The Tillandsias `scripts/install.sh` SHALL pin a single Chromium version
string and a per-platform SHA-256 digest at every Tillandsias release. The
initial pinned version on first ship of this capability is
`148.0.7778.56` (the Chrome for Testing Stable channel head verified via
`https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json`
on 2026-04-25). Subsequent Tillandsias releases bump both the version
string AND the per-platform SHA-256 digests in lockstep via
`scripts/refresh-chromium-pin.sh` BEFORE the release workflow runs.

The pin SHALL include exactly four per-platform SHA-256 digests, one per
supported binary archive:

| Platform | Archive | Variable in install.sh |
|---|---|---|
| `linux64` | `chrome-linux64.zip` | `CHROMIUM_SHA256_LINUX64` |
| `mac-arm64` | `chrome-mac-arm64.zip` | `CHROMIUM_SHA256_MAC_ARM64` |
| `mac-x64` | `chrome-mac-x64.zip` | `CHROMIUM_SHA256_MAC_X64` |
| `win64` | `chrome-win64.zip` | `CHROMIUM_SHA256_WIN64` |

The Chrome for Testing JSON endpoint does NOT publish SHA-256 digests
(verified 2026-04-25), therefore the digests are computed at our
release-cut time by `scripts/refresh-chromium-pin.sh` running
`sha256sum` on each downloaded archive and substituted into
`scripts/install.sh` via shell-variable replacement.

@trace spec:host-chromium-on-demand

#### Scenario: install.sh has all four digests and a pinned version

- **WHEN** auditing `scripts/install.sh` after a release-cut sweep
- **THEN** the file declares non-empty `CHROMIUM_VERSION`,
  `CHROMIUM_SHA256_LINUX64`, `CHROMIUM_SHA256_MAC_ARM64`,
  `CHROMIUM_SHA256_MAC_X64`, and `CHROMIUM_SHA256_WIN64` shell variables
- **AND** each digest is a 64-character lowercase-hex SHA-256
- **AND** `CHROMIUM_VERSION` matches the format `<MAJOR>.<MINOR>.<BUILD>.<PATCH>`
- **AND** the version string is the same one printed by
  `scripts/refresh-chromium-pin.sh --print-pinned`

#### Scenario: refresh-chromium-pin.sh is the sole authoring path

- **WHEN** any commit modifies `CHROMIUM_VERSION` or any
  `CHROMIUM_SHA256_*` variable in `scripts/install.sh`
- **THEN** the same commit either (a) modifies
  `scripts/refresh-chromium-pin.sh`, OR (b) is the output of running
  that script
- **AND** no developer hand-edits the digests directly

### Requirement: Userspace install location under XDG_DATA_HOME

The Chromium binary tree SHALL live exclusively under the user's
`XDG_DATA_HOME` (or platform equivalent), per-version subdirectory, with
a `current` symlink (or Windows directory junction) pointing at the
active version. The exact roots are:

| Platform | Root |
|---|---|
| Linux | `${XDG_DATA_HOME:-$HOME/.local/share}/tillandsias/chromium/` |
| macOS | `$HOME/Library/Application Support/tillandsias/chromium/` |
| Windows | `%LOCALAPPDATA%\tillandsias\chromium\` |

The directory layout SHALL be:

```
<root>/
├── <version>/                    # e.g. 148.0.7778.56/
│   └── chrome-<platform>/        # extracted ZIP root
│       ├── chrome  (or Chromium.app on macOS, chrome.exe on Windows)
│       └── … (libs, locales, resources)
└── current -> <version>          # symlink (Unix) or junction (Windows)
```

The install path is **per-user** and is NEVER written under any system
prefix (`/opt/`, `/usr/`, `/Applications/`, `Program Files\`). The
installer SHALL NOT invoke `sudo` for any step of the Chromium download,
extraction, or symlink creation.

The `current` symlink is repointed atomically at the end of a successful
extract+verify+xattr sequence; partial extracts MUST NOT leave `current`
pointing at an incomplete tree.

@trace spec:host-chromium-on-demand
@cheatsheet runtime/forge-paths-ephemeral-vs-persistent.md

#### Scenario: Linux install lands under XDG_DATA_HOME

- **WHEN** `scripts/install.sh` runs on a Linux user with
  `XDG_DATA_HOME` unset and `$HOME=/home/aj`
- **THEN** the Chromium binary lands at
  `/home/aj/.local/share/tillandsias/chromium/<version>/chrome-linux64/chrome`
- **AND** a symlink at `/home/aj/.local/share/tillandsias/chromium/current`
  points at `<version>`
- **AND** no file is written outside `/home/aj/.local/share/tillandsias/`
- **AND** `sudo` is never invoked

#### Scenario: macOS install respects Library/Application Support

- **WHEN** `scripts/install.sh` runs on a macOS user with `$HOME=/Users/aj`
- **THEN** the bundle lands at
  `/Users/aj/Library/Application Support/tillandsias/chromium/<version>/chrome-mac-arm64/Chromium.app`
  (or `chrome-mac-x64` on Intel)
- **AND** `current -> <version>` is created in the same
  `tillandsias/chromium/` directory

#### Scenario: Windows install respects %LOCALAPPDATA%

- **WHEN** `install.ps1` (or the Windows path of `install.sh` via Git Bash)
  runs on a Windows user
- **THEN** the binary lands at
  `%LOCALAPPDATA%\tillandsias\chromium\<version>\chrome-win64\chrome.exe`
- **AND** the `current` directory junction (created via `mklink /J`)
  points at `<version>`

#### Scenario: cache directory is NEVER used

- **WHEN** auditing `scripts/install.sh` and `src-tauri/src/`
- **THEN** no code path writes the Chromium binary tree under
  `${XDG_CACHE_HOME:-$HOME/.cache}/`, `~/Library/Caches/`, or
  `%LOCALAPPDATA%\…\Cache\`
- **AND** the rationale comment in install.sh cites the freedesktop.org
  XDG Base Directory specification: caches are by definition deletable
  at any time, the Chromium binary is NOT regenerable by the running
  tray, therefore data category — not cache category

### Requirement: SHA-256 verification before extraction

`scripts/install.sh` SHALL compute the SHA-256 of the downloaded
`chrome-<platform>.zip` and compare it against the per-platform digest
baked into the script BEFORE invoking any extraction tool, BEFORE
chmod, and BEFORE moving the archive into the install directory. On
mismatch the installer SHALL abort with a non-zero exit code, leave
the install tree in its prior state, and emit a clear error message
naming the expected digest, the computed digest, and a remediation
hint.

The hash tool used SHALL match the platform's standard:

| Platform | Hash command |
|---|---|
| Linux | `sha256sum` (coreutils) |
| macOS | `shasum -a 256` (BSD shasum) |
| Windows | `certutil -hashfile … SHA256` |

@trace spec:host-chromium-on-demand
@cheatsheet security/owasp-top-10-2021.md

#### Scenario: Mismatched digest aborts the install

- **WHEN** `scripts/install.sh` downloads
  `chrome-linux64.zip` and the computed SHA-256 differs from
  `CHROMIUM_SHA256_LINUX64`
- **THEN** the installer prints
  `Chromium download failed integrity check. Aborting.` along with the
  expected and computed digests
- **AND** exits with status non-zero
- **AND** the install tree at
  `~/.local/share/tillandsias/chromium/` is unchanged from before the
  download attempt
- **AND** no `unzip`, `chmod`, or `mv` is invoked on the bad archive

#### Scenario: Matching digest proceeds to extract+verify chain

- **WHEN** the SHA-256 matches the baked digest
- **THEN** the installer proceeds to extract the archive into the
  per-version subdirectory
- **AND** runs the macOS quarantine-strip step (when applicable)
- **AND** repoints the `current` symlink atomically
- **AND** returns success status

### Requirement: macOS Gatekeeper quarantine attribute is stripped

On macOS, `scripts/install.sh` SHALL run
`xattr -dr com.apple.quarantine "$CHROMIUM_DIR/Chromium.app"`
immediately after the archive is extracted, and BEFORE the `current`
symlink is repointed. The `-r` flag is mandatory because the quarantine
attribute is set on multiple files inside the `.app` bundle when the
ZIP is downloaded via curl. The error path of `xattr` SHALL be
swallowed (`2>/dev/null || true`) so the step is no-op-safe on
filesystems / platforms where the attribute was never set.

@trace spec:host-chromium-on-demand

#### Scenario: Quarantine attribute is removed before launch

- **WHEN** `scripts/install.sh` extracts `chrome-mac-arm64.zip` on a
  macOS host where the curl download set `com.apple.quarantine` on
  every file inside the bundle
- **THEN** the post-extract step runs `xattr -dr com.apple.quarantine`
  on the bundle root
- **AND** subsequent `xattr` queries against any file inside the
  bundle return no `com.apple.quarantine` entry
- **AND** the next launch of `Chromium.app` does NOT trigger
  Gatekeeper's "downloaded from the internet" dialog

#### Scenario: Step is a no-op on Linux and Windows

- **WHEN** `scripts/install.sh` runs on Linux or Windows
- **THEN** the quarantine-strip step is skipped entirely (guarded by
  the platform branch)
- **AND** the install proceeds without invoking `xattr`

### Requirement: Detection priority — userspace first, system fallback, hard error

The tray's `detect_browser()` SHALL resolve the Chromium binary in the
following strict priority order, returning the first match:

1. The userspace install at
   `<XDG_DATA_HOME>/tillandsias/chromium/current/chrome-<platform>/chrome`
   (the install path under capability `host-chromium`).
2. `chromium` or `chromium-browser` on `$PATH`.
3. `google-chrome` or `google-chrome-stable` on `$PATH`.
4. `microsoft-edge-stable` or `microsoft-edge` on `$PATH`.
5. Hard error.

Userspace-first is non-negotiable: once the installer has fetched the
pinned version, the tray uses ONLY it. The system-PATH fallback exists
exclusively to avoid stranding users who installed Tillandsias via
direct AppImage download (no `install.sh` run yet) and have not yet
re-run the installer to fetch the bundled Chromium. The fallback never
applies if the userspace install is present.

When no candidate resolves, the tray SHALL emit a hard error to the
log and to the tray-menu accountability chip with the message
`Chromium not installed. Re-run the installer or run "tillandsias --install-chromium".`
The tray SHALL NOT prompt with a dialog, SHALL NOT add a menu item,
and SHALL NOT trigger an automatic download.

@trace spec:host-chromium-on-demand, spec:opencode-web-session

#### Scenario: Userspace install present — used regardless of system browsers

- **WHEN** the userspace install at
  `~/.local/share/tillandsias/chromium/current/chrome-linux64/chrome`
  exists AND the system also has `google-chrome` on `$PATH`
- **THEN** `detect_browser()` returns the userspace path
- **AND** the system `google-chrome` binary is NOT used
- **AND** the launch flags target the userspace binary's path

#### Scenario: Userspace install missing, system Chromium present — fallback path

- **WHEN** the userspace install does not exist AND
  `which chromium` returns `/usr/bin/chromium`
- **THEN** `detect_browser()` returns `Chromium { bin: /usr/bin/chromium }`
- **AND** the tray logs an accountability warning at info level naming
  the fallback so power users can see it (`spec = "host-chromium-on-demand"`,
  `category = "browser-detect"`, `using = "system-fallback"`)

#### Scenario: Nothing resolves — hard error, no UI prompt

- **WHEN** the userspace install does not exist AND no
  Chromium-family binary is on `$PATH`
- **THEN** `detect_browser()` returns an error variant
- **AND** the next attach attempt fails with the message
  `Chromium not installed. Re-run the installer or run "tillandsias --install-chromium".`
- **AND** no dialog is shown
- **AND** no tray menu item is added
- **AND** no background HTTP download is started

### Requirement: Lazy install subcommand and air-gapped path

The tray binary SHALL expose a subcommand
`tillandsias --install-chromium` that runs the same install logic as
`scripts/install.sh` (download from the canonical URL, SHA-256 verify
against the baked digest, extract, xattr-strip on macOS, repoint
`current`). The subcommand SHALL accept a `--from-zip <path>` flag for
the air-gapped case where the user fetched the ZIP on a connected
machine and copied it across.

`scripts/install.sh` SHALL accept an environment variable
`SKIP_CHROMIUM_DOWNLOAD=1` which, when set, causes the installer to
skip the Chromium download phase entirely. The user can then run
`tillandsias --install-chromium` later when network is available.

@trace spec:host-chromium-on-demand

#### Scenario: Lazy install via tray subcommand

- **WHEN** the user runs `tillandsias --install-chromium` after a fresh
  AppImage install where Chromium was not yet fetched
- **THEN** the subcommand downloads `chrome-linux64.zip` from
  `https://storage.googleapis.com/chrome-for-testing-public/<CHROMIUM_VERSION>/linux64/chrome-linux64.zip`
- **AND** verifies the SHA-256 against the baked `CHROMIUM_SHA256_LINUX64`
- **AND** extracts into `~/.local/share/tillandsias/chromium/<version>/chrome-linux64/`
- **AND** atomically repoints the `current` symlink

#### Scenario: Air-gapped install via --from-zip

- **WHEN** the user invokes
  `tillandsias --install-chromium --from-zip ~/Downloads/chrome-linux64.zip`
- **THEN** no network fetch is attempted
- **AND** the SHA-256 of the supplied ZIP is verified against the baked
  `CHROMIUM_SHA256_LINUX64`
- **AND** on match the install proceeds with the standard extract +
  xattr + symlink-repoint sequence
- **AND** on mismatch the subcommand exits non-zero without modifying
  the install tree

#### Scenario: Skip flag opts out of install-time download

- **WHEN** the user runs `SKIP_CHROMIUM_DOWNLOAD=1 bash install.sh`
- **THEN** install.sh prints a clearly-marked advisory line that
  Chromium will not be installed
- **AND** the rest of install.sh (Tillandsias binary placement,
  desktop-entry, etc.) completes normally
- **AND** the tray on first run emits the
  `Chromium not installed. Run "tillandsias --install-chromium".`
  message (per the detection requirement)

### Requirement: Per-launch CDP and ephemeral profile flags

The tray MUST pass the following flags to the Chromium process for
every browser-window launch via `BrowserKind::Chromium`:

- `--app=<url>` — borderless single-site window, no tabs, no URL bar.
- `--user-data-dir=<ephemeral-tmpdir>` — fresh temporary directory
  per launch, destroyed on window close.
- `--incognito` — guarantees no profile state is persisted across the
  ephemeral tmpdir's lifetime.
- `--no-first-run` — skip welcome wizard.
- `--no-default-browser-check` — skip default-browser prompt.
- `--remote-debugging-port=<random-loopback-port>` — opens CDP for
  capability `opencode-web-session-otp` to inject the session cookie.
  The port is drawn from the IANA ephemeral range (49152–65535) and
  bound to loopback only by Chromium's default behaviour.

The tmpdir SHALL be created under `$XDG_RUNTIME_DIR/tillandsias/browser/`
(or `$TMPDIR` fallback) with a unique-per-launch suffix. The tmpdir
SHALL be removed on browser-window close, OR at next tray startup if
the tray exited unexpectedly while the window was open.

@trace spec:host-chromium-on-demand, spec:opencode-web-session-otp
@cheatsheet runtime/forge-paths-ephemeral-vs-persistent.md

#### Scenario: Launch carries every required flag

- **WHEN** the tray launches Chromium for project `thinking-service`
- **THEN** the spawned process command line contains all of
  `--app=http://opencode.thinking-service.localhost:8080/`,
  `--user-data-dir=<tmpdir>`,
  `--incognito`,
  `--no-first-run`,
  `--no-default-browser-check`,
  and `--remote-debugging-port=<port>` where `<port>` is in the
  ephemeral range `49152..=65535`
- **AND** no two concurrent launches share the same `<tmpdir>` path
- **AND** no two concurrent launches share the same `<port>`

#### Scenario: Ephemeral profile is destroyed on window close

- **WHEN** the user closes a Chromium window opened by the tray
- **THEN** the tmpdir at the launch's `--user-data-dir` is removed
  before the tray records the window-closed event in its log
- **AND** subsequent attaches against the same project allocate a
  fresh tmpdir

### Requirement: Uninstall path is documented one-liner

The Chromium binary tree SHALL be removable by a single command:

| Platform | Command |
|---|---|
| Linux | `rm -rf ~/.local/share/tillandsias/chromium/` |
| macOS | `rm -rf ~/Library/Application\ Support/tillandsias/chromium/` |
| Windows | `rmdir /s /q "%LOCALAPPDATA%\tillandsias\chromium"` |

The `tillandsias --uninstall --wipe` subcommand (capability
`app-lifecycle`) SHALL include the Chromium directory in its removal
set. Plain `tillandsias --uninstall` (without `--wipe`) SHALL leave
the Chromium directory in place so a subsequent reinstall can skip
the download.

`scripts/install.sh` SHALL print a one-line uninstall hint in its
success epilogue so users can find the command without leaving the
terminal session that just installed Tillandsias.

@trace spec:host-chromium-on-demand, spec:app-lifecycle

#### Scenario: --uninstall --wipe removes Chromium

- **WHEN** the user runs `tillandsias --uninstall --wipe`
- **THEN** the Chromium binary tree at the platform's install location
  is removed in full
- **AND** the parent `tillandsias/` directory is also removed if empty
  after the chromium subtree is gone

#### Scenario: --uninstall (no --wipe) preserves Chromium

- **WHEN** the user runs `tillandsias --uninstall` without `--wipe`
- **THEN** the Chromium binary tree is left untouched
- **AND** a subsequent `bash install.sh` skips the download phase
  because the version directory and digest already match

#### Scenario: install.sh epilogue documents the rm command

- **WHEN** `scripts/install.sh` completes successfully
- **THEN** the final lines printed to the user include the platform-
  appropriate `rm -rf …/tillandsias/chromium/` hint
- **AND** the hint is also retrievable via `tillandsias --help`

### Requirement: Rolling-window garbage collection of old versions

The installer SHALL keep at most two Chromium version directories on disk at any time. When a pinned-version change is detected, the installer extracts the new version into a sibling per-version subdirectory, atomically repoints `current` to the new version, and then removes the **previous-previous** version's subdirectory if present. The active version (pointed at by `current`) and the immediately-prior version (kept as a manual-rollback safety net) are the only two retained.

@trace spec:host-chromium-on-demand

#### Scenario: Three versions never coexist

- **WHEN** the user has versions `148.0.7778.56` and `149.0.8000.10`
  on disk and runs an installer that pins `150.0.8200.20`
- **THEN** the installer extracts `150.0.8200.20/`, repoints
  `current -> 150.0.8200.20`, and removes `148.0.7778.56/`
- **AND** `149.0.8000.10/` remains as the rollback safety net
- **AND** the on-disk version count is exactly 2

#### Scenario: First-ever install leaves only the new version

- **WHEN** the installer runs on a host with no prior Chromium tree
- **THEN** only the pinned version's directory exists after install
- **AND** no GC pass runs (nothing to remove)

### Requirement: Consent gate is the curl installer; no runtime UI

The Chromium download SHALL run exclusively at install time, inside
the same shell session the user opted into by piping `curl` into
`bash`. The tray binary at runtime SHALL NEVER:

- Show a dialog asking the user to consent to a Chromium install.
- Add a tray menu item that triggers a Chromium install.
- Start a background HTTP download from the tray process when
  Chromium is missing.

When Chromium is missing the tray SHALL log the hard error per the
detection requirement and surface the same message in the
accountability chip; that is the entirety of the runtime UI surface
for this capability.

This requirement enforces the standing rule
`feedback_no_unauthorized_ux`: no new prompts, dialogs, or menu items
are added without explicit user approval, and the user explicitly
authorised the install.sh download (and only that).

@trace spec:host-chromium-on-demand

#### Scenario: No consent dialog on first attach

- **WHEN** the user installed Tillandsias via `curl … | bash` (which
  ran the Chromium download) and clicks Attach Here for the first time
- **THEN** the tray launches the bundled Chromium directly
- **AND** no dialog is shown asking the user to confirm anything
  about Chromium

#### Scenario: No download triggered from tray on missing binary

- **WHEN** the userspace install is missing AND no system Chromium is
  present AND the user clicks Attach Here
- **THEN** the tray emits the hard-error message and aborts the attach
- **AND** the tray process does NOT initiate any HTTP request to
  `storage.googleapis.com` or `googlechromelabs.github.io`

## Sources of Truth

- `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md` — confirms
  the userspace Chromium install belongs in the persistent / data
  category (not cache, not ephemeral) because the running tray cannot
  regenerate it; informs the XDG_DATA_HOME location decision and the
  ephemeral-tmpdir-per-launch decision for `--user-data-dir`.
- `cheatsheets/security/owasp-top-10-2021.md` — A08 Software and Data
  Integrity Failures: justifies the SHA-256 verification step against
  upstream (or in-flight) tampering of the Chromium archive.
- `cheatsheets/web/http.md` — informs the curl semantics in
  `install.sh` (User-Agent, redirect handling against
  `storage.googleapis.com`, and the `Range`-resumable download
  pattern for the ~150 MB archive).
