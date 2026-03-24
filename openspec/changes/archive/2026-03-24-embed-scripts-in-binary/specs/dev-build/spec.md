## MODIFIED Requirements

### Requirement: Install to local path
The `--install` flag SHALL build a release binary and copy it to `~/.local/bin/` with only non-executable supporting files.

#### Scenario: Install binary
- **WHEN** `./build.sh --install` is run
- **THEN** the binary and runtime libraries are installed to `~/.local/bin/` and `~/.local/lib/tillandsias/`
- **AND** icons are installed for the desktop launcher
- **AND** no shell scripts, flake files, or image sources are copied to `~/.local/share/tillandsias/`
