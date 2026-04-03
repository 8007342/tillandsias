# Design: Windows Full Support

## Architecture Decisions

### CRLF Handling — `write_lf()` Helper
All embedded scripts are compiled via `include_str!`. On Windows with `core.autocrlf=true`, these contain `\r\n`. A `write_lf()` helper in `embedded.rs` strips `\r` before writing any file destined for Linux containers. This is a compile-time problem that manifests at runtime — the helper handles it transparently.

### Bash Dispatch Pattern
Windows can't execute `.sh` files via `Command::new(&script)`. All three call sites (runner.rs, handlers.rs, init.rs) use a `cfg!(target_os = "windows")` guard to dispatch through `bash` instead:
```rust
let mut cmd = if cfg!(target_os = "windows") {
    let mut c = Command::new("bash");
    c.arg(&script);
    c
} else {
    Command::new(&script)
};
```

### Podman Machine Lifecycle
Windows and macOS require a Podman machine (Linux VM). The app now handles the full lifecycle:
1. Check if any machine exists (`has_machine()`)
2. If not, `init_machine()` to create one
3. If not running, `start_machine()` to start it
4. `wait_for_ready()` with exponential backoff before proceeding

### Menu Fingerprinting
`rebuild_menu()` computes a hash of all menu-relevant state fields. If the hash matches the previous rebuild, the `set_menu()` call is skipped entirely. This prevents focus-stealing on Windows and AppImage where replacing the tray menu steals window focus.

### Live i18n Reload
`STRINGS` changed from `LazyLock<StringTable>` to `RwLock<Option<StringTable>>`. A `reload(locale)` function replaces the string table and bumps an `I18N_GENERATION` counter. The counter is included in the menu fingerprint so language changes always trigger a menu rebuild.

## Data Flow

```
install.ps1 → Download NSIS → Silent install → Detect Podman → winget install → machine init → machine start
App launch → detect podman → has_machine? → init_machine → start_machine → wait_for_ready → build forge image
CLI attach → detect podman → has_machine? → init_machine → start_machine → build forge → launch container
Language change → save_selected_language → i18n::reload → bump generation → menu fingerprint invalidated → rebuild_menu
```
