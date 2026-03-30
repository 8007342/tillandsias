## Bug Inventory

Every string bug found during the audit, with exact file:line references.

### BUG-1: "Building Building Forge..." word doubling (CRITICAL)

**Root cause**: `main.rs:326-328` sends `image_name = "Building Forge"` or `"Building Updated Forge"` as the chip name. Then `menu.rs:552` formats it as `"⏳ Building {image_name}..."`, producing **"⏳ Building Building Forge..."** and **"⏳ Building Building Updated Forge..."**.

**Files**:
- `src-tauri/src/main.rs:325-328` — chip names include the word "Building"
- `src-tauri/src/menu.rs:552` — `build_chip_label()` prepends "Building" again
- `src-tauri/src/event_loop.rs:317-321` — `is_forge_build()` matches on "Building Forge"/"Building Updated Forge"

**Fix**: Change `main.rs` to send just `"Forge"` / `"Updated Forge"` as image names, OR change `build_chip_label()` to not prepend "Building". Also update `is_forge_build()` to match the new names.

### BUG-2: Inconsistent checkmark styles across CLI commands

**Pattern**: Some files use Unicode escape `\u{2713}` (plain check ✓), some use literal `✓`, some use `\u{2705}` (emoji ✅), and the tray menu uses `\u{2705}` for completed builds.

| File | Line | Style | Character |
|------|------|-------|-----------|
| `init.rs` | 20 | `\u{2713}` | ✓ (plain) |
| `init.rs` | 35 | `\u{2713}` | ✓ (plain) |
| `init.rs` | 54 | `\u{2713}` | ✓ (plain) |
| `init.rs` | 71 | literal `✓` | ✓ (plain) |
| `runner.rs` | 318 | `\u{2713}` | ✓ (plain) |
| `menu.rs` | 555 | `\u{2705}` | ✅ (emoji) |
| `install.sh` | 83 | literal `✓` | ✓ (plain) |
| `install.sh` | 116 | literal `✓` | ✓ (plain) |
| `install.sh` | 140 | literal `✓` | ✓ (plain) |
| `install.sh` | 151 | literal `✓` | ✓ (plain) |
| `install.sh` | 166 | literal `✓` | ✓ (plain) |
| `install.sh` | 189 | literal `✓` | ✓ (plain) |
| `uninstall.sh` | 27-62 | literal `✓` | ✓ (plain) |

**Similarly for error marks**:
| File | Line | Style | Character |
|------|------|-------|-----------|
| `init.rs` | 31 | `\u{2717}` | ✗ (plain) |
| `init.rs` | 50 | `\u{2717}` | ✗ (plain) |
| `init.rs` | 78 | literal `✗` | ✗ (plain) |
| `runner.rs` | 320 | `\u{2717}` | ✗ (plain) |
| `menu.rs` | 556 | `\u{274C}` | ❌ (emoji) |

**Fix**: Pick one style per context:
- CLI output: plain `\u{2713}` / `\u{2717}` (consistent, works in all terminals)
- Tray menu: emoji `\u{2705}` / `\u{274C}` (visual, expected in GUI)
- Shell scripts: literal `✓` / `✗` (readable in source)

### BUG-3: entrypoint.sh uses inconsistent "done" prefix

**Files**: `images/default/entrypoint.sh`

| Line | Message | Issue |
|------|---------|-------|
| 62 | `"  done OpenCode $(...)"` | "done" with no checkmark |
| 78 | `"  done Claude Code installed"` | "done" with no checkmark |
| 90 | `"  done OpenSpec installed"` | "done" with no checkmark |
| 110 | `"  done OpenSpec initialized"` | "done" with no checkmark |
| 50 | `"Installing OpenCode..."` | Has no corresponding "done" with checkmark |
| 73 | `"Installing Claude Code..."` | Has no corresponding "done" with checkmark |
| 88 | `"Installing OpenSpec..."` | Has no corresponding "done" with checkmark |

**Fix**: Replace `"  done X installed"` with `"  ✓ X installed"` to match install.sh style.

### BUG-4: Duplicated error message string (15+ copies)

The string `"Tillandsias is setting up. If this persists, please reinstall from https://github.com/8007342/tillandsias"` appears as a hardcoded literal in:

- `src-tauri/src/handlers.rs`: lines 285, 291, 312, 329, 641, 651, 1235, 1243
- `src-tauri/src/runner.rs`: lines 42, 52, 60, 85, 99
- `src-tauri/src/init.rs`: lines 89, 107, 118

That is **16 copies** of the same string. If the GitHub URL changes, all 16 must be updated.

**Fix**: Extract to a constant in a shared `strings.rs` module:
```rust
pub const SETUP_ERROR: &str = "Tillandsias is setting up. If this persists, please reinstall from https://github.com/8007342/tillandsias";
```

### BUG-5: Similar duplication for "Development environment not ready yet" message

The string `"Development environment not ready yet. Tillandsias will set it up automatically — please try again in a few minutes."` appears in:

- `src-tauri/src/handlers.rs`: lines 624, 900, 1064, 1219
- `src-tauri/src/runner.rs`: line 320

**Fix**: Extract to a constant.

### BUG-6: cleanup.rs alignment bug — missing space

`cleanup.rs:189`:
```rust
println!("  Installed binary:{} ({})", bin_path.display(), human_bytes(bin_bytes));
```
There is no space between the colon and the path, unlike every other line in the same output which has aligned spacing (e.g., `"  Nix cache:       ..."`, `"  Cargo cache:     ..."`).

**Fix**: Add a space: `"  Installed binary: {} ({})"` and align with other labels.

### BUG-7: "Tillandsias installation may be incomplete" inconsistent wording

`handlers.rs` lines 1259 and 1281 use `"Tillandsias installation may be incomplete. Please reinstall from ..."` while all other error paths use `"Tillandsias is setting up. If this persists, please reinstall from ..."`. Two different messages for the same error class (script extraction failure).

**Fix**: Use the same standard error message or the shared constant.

### BUG-8: init.rs mixes Unicode escapes and literal characters

`init.rs:20` uses `\u{2713}` but `init.rs:71` uses literal `✓`. Same file, same character, two representations. Similarly, `init.rs:31` uses `\u{2717}` but `init.rs:78` uses literal `✗`.

**Fix**: Pick one representation per file. Unicode escapes are preferred for consistency with `menu.rs` patterns.

### BUG-9: update_cli.rs exposes raw endpoint URL to users

`update_cli.rs:89`:
```rust
println!("  Endpoint: {UPDATE_ENDPOINT}");
```
This displays the full GitHub API URL to end users, which is an internal implementation detail and meaningless to Average Joe.

**Fix**: Remove or gate behind `--debug` flag.

### BUG-10: `human_bytes()` is duplicated in two files

Both `cleanup.rs:48-61` and `update_cli.rs:406-419` contain identical `human_bytes()` functions.

**Fix**: Extract to `tillandsias-core` or a shared utility.

---

## Tasks

### 1. Fix the "Building Building" word-doubling bug

- [ ] 1.1 Change `main.rs:325-328` to use `"Forge"` / `"Updated Forge"` as chip names (remove "Building" prefix)
- [ ] 1.2 Update `event_loop.rs:320-321` `is_forge_build()` to match `"Forge"` / `"Updated Forge"`
- [ ] 1.3 Verify `build_chip_label()` in `menu.rs:548-557` produces correct output: "⏳ Building Forge..." and "⏳ Building Updated Forge..."
- [ ] 1.4 Verify the `Completed` and `Failed` paths also read correctly: "✅ Forge ready", "❌ Forge build failed"

### 2. Extract shared error message constants

- [ ] 2.1 Create `src-tauri/src/strings.rs` with constants for: `SETUP_ERROR`, `ENV_NOT_READY`, `INSTALL_INCOMPLETE`
- [ ] 2.2 Replace all 16 copies of `"Tillandsias is setting up..."` with `strings::SETUP_ERROR`
- [ ] 2.3 Replace all 5 copies of `"Development environment not ready yet..."` with `strings::ENV_NOT_READY`
- [ ] 2.4 Replace 2 copies of `"Tillandsias installation may be incomplete..."` with `strings::INSTALL_INCOMPLETE`
- [ ] 2.5 Add `mod strings;` to `main.rs`

### 3. Normalize checkmark/cross-mark styles

- [ ] 3.1 In `init.rs`: standardize all checkmarks to `\u{2713}` and cross-marks to `\u{2717}` (lines 71, 78)
- [ ] 3.2 Verify `runner.rs`, `cleanup.rs` already use consistent `\u{2713}` / `\u{2717}`
- [ ] 3.3 Keep `menu.rs` using emoji variants `\u{2705}` / `\u{274C}` (tray GUI context)

### 4. Fix entrypoint.sh formatting

- [ ] 4.1 Replace `"  done X installed"` with `"  ✓ X installed"` on lines 62, 78, 90, 110
- [ ] 4.2 Add `"  ✗ X install failed"` for the Claude Code failure case on line 80

### 5. Fix cleanup.rs alignment bug

- [ ] 5.1 Add space after colon on line 189: `"  Installed binary: {} ({})"`
- [ ] 5.2 Align column width with other labels in the same report

### 6. Fix update_cli.rs endpoint leak

- [ ] 6.1 Remove or condition the `"Endpoint: {UPDATE_ENDPOINT}"` println on a debug flag

### 7. Extract duplicate `human_bytes()` utility

- [ ] 7.1 Move `human_bytes()` to `tillandsias-core` or a shared crate utility
- [ ] 7.2 Remove duplicate implementations from `cleanup.rs` and `update_cli.rs`

### 8. Verification

- [ ] 8.1 `cargo build --workspace` compiles with no warnings
- [ ] 8.2 `cargo test --workspace` passes
- [ ] 8.3 Manual test: trigger a build chip and verify label says "Building Forge..." not "Building Building Forge..."
- [ ] 8.4 Manual test: `tillandsias init` shows consistent ✓/✗ characters
- [ ] 8.5 Manual test: `tillandsias --stats` / `tillandsias --clean` output is aligned
