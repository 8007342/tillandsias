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

## Cheatsheet Materialization

After routing to a terminal state (status, bootstrap-readme, or bootstrap-readme-and-project):

1. Parse the project's README.md `requires_cheatsheets:` YAML block (if README is valid)
2. For each required cheatsheet:
   - Look up via tier classifier: `bundled` or `distro-packaged` → already on disk
   - `pull-on-demand` → materialize via the cheatsheet recipe system
   - `missing` → emit WARN, continue
3. Emit `readme_requires_pull` telemetry for each materialized cheatsheet
4. Provide the materialized cheatsheets in the agent context (accessible via `cat $TILLANDSIAS_CHEATSHEETS/...`)

## Telemetry

- Event: `startup_routing`
- Field: `resolved_via` ∈ {empty, bootstrap-readme, status}
- Field: `spec` = `project-bootstrap-readme`
- Event: `readme_requires_pull` (for each cheatsheet materialized)
- Field: `triggered_by` = `"readme-requires"`
- Field: `spec` = `project-bootstrap-readme`
