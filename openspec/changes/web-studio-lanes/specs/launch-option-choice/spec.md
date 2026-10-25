## ADDED Requirements

### Requirement: a launch with options asks the user with one recommended choice

When a launch has two or more viable options, the agent and the tray SHALL present them before launching, in this form: a header `we have N options for this:` followed by one line per option, `<name>[ [Recommended]]: <one-line brief>`. Exactly one option SHALL carry `[Recommended]`, chosen by the registry's detector for the project.

#### Scenario: a markdown site asks for a studio

- **WHEN** the user asks to author a Hugo site interactively
- **THEN** the prompt begins `we have N options for this:` with N equal to the number of registered studios, one line each
- **AND** exactly one line ends its name with `[Recommended]`, and it is Decap CMS

#### Scenario: a degraded option

- **WHEN** an option needs a cloud account
- **THEN** its brief says so and it never carries `[Recommended]`

#### Scenario: a single option

- **WHEN** only one option is viable
- **THEN** no prompt is shown and the launch proceeds

### Requirement: the choice is remembered per project and can be changed

The chosen option SHALL be recorded in host state, keyed by project and launch kind. Later launches SHALL reuse it without asking. A `change` action from the tray or the agent SHALL show the prompt again.

#### Scenario: second launch

- **WHEN** the user chose GrapesJS and launches the studio again
- **THEN** GrapesJS opens without a prompt
