---
title: Install golangci-lint for comprehensive Go linting
gap: "missing_tools: golangci-lint — Go linter aggregator absent despite gopls being present"
category: runtime-tool
status: proposed
proposed_at: 2026-06-16T08:00:00Z
changes:
  - file: images/default/Containerfile
    description: |
      Install golangci-lint via go install or from GitHub releases. Add to
      the existing Go-tools RUN layer alongside gopls and delve.
---

## Gap

Multiple diagnostic runs (`diagnostics_20260604T002348Z-summary.md`,
`diagnostics_20260614T062505Z-summary.md`,
`diagnostics_20260614T150524Z-summary.md`) report golangci-lint as missing.

The Go toolchain (golang, gopls, delve) is already installed, but there is no
comprehensive Go linter. golangci-lint aggregates dozens of Go linters
(staticcheck, govet, errcheck, ineffassign, etc.) into a single fast runner.
It is the standard Go linting tool in CI pipelines.

## Evidence

- Reported in 3+ diagnostics files
- `missing_tools` consistently includes `golangci-lint`
- Go toolchain present but linter aggregator absent

## Privacy/Isolation Assessment

- Single static Go binary — can be installed via `go install` or direct download
- Lands in existing `~/go/bin` — same PATH as gopls and delve
- No daemon, no root, no new network egress
- **Safe within the existing privacy/isolation envelope**
