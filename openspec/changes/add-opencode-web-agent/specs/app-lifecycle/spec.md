## ADDED Requirements

### Requirement: shutdown_all terminates web containers and closes webviews

`shutdown_all()` SHALL, as part of the existing quit sequence, stop every running `tillandsias-<project>-forge` container tracked in `TrayState::running` and close every `WebviewWindow` whose label begins with `web-`.

#### Scenario: No web containers survive app exit
- **WHEN** the user quits Tillandsias while one or more web containers are running
- **THEN** `shutdown_all()` stops each one via the existing launcher stop path
- **AND** no matching container remains in `podman ps` when the process exits
- **AND** all open web `WebviewWindow` instances are closed before the final exit

### Requirement: Orphan web containers are swept on shutdown

The orphan-sweep step of `shutdown_all()` SHALL match containers whose names follow `tillandsias-*-forge` (in addition to existing match patterns), so that web containers left behind by a prior crashed session are cleaned up.

#### Scenario: Crashed previous session leaves a stale web container
- **WHEN** `shutdown_all()` runs and the orphan sweep discovers a `tillandsias-<project>-forge` container not in `TrayState::running`
- **THEN** the sweep stops and removes it with the same logic used for other tillandsias orphans
