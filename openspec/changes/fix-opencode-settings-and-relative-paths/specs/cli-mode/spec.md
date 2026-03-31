## Delta: AppImage-aware path resolution

### Requirement: Relative paths resolve against user's working directory
When running as an AppImage, relative path arguments SHALL resolve against `$OWD` (the user's original working directory), not the AppImage FUSE mount CWD.

#### Scenario: Dot path in AppImage context
- **GIVEN** the binary is running as an AppImage with `$OWD` set
- **WHEN** the user runs `tillandsias .`
- **THEN** `.` resolves to the directory in `$OWD`, not the AppImage mount point

#### Scenario: Relative path in AppImage context
- **GIVEN** the binary is running as an AppImage with `$OWD` set
- **WHEN** the user runs `tillandsias ../other-project`
- **THEN** the path resolves relative to `$OWD`

#### Scenario: Absolute path unaffected
- **GIVEN** any execution context
- **WHEN** the user runs `tillandsias /home/user/src/project`
- **THEN** the path is used as-is (canonicalized normally)

#### Scenario: Non-AppImage context
- **GIVEN** `$OWD` is not set
- **WHEN** the user runs `tillandsias .`
- **THEN** `.` resolves via standard `canonicalize()` against CWD (existing behavior)
