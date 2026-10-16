## 1. Specs (this change)

- [x] 1.1 Distil the research into `plan/issues/research/open-it-browser-2026-10-12.md`
- [x] 1.2 ADDED `device-presets` and `browser-window-modes`
- [x] 1.3 MODIFIED `host-browser-mcp`, `local-web-preview`, `chromium-debug-variant`, `inference-engine-slots` (SLOT-6)
- [x] 1.4 File the implementation rows (fragment `20261012t230000z-1656-open-it-browser-macuahuitl.yaml`)

## 2. Already landed or in flight (other rows)

- [x] 2.1 Wayland-only display socket (1641-xbvq)
- [x] 2.2 Containerized `browser.open` admitting the preview port (1649-xqet)
- [x] 2.3 Per-window SNI-bound forwarder (1651-5t7n)
- [ ] 2.4 Device catalogue and resolver, long tail, FE approximation (1643-q3at, 1644-u8b8, 1652-p8xv)
- [ ] 2.5 `browser.open{device}` with CDP emulation and `browser.set_device` (1655-urz9)
- [ ] 2.6 macOS Metal confined helper (1654-6me6)

## 3. Linux

- [ ] 3.1 Development-mode CDP broker: typed tools plus raw `browser.cdp` on the per-lane socket (1656-iktu)
- [ ] 3.2 WebKit engine container for Apple presets (1656-tjv4)
- [ ] 3.3 Engine-neutral development-mode tools across CDP and the Playwright protocol (1656-twhk)
- [ ] 3.4 Framework image fonts and the `--no-sandbox` entrypoint fixture (1656-6c97)

## 4. macOS

- [ ] 4.1 virtio-gpu display on the tray's Linux VM and a `cage` kiosk window sized to the device (1656-cscv)
- [ ] 4.2 Opt-in Safari appliance in a separate macOS guest VM (1656-5rpe)

## 5. Windows

- [ ] 5.1 WSLg browser window (Windows' own row)
- [ ] 5.2 AppContainer-confined NPU inference helper (1656-kbfh, child of 483)
- [ ] 5.3 No host-browser launch anywhere: remove the launch sites, add the guard (1713-3v3f); the toast hand-off lands with 1702-bpnx

## 6. Any host

- [ ] 6.1 Cheatsheet corrections: `--use-angle=d3d11` is Windows-only; virtio-gpu exists for Linux guests on macOS 13+ (1656-mqvk)
- [ ] 6.2 Sync the deltas into `openspec/specs/` and stamp req-ids when the rows land
