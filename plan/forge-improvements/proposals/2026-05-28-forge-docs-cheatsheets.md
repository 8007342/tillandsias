---
title: Create forge reference docs (cheatsheets, agent instructions, cache-discipline)
gap: "hot_paths.cheatsheets missing; TILLANDSIAS_CHEATSHEETS unset; agent_instructions empty"
category: env-var
status: implemented
proposed_at: 2026-05-28T12:15:00Z
approved_at: 2026-05-28T17:05:00Z
implemented_at: 2026-05-28T21:15:00Z
evidence: "Containerfile line 73: /opt/cheatsheets, /opt/cheatsheets-image, /opt/cheatsheet-sources dirs; lines 77-78: COPY cheatsheets/ and cheatsheet-sources/; line 117: COPY instructions/ overlay; lib-common.sh line 554: TILLANDSIAS_CHEATSHEETS export"
changes:
  - file: images/default/Containerfile
    description: |
      Create /opt/cheatsheets directory with forge reference documentation.
      Create ~/.config/opencode/instructions/ with cache-discipline.md and
      agent instruction files. Set TILLANDSIAS_CHEATSHEETS in ENV.
  - file: images/default/entrypoint-forge-opencode.sh
    description: Export TILLANDSIAS_CHEATSHEETS pointing to /opt/cheatsheets if not already set.
approval_required: orchestrator
approved_by: Antigravity (Orchestrator)
---

## Gap

The forge lacks reference documentation and agent instructions:

- `/opt/cheatsheets` — path does not exist (diagnostic: `df /opt/cheatsheets` → "path does not exist")
- `TILLANDSIAS_CHEATSHEETS` — environment variable is unset
- `agent_instructions.paths` — "NONE" (no `.md` files in `~/.config/opencode/instructions/`)
- `agent_instructions.discipline_content_first_lines` — "NONE" (no cache-discipline.md)
- Welcome banner references `help.sh` but no discoverable reference material is available

## Evidence

From `diagnostics_20260528T111351Z.log`:

- `diagnostics[0]`: `"df /opt/cheatsheets: path does not exist (df returned empty; ls confirmed 'No such file or directory')"`
- `diagnostics[1]`: `"TILLANDSIAS_CHEATSHEETS: environment variable is unset despite /opt/cheatsheets being referenced in forge config"`
- `diagnostics[2]`: `"~/.config/opencode/instructions/: directory missing or contains no .md files"`
- `proposed_enhancements` includes: `{"tool": "forge-docs", "ecosystem": "other", "why": "/opt/cheatsheets does not exist and TILLANDSIAS_CHEATSHEETS is unset... Create /opt/cheatsheets with forge reference docs..."}`

## Privacy / Isolation Assessment

- All content is static reference material baked into the image.
- No network access required; no host mounts or credentials.
- cache-discipline.md enforces good cache behavior (reduces need for network).
- **Safe within the existing privacy/isolation envelope.**
