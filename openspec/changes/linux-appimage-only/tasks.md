## 1. Simplify install.sh Linux path

- [ ] 1.1 Remove PKG_TYPE detection (dpkg/rpm check)
- [ ] 1.2 Remove HAS_SUDO check (not needed for AppImage-only)
- [ ] 1.3 Remove entire APT repository section (deb install + fallback)
- [ ] 1.4 Remove entire COPR/dnf/rpm-ostree section (rpm install + fallback)
- [ ] 1.5 Make AppImage the direct Linux path (not a fallback)

## 2. Simplify release workflow

- [ ] 2.1 Remove deb/rpm from artifact collection find patterns
- [ ] 2.2 Remove the entire "Publish APT repository" job
- [ ] 2.3 Remove deb/rpm artifact renaming logic

## 3. Update build.sh

- [ ] 3.1 Change `BUNDLES="deb,rpm"` to `BUNDLES="none"` for Linux release builds

## 4. Update tauri.conf.json

- [ ] 4.1 Remove `linux.deb` and `linux.rpm` configuration sections from bundle config

## 5. Update docs/UPDATING.md

- [ ] 5.1 Remove "Fedora (COPR)" section
- [ ] 5.2 Remove "Fedora Silverblue (COPR)" section
- [ ] 5.3 Remove "Manual RPM / DEB" section

## 6. Remove packaging directory

- [ ] 6.1 Delete `packaging/tillandsias.spec`
- [ ] 6.2 Delete `packaging/copr-custom-script.sh`
- [ ] 6.3 Delete `packaging/COPR-SETUP.md`

## 7. Verify

- [ ] 7.1 Run `./build.sh --check` — zero errors
