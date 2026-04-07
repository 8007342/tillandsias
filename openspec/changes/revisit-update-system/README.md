# revisit-update-system

Proper revisit of update system. Currently 70% complete with duplication: Tauri plugin updater + custom CLI updater both exist with independent download paths, duplicate signature verification, separate config. Tray menu 'Update available' never wired. APPIMAGE_EXTRACT_AND_RUN not set at runtime. Decide: lean into Tauri plugin or custom CLI, not both. Wire the tray menu. Fix AppImage immutable OS support.
