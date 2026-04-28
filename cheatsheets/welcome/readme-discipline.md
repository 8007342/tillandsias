---
tags: [readme, structure, automation, discipline]
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

# Project README Discipline

@trace spec:project-bootstrap-readme @cheatsheet welcome/readme-discipline.md

**Version baseline**: Tillandsias v0.1.170+
**Use when**: Understanding how Tillandsias-managed projects structure and auto-regenerate their README.md files. Referenced by `/startup`, `/bootstrap-readme`, and `/status` skills.

## Provenance

- <https://github.com/8007342/tillandsias> — Tillandsias forge methodology and project bootstrap discipline
- **Last updated:** 2026-04-27

## Overview

Every Tillandsias-managed project's README.md follows a two-section contract:
1. **FOR HUMANS** — timestamps, warnings, banners, install snippets, whimsical description
2. **FOR ROBOTS** — auto-derived tech stack, dependencies, structured metadata

Both sections are auto-regenerated from authoritative sources (manifests, git history, agent observations). The README becomes a first-class agent artifact, not human prose.

## FOR HUMANS Section

Starts with the exact H1 header: `# FOR HUMANS`

**Must contain** (in order):
1. Auto-regen warning (exact string, for validator detection):
   ```
   > ⚠️ This file is auto-regenerated on every git push.
   > Edit source files (Cargo.toml, package.json, flake.nix, etc.),
   > then push. The README will rebuild itself.
   ```

2. Generation timestamp (ISO8601 + timezone, coarse to minutes):
   ```
   > Generated: 2026-04-27T14:23+0000 (UTC)
   ```

3. ASCII art banner (project name, from a curated cache; 3-5 lines max)
4. Install one-liner (the most common way to use or build the project; under 80 chars)
5. Whimsical 3-line description (prose explaining the project's purpose in 3-4 sentences, tone friendly)

**What agents may add** (uncommon; for projects with special needs):
- Deployment instructions (if the project is deployed)
- Quick-start code snippet (if a 5-line example helps)
- Primary maintainer contact (if the project is user-facing)

## FOR ROBOTS Section

Starts with the exact H1 header: `# FOR ROBOTS`

**Must contain** (auto-derived or agent-curated, in H2 order):

1. `## Tech Stack` — concatenated output from applicable summarizers (Cargo.toml → languages, runtimes, frameworks; package.json → Node + npm/yarn; flake.nix → Nix + overlays; etc.).

2. `## Build/Runtime Dependencies` — concatenated output from applicable summarizers. Dependencies grouped as:
   - Build-time (compiler, build tools)
   - Runtime (libraries, frameworks required at execution)
   - Optional (optional dependencies, feature flags)

3. `## Security` — agent-curated. If omitted initially, the `/bootstrap-readme` skill inserts `TODO: Add security notes (authentication, data handling, threat model)`. Not auto-derived.

4. `## Architecture` — agent-curated. If omitted initially, the `/bootstrap-readme` skill inserts `TODO: Add architecture notes (structure, layers, major modules)`. Not auto-derived.

5. `## Privacy` — agent-curated. If omitted initially, the `/bootstrap-readme` skill inserts `TODO: Add privacy notes (data collection, storage, user consent)`. Not auto-derived.

6. `## Recent Changes` — concatenated output from `git log --oneline -N` (N configurable, default 10). Auto-derived; persists across regen.

7. `## OpenSpec — Open Items` — if `openspec list --json` succeeds, concatenated output. Otherwise, omitted silently.

8. `requires_cheatsheets:` — YAML block (see below).

## readme.traces JSONL Schema

Append-only ledger at `<project>/.tillandsias/readme.traces` (committed to git, cross-machine).

Each line is a JSON object:
```json
{
  "ts": "2026-04-27T14:23:45+0000",
  "agent": "bootstrap-readme",
  "observation": "Nix summarizer returned exit code 2 (manifest not found); skipping",
  "severity": "info"
}
```

**Fields**:
- `ts` (ISO8601): When the observation was made
- `agent` (string): Which skill/process created the entry (e.g., `bootstrap-readme`, `opencode-user`, `cilium-scan`)
- `observation` (string): Human-readable note (< 200 chars)
- `severity` (enum): `info` | `warn` | `regen-trigger`

**Retention**:
- File is append-only — dispatcher must NOT rewrite earlier lines
- Latest 50 lines fed back to next regen as context
- Observations help the agent understand previous runs and improve quality

**Regen-trigger rules**:
- A `severity: regen-trigger` line signals the next `/startup` to call `regenerate-readme.sh` even if the README currently passes validation
- Use case: manifest changed in a way the validator doesn't detect (e.g., new optional dependency, architecture refactored but no file structure changed)

## Summarizer Interface

Each language/framework gets a summarizer script (`summarize-<type>.sh`) under `/opt/summarizers/` in the forge image.

**Contract**:
```bash
summarize-cargo.sh [path-to-Cargo.toml]
```

**Behavior**:
- Arg 1: path to manifest (e.g., `/path/to/Cargo.toml`). If omitted, search current directory and up.
- Exit code 0: manifest found and parsed successfully
- Exit code >0: manifest not found or unparseable (2 = "skip", 1 = "error"). Validator distinguishes them.
- Stdout: Markdown under H3 headers (e.g., `### Languages`, `### Runtimes`). Each summarizer owns its H3s; the dispatcher concatenates them into `## Tech Stack` and `## Build/Runtime Dependencies` H2 containers.
- No color codes, no interactive output

**Example output** (summarize-cargo.sh):
```markdown
### Languages

- Rust (1.80.0+)

### Runtimes

- tokio 1.36

### Frameworks/Build Tools

- Tauri v2
- cargo-xwin (for Windows cross-compilation)
```

**Registry**:
- System summarizers live at `/opt/summarizers/` (forged in image)
- Project-local summarizers at `<project>/.tillandsias/summarizers/` (optional, loaded by dispatcher)
- Dispatcher walks both and invokes all

## Validator (`check-readme-discipline.sh`)

```bash
check-readme-discipline.sh [path-to-README.md]
```

**Checks** (in order):
1. File exists
2. `# FOR HUMANS` H1 present
3. `# FOR ROBOTS` H1 present
4. Auto-regen warning string present (exact match for validator scan)
5. Timestamp line parses as ISO8601
6. Timestamp ≤ 7 days old (WARN if older, not ERROR)
7. Seven H2 sections present under FOR ROBOTS (exact order not enforced, but all must exist)
8. `requires_cheatsheets:` YAML block present and well-formed

**Exit codes**:
- 0: README passes all checks
- 1: Structural error (missing header, malformed YAML, etc.)
- Non-zero: Some checks failed; see output lines

**Output** (one line per check, for human or agent action):
```
ERROR: Missing "# FOR HUMANS" header
WARN: README timestamp older than 7 days (generated 2026-04-20)
OK: Structure valid
```

## Dispatcher (`regenerate-readme.sh`)

```bash
regenerate-readme.sh [path-to-project]
```

**Algorithm**:
1. Walk to project root (stop at `.git/`, `.tillandsias/`)
2. Load previous `readme.traces` tail (if present)
3. For each summarizer (system + project-local), run and collect output
4. Load previous README.md; extract agent-curated `## Security`, `## Architecture`, `## Privacy` sections
5. Render FOR HUMANS (timestamp, banner, etc.)
6. Render FOR ROBOTS (Tech Stack, Dependencies, Security/Architecture/Privacy TODOs if missing, Recent Changes, OpenSpec, requires_cheatsheets)
7. Append entry to `readme.traces` (e.g., "Regenerated: 3 summarizers ran, 1 skipped")
8. Write README.md atomically
9. Exit 0

## requires_cheatsheets YAML Block

At the end of FOR ROBOTS:
```yaml
requires_cheatsheets:
  - path: "welcome/sample-prompts.md"
    tier: bundled
  - path: "runtime/forge-cache-dual.md"
    tier: distro-packaged
  - path: "runtime/agent-startup-skills.md"
    tier: bundled
```

**Schema**:
- `path`: Relative path under `cheatsheets/`
- `tier` (optional): bundled | distro-packaged | pull-on-demand | missing (if tier unknown)

**Consumption** (`/startup` and tools):
- For `bundled` or `distro-packaged`: assumed to exist on disk already
- For `pull-on-demand`: agent materializes via cheatsheet recipe system
- For `missing`: emit WARN and continue

## See also

- `welcome/sample-prompts.md` — curated prompts displayed in empty-project flow
- `agents/opencode.md` — OpenCode skill file convention used by `/startup`, `/bootstrap-readme-and-project`, `/bootstrap-readme`, `/status`
- `runtime/agent-startup-skills.md` — four skills and their routing matrix
