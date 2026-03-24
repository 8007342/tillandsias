## Context

GitHub renders README.md as the project landing page. Currently that page is dense with architecture details. Users who just want to try Tillandsias must scroll past diagrams and tables to find install instructions.

## Goals / Non-Goals

**Goals:**
- Make "install and run" the first thing a visitor sees
- Provide a one-liner install for Linux, macOS, and Windows
- Provide a clean uninstall path (binary-only and full wipe)
- Preserve all existing documentation without loss

**Non-Goals:**
- Rewriting the architecture docs (they move intact to README-ABOUT.md)
- Building the actual release artifacts (that is the CI pipeline's job)
- Windows installer script (placeholder `install.ps1` reference only)

## Decisions

### D1: Separate landing page from reference docs

README.md becomes a landing page. README-ABOUT.md holds everything that was there before. The landing page links to it under "Learn More."

### D2: curl | bash installer

Standard pattern for CLI tools. The script detects OS/arch, downloads the correct binary from GitHub Releases, and installs to `~/.local/bin`. It also installs the uninstall script as `tillandsias-uninstall`.

### D3: Uninstall with --wipe flag

Plain `tillandsias-uninstall` removes the binary and lib/data directories. `--wipe` additionally removes caches, container images, and the builder toolbox. This gives users a clean exit without surprise data retention.
