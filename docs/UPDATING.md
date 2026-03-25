# Updating Tillandsias

Tillandsias includes a built-in auto-updater that checks for new versions and
applies them securely with minimal user interaction.

## How It Works

1. **Automatic checks**: The app checks for updates in the background shortly
   after launch and every 6 hours while running. These checks never block the
   tray icon or menu.

2. **Notification**: When a new version is found, an "Update available (vX.Y.Z)"
   item appears in the tray menu. A system notification is also sent the first
   time during a session.

3. **User approval**: Click the "Update available" tray menu item to start the
   update. Updates are never installed without your explicit approval.

4. **Graceful restart**: Before restarting, Tillandsias stops all running
   containers cleanly (10-second grace period). After the update installs, the
   app relaunches automatically with the new version.

## Security

Every update bundle is signed with an Ed25519 key during the release build. The
corresponding public key is compiled into your running binary. Before any update
is applied, the signature is verified locally — no network required for
verification.

- **Unsigned updates are rejected** — they cannot be installed.
- **Tampered updates are rejected** — if the content does not match the
  signature, installation is blocked.
- **The public key cannot be changed at runtime** — it is embedded at build
  time.

## Offline Behavior

Tillandsias works fully offline. If a network connection is unavailable:

- Update checks fail silently with no error dialogs.
- The app continues running the current version normally.
- Checks are retried automatically at the next scheduled interval.
- If the network drops mid-download, the download is aborted and the tray menu
  reverts to "Update available" so you can retry later.

## Configuration

You can adjust update behavior in `~/.config/tillandsias/config.toml`:

```toml
[updates]
# How often to check for updates (in hours). Default: 6
check_interval_hours = 6

# Whether to check for updates when the app launches. Default: true
check_on_launch = true
```

## Manual Updates

You can always download the latest release directly from
[GitHub Releases](https://github.com/8007342/tillandsias/releases) and replace
your existing installation.

## Package Manager Updates (Linux)

If you installed via a package repository, updates arrive through your system
package manager — not the built-in updater.

### Fedora (COPR)

```bash
sudo dnf update tillandsias
```

Or enable `dnf-automatic` for fully unattended updates. The COPR repository is
updated automatically when a new release is published on GitHub.

### Fedora Silverblue (COPR)

On Silverblue, the layered RPM updates automatically with system updates:

```bash
rpm-ostree upgrade
systemctl reboot
```

If you have automatic system updates enabled (via `rpm-ostreed-automatic.timer`
or GNOME Software), Tillandsias updates are applied alongside OS updates with
no manual steps. The COPR repo is checked on every `rpm-ostree upgrade`.

### Manual RPM / DEB

If you installed a standalone `.rpm` or `.deb` from GitHub Releases, you must
download the new package manually from the
[releases page](https://github.com/8007342/tillandsias/releases) and reinstall.
Consider switching to the COPR repo for automatic updates.

## AppImage Users (Linux)

The auto-updater replaces the AppImage file in-place. Make sure the AppImage is
stored in a user-writable location (e.g., `~/Applications/` or `~/.local/bin/`).
If the AppImage is in a read-only location like `/opt/`, the update will fail.
Move it to a writable directory and re-launch.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| No update notification | Check network connectivity; updates are checked every 6 hours |
| Update download fails | Retry by clicking the tray menu item again |
| "Update available" disappears | The menu item persists until installed; restart the app to re-check |
| AppImage update fails | Ensure the file is in a writable directory |
