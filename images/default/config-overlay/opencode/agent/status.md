---
description: "Display project state: recent commits, OpenSpec items, readme.traces tail, suggested next action."
---

# /status

@trace spec:project-bootstrap-readme @cheatsheet runtime/agent-startup-skills.md

**Purpose**: Show project state and suggest the highest-priority next action.

## Flow

1. Run `openspec list --json` (if available) and summarize open items
2. Run `git log --oneline -5` and display last 5 commits
3. Load latest 5 lines from `.tillandsias/readme.traces` (if present)
4. Infer README age from timestamp in README.md
5. Based on state, suggest next action:
   - If README timestamp > 3 days old: "Consider refreshing the README"
   - If commits since last README gen: "README may be out of date; run /bootstrap-readme"
   - If open OpenSpec changes: list them in priority order
   - Default: "Pick an open item from OpenSpec or start new work"

## Output (one screen)

```
Project is ready. Here's the current state:

Recent commits:
  61db7f1 chore(openspec): archive 10 completed changes
  e89184f docs(cheatsheets): add utils/tar.md
  88da8e1 fix(forge): bash/zsh welcome banner
  74262c4 fix(build): tar+exclude source → 17 MB

README generated 3 hours ago (up to date)

OpenSpec open items:
  - project-summarizers (Wave 2: summarizer registry)
  - cross-project-readme-reuse (deferred)

Next: Pick an issue from OpenSpec or start new work.
```

## Telemetry

- Event: `startup_routing`
- Field: `resolved_via` = `"status"`
- Field: `openspec_items` = count of open items
- Field: `readme_age_hours` = hours since README generated
- Field: `spec` = `project-bootstrap-readme`
