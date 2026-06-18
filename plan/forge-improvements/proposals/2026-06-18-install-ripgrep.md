---
title: Install ripgrep (rg) for universal code-content search
gap: "missing_tools: ripgrep — Grep tool in forge depends on rg; no alternative present"
category: runtime-tool
status: proposed
proposed_at: 2026-06-18T06:00:00Z
changes:
  - file: images/default/Containerfile
    description: |
      Install ripgrep via microdnf (`ripgrep` package) on the existing
      system-packages RUN layer. Fedora 44 includes ripgrep as a distro package.
---

## Gap

Diagnostic run `diagnostics_20260617T202340Z-summary.md` and multiple earlier
runs report ripgrep as missing:

- `missing_tools` includes `ripgrep`
- Proposed enhancements: "Universal code-content search; `Grep` tool in forge
  depends on rg; no alternative present"

The forge's internal tooling (Grep tool, code search) depends on `rg` (ripgrep)
being available. Without it, agents lack fast code-content search capability.

## Evidence

- `diagnostics_20260617T202340Z-summary.md`: ripgrep in missing_tools
- The forge's Grep tool implementation calls `rg` for fast file content search
- No alternative search tool is present in the container

## Privacy / Isolation Assessment

- ripgrep is available as a Fedora 44 microdnf package (`ripgrep`) — same
  envelope as other system packages.
- Single static binary; no daemon, no root, no new network egress.
- **Safe within the existing privacy/isolation envelope.**
