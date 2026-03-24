## ADDED Requirements

### Requirement: Interactive bash skill
The forge container SHALL provide a `/bash` OpenCode skill that opens an interactive bash shell in the project directory.

#### Scenario: No arguments
- **WHEN** the user invokes `/bash` with no arguments
- **THEN** an interactive bash session opens in the current project directory

#### Scenario: With arguments
- **WHEN** the user invokes `/bash <command>`
- **THEN** the command is executed in bash and its output is displayed

#### Scenario: Agent blocked
- **WHEN** an AI agent attempts to invoke `/bash`
- **THEN** the invocation is rejected because the skill has `agent_blocked: true`

### Requirement: Private bash skill
The forge container SHALL provide a `/bash-private` OpenCode skill that runs bash in a session where output is never visible to AI agents.

#### Scenario: No arguments (private shell)
- **WHEN** the user invokes `/bash-private` with no arguments
- **THEN** a private interactive bash session opens that is invisible to the AI agent

#### Scenario: With arguments (private command)
- **WHEN** the user invokes `/bash-private <command>`
- **THEN** the command is executed privately and its output is never sent to any AI model

#### Scenario: Agent sees only completion message
- **WHEN** a private session ends
- **THEN** the AI agent sees only "Private command completed." with no command output or history

#### Scenario: Agent blocked
- **WHEN** an AI agent attempts to invoke `/bash-private`
- **THEN** the invocation is rejected because the skill has `agent_blocked: true`

### Requirement: Skill file format
Both skills SHALL be defined as markdown files with YAML frontmatter in the `images/default/skills/command/` directory.

#### Scenario: Frontmatter contains description
- **WHEN** OpenCode loads a skill file
- **THEN** the YAML frontmatter includes a `description` field summarizing the skill's purpose

#### Scenario: Frontmatter marks agent blocking
- **WHEN** OpenCode loads a skill file with `agent_blocked: true`
- **THEN** the skill is available to human users but blocked from AI agent invocation
