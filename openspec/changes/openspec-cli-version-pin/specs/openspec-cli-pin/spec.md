# openspec-cli-pin — delta

## ADDED Requirements

### Requirement: The project records one openspec CLI version

The repository SHALL record the openspec CLI version that generated its
committed `/opsx` commands and `openspec-*` skills in `openspec/cli-version`,
as a single dotted numeric version. `scripts/openspec-pin.sh drift` SHALL
report every tracked generated skill whose `generatedBy` disagrees with it.

#### Scenario: generated sets agree with the pin
- **WHEN** every tracked `*/skills/openspec-*/SKILL.md` carries `generatedBy` equal to `openspec/cli-version`
- **THEN** `scripts/openspec-pin.sh drift` SHALL print `ok:openspec-generated-matches-pin:<version>:<count>` and exit 0

#### Scenario: a generated set is at another version
- **WHEN** any tracked generated skill carries a different `generatedBy`
- **THEN** `drift` SHALL print `drift:openspec-generated:<version>:<count>`, exit 3, and name each file with its version on stderr

### Requirement: A forge runs the project's pinned openspec

A forge launched on a project with `openspec/cli-version` SHALL run openspec at
exactly that version before any openspec command touches the checkout. The
install SHALL go into the npm prefix the forge's shells put first on PATH,
under the npm-update lock. The backgrounded harness refresher SHALL NOT move a
pinned openspec to `@latest`. A project without a pin SHALL keep the existing
`@latest` behaviour.

#### Scenario: pinned project, forge holds a newer global openspec
- **WHEN** the forge's global openspec is `@latest` and the project pins an older version
- **THEN** after `ensure_openspec_pinned` the `openspec` on PATH SHALL report the pinned version
- **AND** the per-project pin marker SHALL hold that version

#### Scenario: warm launch
- **WHEN** the pinned version is already installed
- **THEN** the launch SHALL install nothing

#### Scenario: refresher on a pinned project
- **WHEN** `ensure_forge_harnesses` runs with the pin marker present
- **THEN** it SHALL NOT install `@fission-ai/openspec@latest`, and SHALL still refresh the other harnesses

#### Scenario: pin cannot be installed
- **WHEN** the pinned install fails (for example, no registry egress)
- **THEN** the launch SHALL continue with the installed openspec and warn, and `openspec_init_if_absent` SHALL still leave tracked files unwritten

### Requirement: The coordinator moves the pin deliberately

The meta-orchestration coordinator SHALL check for a newer openspec release and,
when one exists, bump the pin and regenerate every configured tool's generated
set in ONE change, using an openspec configuration isolated from the machine
running it. No other path SHALL move the committed generated sets.

#### Scenario: a newer release is published
- **WHEN** `scripts/openspec-pin.sh check` prints `due:openspec-bump:<pin>-><latest>`
- **THEN** `bump` SHALL install `<latest>` into a version-keyed cache, run `openspec update --force` with a fresh `XDG_CONFIG_HOME`, write the pin, and print `bumped:openspec:<pin>-><latest>:<n>-paths` without committing

#### Scenario: the bump needs a human decision
- **WHEN** the regeneration leaves drift, writes outside the generated surface, or the CLI reports a superseded copy it did not overwrite
- **THEN** `bump` SHALL print `review:openspec-bump:<old>-><new>:<reason>`, exit 6, and name the paths on stderr

#### Scenario: the tree is dirty
- **WHEN** `bump` starts on a tree with any status-visible change
- **THEN** it SHALL print `refused:openspec-bump:dirty-tree` and change nothing
