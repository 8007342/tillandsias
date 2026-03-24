## ADDED Requirements

### Requirement: Cross-platform build documentation
The project SHALL include documentation at `docs/cross-platform-builds.md` explaining the cross-platform build strategy and legal constraints.

#### Scenario: macOS infeasibility documented
- **WHEN** a developer reads `docs/cross-platform-builds.md`
- **THEN** they find a clear explanation that macOS cross-compilation from Linux is not feasible due to Apple EULA restrictions and Tauri's native framework requirements

#### Scenario: Windows cross-compilation documented
- **WHEN** a developer reads `docs/cross-platform-builds.md`
- **THEN** they find instructions for using `build-windows.sh` with its limitations (unsigned, experimental)

#### Scenario: CI-first strategy documented
- **WHEN** a developer reads `docs/cross-platform-builds.md`
- **THEN** they understand that CI (GitHub Actions) remains the authoritative build pipeline for all platforms, and local cross-compilation is supplementary for troubleshooting
