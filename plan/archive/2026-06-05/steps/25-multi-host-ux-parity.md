# Step 25 — Multi-Host UX Parity & Menu Stabilization

Status: ready
Owner: multi-host
Depends on: [rootfs-removal-fedora-pivot]

## Goal
Ensure that the Windows and macOS tray applications provide a 1:1 consistent experience with the Linux reference, resolving UX regressions and completing the "Native Tray" parity contract.

## Tasks
- [ ] **macOS Menu Structure Alignment**: Resolve gap-2 by ensuring the NSMenu items and hierarchy match the `host_shell::MenuStructure` exactly.
- [ ] **macOS Icon & Assets**: Verify the fix for gap-1 (Status item "T") and ensure the Tillandsias icon is correctly rendered as a template image.
- [ ] **Windows EnumerateLocalProjects**: (Optional) Wire the in-VM project enumeration into the Windows tray menu as a fallback or complement to the host-side scan.
- [ ] **UX Gap Sweep**: Finalize any remaining items from `macos-tray-ux-gaps-2026-05-29.md` and equivalent Windows findings.
- [ ] **Status Text Parity**: Verify that "🔵 Downloading...", "🟢 Ready", etc., work identically across all platforms after the Fedora pivot.

## Exit Criteria
- Windows and macOS trays pass the user-attended smoke test (m8/w12).
- Tray menus across all 3 platforms are structurally identical (excluding platform-specific items like "Open Shell").
- No "T" icons or "Failed to fetch" errors on clean installs.
