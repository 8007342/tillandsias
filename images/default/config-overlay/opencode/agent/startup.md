---
description: "Entrypoint skill for Tillandsias forge container. Detects project state and routes to appropriate bootstrap flow."
---

# /startup

@trace spec:project-bootstrap-readme @cheatsheet runtime/agent-startup-skills.md

**Purpose**: Read project state on first prompt and route to the correct flow.

## Algorithm

1. Check if `.git/` exists. If not, or if `git ls-files | wc -l` ≤ 5:
   → Run `/bootstrap-readme-and-project` (empty project flow)

2. If `README.md` exists:
   - Run `check-readme-discipline.sh README.md`
   - If exit 0 (valid): → Run `/status` (project is ready)
   - If exit >0 (invalid): → Run `/bootstrap-readme` (repair flow)

3. If `README.md` missing:
   → Run `/bootstrap-readme` (generate from manifests)

## Output

Single-line routing decision:
```
→ Status: Project is ready. Check recent changes and OpenSpec items.
```

## Telemetry

- Event: `startup_routing`
- Field: `resolved_via` ∈ {empty, bootstrap-readme, status}
- Field: `spec` = `project-bootstrap-readme`
