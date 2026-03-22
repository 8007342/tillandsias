## 1. Fix TrayIcon Lifecycle

- [x] 1.1 Store TrayIcon handle in OnceLock static so it persists for app lifetime
- [x] 1.2 Pass TrayIcon handle to on_state_change callback for menu rebuilds

## 2. Fix Menu Event Dispatch

- [x] 2.1 Ensure menu event handler callback fires on every click
- [x] 2.2 Add Quit fast-path: call process::exit(0) directly from menu handler
- [x] 2.3 Verify other menu items dispatch through channel to event loop

## 3. Fix Dynamic Menu Rebuild

- [x] 3.1 In on_state_change callback, rebuild menu from current state and call tray.set_menu()
- [x] 3.2 Verify menu updates when scanner discovers projects (10 projects detected in debug log)

## 4. Fix Project Detection

- [x] 4.1 Scanner already detects all non-hidden directories (was working, menu rebuild was broken)
- [x] 4.2 All 10 directories in ~/src appear in the menu

## 5. Build and Test

- [x] 5.1 Build, install, and verify: projects show, quit works, menu updates
