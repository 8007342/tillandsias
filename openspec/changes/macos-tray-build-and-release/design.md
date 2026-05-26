## Context

`tillandsias-macos-tray` builds today as a regular Rust binary — `cargo build -p tillandsias-macos-tray` produces a `target/.../tillandsias-tray` executable. macOS users cannot install that as a normal app: they want a `.app` bundle in `/Applications/`, ideally launchable from Spotlight and Login Items, and they want it to add the menubar icon as a hidden system tray application (LSUIElement). The bundle needs an `Info.plist` (with `LSUIElement=true`, version metadata, bundle identifier), an `.entitlements` file (because `Virtualization.framework` access requires `com.apple.security.virtualization`), and a code signature (because macOS 14+ Gatekeeper refuses unsigned binaries on first launch).

The Linux release flow (`scripts/install.sh`, `.github/workflows/release.yml`) is the model: `curl -fsSL <url> | bash` lands a binary in `~/.local/bin/tillandsias`. The macOS equivalent lands `Tillandsias.app` in `/Applications/`. This change implements that flow, intentionally narrow in scope (just packaging + signing + CI + install), reusing the existing release machinery where possible.

## Goals / Non-Goals

**Goals:**
- Reproducible `Tillandsias.app` artifact built by a single shell script.
- Working `curl install-macos.sh | bash` flow on Apple Silicon macOS 14+.
- CI builds the macOS artifact on every push to `linux-next` to catch regressions.
- Release workflow uploads the macOS artifact alongside the existing Linux and Windows artifacts.
- Ad-hoc signing is sufficient for v0.0.1 (free, no Apple Developer account needed).
- Mirror the Linux release pattern (Cosign bundle, SHA256SUMS, install script).

**Non-Goals:**
- Developer ID signing or notarization — v0.0.2 (separate change).
- Intel Mac support — Apple Silicon only for v0.0.1.
- DMG packaging — `.tar.gz` only.
- Auto-update mechanism inside the app — user re-runs install-macos.sh.
- macOS App Store distribution — never (would require sandboxing incompatible with `com.apple.security.virtualization`).
- Multiple-arch fat binaries — `aarch64-apple-darwin` only.

## Decisions

### D1: Ad-hoc codesigning for v0.0.1 (right-click-Open Gatekeeper UX)

`codesign --force --sign - --entitlements <file> Tillandsias.app`. Free, no Apple Developer account, the `Virtualization.framework` entitlement works the same as with Developer ID for runtime checks. The trade-off: macOS Gatekeeper shows "Tillandsias is from an unidentified developer" on first launch; users right-click → Open to bypass.

**Why over alternatives:**
- Developer ID ($99/yr, plus cert management in CI) — meaningful UX improvement (Gatekeeper allows on first launch) but adds release-engineering complexity and recurring cost the alpha audience doesn't justify.
- Notarized ($99/yr + per-release `notarytool submit`) — best UX but adds ~10 min wall-clock per release.

The install script must explicitly print the Gatekeeper workaround so users aren't confused.

### D2: `.tar.gz` distribution, not `.dmg`

Plain gzipped tarball containing `Tillandsias.app/`. `install-macos.sh` extracts to `/Applications/`. The Linux flow ships a bare binary; the macOS .tar.gz is the smallest analog that holds a `.app` directory.

**Why over alternatives:**
- `.dmg` — requires `hdiutil` build step, more polished UI for manual users, but adds ~30 lines to the build script and ~5 MB to the artifact size. Not worth it when the curl-install flow extracts straight to `/Applications/`.
- `.pkg` (productbuild) — needs an installer GUI, requires `pkgbuild` + `productbuild`, makes uninstall harder. Way over-engineered for v0.0.1.

### D3: `cargo build --target aarch64-apple-darwin` against the host toolchain

Build natively on Apple Silicon CI (`macos-latest` on GitHub Actions is Apple Silicon since 2024-Q4). No cross-compilation, no fat binaries.

**Why:** simplest possible build pipeline. Intel Mac support is a separate, larger change (would require either fat binaries via `lipo` or two-artifact builds + auto-arch-detect in the installer).

### D4: Info.plist template substitution by `sed`

`crates/tillandsias-macos-tray/assets/Info.plist.template` already exists with `@VERSION@`, `@VERSION_SHORT@`, `@MIN_MACOS@` placeholders. `scripts/build-macos-tray.sh` reads the VERSION file via `scripts/bump-version.sh` and substitutes via `sed`. The build-time-templated `Info.plist` is the only `Info.plist` shipped.

**Why over alternatives:**
- A Rust build-script that emits Info.plist — overkill; templating is one `sed` per placeholder.
- Hardcoded Info.plist — version drift between binary and bundle metadata; rejected.

### D5: CI runs `macos-build` on every push to `linux-next`, not just PRs

Per repo precedent (`ci.yml` builds Linux on every push). Catches regressions in shared `tillandsias-vm-layer`, `tillandsias-control-wire`, or `tillandsias-host-shell` code that compile on Linux but break the macOS gate.

**Cost:** ~$0.40–$0.80 per push. The owner is the only consumer; acceptable burn while v0.0.1 is in active development. Can switch to PR-only after v0.0.1 ships.

### D6: Release artifact name = `tillandsias-tray-<full-version>-macos-arm64.tar.gz`

Matches the Linux convention `tillandsias-linux-x86_64` (no version in name, but versioned via release tag). The macOS name includes the version explicitly because the `.tar.gz` filename is what shows up in download lists — clearer for users to see which version they're grabbing.

Release-asset list also includes `install-macos.sh` (script, not versioned in filename) and `tillandsias-tray-<version>-macos-arm64.tar.gz.cosign.bundle`.

### D7: Cosign signing matches the Linux flow

Use the existing Cosign keyless OIDC step from `release.yml` (already in use for Linux). Produces a `.cosign.bundle` per artifact. Verifiable with `cosign verify-blob --bundle <bundle> <artifact>`. No new infrastructure needed.

## Risks / Trade-offs

- **[R1] Apple Silicon-only excludes Intel Mac users.** → Documented in install-macos.sh's arch-gate; the gate prints "Intel Macs are not supported in v0.0.1 — see GitHub issue #X for status." (X to be filed.) Intel support is a separate post-v0.0.1 change if demand materializes.
- **[R2] Ad-hoc signing UX hiccup on first launch.** → install-macos.sh ends with a clear "If Gatekeeper blocks: right-click Tillandsias in /Applications/ and choose Open" message. Acceptable for alpha.
- **[R3] `runs-on: macos-latest` minutes are expensive.** → Build job is gated to `linux-next` push + PR; release job only on `workflow_dispatch`. Owner is the only PR contributor today. Monthly burn estimate: ~$5–10. Bearable.
- **[R4] `objc2-virtualization` version drift between dev host and CI.** → Cargo.toml pins the patch version under `[target.'cfg(target_os = "macos")']`. `Cargo.lock` is committed to the repo.
- **[R5] CI hosts may have an older Xcode CLT that lacks the codesign flags we use.** → `actions/setup-xcode` step pins a Xcode version. Document the minimum (Xcode 15+).
- **[R6] No notarization means malware-detection delays on first launch (Gatekeeper does a hash lookup against Apple's notarization service even for unsigned apps).** → Documented; acceptable for alpha (~5 s extra on first launch).

## Migration Plan

1. Land `scripts/build-macos-tray.sh` + `Tillandsias.entitlements` + `install-macos.sh` on `linux-next`. No CI changes yet; manually validate on a dev host.
2. Add the `macos-build` CI job. Verify green on a test PR.
3. Add the `macos-release` job + extend the release artifact list. Verify on a no-op test tag.
4. Tag the first v0.0.1 release after Phases 1–5 of the implementation plan complete.

Rollback: revert the workflow edits; keep the scripts in-tree (no harm, can be invoked manually).

## Open Questions

- **Should `install-macos.sh` install to `/Applications/` (system-wide, requires sudo) or `~/Applications/` (per-user, no sudo)?** *Default:* prefer `/Applications/`, fall back to `~/Applications/` if not writable without sudo. Document the fallback.
- **Should the install script optionally add the app to Login Items by default, or only on `--login-item` flag?** *Default:* opt-in via `--login-item` flag; the user explicitly chooses to have the tray start on boot.
- **App icon source.** Today there's no `.icns` icon. v0.0.1 ships with a placeholder "T" character — acceptable. A real icon is post-v0.0.1 art work.
- **Cosign verification step in `install-macos.sh`** — should the install script verify the Cosign bundle, or trust the SHA256SUMS check? *Default:* SHA256SUMS only for v0.0.1; cosign verify is opt-in via `--verify-cosign` flag. Avoids forcing users to install cosign.
