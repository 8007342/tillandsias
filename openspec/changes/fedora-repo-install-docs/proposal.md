## Why

The README has Fedora COPR instructions using `sudo dnf`, but on Fedora Silverblue (the primary development platform) `dnf` is not available on the host — the immutable base uses `rpm-ostree`. Users on Silverblue need explicit instructions to add the COPR repo and layer the RPM so it auto-updates with system updates.

## What Changes

- Add "Fedora Silverblue" install instructions to README.md under the Linux "Other ways to install" section
- Add Silverblue-specific instructions to `docs/UPDATING.md` under the "Fedora (COPR)" section
- Instructions cover: adding COPR repo file manually, `rpm-ostree install`, reboot, and auto-update behavior

## Capabilities

### New Capabilities
- `silverblue-install-docs`: Fedora Silverblue installation and auto-update instructions in user-facing documentation

### Modified Capabilities

## Impact

- **Modified files**: `README.md`, `docs/UPDATING.md`
- **No code changes** — documentation only
