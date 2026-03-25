## Decisions

### D1: COPR repo file via curl, not dnf copr plugin

On Silverblue, `dnf copr enable` is unavailable on the host. Download the `.repo` file directly from `copr.fedorainfracloud.org` and place it in `/etc/yum.repos.d/`. This is the standard COPR approach for immutable systems.

### D2: rpm-ostree install + reboot

On Silverblue, RPMs are layered via `rpm-ostree install`, which requires a reboot to apply. Document this clearly — users coming from Workstation expect `dnf install` to work immediately.

### D3: Auto-updates via rpm-ostree upgrade

Once the COPR repo is added and the RPM layered, `rpm-ostree upgrade` (or automatic system updates) will pick up new Tillandsias versions from COPR. No built-in updater needed for the RPM path.
