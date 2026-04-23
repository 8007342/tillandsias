## ADDED Requirements

### Requirement: CLI modes are tray-aware

`tillandsias --debug` and `tillandsias <path>` SHALL spawn the tray icon in addition to their CLI behaviour when `desktop_env::has_graphical_session()` returns `true`. Other CLI subcommands (`--init`, `--update`, `--clean`, `--stats`, `--uninstall`, `--version`, `--help`, `--github-login`) SHALL retain their current single-purpose behaviour with no tray spawn.

#### Scenario: Debug mode spawns tray
- **WHEN** the user runs `tillandsias --debug` in a graphical session
- **THEN** the tray icon appears
- **AND** logs continue to print to the terminal

#### Scenario: Path attach spawns tray and runs foreground
- **WHEN** the user runs `tillandsias /some/path` in a graphical session
- **THEN** the tray icon appears
- **AND** the OpenCode TUI runs in the terminal foreground
- **AND** when the user exits OpenCode, the parent process returns control to the shell with status 0
- **AND** the tray remains running

#### Scenario: Init / update / version do NOT spawn tray
- **WHEN** the user runs `tillandsias --init`, `--update`, `--version`, or any other one-shot CLI subcommand
- **THEN** no tray child is spawned
- **AND** the command exits as it does today

### Requirement: SIGINT triggers clean shutdown on every CLI path

Every CLI path that may have started enclave infrastructure SHALL install a SIGINT handler that, on first Ctrl+C, calls `handlers::shutdown_all()`, prints a brief "stopping…" message, and exits with status 0. A second SIGINT during shutdown SHALL fall through to default termination so the user can always force-quit.

#### Scenario: Ctrl+C during foreground attach
- **WHEN** the user hits Ctrl+C while `tillandsias /path` is in the foreground OpenCode TUI
- **THEN** SIGINT is caught
- **AND** `shutdown_all()` runs to stop proxy, git-service, inference, and any tracked forge containers
- **AND** the process exits with status 0

#### Scenario: Ctrl+C during --debug
- **WHEN** the user hits Ctrl+C while `tillandsias --debug` is streaming logs
- **THEN** SIGINT is caught
- **AND** the process exits with status 0
- **AND** the tray child (if spawned) continues to run independently

#### Scenario: Second Ctrl+C forces exit
- **WHEN** the user hits Ctrl+C twice within a few seconds
- **THEN** the second SIGINT is not handled by the cleanup path
- **AND** the process terminates immediately via the default signal action
