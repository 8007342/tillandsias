---
description: "Regenerate and validate README.md from source manifests."
---

# /bootstrap-readme

@trace spec:project-bootstrap-readme @cheatsheet runtime/agent-startup-skills.md

**Purpose**: Repair a missing or non-compliant README by auto-deriving from manifests and validating structure.

## Flow

1. Print "Regenerating README.md from source manifests..."
2. Run `regenerate-readme.sh` (invokes summarizers, writes README.md)
3. Run `check-readme-discipline.sh README.md` (validates structure)
4. Print per-check status and result
5. If validation fails, offer next step (re-run, or manual edit)
6. Preserve any agent-curated sections (Security, Architecture, Privacy) from previous README

## Output (one screen)

```
Regenerating README.md from source manifests...

Ran summarizers:
  ✓ Cargo.toml (Rust workspace)
  ✓ flake.nix (Nix inputs + outputs)
  ✗ package.json (not found)

README.md written. Checking structure...

✓ FOR HUMANS header present
✓ FOR ROBOTS header present
✓ Auto-regen warning found
✓ Timestamp valid
✓ Seven H2 sections present

README is ready. Next, consider adding descriptions to:
  - Security (threat model, authentication)
  - Architecture (layers, major modules)
  - Privacy (data handling, user consent)
```

## Telemetry

- Event: `readme_regen`
- Field: `resolved_via` = `"bootstrap-readme"`
- Field: `summarizers_run` = list of ran summarizers
- Field: `spec` = `project-bootstrap-readme`
