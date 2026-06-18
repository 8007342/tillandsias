---
title: Install marksman (Markdown LSP server)
gap: "missing_tools: marksman — Markdown language server absent despite extensive documentation files"
category: runtime-tool
status: proposed
proposed_at: 2026-06-18T06:00:00Z
changes:
  - file: images/default/Containerfile
    description: |
      Install marksman (Markdown LSP server) from GitHub releases or via
      dotnet tool install. Add to the existing LSP layer alongside other
      language servers.
---

## Gap

Diagnostic run `diagnostics_20260617T221030Z-summary.md` reports marksman as
missing:

- Proposed enhancements: "marksman — Markdown language server for editing
  documentation and spec files"

The project contains extensive Markdown documentation (specs, methodology,
plan files, cheatsheets, proposals). Without a Markdown LSP server, agents
lack code intelligence (completion, diagnostics, hover, references) for .md
files.

## Evidence

- `diagnostics_20260617T221030Z-summary.md`: marksman in proposed enhancements
- Project has hundreds of .md files across specs, methodology, plan, docs
- No alternative Markdown LSP is present

## Privacy / Isolation Assessment

- marksman is a single static .NET binary (self-contained) — download from
  GitHub releases at build time
- Also available via npm (`marksman` or `@microsoft/marksman`)
- No daemon, no root, no new network egress beyond initial download
- **Safe within the existing privacy/isolation envelope.**
