# Delta: cli-mode (Windows extended-path stripping)

## ADDED Requirements

### Requirement: CLI canonicalize strips Windows extended-path prefix

After `Path::canonicalize()` returns a Windows extended-path-prefixed result (`\\?\C:\...`), the system SHALL strip the `\\?\` prefix before using the path for any operation that may interpret leading `\\` as a UNC URL scheme. UNC paths (`\\?\UNC\server\share`) SHALL be preserved unchanged because they have no shorter equivalent. On non-Windows platforms, this transformation SHALL be the identity.

@trace spec:cli-mode, spec:cross-platform, spec:fix-windows-extended-path

#### Scenario: Relative-path attach on Windows
- **WHEN** the user runs `tillandsias.exe .\my-project --bash` on Windows
- **AND** `canonicalize()` returns `\\?\C:\Users\bullo\src\my-project`
- **THEN** the system SHALL convert this to `C:\Users\bullo\src\my-project` before passing to any git, podman, or downstream operation
- **AND** `git clone --mirror C:\Users\bullo\src\my-project ...` SHALL succeed (where previously it failed with "hostname contains invalid characters")

#### Scenario: UNC path preserved
- **WHEN** a path starts with `\\?\UNC\server\share`
- **THEN** the simplification function SHALL return the input unchanged
- **AND** subsequent operations SHALL handle the UNC path through whatever native mechanism applies

#### Scenario: Already-simple paths pass through
- **WHEN** a path does not start with `\\?\` (e.g., `C:\Users\bullo`)
- **THEN** the simplification function SHALL return the input unchanged

#### Scenario: Local-only and remote-backed projects both work
- **WHEN** the project at the simplified path has a GitHub remote configured
- **THEN** the mirror's origin SHALL be set to the GitHub URL and auto-push hooks SHALL push there on commit
- **WHEN** the project at the simplified path has NO remote configured
- **THEN** the mirror SHALL still be created from the local path
- **AND** the post-receive hook SHALL silently no-op (no push)
- **AND** the forge SHALL clone from the local-only mirror via `git://git-service:9418/<project>` exactly as it would for a remote-backed project — workflow inside the forge is identical
