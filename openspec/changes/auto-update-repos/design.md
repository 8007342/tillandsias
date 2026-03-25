## Context

The release workflow already produces .deb and .rpm files. They're uploaded to GitHub Releases but there's no package repository — users must manually download new versions. The Tauri auto-updater only works for AppImage (Linux), .app (macOS), and NSIS (Windows).

## Goals / Non-Goals

**Goals:**
- `dnf copr enable 8007342/tillandsias && dnf install tillandsias` for Fedora users
- `apt update && apt install tillandsias` for Debian/Ubuntu users
- Automatic updates via standard OS package managers
- GPG-signed packages and repo metadata
- Zero manual steps after initial repo setup

**Non-Goals:**
- Building from source in COPR (too complex for Tauri/Rust — download pre-built)
- Homebrew tap (macOS — future)
- Windows package manager (winget/chocolatey — future)

## Decisions

### Decision 1: COPR for RPM

**Choice**: Create a COPR project that uses a "Custom" source method — a script that downloads the latest .rpm from GitHub Releases and imports it. This avoids the nightmare of building Rust from source in COPR.

**User experience**:
```bash
sudo dnf copr enable 8007342/tillandsias
sudo dnf install tillandsias
# Future updates: automatic via dnf-automatic or `dnf update`
```

**Automation**: GitHub webhook triggers COPR rebuild on new release tag.

### Decision 2: GitHub Pages for APT/DEB repo

**Choice**: Use the `gh-pages` branch to host APT repository metadata. The release workflow generates `Packages`, `Release`, and `InRelease` files using `dpkg-scanpackages` and `apt-ftparchive`, signs with a GPG key stored as a GitHub secret, and pushes to `gh-pages`.

**User experience**:
```bash
curl -fsSL https://8007342.github.io/tillandsias/key.gpg | sudo gpg --dearmor -o /usr/share/keyrings/tillandsias.gpg
echo "deb [signed-by=/usr/share/keyrings/tillandsias.gpg] https://8007342.github.io/tillandsias stable main" | sudo tee /etc/apt/sources.list.d/tillandsias.list
sudo apt update && sudo apt install tillandsias
```

**GPG key**: Generate a dedicated repo signing key, store private key as `REPO_GPG_PRIVATE_KEY` GitHub secret, publish public key at `https://8007342.github.io/tillandsias/key.gpg`.

### Decision 3: Install script configures repos

**Choice**: `install.sh` detects the OS and configures the appropriate repo before installing. This means even users who install via `curl | bash` get auto-updates on subsequent runs.

## Risks / Trade-offs

- **[GPG key management]** → Key stored as GitHub Actions secret. Rotation requires updating users' keyrings.
- **[COPR webhook reliability]** → Fallback: manual trigger from GitHub Actions.
- **[GitHub Pages bandwidth]** → 100GB/month free. .deb is ~6MB, each `apt update` downloads ~1KB of metadata. Would need 16M+ update checks/month to exceed. Not a concern.
