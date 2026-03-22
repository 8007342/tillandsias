## MODIFIED Requirements

### Requirement: Project detection heuristics
The scanner SHALL detect all non-empty, non-hidden directories under the watch path as projects, regardless of whether they contain recognized manifest files.

#### Scenario: Directory with no manifest
- **WHEN** a non-empty directory exists in ~/src with no Cargo.toml, package.json, etc
- **THEN** it is detected as an Unknown-type project eligible for "Attach Here"

#### Scenario: Empty directory
- **WHEN** an empty directory exists in ~/src
- **THEN** it is still detected as a project (the user created it for a reason)
