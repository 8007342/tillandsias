## ADDED Requirements

### Requirement: Project mounted at correct hierarchy
The project directory SHALL be mounted at `/home/forge/src/<project-name>/` preserving the source hierarchy.

#### Scenario: OpenCode shows correct path
- **WHEN** OpenCode starts in the container
- **THEN** the status bar shows `src/<project-name>:main` (not just `src:main`)
