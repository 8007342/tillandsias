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

Guest git identity (user.name / user.email) is configured inside the
container at entry, from Tillandsias-provided values — never mounted,
copied, or leaked from the host's global git config.

#### Scenario: Host identity absent in the guest

- **WHEN** a forge container starts on a host whose global git config names
  the operator
- **THEN** commits made inside the guest carry the project-scoped identity,
  not the operator's

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
