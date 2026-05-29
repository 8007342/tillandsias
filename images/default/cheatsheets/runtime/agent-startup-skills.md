---
tags: [startup, skills, routing, agents, opencode]
languages: []
since: 2026-04-27
last_verified: 2026-04-27
sources:
  - https://github.com/8007342/tillandsias
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: false
---

# Agent Startup Skills

@trace spec:project-bootstrap-readme @cheatsheet runtime/agent-startup-skills.md

**Version baseline**: Tillandsias v0.1.170+
**Use when**: Understanding how the four startup skills (`/startup`, `/bootstrap-readme-and-project`, `/bootstrap-readme`, `/status`) route an OpenCode agent into the correct flow on first prompt of a new container session.

## Provenance

- <https://github.com/8007342/tillandsias> — Tillandsias forge methodology and agent startup discipline
- **Last updated:** 2026-04-27

## Overview

When OpenCode launches in a Tillandsias forge, the entrypoint shim injects a synthetic first message: `run /startup`. This skill reads the project state and dispatches to one of three sub-skills:
- `/bootstrap-readme-and-project` — empty project (no git history)
- `/bootstrap-readme` — non-empty project, missing or non-compliant README
- `/status` — non-empty project with a valid README (ready for work)

All output fits on a single screen; next prompt lands on real work.

## Four Skills

### 1. `/startup` — Entrypoint & Router

**Input**: None (always invoked by OpenCode entrypoint shim)

**Algorithm**:
```
1. Check git status:
   - If "fatal: not a git repository": ROUTE → /bootstrap-readme-and-project (empty project)
   - Else if "git ls-files | wc -l" ≤ 5: ROUTE → /bootstrap-readme-and-project (new, few files)
   
2. If README.md exists:
   - Run `check-readme-discipline.sh README.md`
   - If exit code 0 (valid): ROUTE → /status (ready for work)
   - If exit code >0 (invalid): ROUTE → /bootstrap-readme (repair flow)
   
3. If no README.md: ROUTE → /bootstrap-readme (missing flow)
```

**Output**: One-line routing decision + rationale:
```
→ Status: Project is ready. Check recent changes and OpenSpec items.
```

**Telemetry**:
- Event: `startup_routing`
- Field: `resolved_via` ∈ {empty, bootstrap-readme, status}
- Spec: `project-bootstrap-readme`

---

### 2. `/bootstrap-readme-and-project` — Empty Project Welcome

**Input**: None

**Algorithm**:
1. Detect project name (guess from PWD or ask user)
2. Load ASCII art banner from the curated cache
3. Load `cheatsheets/welcome/sample-prompts.md`
4. Display 3 sample prompts (first 3, or `shuf -n 3` if randomization is desired)
5. Print forge capability summary (one paragraph on what OpenCode + Flutter + Nix + Ollama can build)
6. End with "What would you like to build?" (open-ended, no force)

**Output** (fits one screen, ~20 lines):
```
╔═══════════════════════════════════════════════════════════╗
║           🌺 Welcome to [ProjectName]                      ║
╚═══════════════════════════════════════════════════════════╝

You're starting from scratch. Here are three ideas to get you going:

1. Build a Pong web app. "Build me a single-page web Pong game
   using Flutter web and the Flame engine..."

2. Inventory for my business. "Help me build an inventory app for
   my small business..."

3. Calculus tutor. "Design a single-page web app that helps me
   understand derivatives..."

This forge can build Flutter apps (web and desktop), Nix packages,
data pipelines with Rust, and more. You've got Ollama for local AI.

What would you like to build?
```

**Telemetry**:
- Event: `readme_regen` (or `startup_routing`)
- Field: `resolved_via: "empty"`
- Spec: `project-bootstrap-readme`

---

### 3. `/bootstrap-readme` — Repair README

**Input**: None (called when README is missing or non-compliant)

**Algorithm**:
1. If README missing: print "README.md not found"
2. Run `regenerate-readme.sh` to auto-derive from manifests
3. Run `check-readme-discipline.sh` on the newly generated README
4. If validation passes: print "README regenerated and validated ✓"
5. If validation fails: print each failure line, offer to run regen again
6. Preserve any agent-curated sections (Security, Architecture, Privacy) if they existed

**Output** (one screen):
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

**Telemetry**:
- Event: `readme_regen`
- Field: `resolved_via: "bootstrap-readme"`
- Field: `summarizers_run: [list]` (e.g., ["cargo", "nix"])
- Spec: `project-bootstrap-readme`

---

### 4. `/status` — Ready-State Status & Suggestion

**Input**: None (called when README is valid and project is non-empty)

**Algorithm**:
1. Run `openspec list --json` (if `openspec` is available)
   - If yes: summarize open items (count, priority)
   - If no: print "(No OpenSpec changes tracked)"
2. Run `git log --oneline -5` to show last 5 commits
3. Load latest 5 lines from `.tillandsias/readme.traces` (if present)
4. Based on traces + commits + OpenSpec state, suggest next action:
   - If README timestamp > 3 days old: "Consider refreshing the README"
   - If commits since last README gen: "README may be out of date; run /bootstrap-readme"
   - If open OpenSpec changes: list them in priority order
   - Default: "Pick an open item from OpenSpec or start new work"

**Output** (one screen):
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

**Telemetry**:
- Event: `startup_routing`
- Field: `resolved_via: "status"`
- Field: `openspec_items: N` (count of open items)
- Field: `readme_age_hours: N`
- Spec: `project-bootstrap-readme`

---

## Routing Matrix

| Condition | Routed To | Flow |
|-----------|-----------|------|
| No `.git/` directory | `/bootstrap-readme-and-project` | Empty project welcome |
| `git ls-files \| wc -l` ≤ 5 | `/bootstrap-readme-and-project` | Empty project welcome |
| `README.md` missing | `/bootstrap-readme` | Auto-generate + validate |
| `README.md` exists, invalid | `/bootstrap-readme` | Repair + validate |
| `README.md` exists, valid | `/status` | Show state, suggest next |

---

## Empty-Project Heuristic

`/startup` distinguishes "empty project" (new repo, few files, user hasn't started coding) from "mature project with missing README" (many files, history exists, README lost or never created).

**Heuristic**:
- If `git ls-files | wc -l` ≤ 5 OR `fatal: not a git repository`: treat as **empty**.
- Otherwise, treat as **non-empty**.

**Why**: A fresh Tillandsias container mounts a 3-5 file `.tillandsias/` directory and the empty project's directory. An agent's first real file (e.g., `lib.rs`, `main.ts`, `pubspec.yaml`) gets it past the threshold, and subsequent runs assume the user has started coding.

---

## OpenCode Entrypoint Shim

The shim is in `images/default/entrypoint-forge-opencode.sh`. Before `exec`ing OpenCode, it:

```bash
# Write synthetic first prompt to OpenCode's auto-prompt path
OPENCODE_INIT="$HOME/.config/opencode/init-prompt.txt"
echo "run /startup" > "$OPENCODE_INIT"

# Export for OpenCode to consume
export OPENCODE_INIT_PROMPT_FILE="$OPENCODE_INIT"

# Launch OpenCode (it consumes the init-prompt)
exec opencode
```

**Key points**:
- Shim runs EVERY time the container starts (idempotent)
- Synthetic prompt writes to a known path before `exec`
- OpenCode reads and deletes the file during startup
- Subsequent prompts go through the normal flow

---

## See also

- `welcome/readme-discipline.md` — README structural contract and schema
- `welcome/sample-prompts.md` — curated prompts for empty-project flow
- `agents/opencode.md` — OpenCode skill file convention (YAML frontmatter, description, flow)
