---
title: Install tillandsias-help shell script
gap: "shell.tillandsias_help: command not found in PATH; welcome scripts register it but it's absent"
category: shell-tool
status: proposed
proposed_at: 2026-05-28T12:15:00Z
changes:
  - file: images/default/Containerfile
    description: |
      Create a tillandsias-help script (or symlink) and install it to
      /usr/local/bin/ so it is always in PATH. The script should document
      forge commands, environment variables, and common workflows.
  - file: images/default/entrypoint-forge-opencode.sh
    description: No changes needed (already in PATH via /usr/local/bin).
approval_required: orchestrator
approved_by:
---

## Gap

The forge welcome scripts register `tillandsias-help` as a shell helper,
but the command is not installed in PATH. Users who type `tillandsias-help`
get `command not found`.

## Evidence

From `diagnostics_20260528T111351Z.log`:

- `diagnostics[3]`: `"tillandsias-help: command not found in PATH"`
- Stderr log confirmed: `type tillandsias-help` → `NOT_FOUND`
- `proposed_enhancements` includes: `{"tool": "tillandsias-help", "ecosystem": "other", "why": "Shell helper registered in welcome scripts but not installed in PATH..."}`

## Privacy / Isolation Assessment

- Static shell script baked into the image at `/usr/local/bin/tillandsias-help`.
- No network access, host mounts, or credentials required.
- **Safe within the existing privacy/isolation envelope.**
