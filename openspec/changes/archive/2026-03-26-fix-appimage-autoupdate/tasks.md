## 1. Fix tauri.conf.json updater artifacts setting

- [ ] 1.1 Change `createUpdaterArtifacts` from `"v1Compatible"` to `true`

## 2. Fix release workflow artifact collection

- [ ] 2.1 Add `*.AppImage.tar.gz` and `*.AppImage.tar.gz.sig` to the `find` command in collect step
- [ ] 2.2 Rename collected `.AppImage.tar.gz` and `.AppImage.tar.gz.sig` to versionless names
- [ ] 2.3 Replace `publish-update-manifest` job with `latest.json` generation inside `sign-and-release`
- [ ] 2.4 Generate `latest.json` with correct Tauri v2 format including all platform entries
- [ ] 2.5 Upload `latest.json` to the GitHub release alongside other assets

## 3. Fix version comparison in --update CLI

- [ ] 3.1 Normalize version strings to same part count before comparison (truncate 4-part to 3-part when comparing against CARGO_PKG_VERSION)

## 4. Fix reqwest TLS configuration

- [ ] 4.1 Add `rustls-tls` feature to `reqwest` dependency in `src-tauri/Cargo.toml`

## 5. Verify

- [ ] 5.1 Run `./build.sh --check` to confirm compilation
