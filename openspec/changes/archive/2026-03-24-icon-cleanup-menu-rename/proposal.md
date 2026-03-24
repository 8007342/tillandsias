# Proposal: Icon Generation, Menu Cleanup, Security Audit

## Motivation

The tray/app icons were 104-byte solid green squares -- placeholder files that
gave no visual identity. The "Start" menu item was a duplicate of "Attach Here"
(identical handler), adding confusion. "Terminal" is developer jargon that
Average Joe users won't understand. Container security flags needed formal
documentation.

## What Changed

### 1. Tillandsia Icon Generation

Created `scripts/generate-icons.py` that produces a geometric tillandsia
rosette silhouette (8 curved leaves radiating from a central point). Uses
Pillow when available, falls back to raw PNG encoding via struct+zlib.

Generated files:
- `src-tauri/icons/tray-icon.png` (32x32, white on transparent)
- `src-tauri/icons/32x32.png` (32x32, green #4CAF50 on transparent)
- `src-tauri/icons/128x128.png` (128x128, green on transparent)
- `src-tauri/icons/icon.png` (256x256, green on transparent)

### 2. Menu Cleanup

- Removed "Start" menu item from project submenus (was identical to Attach Here)
- Renamed "Terminal" to "🌱 Ground" (plant-themed, user-friendly)
- Removed the `ids::start()` helper function (dead code)
- Kept `MenuCommand::Start` enum variant for backwards compatibility but the
  event loop now logs and ignores it

### 3. Container Security Audit

Verified all three container launch paths (Attach Here, Ground, GitHub Login)
enforce the required isolation flags. Added a security model doc-comment at the
top of `handlers.rs` documenting:
- All five required security flags
- The three permitted volume mount categories
- Explicitly listing what is NOT mounted

## Impact

- Visual: App now has a recognizable plant icon instead of a green square
- UX: Simpler menu (no duplicate action), friendlier terminology
- Security: Documented and verified container isolation model
