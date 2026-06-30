# Build/install smoke E2E findings - 2026-06-18

Status: pass

Full destructive Windows build/install/reset/provision smoke passed on the
integrated `windows-next` head (synced with `linux-next`).

## Evidence

- log_dir: `target/build-install-smoke-e2e/20260618T001325Z`
- build/install: `scripts/install-windows.ps1` passed (exit 2 accepted for first install)
- installed binary: `tillandsias-tray 0.3.260618.1 (d36f9ba1)`
- substrate reset: `wsl --unregister tillandsias` completed and cache was cleared
- cold provision: `tillandsias-tray --provision-once` completed with `RESULT: VM Ready — control wire up ✓`
- diagnose check: `tillandsias-tray --diagnose --json` reports `VM Ready` in logs and `distro_registered: true`

## Notes

- First full E2E of 2026-06-18 on Windows 11 hardware.
- The `windows-next` branch was fast-forwarded to `linux-next` (`d36f9ba1`) before testing.
- The `hvsocket` connection correctly reports failure when the VM is not running (post-provision idle), which is expected.
- All core Windows tray and WSL provisioning components are operational.
