## ADDED Requirements

### Requirement: the dialog shows Mācron doing the action

The approval dialog SHALL be a small window at normal stacking level showing
Mācron, drawn to the character canon in the macron.dev repository, performing
the action being approved in a small workshop among tillandsias, with one
illustration per action kind, plus the curated sentences and two buttons:
Approve and Not now. Approve SHALL hand off to the OS verification prompt.

#### Scenario: each action kind has its own illustration

- **WHEN** a test renders the dialog for every action kind in the gate table
- **THEN** each has a distinct illustration and both sentences

### Requirement: messages are curated, honest and calm

Each action kind SHALL have a fixed pair of sentences, what happens and what
it costs, written in plain second-person present tense, with numbers when
known and the way back named. They SHALL NOT use exclamation marks, all-caps
emphasis, or alarm words unless literally true. A lint test SHALL enforce this.

#### Scenario: the lint rejects a panicky sentence

- **WHEN** a sentence contains "WARNING" or an exclamation mark
- **THEN** the lint test fails

#### Scenario: the cost is stated

- **WHEN** the dialog asks to dispatch a GitHub workflow
- **THEN** it names the workflow, the branch, and its estimated Actions minutes
