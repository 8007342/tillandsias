## NEW Requirements

### Requirement: Skill deployment pipeline
OpenCode skills SHALL be bundled into the container image at build time and deployed to the workspace at runtime.

#### Scenario: Skills copied into image
- **WHEN** the forge image is built via `nix build .#forge-image`
- **THEN** the `images/default/skills/` directory is copied to `/usr/local/share/tillandsias/opencode/` inside the image

#### Scenario: Skills deployed at runtime
- **WHEN** the container starts and a project directory exists
- **THEN** the entrypoint copies skills from `/usr/local/share/tillandsias/opencode/` to the project's `.opencode/` directory

#### Scenario: OpenCode discovers skills
- **WHEN** OpenCode launches in the project directory
- **THEN** `/gh-auth-login` appears as an available command

### Requirement: Agent-blocked authentication skill
The `/gh-auth-login` skill SHALL authenticate with GitHub while keeping credentials invisible to AI agents.

#### Scenario: Agent cannot invoke skill
- **GIVEN** the skill has `agent_blocked: true` in its frontmatter
- **WHEN** an AI agent attempts to invoke `/gh-auth-login`
- **THEN** the invocation is rejected

#### Scenario: Private authentication flow
- **WHEN** the user runs `/gh-auth-login`
- **THEN** the GitHub device flow runs via `/bash-private` so tokens and one-time codes are never visible to agents

#### Scenario: Git identity configured
- **WHEN** the user completes `/gh-auth-login`
- **THEN** `git config --global user.name` and `git config --global user.email` are set

#### Scenario: Credential persistence
- **WHEN** the user authenticates and the container restarts
- **THEN** the user remains authenticated because credentials are stored in the persistent cache volume
