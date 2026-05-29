---
title: Install Python LSP (pyright) and linter/formatter (ruff)
gap: "missing_tools: pyright, ruff; Python3 present but no developer tooling"
category: runtime-tool
status: implemented
proposed_at: 2026-05-28T12:15:00Z
approved_at: 2026-05-28T17:05:00Z
implemented_at: 2026-05-28T21:15:00Z
evidence: "Containerfile line 38: pyright, ruff, poetry, pipx, uv, mypy, pytest via pip3"
changes:
  - file: images/default/Containerfile
    description: |
      Install python3-pip via microdnf, then pip install pyright ruff. Consider
      also installing pipx for isolated tool installations.
  - file: images/default/entrypoint-forge-opencode.sh
    description: No changes needed (pip-installed binaries land in PATH-accessible locations).
approval_required: orchestrator
approved_by: Antigravity (Orchestrator)
---

## Gap

Python3 (`/usr/sbin/python3`) is installed and available, but no Python language server
(pyright) or linter/formatter (ruff) are present. These are essential for IDE-quality
Python development in the forge.

## Evidence

From `diagnostics_20260528T111351Z.log`:

- `missing_tools`: `["pyright", "ruff"]`
- Stderr log confirmed `command -v pyright` → `MISSING`, `command -v ruff` → `MISSING`
- `proposed_enhancements` includes: `{"tool": "pyright+ruff", "ecosystem": "python", "why": "Python3 is installed but no LSP (pyright) or linter/formatter (ruff) are present."}`

## Privacy / Isolation Assessment

- Tools install via `pip` into user-local or system site-packages within the forge sandbox.
- No external network access beyond the existing proxy.
- All install artifacts live in the image layer; no host contamination.
- **Safe within the existing privacy/isolation envelope.**
