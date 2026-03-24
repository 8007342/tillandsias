## ADDED Requirements

### Requirement: GitHub Login delegates to embedded script
The tray GitHub Login handler SHALL use the binary-embedded `gh-auth-login.sh` content, not a filesystem script.

#### Scenario: Script not found on disk
- **WHEN** no `gh-auth-login.sh` exists at any filesystem location
- **THEN** the handler still works by extracting the embedded script to temp

#### Scenario: Tampered script on disk ignored
- **WHEN** a modified `gh-auth-login.sh` exists at `~/.local/share/tillandsias/`
- **THEN** the handler ignores it and uses the embedded version
