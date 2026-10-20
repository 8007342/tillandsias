## ADDED Requirements

### Requirement: Piped litmus commands are a carried-obligation backlog

The local gate SHALL print, on every `--check`, the count of litmus
`command:` lines with a pipe outside quotes and its split by decision
family (`scripts/lua/census-litmus-pipes.lua`). `methodology/convergence.yaml`
SHALL carry a `litmus-piped-commands` backlog whose counter is that line,
whose item is one converted `command:` with its floor line lowered, and
whose stage starts advisory: a change in the area is warned, never refused.
A change that edits an existing piped `command:` line and leaves a pipe in it
SHALL be named by the shell ratchet (a warning at the advisory stage).

#### Scenario: the counter is printed

- **WHEN** `./build.sh --check` runs
- **THEN** its output contains one `ok:litmus-pipe-census:piped=<n>:three-plus=<m>:…` line

#### Scenario: editing a piped command without converting it is named

- **WHEN** a diff changes a `command:` line that had a pipe and the new line still has one
- **THEN** the ratchet prints a warning naming that file and line, and does not refuse while the backlog is advisory
