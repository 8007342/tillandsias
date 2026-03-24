## MODIFIED Requirements

### Requirement: Tag-triggered release workflow
The release pipeline SHALL be triggered by git tag pushes matching the `v*` pattern OR by manual `workflow_dispatch` with a version input. No other event SHALL trigger release builds.

#### Scenario: Version tag pushed
- **WHEN** a tag matching `v*` (e.g., `v0.1.0`, `v1.0.0-rc.1`) is pushed to the repository
- **THEN** the release workflow starts and builds artifacts for all configured platform targets

#### Scenario: Manual dispatch with version
- **WHEN** a `workflow_dispatch` is triggered with a `version` input (e.g., `0.0.25.21`)
- **THEN** the release workflow starts using the provided version for tag validation

#### Scenario: Manual dispatch without version
- **WHEN** a `workflow_dispatch` is triggered without a `version` input
- **THEN** the workflow fails early with a clear error message asking for the version input

#### Scenario: Non-version tag pushed
- **WHEN** a tag not matching `v*` (e.g., `test-123`, `release-candidate`) is pushed
- **THEN** the release workflow does not trigger

#### Scenario: Regular commit pushed
- **WHEN** a commit is pushed to any branch (including `main`)
- **THEN** the release workflow does not trigger

### Requirement: Version consistency validation
The pipeline SHALL verify that the resolved version (from tag or workflow_dispatch input) matches the version declared in the VERSION file.

#### Scenario: Version match from tag
- **WHEN** the tag is `v0.0.25.21` and VERSION file contains `0.0.25.21`
- **THEN** the build proceeds normally

#### Scenario: Version match from workflow_dispatch
- **WHEN** the workflow_dispatch `version` input is `0.0.25.21` and VERSION file contains `0.0.25.21`
- **THEN** the build proceeds normally

#### Scenario: Version mismatch
- **WHEN** the resolved version does not match the VERSION file
- **THEN** the workflow fails early with a clear error message indicating both values

## ADDED Requirements

### Requirement: Node.js 24 runtime for GitHub Actions
Both CI and release workflows SHALL opt into Node.js 24 for GitHub Actions runners using `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24=true`.

#### Scenario: CI workflow uses Node.js 24
- **WHEN** the CI workflow runs
- **THEN** the `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24` environment variable is set to `true` at the workflow level

#### Scenario: Release workflow uses Node.js 24
- **WHEN** the release workflow runs
- **THEN** the `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24` environment variable is set to `true` at the workflow level

#### Scenario: Node setup version
- **WHEN** `actions/setup-node@v4` is used in the release workflow
- **THEN** `node-version` is set to `24`
