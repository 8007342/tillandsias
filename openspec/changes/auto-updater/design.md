## Context

Tillandsias is a Tauri v2 tray application distributed as platform-native binaries (AppImage, .dmg, .exe) via GitHub Releases. Phase 1 (release-pipeline) automates multi-platform builds with SHA256 checksums. Phase 2 (cosign-signing) adds Cosign keyless signatures for independent verification. Phase 3 closes the loop: the application updates itself silently and securely, so users never run stale versions.

Tauri v2 provides `tauri-plugin-updater`, a built-in updater that integrates with GitHub Releases as an update endpoint. It uses Ed25519 signatures (separate from Cosign) to verify update bundles before installation. The Tauri signing key is generated once and stored as a CI secret; the public key is compiled into the binary. This gives fast, offline-capable signature verification without depending on Sigstore infrastructure at update time.

**Constraints:**
- Tray-only application (no main window) — update notifications must work via tray menu and system notifications
- Update checks must never block the UI or delay app startup
- Signature verification is mandatory — unsigned or incorrectly signed updates MUST be rejected
- Offline users must not experience crashes or degraded behavior
- The user experience must match TILLANDSIAS-RELEASE.md section 12: "Download → Run → Tray appears → Done" with updates being unobtrusive, safe, and fast

## Goals / Non-Goals

**Goals:**
- Silent update check on app launch and at configurable intervals (default every 6 hours)
- Non-intrusive notification when an update is available (tray menu item, optional system notification)
- User-approved installation (one click, no technical prompts)
- Mandatory Ed25519 signature verification before applying any update
- Graceful restart after update (stop managed containers cleanly, then relaunch)
- Resilient offline behavior (no crash, no error dialogs, silent retry on next interval)

**Non-Goals:**
- Delta/incremental updates (full binary replacement only in Phase 3)
- Background download without user awareness (user approves before download)
- Custom update server or CDN (GitHub Releases is the sole endpoint)
- macOS notarization or Windows Authenticode integration (Phase 4)
- Rollback to previous versions (user can manually download from GitHub Releases)
- Auto-update without user consent (user always approves)

## Decisions

### D1: Tauri Built-In Updater Plugin

**Choice:** Use `tauri-plugin-updater` with the GitHub Releases provider.

The plugin handles:
1. Querying GitHub Releases API for the latest version
2. Comparing the remote version against the running version
3. Downloading the platform-appropriate update artifact
4. Verifying the Ed25519 signature against the compiled-in public key
5. Replacing the running binary and triggering a restart

**Why over a custom updater:** Tauri's updater is maintained by the Tauri team, handles platform-specific binary replacement (AppImage self-replacement, macOS .app bundle swap, Windows .exe replacement), and integrates with the Tauri lifecycle. Building a custom updater would duplicate this work and introduce platform-specific bugs.

**Alternatives considered:**
- Custom HTTP polling + binary replacement — significant platform-specific complexity, no signature integration, maintenance burden
- System package managers (apt, brew, winget) — requires package registry submissions, not suitable for early-stage rapid iteration, different UX per platform
- Sparkle (macOS) / WinSparkle (Windows) — platform-specific, no Linux support, no Rust integration

### D2: Ed25519 Signing for Updates (Separate from Cosign)

**Choice:** Use Tauri's Ed25519 signing key for update bundles. Cosign signatures remain available for independent manual verification but are not used by the updater.

**Why two signature schemes:** Cosign keyless mode requires Sigstore infrastructure (Fulcio, Rekor) at verification time. The auto-updater runs on user machines that may be offline or behind restrictive firewalls. Ed25519 verification is purely local — the public key is compiled into the binary, and verification requires no network access. Cosign covers the "trust the source" use case (transparency, identity); Ed25519 covers the "trust the update" use case (fast, offline, automated).

**Key management:**
- One-time generation: `tauri signer generate -w ~/.tauri/tillandsias.key`
- Private key stored as `TAURI_SIGNING_PRIVATE_KEY` GitHub Actions secret
- Password stored as `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` GitHub Actions secret
- Public key embedded in `tauri.conf.json` under `plugins.updater.pubkey`

### D3: GitHub Releases as Update Endpoint

**Choice:** Configure the updater to use `https://github.com/<owner>/tillandsias/releases/latest/download/latest.json` as the update endpoint.

The Tauri GitHub Releases provider generates a `latest.json` manifest during the build that contains:
- Version number
- Platform-specific download URLs
- Ed25519 signatures for each artifact
- Release notes

**Why GitHub Releases over a custom endpoint:** Zero infrastructure cost, automatic CDN via GitHub, version metadata is already there from Phase 1, and the Tauri plugin has native GitHub integration.

### D4: Update Check Timing

**Choice:** Check for updates on app launch (after a 5-second delay to avoid blocking startup) and every 6 hours while running. The interval is configurable via `~/.config/tillandsias/config.toml`.

```toml
[updates]
check_interval_hours = 6
check_on_launch = true
```

**Why not check immediately on launch:** The tray app should appear instantly. A 5-second delay ensures the tray icon and menu are responsive before any network activity. The update check runs as a background tokio task and never blocks the main event loop.

**Why 6 hours:** Balances freshness against unnecessary network requests. Users who leave the app running all day will get at most 4 checks per day. Users who restart frequently get one check per launch.

### D5: Update Notification UX

**Choice:** Two-tier notification:
1. A tray menu item appears: "Update available (v0.2.0)" — always visible until dismissed or installed
2. An optional system notification (platform toast) on first detection — respects system notification settings

The user clicks the tray menu item to approve and start the update. A progress indicator appears in the menu during download. After installation, the app restarts automatically.

**Why tray menu over a dialog window:** Tillandsias is a tray-only application with `windows: []`. Opening a dialog window breaks the tray-only paradigm and requires additional Tauri window configuration. A tray menu item is consistent with the existing UX and non-intrusive.

### D6: Graceful Restart After Update

**Choice:** Before restarting, the app follows the same shutdown sequence as a user-initiated quit: stop all managed containers gracefully (SIGTERM → 10s grace → SIGKILL), flush state, then relaunch.

**Why not just restart:** Running containers would be orphaned if the app restarts without cleanup. The graceful shutdown sequence from the app-lifecycle spec ensures no orphaned containers and consistent state on relaunch.

## Risks / Trade-offs

**[Ed25519 key compromise]** If the `TAURI_SIGNING_PRIVATE_KEY` secret is compromised, an attacker could sign malicious update bundles. Mitigation: GitHub Actions secrets are encrypted at rest and only exposed during workflow runs. Key rotation requires publishing a new version signed with the old key that embeds the new public key — a standard key rotation pattern.

**[GitHub Releases availability]** If GitHub is down, update checks fail silently. The app continues running the current version. Mitigation: GitHub has high availability; the retry-on-next-interval approach means transient outages are invisible to users.

**[Large update downloads]** Full binary replacement means every update downloads the entire binary (50-100MB depending on platform). Mitigation: acceptable for Phase 3; delta updates can be explored in future phases if bandwidth becomes a concern.

**[Restart disrupts running containers]** The graceful shutdown stops all containers before restarting. Users with long-running work sessions may find this disruptive. Mitigation: the user explicitly approves the update, so they choose when to restart. The tray menu shows which containers are running.

**[Version skipping]** If a user skips several versions, the updater always downloads the latest. There is no sequential upgrade path. Mitigation: Tillandsias is a single binary with no database migrations. Any version can replace any other version.

## Open Questions

- **Should the update check interval be shorter for pre-1.0 releases?** Rapid iteration during early development may warrant more frequent checks (e.g., every hour). Could use a build-time flag to set different defaults for pre-release vs stable.
- **Should there be a "Check for updates now" manual menu item?** Low cost to add, gives power users control. Likely yes, but not blocking for Phase 3 MVP.
- **Tauri updater behavior on AppImage:** AppImage self-update replaces the file in-place. Need to verify this works correctly when the AppImage is launched from a read-only location (e.g., `/opt`). May need to document that the AppImage should be in a user-writable location.
