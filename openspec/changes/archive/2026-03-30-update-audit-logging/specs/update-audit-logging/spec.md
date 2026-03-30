## ADDED Requirements

### Requirement: Persistent update audit log
The application SHALL maintain a persistent, human-readable audit log of all update events at `~/.cache/tillandsias/update.log` (platform-aware via `cache_dir()`).

#### Scenario: Log file created on first event
- **WHEN** an update event (check, download, apply, or error) occurs and `update.log` does not yet exist
- **THEN** the file and any missing parent directories are created automatically with the first log entry appended

#### Scenario: Log file is append-only
- **WHEN** subsequent update events occur
- **THEN** new entries are appended to `update.log` without truncating or modifying existing entries

#### Scenario: Log entries use RFC 3339 timestamps
- **WHEN** any entry is written to `update.log`
- **THEN** the entry is prefixed with an RFC 3339 UTC timestamp in the form `[YYYY-MM-DDTHH:MM:SSZ]`

### Requirement: update_cli.rs logs all update flow events
The `--update` command SHALL log each significant step to `update.log` before printing to stdout.

#### Scenario: Up-to-date check logged
- **WHEN** `--update` is run and the current version is already the latest
- **THEN** an entry `UPDATE CHECK: v<current> — already up to date` is appended to `update.log`

#### Scenario: Available update logged
- **WHEN** `--update` is run and a newer version is found
- **THEN** an entry `UPDATE CHECK: v<current> → v<latest> available` is appended to `update.log`

#### Scenario: Download logged
- **WHEN** the update archive is downloaded successfully
- **THEN** an entry `DOWNLOAD: <size> from <url>` is appended, where `<size>` uses the same human-readable format as `human_bytes()`

#### Scenario: Apply logged with SHA256
- **WHEN** the new binary is applied (atomic replace of AppImage)
- **THEN** an entry `APPLIED: v<old> → v<new> (replaced <path>) SHA256: <hex>` is appended, where `<hex>` is the lowercase hex-encoded SHA256 of the replacement binary after it is written to disk

#### Scenario: Errors logged
- **WHEN** any step fails (manifest fetch, parse, download, apply)
- **THEN** an entry `ERROR: <description>` is appended to `update.log` before the function returns false

### Requirement: Background auto-updater logs detection and install
The background Tauri updater (`updater.rs`) SHALL log update detections and install outcomes to the same `update.log` file.

#### Scenario: Background update detection logged
- **WHEN** `check_for_update()` detects a new version not previously seen in this session
- **THEN** an entry `UPDATE CHECK: v<current> → v<new_version> available (background)` is appended to `update.log`

#### Scenario: Background install success logged
- **WHEN** `install_update()` completes `download_and_install()` without error
- **THEN** an entry `APPLIED: background updater installed v<new_version>` is appended to `update.log`

#### Scenario: Background install failure logged
- **WHEN** `install_update()` receives an error from `download_and_install()`
- **THEN** an entry `ERROR: background update install failed: <msg>` is appended to `update.log`

### Requirement: --stats shows last update entry
The `--stats` command SHALL display the most recent line from `update.log` so users can confirm update history at a glance.

#### Scenario: Last update shown when log exists
- **WHEN** `--stats` is run and `update.log` contains at least one entry
- **THEN** the output includes `  Last update:      <last line from update.log>`

#### Scenario: Last update absent when log missing
- **WHEN** `--stats` is run and `update.log` does not exist (or is empty)
- **THEN** the output includes `  Last update:      (no update log)`

### Requirement: Log rotation keeps file bounded
The update log SHALL be bounded to prevent unbounded growth on long-running installs.

#### Scenario: Rotation triggered at 1 MB
- **WHEN** an update event is about to be logged and `update.log` is larger than 1 MB (1,048,576 bytes)
- **THEN** the file is rewritten retaining only the last 100 lines, followed by a rotation marker entry `LOG ROTATED (kept last 100 entries)`, before the new event entry is appended

#### Scenario: File under threshold is not rotated
- **WHEN** `update.log` is smaller than 1 MB
- **THEN** rotation does not occur and the file is only appended to
