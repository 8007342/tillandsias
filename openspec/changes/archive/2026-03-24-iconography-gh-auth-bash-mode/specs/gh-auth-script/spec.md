## ADDED Requirements

### Requirement: Standalone GitHub authentication script
The project SHALL provide a `gh-auth-login.sh` script that runs `gh auth login` and git identity setup inside a forge container with full interactive TTY.

#### Scenario: Default invocation
- **WHEN** `./gh-auth-login.sh` is run in a terminal
- **THEN** a forge container starts interactively, prompts for git name and email, runs `gh auth login`, and persists credentials to `~/.cache/tillandsias/secrets/`

#### Scenario: Credentials already configured
- **WHEN** `./gh-auth-login.sh` is run and `~/.cache/tillandsias/secrets/gh/hosts.yml` exists
- **THEN** the script informs the user that credentials exist and offers to re-authenticate

#### Scenario: Forge image not available
- **WHEN** `./gh-auth-login.sh` is run and the forge image is not present
- **THEN** the script offers to build it via `scripts/build-image.sh`

#### Scenario: Help flag
- **WHEN** `./gh-auth-login.sh --help` is run
- **THEN** usage information is displayed

#### Scenario: Status check
- **WHEN** `./gh-auth-login.sh --status` is run
- **THEN** the script reports whether GitHub credentials and git identity are configured

### Requirement: Remove leftover skill
The file `images/default/skills/command/gh-auth-login.md` SHALL be deleted.

#### Scenario: Skill file removed
- **WHEN** the change is applied
- **THEN** `images/default/skills/command/gh-auth-login.md` no longer exists
