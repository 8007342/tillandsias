# terminal-lifecycle — REJECTED

**Reason**: Depended on terminal-in-tauri (Tauri-owned windows) which was rejected due to WebView performance overhead. Focus recovery via Tauri window.set_focus() is no longer available.

**Alternative**: `named-terminals` — custom window titles make terminals findable via Alt+Tab. Don't-relaunch protection via container existence check. Native notification when user tries to relaunch an already-running environment.
