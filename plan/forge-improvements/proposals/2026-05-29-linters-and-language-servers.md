---
title: Install linters and language servers (pylsp, yamllint, markdownlint, actionlint, vale)
gap: "missing_tools: pylsp, yamllint, markdownlint, actionlint, vale; code intelligence and automated code quality tools absent"
category: runtime-tool
status: implemented
proposed_at: 2026-05-29T16:06:00Z
approved_at: 2026-05-29T16:06:00Z
implemented_at: 2026-05-29T16:15:00Z
evidence: "Containerfile line 51: python-lsp-server, yamllint via pip3; line 53: markdownlint-cli via npm; lines 79-80: actionlint and vale binaries via curl/tar"
changes:
  - file: images/default/Containerfile
    description: |
      Install python-lsp-server and yamllint via pip3 at image build time.
      Install markdownlint-cli via npm.
      Download and install actionlint (1.7.12) and vale (3.14.2) static binaries from GitHub releases.
approval_required: orchestrator
approved_by: Antigravity (Orchestrator)
---

## Gap

A robust batch of linters and language servers are missing from the default forge image:

- `pylsp` — Python LSP server (`python-lsp-server`) for rich editor autocomplete and diagnostic integration.
- `yamllint` — Linter for YAML configuration files, crucial for managing the plan and spec ledger.
- `markdownlint` — Linter/formatter for Markdown files, ensuring specs are well-formed.
- `actionlint` — Automated linter for GitHub Actions workflows.
- `vale` — Syntax-aware prose linter for documentation and specifications.

Installing these directly at image build time ensures coding agents can perform static analysis and syntax validation on all project artifacts natively.

## Evidence

From the live diagnostics runs (`diagnostics_20260529T151307Z-summary.md`):
- `missing_tools` list includes: `pylsp`, `yamllint`, `markdownlint`, `actionlint`, `vale`.
- The curated enhancement backlog specifically identifies these tools as key gaps.

## Privacy / Isolation Assessment

- **All tools execute locally inside the container sandbox.**
- No external network access is needed or configured at runtime.
- No new secrets, credentials, or mounts are introduced.
- **Strictly preserves the container isolation envelope (--cap-drop=ALL, no-new-privileges, keep-id, etc.).**
