## Why

Users who install via .deb or .rpm have no auto-update path — they must manually re-download each release. "Users know how to re-download" is lazy. No user left behind. Package repositories enable `apt upgrade` and `dnf update` to just work.

## What Changes

- **COPR repository for RPM** — Fedora-native `dnf copr enable 8007342/tillandsias`. The COPR project downloads pre-built RPMs from GitHub Releases (no building Rust from source). Webhook triggers rebuild on new release.
- **GitHub Pages APT repository for DEB** — Self-hosted on the `gh-pages` branch. GPG-signed. The release workflow updates repo metadata after each release. Users add the source and get `apt upgrade`.
- **Install script updated** — `install.sh` configures the repo before installing, so future updates come automatically.
- **README updated** — Repo install commands for Fedora and Debian/Ubuntu.

## Capabilities

### New Capabilities
- `package-repos`: APT and RPM repositories with automatic updates from GitHub Releases

### Modified Capabilities
- `ci-release`: Release workflow publishes to GitHub Pages APT repo after signing
- `dev-build`: install.sh configures repos before installing

## Impact

- **New files**: `.github/workflows/publish-repos.yml` (or added to release.yml), COPR .spec file
- **Modified files**: `scripts/install.sh` (add repo config), `README.md` (repo install instructions)
- **New branch**: `gh-pages` for APT repo metadata
- **External**: COPR project at copr.fedorainfracloud.org
