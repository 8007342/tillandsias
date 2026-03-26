## Why

On Fedora Silverblue (and other immutable/ostree systems like Kinoite and uBlue), the install script currently silently falls through to AppImage only when piped from curl — because `HAS_SUDO=false` gates the entire RPM section. This is the right outcome, but it happens for the wrong reason. If a user ever runs the script interactively on Silverblue with sudo available, the script would attempt COPR → `dnf` (which doesn't exist on the immutable host) → `rpm-ostree install` — which requires a reboot, pollutes the layered package state, and disables Tauri's built-in auto-updater.

AppImage is actually the **better** install method on immutable OS because:
- No reboot required (rpm-ostree layering needs a reboot to apply)
- Tauri's built-in auto-updater works end-to-end
- Zero impact on `rpm-ostree upgrade` performance (no layered packages)
- Works immediately after install, from any invocation context (piped curl or interactive)

The fix is early, explicit detection of immutable OS before any `HAS_SUDO` gating, with a clear user-facing message explaining why the package manager path is skipped.

## What Changes

- **`scripts/install.sh`** — Add immutable OS detection block (checks `/run/ostree-booted` and `rpm-ostree` command presence) immediately after architecture detection. If immutable OS is detected, set `IS_IMMUTABLE=true` and skip directly to the AppImage userspace install path, bypassing all package manager logic.

## Capabilities

### New Capabilities
- `immutable-os-detection`: The installer detects ostree/immutable OS and routes to AppImage unconditionally, regardless of sudo availability or invocation context.

### Modified Capabilities
- `linux-install`: On immutable OS, the install path no longer attempts COPR, dnf, or rpm-ostree. It goes straight to AppImage with a clear user message.

## Impact

- **Modified files**: `scripts/install.sh`
- **No new dependencies** — detection uses only `/run/ostree-booted` (standard ostree marker) and `command -v rpm-ostree`
- **No behavior change on mutable systems** — the existing deb/rpm/AppImage fallback chain is untouched
