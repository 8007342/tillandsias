## 1. Release workflow fix

- [ ] 1.1 Change `linux-x86_64` URL in latest.json from `.AppImage.tar.gz` to `.AppImage`
- [ ] 1.2 Change `LINUX_SIG` source from `.AppImage.tar.gz.sig` to `.AppImage.sig`

## 2. Update CLI fix

- [ ] 2.1 Refactor `apply_appimage_update` to accept the download URL and branch on extension
- [ ] 2.2 For `.AppImage` URL: skip tar extraction, use downloaded file directly as replacement binary
- [ ] 2.3 For `.tar.gz` URL: retain existing tar extraction path (macOS / future Linux compat)
- [ ] 2.4 Update module-level doc comment to reflect corrected Linux update flow

## 3. Verification

- [ ] 3.1 `./build.sh --check` passes with no type errors
- [ ] 3.2 `cargo test -p tillandsias` — existing update CLI tests still pass
