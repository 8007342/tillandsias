## Tasks

- [ ] 1. In `README.md`, after the "Fedora (COPR)" block (line ~33), add a "Fedora Silverblue (COPR — auto-updates)" section with:
  - `sudo curl` to download the COPR `.repo` file to `/etc/yum.repos.d/`
  - `rpm-ostree install tillandsias`
  - Note: reboot required to apply
- [ ] 2. In `docs/UPDATING.md`, after the "Fedora (COPR)" section (line ~77), add a "Fedora Silverblue" subsection explaining:
  - `rpm-ostree upgrade` picks up new COPR versions
  - System auto-updates (if enabled) handle this automatically
  - Reboot applies the update
- [ ] 3. Verify markdown renders correctly on GitHub (no broken HTML in details/summary blocks)
