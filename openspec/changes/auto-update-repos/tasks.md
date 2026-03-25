## 1. GPG Key Setup

- [x] 1.1 Generate a dedicated GPG key for repo signing (4096-bit RSA, no passphrase for CI)
- [x] 1.2 Store private key as `REPO_GPG_PRIVATE_KEY` GitHub Actions secret
- [x] 1.3 Export public key to `repo/key.gpg` for gh-pages branch

## 2. GitHub Pages APT Repository

- [x] 2.1 Create `gh-pages` branch with initial structure: `deb/pool/`, `deb/dists/stable/main/binary-amd64/`
- [x] 2.2 Add publish-apt-repo job to release workflow: download .deb artifact, generate Packages + Release + InRelease using dpkg-scanpackages + apt-ftparchive + gpg sign
- [x] 2.3 Push updated metadata to gh-pages branch
- [x] 2.4 Publish GPG public key at `https://8007342.github.io/tillandsias/key.gpg`
- [x] 2.5 Test: `apt update` from the repo, verify package listing and GPG signature

## 3. COPR RPM Repository

- [ ] 3.1 Create COPR project at copr.fedorainfracloud.org (8007342/tillandsias)
- [x] 3.2 Write .spec file that downloads pre-built RPM from GitHub Releases (Custom source method)
- [x] 3.3 Configure COPR webhook to trigger on new GitHub release
- [ ] 3.4 Test: `dnf copr enable 8007342/tillandsias && dnf install tillandsias`

## 4. Install Script Update

- [x] 4.1 Update `install.sh` — Fedora: enable COPR repo + dnf install (before AppImage fallback)
- [x] 4.2 Update `install.sh` — Debian/Ubuntu: add GPG key + APT source + apt install (before AppImage fallback)
- [x] 4.3 Upload updated install.sh to current release

## 5. Documentation

- [x] 5.1 Update README.md with repo install instructions for Fedora and Debian/Ubuntu
- [x] 5.2 Add repo setup instructions to docs/ if needed

## 6. Verification

- [ ] 6.1 Test full cycle: push release → APT repo updated → apt upgrade works
- [ ] 6.2 Test full cycle: push release → COPR rebuilt → dnf update works
