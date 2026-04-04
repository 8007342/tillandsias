## ADDED Requirements

### Requirement: Git accountability window
The system SHALL provide a `--log-git` accountability flag that enables a curated view of git mirror operations. Events SHALL include mirror creation/update, clone/push from forge, and remote push results. No credentials SHALL appear in logs. Each event SHALL include a clickable `@trace spec:git-mirror-service` link.

@trace spec:runtime-logging, spec:git-mirror-service

#### Scenario: Git log flag enables mirror events
- **WHEN** the application is launched with `--log-git`
- **THEN** git mirror events SHALL be visible in the accountability output

#### Scenario: Remote push failure logged prominently
- **WHEN** a post-receive hook fails to push to remote
- **AND** `--log-git` is active
- **THEN** the output SHALL show the failure at WARN level with the error message
