## ADDED Requirements

### Requirement: Welcome banner on CLI launch
A brief system status banner SHALL be printed when launching in CLI attach mode from a terminal.

#### Scenario: Banner displayed on interactive launch
- **GIVEN** stdout is a terminal (TTY)
- **WHEN** the user runs `tillandsias <project-path>`
- **THEN** a welcome banner is printed to stdout showing:
  - Application name and 4-part version (e.g., `Tillandsias v0.1.97.76`)
  - Detected OS (e.g., `OS: Fedora Silverblue 43`)
  - Podman version (e.g., `Podman: 5.8.1`)
  - Forge image status (e.g., `Forge: tillandsias-forge:v0.1.97 (ready)`)

#### Scenario: Banner suppressed when not a TTY
- **GIVEN** stdout is not a terminal (piped or redirected)
- **WHEN** the user runs `tillandsias <project-path> | cat`
- **THEN** no welcome banner is printed

#### Scenario: Banner suppressed in tray mode
- **WHEN** the user runs `tillandsias` (no arguments, tray mode)
- **THEN** no welcome banner is printed

#### Scenario: Banner suppressed for subcommands
- **WHEN** the user runs `tillandsias --help`, `tillandsias --stats`, `tillandsias --clean`, `tillandsias --update`, or `tillandsias init`
- **THEN** no welcome banner is printed (these commands have their own output)

#### Scenario: Banner shows podman not found
- **GIVEN** podman is not installed
- **WHEN** the user runs `tillandsias <project-path>`
- **THEN** the banner shows `Podman: not found`
- **AND** the Forge line is omitted

#### Scenario: Banner shows forge not built
- **GIVEN** no forge image exists
- **WHEN** the user runs `tillandsias <project-path>`
- **THEN** the banner shows `Forge: not built (run: tillandsias init)`

### Requirement: Sectioned help output
The `--help` output SHALL be organized into semantic sections.

#### Scenario: Help text has sections
- **WHEN** the user runs `tillandsias --help`
- **THEN** the output contains the following sections in order:
  1. `USAGE:` — how to invoke the binary
  2. `ACCOUNTABILITY:` — `--log-secret-management`, `--log-image-management`, `--log-update-cycle`
  3. `OPTIONS:` — `--log=MODULES`, `--image`, `--debug`, `--bash`
  4. `MAINTENANCE:` — `--stats`, `--clean`, `--update`
  5. `--help` and `--version` at the bottom

#### Scenario: Help text contains no forbidden words
- **WHEN** the user runs `tillandsias --help`
- **THEN** the output does NOT contain the words "container", "pod", "runtime" in the container sense
- **AND** references to container images use "environment" or equivalent user-friendly terms

### Requirement: Version flag
A `--version` flag SHALL print the 4-part version and exit.

#### Scenario: Version output
- **WHEN** the user runs `tillandsias --version`
- **THEN** stdout shows `tillandsias <4-part-version>` (e.g., `tillandsias 0.1.97.76`)
- **AND** the program exits with code 0
- **AND** no other output is printed

### Requirement: No forbidden terminology in user-facing output
All user-facing text (banner, help, error messages) SHALL follow CLAUDE.md terminology conventions.

#### Scenario: User never sees container jargon
- **WHEN** any user-facing text is displayed (banner, help, error)
- **THEN** the words "container", "pod", "image" (in the container sense), and "runtime" do not appear
- **AND** equivalent terms are used: "environment", "project", "forge"

## MODIFIED Requirements

### Requirement: CLI argument parsing (updated)
The CLI parser SHALL handle the new `--version` flag and the future `--log` flags.

#### Scenario: --version returns None
- **WHEN** the user passes `--version`
- **THEN** `cli::parse()` prints the version and returns `None`
- **AND** the caller exits cleanly

#### Scenario: Unknown --log flags are accepted
- **WHEN** the user passes `--log=secrets:debug` (before logging change is implemented)
- **THEN** the flag is parsed and stored in `LogConfig`
- **AND** if the logging framework is not yet wired, the flag is silently ignored
- **AND** no error is produced
