## ADDED Requirements

### Requirement: Specs declare their cheatsheet sources of truth

Every new spec file (`openspec/specs/<capability>/spec.md` or `openspec/changes/<change>/specs/<capability>/spec.md`) SHALL include a top-level `## Sources of Truth` section listing one or more cheatsheets from `cheatsheets/` (or `/opt/cheatsheets/` from the agent perspective) that informed the spec's implementation guidance. The section appears at the bottom of the spec, after the requirements. Each entry is a single line of the form `- <category>/<filename>.md  — <one-line reason this cheatsheet was relevant>`.

The requirement applies to NEW specs starting from the date this change is archived. Existing specs (those present before this change) are exempt from the requirement until a separate retrofit sweep adds the section to them. `openspec validate` SHALL emit a warning (not an error) for new specs missing the section, allowing a soft adoption gradient.

#### Scenario: New spec includes Sources of Truth
- **WHEN** a contributor writes a new spec file as part of an OpenSpec change archived after this change
- **THEN** the spec SHALL contain a `## Sources of Truth` section listing one or more `cheatsheets/<category>/<filename>.md` references

#### Scenario: Validation warns on missing Sources of Truth
- **WHEN** `openspec validate <change>` runs against a change whose spec lacks the `## Sources of Truth` section
- **THEN** validation SHALL emit a warning identifying the spec file and the missing section
- **AND** validation SHALL still pass (warning is non-blocking)

#### Scenario: Existing specs are exempt until retrofit
- **WHEN** an existing pre-change spec (e.g., `openspec/specs/tray-app/spec.md` as of the merge date of this change) is read by `openspec validate`
- **THEN** the missing `## Sources of Truth` section SHALL NOT generate a warning
- **AND** the warning SHALL apply only to specs created or substantially modified after the change's archive date

### Requirement: Sources of Truth references are resolvable paths

Each entry in a spec's `## Sources of Truth` section SHALL be a relative path from the repository root to a real file in `cheatsheets/`. References to non-existent cheatsheets SHALL be flagged as warnings by `openspec validate`.

#### Scenario: Valid reference resolves
- **WHEN** a spec's Sources of Truth section lists `cheatsheets/languages/python.md  — used the type-hint patterns table`
- **AND** `cheatsheets/languages/python.md` exists in the repository
- **THEN** validation passes for that entry

#### Scenario: Missing cheatsheet reference warns
- **WHEN** a spec lists `cheatsheets/languages/cobol.md  — ...` and that file does not exist
- **THEN** validation emits a warning identifying the spec file and the missing cheatsheet
- **AND** validation still passes (advisory warning, not blocking)
