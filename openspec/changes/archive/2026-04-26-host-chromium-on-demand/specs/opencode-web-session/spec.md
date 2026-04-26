## MODIFIED Requirements

### Requirement: Native browser launch contract

Every "Attach Here" in web mode SHALL launch the bundled Chromium binary
provided by capability `host-chromium` in app-mode (single-site window,
no tabs, no URL bar) against the forge's URL. The tray SHALL resolve
the Chromium binary via the detection priority defined in
`host-chromium`'s `Detection priority — userspace first, system fallback,
hard error` requirement (userspace install → system PATH fallback →
hard error). The tray SHALL NOT launch Safari, Firefox, or any non-
Chromium-family browser; the previous Safari/Firefox/OsDefault paths
in `src-tauri/src/browser.rs` are tombstoned and removed three releases
after this change ships per the project's `@tombstone` convention.

The launch flags SHALL match the `Per-launch CDP and ephemeral profile
flags` requirement in capability `host-chromium`:
`--app=<url>`, `--user-data-dir=<ephemeral-tmpdir>`, `--incognito`,
`--no-first-run`, `--no-default-browser-check`,
`--remote-debugging-port=<random-loopback-port>`. The CDP port enables
session-cookie injection by capability `opencode-web-session-otp`.

@trace spec:opencode-web-session, spec:host-chromium-on-demand, spec:opencode-web-session-otp

#### Scenario: Bundled Chromium present — used in app-mode

- **WHEN** the user clicks Attach Here on a project AND the userspace
  Chromium install at
  `~/.local/share/tillandsias/chromium/current/chrome-<platform>/chrome`
  exists
- **THEN** the tray spawns that exact binary with
  `--app=http://opencode.<project>.localhost:8080/`,
  `--user-data-dir=<tmpdir>`, `--incognito`, `--no-first-run`,
  `--no-default-browser-check`, and `--remote-debugging-port=<random-port>`
- **AND** a borderless single-site window opens
- **AND** the spawned process is a direct child of the tray (or its
  launch helper), not visible as a tab in any existing browser session

#### Scenario: Userspace install absent — system Chromium fallback

- **WHEN** the userspace install does not exist (e.g., user installed
  via direct AppImage download and has not yet re-run `install.sh`)
  AND `which chromium` resolves to `/usr/bin/chromium`
- **THEN** the tray spawns `/usr/bin/chromium` with the same flag set
- **AND** an info-level accountability log entry records the fallback
  with `category = "browser-detect"`,
  `spec = "host-chromium-on-demand"`, `using = "system-fallback"`

#### Scenario: No Chromium present — hard error, no UI prompt

- **WHEN** neither the userspace install nor any system Chromium-family
  binary is available
- **THEN** the attach fails with the message
  `Chromium not installed. Re-run the installer or run "tillandsias --install-chromium".`
- **AND** no dialog is shown
- **AND** no tray menu item is added
- **AND** no background HTTP download is triggered from the tray

#### Scenario: Safari, Firefox, OsDefault paths are removed

- **WHEN** auditing `src-tauri/src/browser.rs` after the three-release
  tombstone window for this change has elapsed
- **THEN** the `BrowserKind::Safari`, `BrowserKind::Firefox`, and
  `BrowserKind::OsDefault` variants and their launch arms are deleted
- **AND** during the tombstone window each removed branch carries a
  `// @tombstone superseded:host-chromium-on-demand` comment naming
  the release in which it was removed and the release after which it
  is safe to delete

## Sources of Truth

- `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md` — confirms
  the per-launch `--user-data-dir` belongs in the ephemeral category
  (`$XDG_RUNTIME_DIR`), not in the data or cache categories; the
  bundled binary itself is data per the `host-chromium` capability.
- `cheatsheets/web/http.md` — cookie / origin semantics that the
  `--app=<url>` window depends on (loopback secure-context handling,
  Origin / Host header behaviour for the loopback subdomain).
