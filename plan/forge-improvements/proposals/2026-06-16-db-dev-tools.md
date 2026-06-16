---
title: Install DB and dev tools (sqlite3, redis-cli, hadolint, pre-commit)
gap: "missing_tools: sqlite3, redis-cli, hadolint, pre-commit — database CLIs and development quality tools"
category: runtime-tool
status: proposed
proposed_at: 2026-06-16T08:00:00Z
changes:
  - file: images/default/Containerfile
    description: |
      Install sqlite3 and redis-cli via microdnf. Install hadolint (Dockerfile
      linter) from GitHub releases. Install pre-commit via pip3.
---

## Gap

Diagnostic runs (`diagnostics_20260603T192817Z-summary.md`,
`diagnostics_20260604T002348Z-summary.md`,
`diagnostics_20260614T062505Z-summary.md`,
`diagnostics_20260614T160501Z-summary.md`,
`diagnostics_20260614T070420Z-summary.md`) report these tools as missing:

- **sqlite3**: SQLite CLI for database inspection
- **redis-cli**: Redis CLI for cache/queue debugging
- **hadolint**: Dockerfile/Containerfile linter — directly relevant to forge
  image development
- **pre-commit**: Git hooks framework for automated quality checks

## Evidence

- sqlite3: 2 diagnostic files
- redis-cli: `diagnostics_20260614T160501Z-summary.md`
- hadolint: `diagnostics_20260614T062505Z-summary.md`,
  `diagnostics_20260614T070420Z-summary.md`
- pre-commit: `diagnostics_20260604T002348Z-summary.md`

## Privacy/Isolation Assessment

- sqlite3, redis-cli: microdnf packages — same envelope
- hadolint: single static Haskell binary — download from GitHub releases
- pre-commit: pip3 install — same envelope as existing Python tooling
- No daemon, no root, no new network egress
- **Safe within the existing privacy/isolation envelope**
