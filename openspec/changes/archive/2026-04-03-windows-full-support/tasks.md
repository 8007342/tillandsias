# Tasks: Windows Full Support

All tasks completed. Implementation verified on Windows 11 with Podman 5.8.1 WSL2.

## Tasks

- [x] Fix install.ps1 — TLS 1.2, correct NSIS asset name, silent install
- [x] Add Podman CLI detection + winget install to install.ps1
- [x] Add podman machine init + start to install.ps1
- [x] Update uninstall.ps1 for NSIS uninstaller
- [x] Add write_lf() helper to embedded.rs — strip \r from all embedded file writes
- [x] Replace all fs::write calls in write_image_sources() with write_lf()
- [x] Replace all fs::write calls in write_temp_script() with write_lf()
- [x] Add bash dispatch for .sh scripts in runner.rs
- [x] Add bash dispatch for .sh scripts in handlers.rs
- [x] Add bash dispatch for .sh scripts in init.rs
- [x] Fix open_terminal on Windows to detect .sh files and use bash
- [x] Add has_machine() to PodmanClient
- [x] Add init_machine() to PodmanClient
- [x] Add machine init/start to tray app launch (main.rs)
- [x] Add machine init/start to CLI runner (runner.rs)
- [x] Add Windows detection to detect_host_os() in config.rs
- [x] Add menu fingerprinting to skip no-op rebuilds (main.rs)
- [x] Convert i18n STRINGS from LazyLock to RwLock
- [x] Add i18n::reload() for live language switching
- [x] Add I18N_GENERATION counter for menu fingerprint invalidation
- [x] Call i18n::reload() from SelectLanguage event handler
- [x] Create Windows setup cheatsheet
- [x] Create OpenSpec install cheatsheet
- [x] Verify all three CLI modes on Windows (default, --bash, --claude)
- [x] Run full test suite (76 tests pass)
