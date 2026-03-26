## Context

Tillandsias is distributed as an AppImage on Linux (especially on immutable OSes like Fedora Silverblue where it is the primary install method). The AppImage runtime sets `$APPIMAGE` to the absolute path of the `.AppImage` file. GNOME's shell and taskbar rely on `.desktop` files and the hicolor icon theme to associate windows with applications — without these, the app shows a generic blue gear icon.

The `install.sh` script already writes `.desktop` and icon files, but AppImage users bypass it entirely. The icons (32x32, 128x128, 256x256) are already compiled into the binary via `include_bytes!` in the SVG icon pipeline, so no new build dependencies are needed.

## Goals / Non-Goals

**Goals:**
- AppImage users see the tillandsia icon in GNOME taskbar and dock on first run
- Integration is idempotent — safe to run on every startup
- Integration is fast — no perceptible delay at startup
- `Exec=` in `.desktop` points to the actual AppImage location so launching from the dock works
- `StartupWMClass=tillandsias-tray` matches the Tauri window class for proper GNOME dock association
- Fix install.sh to also install the 256x256 icon

**Non-Goals:**
- Handling AppImage moves (if user moves the AppImage, the `.desktop` Exec path becomes stale — user reruns to fix)
- Windows or macOS support (AppImage is Linux-only)
- Autostart integration (separate feature)

## Decisions

### D1: Detection via $APPIMAGE Environment Variable

**Choice:** Check `std::env::var("APPIMAGE")` to detect AppImage runtime.

**Why:** The AppImage runtime unconditionally sets this variable to the absolute path of the `.AppImage` file. It is the canonical, documented way to detect AppImage execution. No false positives from other runtimes.

### D2: Staleness Check via .desktop File Content

**Choice:** Write `.desktop` file only if it does not exist or its `Exec=` line does not match the current `$APPIMAGE` path.

**Why:** This handles the case where the user moves the AppImage to a new location — the next run detects the stale `Exec=` path and rewrites. It also avoids unnecessary writes on every startup (reducing disk I/O and log noise).

### D3: Early Synchronous Execution in main()

**Choice:** Call `ensure_desktop_integration()` in main.rs after CLI parsing but before the tray setup, on the main thread.

**Why:** Writing a few small files and running two shell commands takes <100ms. It must complete before the tray appears so the icon is available when GNOME processes the window. Running it async would risk a race condition where the tray appears before the icon is installed.

### D4: Icons via include_bytes!

**Choice:** Embed icon PNGs at compile time using `include_bytes!("../icons/32x32.png")` etc.

**Why:** The icons are already present in `src-tauri/icons/`. Embedding them means no runtime file lookup, no missing-file errors, and the binary is fully self-contained. The total overhead is ~100KB (32+128+256 PNGs).

### D5: Silent Failure

**Choice:** Log warnings but never panic or exit on desktop integration failures.

**Why:** Desktop integration is cosmetic. A missing icon is annoying but the app is fully functional. Crashing because `/usr/bin/gtk-update-icon-cache` is missing would be unacceptable.

## Risks / Trade-offs

**[AppImage moved after integration]** — The `.desktop` file's `Exec=` becomes stale. Mitigation: staleness check on every run rewrites if path changed.

**[update-desktop-database not installed]** — Some minimal systems may not have it. Mitigation: run with `|| true` equivalent, log a warning. GNOME will still pick up the `.desktop` file on next session.

**[Race with GNOME shell]** — The tray window may appear before GNOME processes the new `.desktop` file. Mitigation: the icon cache update is synchronous, and GNOME typically picks up changes within the same session. Worst case: first launch shows gear icon, second launch is correct.
