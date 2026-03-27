## Why

The AppImage update system has two misaligned assumptions introduced during the initial auto-updater implementation.

**Issue 1 — wrong artifact URL in `latest.json`**: The release workflow's "Generate latest.json" step points the `linux-x86_64` platform URL to `Tillandsias-linux-x86_64.AppImage.tar.gz`. Tauri v2 on Linux does NOT produce a `.tar.gz` wrapper for the AppImage — it produces the raw `.AppImage` and a detached `.AppImage.sig` signature file. The `.tar.gz` path was copied from macOS convention (which does produce `.app.tar.gz`) and does not match any file that exists in the release.

**Issue 2 — wrong extraction logic in `--update` CLI**: `apply_appimage_update()` in `src-tauri/src/update_cli.rs` unconditionally runs `tar --extract --gzip` on the downloaded file, assuming a `.tar.gz`. When the URL is corrected to point at the raw `.AppImage`, the tar extraction will fail because the download is not a tarball. The function must detect the URL format and, for a `.AppImage` download, skip extraction entirely — the downloaded file IS the new binary.

Together these bugs mean the Linux self-update path is completely broken: `latest.json` references a file that was never uploaded, and even if the URL were corrected by hand, the update CLI would still fail to apply it.

## What Changes

- **Release workflow** (`release.yml`) — Change the `linux-x86_64` platform URL in the "Generate latest.json" step from `.AppImage.tar.gz` to `.AppImage`, and read the signature from `.AppImage.sig` instead of `.AppImage.tar.gz.sig`.
- **Update CLI** (`src-tauri/src/update_cli.rs`) — In `apply_appimage_update()` (and its call site), detect whether the downloaded file is a `.tar.gz` or a raw `.AppImage` and branch accordingly. For a raw AppImage, skip `tar` extraction and treat the downloaded file as the replacement binary directly.
- **Module-level doc comment** (`update_cli.rs`) — Update the `# Update mechanism` section to reflect the corrected Linux flow.

## Capabilities

### New Capabilities
(none)

### Modified Capabilities
- `fix-update-artifacts`: Linux AppImage self-update now uses the correct artifact format (raw `.AppImage`) throughout the full pipeline — manifest generation, download, and in-place replacement.

## Impact

- **Modified files**: `.github/workflows/release.yml`, `src-tauri/src/update_cli.rs`
- **No new files**
- **No user-visible behaviour change** — the update flow looks identical to the user; only the artifact format and extraction logic change
