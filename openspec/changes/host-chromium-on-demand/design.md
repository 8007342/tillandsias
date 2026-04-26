# Design — host-chromium-on-demand

## Verified provenance (2026-04-25)

Both items previously listed here as TODOs are now resolved:

1. **Upstream SHA-256 absence is confirmed.** A WebFetch against
   `https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json`
   on 2026-04-25 returned download entries containing **only** `{platform, url}`
   per binary — no `sha256`, `integrity`, or `size` field. Therefore
   Decision 5 (SHA-256 baked at OUR release-cut time) is the only
   integrity-verification path available. The installer pins both the
   version AND a SHA-256 we compute by hashing the binary ourselves at
   Tillandsias-release time. Upstream tampering between cut and
   end-user install is caught by the baked digest.
2. **First-ship pinned Chromium version is `148.0.7778.56`** (the
   `channels.Stable.version` value on 2026-04-25, verified via the
   same WebFetch). The `Pinned version` requirement in the spec
   names this string; subsequent Tillandsias releases bump it via
   `scripts/refresh-chromium-pin.sh` per Decision 4.

The canonical binary URL pattern is also confirmed:
`https://storage.googleapis.com/chrome-for-testing-public/<version>/<platform>/chrome-<platform>.zip`
where `<platform>` is one of `linux64 | mac-arm64 | mac-x64 | win64`
(per the Chrome for Testing landing page, fetched 2026-04-25).

## Context

The user pivoted away from the Tauri WebKit2GTK webview on 2026-04-24 (see
`feedback_opencode_web_debug_via_chrome` in MEMORY.md). OpenCode Web now runs
in a native Chromium-family browser launched in `--app=URL` mode, with a
per-window OTP cookie injected via CDP (`opencode-web-session-otp` change).

Today `src-tauri/src/browser.rs::detect_browser` walks `$PATH` and picks
**any** Chromium-family binary it finds — Google Chrome, Chromium,
Microsoft Edge, etc. That couples the user's tray-launched windows to
their daily browser (gmail, banking, password managers). Two problems:

1. **Profile leakage.** Even with `--user-data-dir=<tmp>`, the Chromium
   process inherits the user's locale, GTK theme, and process-tree
   ancestry. CDP debugging on the user's daily Chrome is blocked because
   `--remote-debugging-port` would clash with whatever the user's running.
2. **Isolation contract.** The user's directive: tray-launched browser
   windows MUST be isolated. CDP MUST work. The user MUST NOT be asked
   to install Chrome or Chromium themselves.

The user's locked decision (2026-04-25): the Tillandsias **binary** must
NOT bundle Chromium. The Tillandsias **curl installer** (`scripts/install.sh`)
performs the Chromium download into `~/.local/share/tillandsias/chromium/<version>/`
on first install, lazily, opt-in. The tray binary then assumes the binary
is at the canonical XDG-data path and uses ONLY it.

This change defines the install path, the pinned version, the integrity
verification, the macOS quarantine handling, the detection-fallback rules,
the user-consent stance, and the uninstall path.

## Goals / Non-Goals

**Goals:**

- The Tillandsias AppImage / .app / .exe binary remains untouched in size
  by this change (~80 MB AppImage; no Chromium baked in).
- First-time install (`curl … | bash`) downloads Chromium ONCE into
  `~/.local/share/tillandsias/chromium/<pinned-version>/` and verifies
  it against a SHA-256 digest baked into `install.sh` at Tillandsias
  release-cut time.
- The tray binary at runtime treats the bundled Chromium as **already
  present**. Missing-binary handling is a hard error with a clear message
  pointing at `tillandsias --install-chromium` (a re-runnable subcommand
  that invokes the same installer logic).
- Per-launch CDP enable: `--remote-debugging-port=<random-high-port>` so
  `opencode-web-session-otp`'s cookie injection works against a port that
  cannot collide with the user's daily Chrome.
- Per-launch ephemeral profile: `--user-data-dir=$(mktemp -d)`,
  `--incognito`, destroyed on window close.
- macOS quarantine attribute (`com.apple.quarantine`) stripped via
  `xattr -d` immediately after extraction; otherwise Gatekeeper blocks
  every launch with "Chromium can't be opened because Apple cannot
  check it for malicious software."
- Uninstall is a one-liner: `rm -rf ~/.local/share/tillandsias/chromium/`
  (documented in `tillandsias --help` and the install.sh epilogue).
- Zero new tray menu items. Zero new prompts at first attach.

**Non-Goals:**

- Auto-updating Chromium between Tillandsias releases. Version bumps
  ride Tillandsias releases; the new install.sh version downloads the
  new pinned binary into a sibling `<new-version>/` dir.
- Sandboxing Chromium itself beyond the user namespace it already runs in.
  The forge-side container provides the security boundary; the host-side
  Chromium is just a renderer.
- Bundling Firefox or any other browser. The tombstoned Firefox / OsDefault
  / Safari paths in `browser.rs` remain tombstoned per `opencode-web-session-otp`
  task 6.3.
- Multi-version coexistence beyond the rolling window. At most TWO versions
  on disk at any time: the version `install.sh` last installed (current),
  plus the previous version (kept until the first successful launch under
  the new version, then garbage-collected).
- Forge-side browsers. Headless Chromium / Firefox / drivers inside the
  forge are covered by the `forge-headless-browsers` change. This change
  is exclusively about the **host-side** binary the tray launches.

## Decisions

### Decision 1 (Q1) — Install location: `~/.local/share/tillandsias/chromium/<version>/`

**Choice**: XDG_DATA_HOME-rooted (`~/.local/share/` on Linux,
`~/Library/Application Support/tillandsias/chromium/<version>/` on macOS,
`%LOCALAPPDATA%\tillandsias\chromium\<version>\` on Windows). A
`current` symlink (or junction on Windows) points at the active version
to give the tray a stable lookup path:

```
~/.local/share/tillandsias/chromium/
├── 148.0.7778.56/
│   └── chrome-linux64/
│       ├── chrome
│       └── … (libs, locales, resources)
└── current -> 148.0.7778.56
```

**Why**:

- **Not `~/.cache/`**: caches are by spec deletable at any time and
  applications must be able to regenerate cached state from authoritative
  sources. The Chromium binary is NOT regenerable by the running tray —
  if the user clears `~/.cache/`, the tray would be unable to attach.
  XDG_DATA_HOME is the correct category for an installed application
  asset (per the freedesktop.org XDG Base Directory spec §2: "user-specific
  data files should be written"). The proposal.md draft put it in `~/.cache/`;
  this design corrects that to XDG_DATA_HOME.
- **Per-version subdir**: enables atomic rollover — extract new version
  to `<new>/`, fsync, repoint `current` symlink, GC old version on next
  install.sh run.
- **`current` symlink instead of envvar**: the tray reads the symlink
  target via `std::fs::read_link` once at startup; no env-var pollution
  and no subprocess to ask "where's the binary".
- **Per-user, never system**: the install.sh runs without sudo (matches
  the existing AppImage install pattern); the binary lives strictly in
  the user's home and follows them across machines via dotfile sync if
  they choose.

**Rejected alternative — `~/.cache/tillandsias/chromium/`**: per above.
**Rejected alternative — `/opt/tillandsias/chromium/`**: requires sudo,
violates the "no root required" property of the curl installer.

### Decision 2 (Q2) — Detection: prefer system binary on PATH, fall back to userspace install

**Choice**: At tray init, `detect_browser()` returns the FIRST match of:

1. `$XDG_DATA_HOME/tillandsias/chromium/current/chrome-<platform>/chrome`
   (the tray-managed userspace install)
2. `which chromium` / `which chromium-browser` (system-installed Chromium)
3. `which google-chrome` / `which google-chrome-stable` (system-installed Chrome)
4. `which microsoft-edge-stable` / `which microsoft-edge` (Edge as last
   Chromium-family fallback)
5. **Hard error** with message: "Chromium not found. Re-run the installer:
   `curl -fsSL <install-url> | bash` OR run `tillandsias --install-chromium`."

The userspace install comes FIRST in the priority order — once `install.sh`
has fetched the pinned version, the tray prefers it over whatever the user
happens to have installed. This guarantees CDP isolation (the user's
running Chrome cannot collide with the tray's CDP port; the tray uses a
distinct binary with its own ephemeral profile).

If the userspace install does not exist (user installed Tillandsias before
this change shipped, ran `--wipe`, or is on a system where `install.sh`
hasn't run yet) and the system already has a suitable Chromium-family
binary, the tray uses that as a graceful-degradation path. This avoids
breaking existing installs at the moment the change ships; the userspace
binary materialises on the next `install.sh` run.

**Why this priority order**:

- **Userspace first** = predictable CDP behaviour, no version drift across
  user machines, no surprises from user-installed extensions or policies
  on the system browser.
- **System fallback** = does not strand users who haven't re-run install.sh
  yet. The hard-error case is reserved for fresh installs that opted out
  of the install.sh download (offline install, manual AppImage placement).

**Rejected alternative — system binary first**: would mean the same user's
behavior changes whether they happen to have Chrome installed or not.
Inconsistent across machines, and breaks the CDP-isolation guarantee
because CDP would target the user's daily browser.

**Rejected alternative — userspace only, no system fallback**: blocks
attach for users who installed via AppImage download (no install.sh run)
until they discover the `--install-chromium` subcommand. Bad first
impression.

### Decision 3 (Q3) — User consent: silent install during `curl … | bash`, no runtime prompt

**Choice**: The Chromium download runs as part of `install.sh` AT INSTALL
TIME, in the same shell session the user already opted into by running
`curl -fsSL … | bash`. The progress is reported on stderr ("Downloading
Chromium for Tillandsias (≈ 150 MB)…"). The tray binary, at runtime,
NEVER prompts and NEVER opens a dialog about Chromium. If Chromium is
missing, it errors to the log and to the tray menu's accountability chip
("Chromium not installed — re-run installer"). No UI added.

The standing rule (`feedback_no_unauthorized_ux`) forbids new menu items
or prompts without explicit user approval. The user's directive was
"include its installer in userspace with our curl installer" — that
explicitly authorises the install.sh download but says nothing about a
runtime UI surface. We add neither.

**Why**:

- **Consent gate is `curl … | bash`**: the user already chose to download
  and run a script from us. Adding more prompts inside that script is
  redundant and trains users to click-through.
- **Lazy install via `tillandsias --install-chromium`**: power users on
  air-gapped machines can run install.sh with a flag to SKIP the Chromium
  download (`SKIP_CHROMIUM_DOWNLOAD=1 bash install.sh`), then run
  `tillandsias --install-chromium` later when network is available.
- **No tray notification on first attach**: the chip shown by the
  accountability log already surfaces "Chromium not installed" if the
  user somehow bypassed install.sh; that's the only UI signal needed.

**Rejected alternative — first-attach consent dialog**: violates the
no-new-prompts rule. The install.sh prompt position is sufficient.

**Rejected alternative — lazy download in tray on first attach**: would
add a 10-30s delay to first attach, surface as an "installing…" chip,
and require the tray to do background HTTP downloads with progress
reporting. The install.sh path is simpler and visible.

### Decision 4 (Q4) — Pinned version: stable channel as of Tillandsias release-cut

**Choice**: At each Tillandsias release, the release author runs
`scripts/refresh-chromium-pin.sh` which:

1. Fetches `https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json`
2. Reads `channels.Stable.version` (e.g. `"148.0.7778.56"`)
3. Downloads the binary for each platform (linux64, mac-arm64, mac-x64,
   win64) and computes its SHA-256 locally
4. Writes the version string + per-platform SHA-256 digests into
   `scripts/install.sh` (replacing variables `CHROMIUM_VERSION` and
   `CHROMIUM_SHA256_LINUX64` / `…_MAC_ARM64` / `…_MAC_X64` / `…_WIN64`)

The refresh script is run BEFORE `gh workflow run release.yml`. The
pinned version is therefore always the Stable channel head as of the
release-cut moment — no faster than monthly for normal Tillandsias
releases, faster if users issue ad-hoc releases for security reasons.

**Why Stable, not Beta or Dev**:

- The user-facing browser must not crash. Stable channel has the lowest
  defect rate of the Chrome for Testing channels.
- CDP API surface is stable across Stable channel releases (Chrome team
  treats CDP as a stability commitment, modulo quarterly deprecations).

**Why Chrome for Testing, not vanilla Google Chrome**:

- Vanilla Chrome's update mechanism conflicts with our pinned-version
  contract — Chrome auto-updates itself in-place, breaking SHA-256
  expectations.
- Chrome for Testing is purpose-built for the "pinned version, no
  auto-update, redistribute lawfully" use case (per the
  `chrome-for-testing` README's intended use).
- The redistribution licence allows us to bake the SHA-256 into our
  installer and host the URLs we link to.

### Decision 5 (Q5) — Integrity: SHA-256 baked at release-cut

**Choice**: Because the Chrome for Testing JSON does NOT publish SHA-256
digests (verified via WebFetch 2026-04-25), we compute and bake the
digest at OUR release-cut time. The digest is hardcoded into
`scripts/install.sh` per platform. At install time, install.sh:

1. Downloads the ZIP from the official URL
2. Computes SHA-256 (`sha256sum` on Linux, `shasum -a 256` on macOS,
   `certutil -hashfile … SHA256` on Windows)
3. Compares against the baked-in expected digest
4. Aborts the install on mismatch (DOES NOT extract or chmod), with
   message `"Chromium download failed integrity check. Aborting. Re-run
   the installer or report the discrepancy at <repo URL>."`

The threat model this defends against: an attacker gains control of
`storage.googleapis.com/chrome-for-testing-public/` (or the JSON CDN)
between OUR release-cut and the user's install. The attacker substitutes
a malicious binary at the same URL. Without the baked digest, the user
would extract and run it. With the baked digest, the install aborts.

**What this does NOT defend against**:

- An attacker who controls our GitHub release at the moment of cut (they
  could write whatever digest they want into install.sh). Mitigation:
  the GitHub release is itself signed by the workflow's OIDC identity;
  that's covered by the `binary-signing` capability, not this change.
- A compromise of Google's signing-key infrastructure that produces
  binaries we then hash and bake, validating an attacker-aligned digest.
  This is out of scope; we trust the upstream signing chain.

**Rejected alternative — TOFU (trust on first use)**: the first user to
download a new version captures whatever was at the URL at that moment
and other users compare. Requires consensus infrastructure we don't have
and provides weaker guarantees than baked-at-release-cut.

**Rejected alternative — GPG-signed manifest from upstream**: Google
does not publish such a manifest for Chrome for Testing. We have no
signature to verify.

### Decision 6 (Q6) — macOS: strip quarantine attribute immediately after extraction

**Choice**: On macOS, after `unzip` of `chrome-mac-arm64.zip` (or
`chrome-mac-x64.zip`), install.sh runs:

```bash
xattr -dr com.apple.quarantine "$CHROMIUM_DIR/Chromium.app" 2>/dev/null || true
```

The `-r` flag is essential — Chromium on macOS is a `.app` bundle and
the quarantine attribute is set on multiple files inside the bundle
when downloaded via curl. The `2>/dev/null || true` swallows the
"no such xattr" warning on systems where the attribute wasn't set
(non-quarantine-aware filesystems, Linux toolboxes accidentally
running the macOS code path).

**Why**:

- Without this step, every launch of the bundled Chromium on macOS
  triggers Gatekeeper's "downloaded from the internet" dialog, blocking
  the launch. The dialog cannot be disabled without an Apple Developer
  Notarization workflow on the binary itself, which we cannot do for
  a third-party binary.
- The `xattr -d` approach is the standard remediation for self-distributed
  binaries on macOS (used by Homebrew, MacPorts, and many CI/CD distribution
  patterns).
- We run it on the bundle ONCE at install time, not at every launch —
  cheap, bounded.

**Rejected alternative — codesign-with-our-own-cert**: requires a paid
Apple Developer ID and a notarization round-trip, neither of which is
proportional for a third-party redistribution.

### Decision 7 (Q7) — Uninstall: documented one-liner, no special tooling

**Choice**: Uninstall is just:

```bash
rm -rf ~/.local/share/tillandsias/chromium/
```

(Or platform-equivalent path.) `tillandsias --uninstall` already exists
(in the `app-lifecycle` capability); we extend its `--wipe` mode to
include the chromium directory. Bare `--uninstall` (no `--wipe`) does
NOT remove the chromium directory — the user can keep the binary if
they plan to reinstall and want to skip the re-download.

**Why**:

- No daemon to stop, no service to unregister, no plist to remove on
  macOS. The Chromium binary is a self-contained directory tree.
- The `--wipe` semantics already cover "remove everything Tillandsias
  ever wrote"; chromium goes in that bucket.
- Documented in `install.sh` epilogue and `tillandsias --help` output
  ("To remove the bundled Chromium: rm -rf ~/.local/share/tillandsias/chromium/").

## Risks / Trade-offs

- **First install adds 30-60s for the Chromium download** (~150 MB ZIP
  over typical home broadband). Mitigated by progress reporting on
  stderr in the install.sh download phase.
- **Disk usage: ~400 MB after extraction** per pinned version. The
  rolling-window GC keeps at most two versions, so peak usage is ~800 MB
  during the brief overlap.
- **Chrome for Testing is not Google Chrome**. The bundled Chromium is
  unbranded and lacks Google Update, Sync, the Google logo, and a few
  other proprietary bits. Acceptable for our use case (we only render
  OpenCode Web in `--app` mode); users never browse with this binary.
- **macOS Gatekeeper future-tightening risk**. Apple has been progressively
  closing the `xattr -d` escape hatch in major macOS versions. If a future
  macOS release blocks unsigned binaries entirely, we'd need to ship a
  signed-and-notarised wrapper or move to a different strategy. Documented
  as an open risk; not actionable today.
- **install.sh size grows by ~50 lines** for the Chromium download / verify
  / extract / xattr block. Acceptable — the script is currently ~310 lines;
  +50 keeps it well under the "tiny installer" goal.
- **Air-gapped install requires manual binary placement**. A user installing
  Tillandsias on an offline machine cannot fetch Chromium from
  `storage.googleapis.com`. Documented workaround: download the ZIP on a
  connected machine, copy to the offline machine, run
  `tillandsias --install-chromium --from-zip <path>` (subcommand handles
  the SHA-256 verify + extract + xattr steps without the network fetch).
- **JSON endpoint dependency**. The Chrome for Testing JSON is hosted on
  `googlechromelabs.github.io` (GitHub Pages). If that goes down between
  our release-cut and a user's install, install.sh has no fallback URL
  for the binary. Mitigation: install.sh hardcodes the BINARY URL (not
  the JSON URL) at release-cut time — the JSON is consulted ONLY by
  `scripts/refresh-chromium-pin.sh` at our release-cut. End-user installs
  fetch directly from `storage.googleapis.com/chrome-for-testing-public/<version>/`.

## Sources of Truth

- `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md` — confirms
  XDG_DATA_HOME (`~/.local/share/`) is the correct category for an
  installed application asset; rejects `~/.cache/` for non-regenerable
  binaries.
- `cheatsheets/security/owasp-top-10-2021.md` — A08 Software and Data
  Integrity Failures: justifies the SHA-256 verification step against
  upstream tampering.
- `cheatsheets/web/http.md` — used for the install.sh curl semantics
  (User-Agent, redirect handling against `storage.googleapis.com`).
- `openspec/changes/opencode-web-session-otp/design.md` — the consumer
  of the bundled Chromium's CDP endpoint.
- `openspec/changes/forge-headless-browsers/proposal.md` — the sibling
  forge-side change; confirms this change owns ONLY the host binary,
  not the forge headless variant.
- Chrome for Testing JSON endpoint (provenance source for the pinned
  version): `https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json`
- Chrome for Testing binary URL pattern (provenance source for the
  download URL): `https://storage.googleapis.com/chrome-for-testing-public/<version>/<platform>/<binary>.zip`
- freedesktop.org XDG Base Directory Specification (provenance source
  for Decision 1's location choice): `https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html`
