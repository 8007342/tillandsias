## ADDED Requirements

### Requirement: branch discipline can mark promotions as approval-required

A project's branch-discipline seed MAY list promotions, each with `from`, `to`
and `approval: required | none`. The git-mirror pre-receive hook SHALL require
a valid grant only for updates that match a promotion marked required. It
SHALL gate nothing when the list is absent.

#### Scenario: a required promotion is gated

- **WHEN** the seed marks `research/* -> linux-next` required and a push
  promotes a research branch into `linux-next` with no grant, on a host in
  `enforced` mode
- **THEN** the push is refused before the relay

#### Scenario: an unlisted merge is not gated

- **WHEN** a work ref is landed into `linux-next` and no promotion entry
  matches
- **THEN** no approval is required
