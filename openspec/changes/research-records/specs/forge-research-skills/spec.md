## ADDED Requirements

### Requirement: The forge ships a skill that finds, vets and pulls in research

`skills/find-research/SKILL.md` SHALL guide an agent to search reputable
sources for a stated design question, verify each candidate (resolve the DOI
or open the standards page, obtain an archive snapshot), grade authority and
strength, and write a record into the project's `research/` using the
template, then run the validator. It SHALL say to drop any source that cannot
be opened rather than cite it from memory.

@trace spec:research-records

#### Scenario: An unverifiable source is dropped
- **WHEN** the agent cannot open a candidate source
- **THEN** no record is written for it and the agent says so

### Requirement: The forge ships a skill that cites research and carries the fine-tuning trigger

`skills/cite-research/SKILL.md` SHALL state the citation grammar and SHALL
instruct the agent that, after repeated user adjustments to one feature in a
session, it offers once: "that's a lot of fine-tuning for this feature, shall
we search online for research from reputable authorities?" and, on yes,
invokes find-research.

@trace spec:research-records

#### Scenario: The trigger offers, it does not insist
- **WHEN** the user declines the research search
- **THEN** the agent continues the fine-tuning and does not offer again for that feature in the session

### Requirement: A new project starts with a research pass

`skills/start-a-new-project` SHALL, after learning what the app is, check the
shared library index for records whose `applies_to` matches the app, pull the
relevant ones into the project's `research/`, and only then scaffold. The
scaffold SHALL create `research/README.md` when absent.

@trace spec:research-records

#### Scenario: A game project starts with GameFlow and flow in its store
- **WHEN** the user says they are building a game
- **THEN** the project's `research/` holds the games and psychology records
  before the first spec is written
