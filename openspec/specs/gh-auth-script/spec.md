# gh-auth-script Specification

## Purpose
TBD - created by archiving change iconography-gh-auth-bash-mode. Update Purpose after archive.
## Requirements
### Requirement: GitHub Login runs in git service container
When the user triggers "GitHub Login", the system SHALL run `gh auth login` inside the git service container (which has D-Bus for host keyring access). If no git service is running, a temporary one SHALL be started. The standalone forge-based auth flow SHALL be removed.

@trace spec:gh-auth-script, spec:git-mirror-service, spec:forge-offline

#### Scenario: GitHub Login with running git service
- **WHEN** the user clicks "GitHub Login" in the tray
- **AND** a git service container is running
- **THEN** the system SHALL exec `gh auth login` inside the running git service container
- **AND** credentials SHALL be stored in the host keyring via D-Bus

#### Scenario: GitHub Login without running git service
- **WHEN** the user clicks "GitHub Login"
- **AND** no git service container is running
- **THEN** the system SHALL start a temporary git service container with D-Bus
- **AND** run `gh auth login` inside it
- **AND** stop the temporary container after auth completes

#### Scenario: Credential refresh while agents work
- **WHEN** agents are working in forge containers
- **AND** a git push fails due to expired credentials
- **AND** the user clicks "GitHub Login"
- **THEN** the credential refresh SHALL happen in the git service container
- **AND** subsequent pushes from forge containers SHALL succeed
- **AND** no forge containers need to be restarted

### Requirement: Remove leftover skill
The file `images/default/skills/command/gh-auth-login.md` SHALL be deleted.

#### Scenario: Skill file removed
- **WHEN** the change is applied
- **THEN** `images/default/skills/command/gh-auth-login.md` no longer exists

