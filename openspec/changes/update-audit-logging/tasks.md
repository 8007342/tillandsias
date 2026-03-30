## 1. Shared Log Module

- [x] 1.1 Create `src-tauri/src/update_log.rs` with `log_path() -> PathBuf` returning `cache_dir().join("update.log")`
- [x] 1.2 Implement `append_entry(line: &str)` — creates parent dirs if absent, opens file in append mode, writes `[<rfc3339>] <line>\n`
- [x] 1.3 Implement `rotate_if_needed()` — if `update.log` exceeds 1 MB, read all lines, keep last 100, rewrite file, append a `[<rfc3339>] LOG ROTATED (kept last 100 entries)` header line
- [x] 1.4 Implement `read_last_entry() -> Option<String>` — reads the last non-empty line from `update.log`, returns `None` if file absent
- [x] 1.5 Add `sha2` and `hex` to `src-tauri/Cargo.toml` dependencies for SHA256 computation
- [x] 1.6 Implement `sha256_file(path: &Path) -> Result<String, String>` — read file bytes, compute SHA256, return lowercase hex string

## 2. update_cli.rs Logging

- [x] 2.1 On successful manifest fetch where version is already current: append `UPDATE CHECK: v<current> — already up to date`
- [x] 2.2 On update available: append `UPDATE CHECK: v<current> → v<latest> available`
- [x] 2.3 On manifest fetch error: append `ERROR: failed to fetch update manifest: <msg>`
- [x] 2.4 On download complete: append `DOWNLOAD: <human_bytes> from <url>`
- [x] 2.5 On download error: append `ERROR: download failed: <msg>`
- [x] 2.6 On apply success: append `APPLIED: v<old> → v<new> (replaced <path>) SHA256: <hex>`
- [x] 2.7 On apply error: append `ERROR: failed to apply update: <msg>`
- [x] 2.8 Call `rotate_if_needed()` once at the start of `run()` (before any new entries are written) if `update.log` already exists

## 3. updater.rs Logging

- [x] 3.1 In `check_for_update()`: when `updater.check()` returns `Ok(Some(update))` for a new version not yet seen this session, append `UPDATE CHECK: v<current> → v<new_version> available (background)`
- [x] 3.2 In `install_update()`: after `download_and_install` succeeds, append `APPLIED: background updater installed v<new_version>` (no SHA256 here — Tauri manages the binary replacement)
- [x] 3.3 In `install_update()`: on `download_and_install` error, append `ERROR: background update install failed: <msg>`

## 4. cleanup.rs --stats

- [x] 4.1 After the "Installed binary" block in `run_stats()`, read `update_log::read_last_entry()` and print `  Last update:      <entry>` or `  Last update:      (no update log)` if absent

## 5. Verification

- [ ] 5.1 Manual test: run `tillandsias --update` on an up-to-date install, verify `update.log` contains an "already up to date" entry
- [ ] 5.2 Manual test: run `tillandsias --stats`, verify "Last update" line appears
- [ ] 5.3 Manual test: force rotation by writing a >1 MB `update.log` (many lines), run `--update`, verify file is truncated to ~100 lines plus the rotation marker
- [ ] 5.4 Run `./build.sh --check` to confirm the build type-checks cleanly
