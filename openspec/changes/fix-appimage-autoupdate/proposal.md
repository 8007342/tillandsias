## Why

The AppImage auto-update system is completely broken — neither the Tauri built-in updater nor the `--update` CLI flag can find or apply updates. Five root causes identified through release workflow log analysis and code inspection.

## What Changes

1. **Generate `latest.json` in CI** — Switch `createUpdaterArtifacts` from `"v1Compatible"` to `true` so Tauri v2 generates the update manifest per-platform. Generate a merged `latest.json` in the release workflow from per-platform manifests and upload it to the GitHub release.
2. **Collect `.AppImage.tar.gz` updater artifacts** — The `find` command in the build step omits `*.AppImage.tar.gz` and `*.AppImage.tar.gz.sig`. Add them to the collect step and rename to versionless names.
3. **Fix version comparison** — `CARGO_PKG_VERSION` is 3-part (`0.1.65`) but `latest.json` version is 4-part (`0.1.65.38`). The `--update` CLI would always see an update. Normalize comparison to 3-part semver for `--update` CLI.
4. **Enable `rustls-tls` in reqwest** — `reqwest` is declared with `default-features = false` and no TLS feature, so HTTPS requests may fail at runtime.
5. **Remove stale `publish-update-manifest` job** — Replace with a `generate-update-manifest` step inside `sign-and-release` that builds `latest.json` from the collected artifacts and uploads it alongside the release.

## Capabilities

### New Capabilities
(none)

### Modified Capabilities
- `update-system`: Fix all five broken links in the update chain
- `ci-release`: Generate and publish `latest.json` correctly

## Impact

- **Modified files**: `src-tauri/tauri.conf.json`, `src-tauri/src/update_cli.rs`, `src-tauri/Cargo.toml`, `.github/workflows/release.yml`
