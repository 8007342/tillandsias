# forge-git-identity-anonymization Specification

@trace spec:forge-git-identity-anonymization

## Status

active

## Purpose

A forge guest commits as a project-scoped identity, never as the operator,
and every agentic commit carries machine-readable attribution. Seven guest
entrypoints (`images/default/entrypoint-forge-*.sh`, `entrypoint-terminal.sh`)
and `lib-common.sh` traced this contract for months while the spec file did
not exist — order 877 closed that ghost. The 2026-08-24 retrospective showed
why the contract matters beyond privacy: ledger tooling that fell back to git
author names inherited display-name garbage (`Laptopirria`, `Tlatoāni`) that
declared identity (856/864/874-idnt) exists to replace.

## Requirements

### Requirement: The guest never inherits the host's git identity
<!-- req-id: f257a89a -->

Guest git identity (user.name / user.email) SHALL be derived from the GitHub
App's authenticated user plus a host component and a Tillandsias-name
component, and SHALL be configured inside the container at entry. It SHALL
NOT be read from, mounted from, or copied from the host's global git config.
(Order 1453-7rzd, operator 2026-09-28: "now that we login with a GitHub app we
should have access to the user's name and email. We just need to juggle host
names, and append some tillandsias names for randomness".)

The shape, until the operator answers the open questions in
`openspec/changes/forge-git-identity-from-github-app/`: display name
`<GitHub name> (<host> · tillandsia-<species>)`, email
`<id>+<login>@users.noreply.github.com`, the species chosen once per forge.

@trace spec:forge-git-identity-anonymization, order:1453-7rzd

#### Scenario: Host gitconfig does not reach the guest

- **WHEN** a forge starts on a host whose global git config names someone
  other than the GitHub App's authenticated user
- **THEN** commits made inside the guest carry the App-derived identity, and
  no field of the host gitconfig's user.name or user.email

#### Scenario: No App login yields no borrowed identity

- **WHEN** no GitHub App login is stored for the project
- **THEN** the forge falls back to a project-scoped identity and says so in
  its lifecycle trace, and still does not read the host gitconfig

### Requirement: Guest identity is config, not exported environment

The forge SHALL write the identity as git configuration and SHALL NOT export
GIT_AUTHOR_* or GIT_COMMITTER_* into agent shells, so a scratch repository
that sets its own identity (`-c user.name`, a local config) commits as that
identity. The launcher passes the values as `TILLANDSIAS_GIT_NAME`,
`TILLANDSIAS_GIT_EMAIL` and `TILLANDSIAS_GIT_HOST` for the guest to write.

#### Scenario: A fixture's scratch identity wins inside a forge

- **WHEN** a fixture inside a forge runs `git -c user.name=fixture -c
  user.email=f@x commit` in a scratch repository
- **THEN** the commit's author is `fixture <f@x>`

### Requirement: Committer host stays derivable

Every commit made in a forge SHALL carry its host in a `Tillandsias-Host:`
trailer, which `scripts/fleet-activity.sh` and `tillandsias-plan discipline
derive` read before falling back to the author email's domain, so attributing
a commit to a host does not depend on that domain.

#### Scenario: Host attribution survives a noreply email

- **WHEN** a forge commit's author email is a users.noreply.github.com address
- **THEN** the fleet activity report attributes it to the forge's host, not
  to the unattributed bucket

### Requirement: Agentic commits carry attribution trailers
<!-- req-id: 621c8801 -->

A `prepare-commit-msg` hook (installed via `core.hooksPath` in the GUEST's
global config, so the host's `.git/hooks/` is never touched) appends
`Co-Authored-By` and `Generated-By` trailers when `TILLANDSIAS_AGENT_NAME`
is set at commit time. Installation is idempotent; merge/squash/amend
sources are exempt; an existing `Generated-By:` trailer is never duplicated.

#### Scenario: Agent commit gains trailers exactly once

- **WHEN** an agent with `TILLANDSIAS_AGENT_NAME` set commits twice, the
  second time amending
- **THEN** the message carries one `Co-Authored-By` and one `Generated-By`
  trailer, not two

### Requirement: Hook installation cannot break a hostile environment
<!-- req-id: f9f6e107 -->

Every step of hook installation degrades gracefully (`|| true` /
`|| return 0`): a read-only cache directory or missing git binary leaves the
forge functional without attribution rather than dead at entry.

#### Scenario: Read-only cache does not kill the entrypoint

- **WHEN** `$HOME/.cache/tillandsias` is not writable at entry
- **THEN** the entrypoint continues (no attribution) instead of failing the
  forge launch

## Sources of Truth

- `images/default/lib-common.sh` — identity setup and
  `_install_agent_trailer_hook`
- `images/default/entrypoint-forge-*.sh`, `entrypoint-terminal.sh`
- Related: `scripts/agent-identity.sh` (order 756-hn3a) for the LEDGER
  identity grammar this guest-side identity feeds
