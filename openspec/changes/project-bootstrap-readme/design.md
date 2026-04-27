# Design — project-bootstrap-readme

## Context

### The agent-cold-start problem

When an in-forge agent (OpenCode, Claude Code, OpenSpec) attaches to a project for the first time in a fresh container, it has no priors. It cannot rely on session memory (the container is ephemeral per `forge-cache-dual`), it cannot see other projects (per the same isolation invariant), and the OpenCode session itself starts at message zero. The agent's first user-visible work happens after it has done all of:

1. Discovered what tools are on `$PATH` (per the `forge-opencode-onboarding` discovery sequence).
2. Read `$TILLANDSIAS_CHEATSHEETS/INDEX.md` to know what the forge knows.
3. Run `openspec list` to know what work is in flight.
4. Walked the project tree (`fd`/`rg`) to know what languages, frameworks, and patterns it is dealing with.
5. Parsed `flake.nix` / `Cargo.toml` / `pubspec.yaml` / `package.json` / `pyproject.toml` to know the actual dependency surface.
6. Asked the user "so, what are we doing today?" — the cold start has consumed the user's first prompt.

In observed Tillandsias sessions (and in the `~/src/java/ENVIRONMENT_REPORT.md` story that triggered the `forge-opencode-methodology-overhaul` change), step 1–5 routinely consumes 5–15 minutes of wall clock and ~30–80 KB of context window before the agent has produced any user-visible work. The `forge-opencode-onboarding` capability addressed step 1–3 by baking a discovery sequence into the OpenCode instructions. This change addresses step 4–5: a per-project bootstrap surface that is already loaded with the answers to "what is this project, what can I build it with, what is in flight."

### Why the README

The README is the obvious surface: every agent already reads it without being told to, every git hosting platform indexes it, every developer expects it. The problem is that human-written READMEs decay — they were correct at commit time, but `flake.nix` shipped a new dependency last week, the architecture migrated to event-driven last month, and the README still says "uses MySQL" because nobody updated it after the migration to Postgres. The convergence story (`source_of_truth_stack`, `convergence_philosophy`) is clear: if the README is to be trusted, it must be **derived from the manifests, not hand-written**, and must be **regenerated on every push** so its `Last generated` timestamp is never more than one commit old.

### Why CRDT-via-commit (not CRDT-via-merge)

A README that is auto-regenerated on every push from manifests is monotonic in commit history: every regen is a snapshot of project state at that commit. There is never a "merge" of two README states — the merger is the underlying manifests (`flake.nix` and friends), which already merge cleanly via git. The README is a projection, not an authority. This means:

- Hand edits to README are ignored (warned at commit time, regenerated on push). The header warning at the top of every README states this loudly.
- Multiple machines pushing to the same project regenerate independently; the second push regenerates against the merged manifest state.
- README history is the convergence trail: `git log -- README.md` shows every state the project has been in, including agent observations carried through `readme.traces`.

This is the same pattern as `feedback_no_hard_shadow_crdt` (CRDT override discipline): the file is a single replica that gets re-derived from a multi-replica source-of-truth (commit history + manifests + traces).

### Why structural-only validation, content-quality by agent

The validator (`scripts/check-readme-discipline.sh`) only checks that required sections **exist** — H1 headers, H2 headers, the auto-regen warning string, the YAML block under `requires_cheatsheets:`. It does not grade content quality. Content quality is the agent's job, informed by:

- `readme.traces` — past observations like "the JDK section was generic" or "the Recent Changes block missed the v0.1.169 work" feed forward into the next regen as context.
- Cheatsheet cache-hit-miss metrics — when an agent looks up a cheatsheet during regen and gets a `miss`, that signal feeds forward.
- The agent's own judgment after reading the manifests.

This split (structural by script, content by agent) is the same split as `agent-cheatsheets`: the validator confirms the frontmatter is well-formed, the agent decides whether the content is good. It avoids the trap of an over-strict validator rejecting valid edge cases, while keeping a single deterministic check that "the file at least has the bones in the right place."

### Stakeholders

| Stakeholder | What they need from this system |
|---|---|
| In-forge agents (primary) | A README that contains everything they need to start work on prompt 1 — runtime + build deps, security/architecture/privacy, recent commit summary, OpenSpec backlog summary. |
| AJ (the Average Joe end user, secondary) | The FOR HUMANS section: a banner, an install URL, a one-paragraph description, no jargon. Never sees FOR ROBOTS. |
| Host maintainers (tertiary) | A reproducible regen path (`scripts/regenerate-readme.sh`) they can invoke locally to validate without pushing; a structural validator that fails fast in CI. |
| Future agents on other machines (quaternary) | `readme.traces` carries forward what previous agents learned about the project; the next agent doesn't repeat the same discovery work. |

## Goals / Non-Goals

### Goals

- **Productive prompt 1.** An agent attaching to a project with a compliant README SHALL be able to act on the user's first prompt without first scanning the project. The README is sufficient context for ~90% of bootstrap questions.
- **Auto-regenerated on every push.** The pre-push hook regenerates the README so its `Last generated` line is never more than one commit out of date. If regen fails, the hook falls back to a timestamp-only commit (so the convergence trail is preserved).
- **Convergence via commit history.** The README's authority is the underlying manifests. Hand edits to README are ignored. The user prompts the agent instead.
- **Three skills, one entrypoint.** `/startup` routes; `/bootstrap-readme-and-project`, `/bootstrap-readme`, `/status` are the three branches. Each branch is a normal user-invokable command (the user can run any of them at any time).
- **Empty-project welcome.** Three curated sample prompts (read from a cheatsheet, editable without rebuild) showcase the breadth of what the forge can do, biased toward demonstrating the Flutter / Nix / Flame engine defaults that already exist in the methodology.
- **Telemetry foundation.** Every routing decision and every regen invocation emits a structured event into `cheatsheet-telemetry`'s `lookups.jsonl`, so the host can later prioritize which projects need README quality work.
- **`readme.traces` carries learning forward.** The JSONL trace ledger lets each regen build on the observations of the previous regen, monotonically improving README quality.

### Non-Goals

- **We do NOT build the user's project for them.** `/bootstrap-readme-and-project` welcomes and proposes; the agent builds whatever the user asks for. No automatic `flutter create` on first attach.
- **We do NOT replace the six-pillar source-of-truth stack** (per `feedback_source_of_truth_stack`). The README is one surface — a projection of `flake.nix` + `Cargo.toml` + git log + OpenSpec list + `readme.traces`. It is **not** the source of truth itself; it is a convergent view.
- **We do NOT support human README edits** as first-class. Humans MAY edit README in the working tree to test something locally, but the next regen overwrites it without asking, and the pre-push hook leaves no merge surface. The header warning makes this explicit.
- **We do NOT cross-share READMEs between projects.** Each project has its own; per-project isolation per `forge-cache-dual`.
- **We do NOT touch Claude Code or terminal entrypoints in v1.** Only `entrypoint-forge-opencode.sh`. Claude has its own skill mechanism; supporting it is a separate change.
- **We do NOT solve "the user committed README directly" gracefully in v1.** The next regen overwrites; the user learns once. v2 may add a pre-commit hook to refuse README-only edits.
- **We do NOT pre-generate sections we cannot derive.** `## Security`, `## Architecture`, `## Privacy` are agent-curated stubs marked `<!-- agent-curated -->`; the validator checks they exist, the agent fills them in over time.

## Decisions

### Decision 1 — Three (then four) skills, with `/startup` as the routing entrypoint

| Skill | Trigger | What it does | When the user might invoke it directly |
|---|---|---|---|
| `/startup` | OpenCode entrypoint shim writes `run /startup` as synthetic first user message | Detects project state, dispatches to one of the three branches, then prints a one-screen summary of what it found | Manually re-routing after switching branches in the same forge session |
| `/bootstrap-readme-and-project` | `/startup` dispatches when project is empty | Welcome banner, three sample prompts from `cheatsheets/welcome/sample-prompts.md`, forge capability summary, "what would you like to do?" | User wants the welcome screen again |
| `/bootstrap-readme` | `/startup` dispatches when project is non-empty AND validator fails | Explains the gap, runs `regenerate-readme.sh`, leaves agent-curated sections as `TODO:` stubs, prints the new state | User suspects README has drifted |
| `/status` | `/startup` dispatches when project is non-empty AND validator passes | `openspec list`; last 5 commits; last build's commit (if different); last 5 `readme.traces` entries; one suggested next action | User wants a "where are we" snapshot |

**Rationale.** Routing inside a single `/startup` skill — rather than at the entrypoint level (e.g., `if [empty]; then exec opencode -- /bootstrap-readme-and-project`) — means the dispatch logic is a markdown skill that can be edited without rebuilding the forge image. It also keeps the routing decision visible in the OpenCode session log (the agent thinks aloud about which branch to take, which is auditable and replayable). The three branch skills exist as standalone commands so the user can also invoke them directly — the routing is a convenience, not a gate.

**Alternative considered.** Single mega-skill `/startup` that does everything inline. Rejected because (a) the four flows are semantically distinct and have different output shapes, (b) users may want to re-run a single branch ("show me status again"), and (c) markdown skills compose poorly when they're 200+ lines.

**Alternative considered.** Make routing a pre-OpenCode bash decision (entrypoint runs `regenerate-readme.sh` and `check-readme-discipline.sh` itself, sets `OPENCODE_FIRST_PROMPT` accordingly). Rejected because (a) it hides the routing decision from the OpenCode session — no chain of thought trace of why this branch was taken — and (b) it couples the routing to the entrypoint shell, making a future Claude or terminal version harder.

### Decision 2 — OpenCode entrypoint shim mechanism

The forge entrypoint (`images/default/entrypoint-forge-opencode.sh`) gains a block, just before the final `exec "$OC_BIN" "$@"`, that writes a synthetic first user message to OpenCode's session-bootstrap path. The exact mechanism depends on OpenCode's session-startup hook:

- Preferred: write to `~/.config/opencode/auto-prompt.md` (or whatever path OpenCode reads for an auto-injected first turn). This is a known OpenCode convention used by other tools.
- Fallback: pipe the prompt as stdin to a non-interactive `opencode --auto-prompt "/startup"` invocation, then `exec` the interactive session.

The shim writes one line: `/startup` (no newline issues — slash commands are single-token).

**Rationale.** Doing this as a synthetic first message — rather than e.g. an OpenCode CLI flag — preserves CRDT discipline: the agent's chain of thought for the routing decision is a normal session turn, recorded in the OpenCode session log alongside everything else. When the user later asks "why did you start with /status?", the answer is visible in the transcript. It also survives OpenCode upgrades: the synthetic message is just text in a file, not a CLI flag that OpenCode might rename in v2.

**Alternative considered.** Bake `/startup` into the `default_agent` in `config.json` (set the default agent's first system message to "you must run /startup first"). Rejected because (a) it conflates two surfaces (system prompt vs auto-prompt), (b) it's harder to skip when the user wants to (they'd have to edit config.json), and (c) it's invisible in the session log unless OpenCode explicitly surfaces system prompts.

### Decision 3 — README structure

The exact skeleton emitted by `regenerate-readme.sh`:

```markdown
<!-- This file is auto re-generated, changes are ignored. Simply prompt away instead. -->
<!-- @trace spec:project-bootstrap-readme @cheatsheet welcome/readme-discipline.md -->

# FOR HUMANS

_Last generated: 2026-04-26 14:23 UTC-0700_

```
   _____  _ _ _              _           _
  |_   _|(_) | | __ _ _ __  | |_ ___    (_) __ _ ___
    | |  | | | |/ _` | '_ \ | __/ __|   | |/ _` / __|
    | |  | | | | (_| | | | || |__\__ \  | | (_| \__ \
    |_|  |_|_|_|\__,_|_| |_| \__|___/  |_|\__,_|___/
```

Tillandsias keeps your dev environments invisibly safe — like air plants
that bloom on the wall and ask nothing of you.

**Try it:** `curl -fsSL https://tillandsias.dev/install.sh | sh`
**Releases:** <https://github.com/8007342/tillandsias/releases>

# FOR ROBOTS

## Tech Stack

(auto-derived by `summarize-cargo.sh` + `summarize-nix.sh`)

- Rust 1.86, Tauri v2 (system-tray binary)
- Nix flakes for forge image builds
- TOML config (`postcard` for IPC; no JSON in hot paths)

## Build Dependencies

(auto-derived by `summarize-cargo.sh` + `summarize-nix.sh` from `[build-dependencies]` and devShell)

- `cargo`, `rustc` 1.86+
- `nix` 2.18+, `podman` 4.0+, `toolbox` (Silverblue only)
- System: `gtk3-devel`, `webkit2gtk4.1-devel`, `libappindicator-gtk3-devel`

## Runtime Dependencies

(auto-derived from `[dependencies]` and Containerfile RUN lines)

- `podman` 4.0+ at runtime, host keyring (Linux: Secret Service via D-Bus)
- Forge container ships its own toolchain; host needs only podman

## Security

<!-- agent-curated -->
- Forge containers are credential-free (`--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`).
- Host keyring is the only secret store; D-Bus bridge to git-service.
- Proxy domain allowlist gates all enclave egress.

## Architecture

<!-- agent-curated -->
- Multi-container enclave: tray (host) + proxy + git-service + forge + inference.
- Event-driven (`notify`, `podman events`), never polling.

## Privacy

<!-- agent-curated -->
- All inference local (ollama in inference container).
- No telemetry leaves the host.

## Recent Changes

(auto-derived from `git log --oneline -10` and last build's commit)

- 2026-04-26 `61db7f1` archive 10 OpenSpec changes + sync specs to v0.1.170
- 2026-04-26 `e89184f` add cheatsheets/utils/tar.md
- ...

## OpenSpec — Open Items

(auto-derived from `openspec list`)

- `cheatsheet-methodology-evolution` — proposal
- `cheatsheets-license-tiered` — design + specs
- ...

```yaml
requires_cheatsheets:
  - languages/rust.md
  - build/cargo.md
  - build/nix-flake-basics.md
  - runtime/forge-container.md
  - welcome/readme-discipline.md
```
```

Required structural elements (validator-enforced):

| Element | Required by validator | Auto-derived | Agent-curated |
|---|---|---|---|
| Auto-regen warning HTML comment (line 1) | YES | YES | NO |
| `# FOR HUMANS` H1 | YES | YES (regenerator emits) | NO |
| `_Last generated:_` line with timestamp + tz | YES | YES | NO |
| ASCII-art project banner | YES (presence; not content) | YES (initial); agent may regenerate variants | partially — variant prose |
| Install one-liner OR releases URL | YES (one of) | partial — derived from VERSION + repo URL when possible | YES — agent may add curl |
| Whimsical one-paragraph description | YES (presence) | NO | YES |
| `# FOR ROBOTS` H1 | YES | YES | NO |
| `## Tech Stack` H2 | YES | YES | NO (auto-derived only) |
| `## Build Dependencies` H2 | YES | YES | NO (auto-derived only) |
| `## Runtime Dependencies` H2 | YES | YES | NO (auto-derived only) |
| `## Security` H2 | YES | NO | YES |
| `## Architecture` H2 | YES | NO | YES |
| `## Privacy` H2 | YES | NO | YES |
| `## Recent Changes` H2 | YES | YES | NO (auto-derived only) |
| `## OpenSpec — Open Items` H2 | YES | YES | NO (auto-derived only) |
| `requires_cheatsheets:` YAML block | YES (presence; YAML parseable) | partial — initial seed; agent updates over time | YES — agent decides which cheatsheets are required |

**Rationale.** Two H1s (`# FOR HUMANS`, `# FOR ROBOTS`) violate the "one H1 per document" markdown convention, but they are deliberate: the two sections are functionally separate documents that happen to share a file. Most markdown renderers (GitHub, GitLab, mdbook) handle this fine. The visual size difference between H1 and H2 makes the structure obvious to a human scanning. The user explicitly asked for "large header" + "similarly sized title."

**Alternative considered.** Single H1 (project name) with `## FOR HUMANS` and `## FOR ROBOTS`. Rejected because (a) the user's direction was specific about "large headers" for both sections, (b) the FOR ROBOTS section already has H2 subsections (Tech Stack, etc.) and demoting it to H2 means the subsections become H3, which renders too small to scan.

**Alternative considered.** Separate files (`README.md` for humans, `AGENTS.md` for robots). Rejected because (a) GitHub treats README.md specially (front-page rendering), and we want both surfaces in the user's first-glance file, and (b) agents are trained to read README first; making them open a second file is friction we control by not creating it.

### Decision 4 — Per-language summarizer interface

Each summarizer SHALL be an executable script (bash by default; any interpreter the forge ships is fine) under `images/default/summarizers/<name>.sh`. The contract:

```
Usage: summarize-<lang>.sh <project-root>

Behavior:
  1. Detect whether the project uses this language. The detection rule is per-summarizer:
     - summarize-cargo.sh: exists Cargo.toml at project root or any workspace member
     - summarize-nix.sh:   exists flake.nix at project root
     - summarize-package-json.sh: exists package.json at project root
     - summarize-pubspec.sh: exists pubspec.yaml at project root
     - summarize-go-mod.sh: exists go.mod at project root
     - summarize-pyproject.sh: exists pyproject.toml at project root

  2. If detected, read the manifest(s) and write markdown to stdout in this shape:
     ## (skipped — caller adds the section header)
     ### <SubsectionLabel> (e.g., "Cargo")
     - Brief, scannable bullets. Pin versions where possible. Group by category
       (build vs runtime vs dev) if the manifest distinguishes.

  3. Exit code:
       0 if detected (whether or not the manifest had useful content)
       64 if not detected (this language is not used in the project)
       1+ on error (manifest exists but is malformed); stderr explains

Example invocation by dispatcher:
   for s in /opt/summarizers/*.sh ~/.tillandsias/summarizers/*.sh; do
     [ -x "$s" ] || continue
     out="$($s "$PROJECT_ROOT" 2>/tmp/summarizer-err)" && echo "$out"
   done
```

**Project-local summarizers** at `<project>/.tillandsias/summarizers/*.sh` are executed by the dispatcher AFTER the bundled summarizers (so a project can override a bundled one by exiting 64 from the bundled and emitting its own from the project-local). The user must `chmod +x` the project-local script and commit it; the dispatcher trusts what's in the project tree (the supply-chain risk is the project owner's, not the forge's, since project-local scripts only run when an agent in the project's forge invokes the dispatcher).

**Initial six summarizers** (each ≤ 80 lines of bash):

| Summarizer | Manifest(s) it reads | Cheatsheet authority |
|---|---|---|
| `summarize-cargo.sh` | `Cargo.toml`, optionally `Cargo.lock` for pinned versions | `cheatsheets/build/cargo.md` |
| `summarize-nix.sh` | `flake.nix`, optionally `flake.lock` | `cheatsheets/build/nix-flake-basics.md` |
| `summarize-package-json.sh` | `package.json`, optionally `package-lock.json` / `pnpm-lock.yaml` / `yarn.lock` | `cheatsheets/build/npm.md` |
| `summarize-pubspec.sh` | `pubspec.yaml`, optionally `pubspec.lock` | `cheatsheets/build/flutter.md` |
| `summarize-go-mod.sh` | `go.mod`, optionally `go.sum` | `cheatsheets/build/go.md` |
| `summarize-pyproject.sh` | `pyproject.toml`, optionally `uv.lock` / `poetry.lock` | `cheatsheets/build/uv.md` + `cheatsheets/build/poetry.md` |

**Rationale.** Bash + the dependency-of-the-dependency-manager (e.g., `cargo metadata`, `nix flake show`) is good enough; no new heavy tooling. Exit code 64 (the conventional "command line usage error" code in `sysexits.h`, but reused here as "not applicable") signals "not detected" without ambiguity — vs 0 ("detected, here's output") or 1+ ("detected, but error"). Project-local extension means a Java/Maven project can ship `summarize-pom-xml.sh` without needing to land it in the forge image. Each summarizer cites its authoritative cheatsheet via `# @cheatsheet build/<tool>.md` near the top, so the cheatsheet → summarizer → README chain is queryable.

**Alternative considered.** A single Python script with a registry of language detectors. Rejected because (a) it forces Python in the dispatch chain (we already have bash), (b) it makes per-project extension harder (the user would have to extend a Python registry), and (c) bash scripts are easier to copy-paste-tweak when a new language emerges.

### Decision 5 — `regenerate-readme.sh` dispatcher

```
/usr/local/bin/regenerate-readme.sh <project-root>

1. Acquire flock on <project-root>/.tillandsias/regenerate.lock (refuse second concurrent run).
2. Read existing README.md if present, parse out agent-curated sections (any section
   between H2 markers that contains the `<!-- agent-curated -->` marker on the line
   immediately after the H2). Preserve them verbatim.
3. Read latest 50 lines of <project-root>/.tillandsias/readme.traces (if exists);
   stash as feedforward context (printed to stderr at INFO level for the agent
   running this script to see).
4. Run every summarizer in /opt/summarizers/*.sh and <project-root>/.tillandsias/summarizers/*.sh.
   Concatenate stdout under ## Tech Stack and ## Build/Runtime Dependencies.
5. Run `git log --oneline -10`. Format under ## Recent Changes.
6. Run `openspec list 2>/dev/null` (best-effort). Format under ## OpenSpec — Open Items.
7. Generate ASCII-art banner via `figlet -f standard "<project-name>"` (figlet baked into forge).
   Pick a font deterministically from the commit hash so the banner mutates over time
   but is reproducible per commit.
8. Compute timestamp via `date "+%Y-%m-%d %H:%M %Z"` (coarse to minutes, includes timezone).
9. Compose README from the template, substituting all auto-derived sections AND
   preserving the agent-curated sections from step 2.
10. Atomic write: tempfile + rename.
11. Emit one cheatsheet-telemetry event:
    {ts, project, cheatsheet="welcome/readme-discipline.md", event="readme-regen",
     resolved_via="auto", chars_written=<N>, summarizers_invoked=<list>,
     spec="project-bootstrap-readme", accountability=true}
12. Exit 0.
```

**Failure modes**:

- A summarizer exits 1+: log the stderr to `readme.traces` as `severity: warn`, omit its section, continue.
- All summarizers exit 64 (no detected language): emit a single `### Language` placeholder under Tech Stack saying "no language manifest detected — agent should curate this section".
- `git log` fails (not a git repo): omit `## Recent Changes`, log to traces.
- `openspec list` fails or is absent: omit `## OpenSpec — Open Items`, log to traces.
- `figlet` missing: fallback to a plain `# <project-name>` heading inside the code fence.

**Rationale.** Best-effort, never blocks. The header warning + the validator catch any missing structural element; the dispatcher's job is to emit as much as it can deterministically. The flock prevents concurrent regen during a fast push from corrupting the file. Steps 2 (preserve agent-curated) and 3 (feedforward traces) are the parts that make this monotonically converging, not just a fresh re-emit each time.

### Decision 6 — `readme.traces` JSONL schema

```jsonl
{"ts":"2026-04-26T14:23:00-07:00","agent":"opencode/big-pickle","observation":"summarize-cargo.sh missed the [build-dependencies] section because the workspace member's manifest is at crates/tillandsias-podman/Cargo.toml not the root","severity":"warn","triggered_by":"regen"}
{"ts":"2026-04-26T14:24:11-07:00","agent":"opencode/big-pickle","observation":"agent-curated ## Architecture section was 4 days stale relative to the migration to event-driven podman events; refreshed","severity":"info","triggered_by":"agent-curated-update"}
{"ts":"2026-04-26T14:25:01-07:00","agent":"opencode/big-pickle","observation":"requires_cheatsheets pulled welcome/readme-discipline.md as a stub; first time this project has needed it","severity":"info","triggered_by":"requires_cheatsheets-resolution"}
```

| Field | Type | Notes |
|---|---|---|
| `ts` | ISO 8601 with TZ | Append-only ordering key |
| `agent` | string | e.g., `opencode/big-pickle`, `claude/sonnet-4.5`, `regen-script` |
| `observation` | string | Free-form, single line, what happened or what the agent learned |
| `severity` | enum | `info`, `warn`, `regen-trigger` |
| `triggered_by` | enum | `regen` (script-driven), `agent-curated-update` (agent ran an update), `requires_cheatsheets-resolution` (cheatsheet stub pulled), `validator-warn` (check-readme-discipline.sh emitted a warning) |

**Append-only**: never edited or truncated. If size becomes a concern, the auditor MAY rotate (truncate to newest 50%) per the same convention as `external-logs-layer`'s in-place rotation; rotation event is itself logged.

**Feedforward**: the dispatcher reads the latest 50 entries and prints them to stderr at INFO level so the agent driving the regen sees them. The agent then has context about what previous regens noticed — including its own past observations from previous sessions.

**Committed to git**: yes. The trace ledger is per-project state and travels with the project across machines. The signal-to-noise is high (one entry per regen; agent observations are sparse and high-value).

**Rationale.** JSONL because it's the simplest append-only structured format, queryable with `jq -c`, and matches the existing `cheatsheet-telemetry` `lookups.jsonl` schema. Severity is intentionally three-valued (not the full RFC 5424 set) — the consumers are agents, not log analyzers. Committing to git means cross-machine continuity (matches `feedback_dual_cache_architecture` per-project semantics), and the file size is bounded in practice (one entry per push, typical project sees < 100 entries/year).

### Decision 7 — Pre-push hook installation and contract

Hook path: `<project>/.git/hooks/pre-push` (standard git hook location).

Hook content (idempotent re-installation; the installer compares against a known SHA and re-installs if different):

```bash
#!/usr/bin/env bash
# tillandsias pre-push hook (project-bootstrap-readme)
# @trace spec:project-bootstrap-readme @cheatsheet welcome/readme-discipline.md
set -e
PROJECT_ROOT="$(git rev-parse --show-toplevel)"
if command -v regenerate-readme.sh >/dev/null 2>&1; then
  if regenerate-readme.sh "$PROJECT_ROOT" 2>>"$PROJECT_ROOT/.tillandsias/regenerate.log"; then
    if ! git diff --quiet README.md; then
      git add README.md
      git commit --no-edit -m "chore(readme): regenerate at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    fi
  else
    # Fallback: bump only the timestamp in README.md so the convergence trail is preserved.
    if [ -f "$PROJECT_ROOT/README.md" ]; then
      sed -i.bak -E "s/^_Last generated: .*/_Last generated: $(date -u +'%Y-%m-%d %H:%M %Z')_/" "$PROJECT_ROOT/README.md"
      rm -f "$PROJECT_ROOT/README.md.bak"
      if ! git diff --quiet README.md; then
        git add README.md
        git commit --no-edit -m "chore(readme): timestamp-only regen (regenerator failed; see .tillandsias/regenerate.log)"
      fi
    fi
  fi
fi
exit 0  # never block the push
```

**Installation timing**: `/startup` checks for the hook on every invocation. If missing OR if its SHA differs from the canonical one (`scripts/install-pre-push-hook.sh` baked into the forge image computes and compares the SHA), `/startup` reinstalls. Idempotent.

**Why never block the push**: the hook is best-effort. The user's push must succeed even if regen fails; the failure is logged to `regenerate.log` and surfaced via the timestamp-only fallback so the convergence trail is preserved. A blocking hook would surprise users at the worst time (right when they want to publish work).

**`--no-verify` escape hatch**: standard git semantics; the user can bypass by `git push --no-verify`. We do not detect or warn on bypass — it's an opt-out the user explicitly chose.

**Rationale.** Pre-push (not pre-commit) because (a) commits are local and frequent during work, regen would slow them down, (b) regen needs a final view of state including the latest commit, (c) push is the natural "publish" boundary where it makes sense to have a fresh README. Idempotent re-installation means we can iterate on the hook content without manual cleanup. The `regenerate.log` capture lets us debug failed regens after the fact.

**Alternative considered.** Server-side hook (post-receive on the git-mirror service that regenerates and force-pushes back). Rejected because (a) it requires the git service to have the summarizers + dispatcher, doubling the surface area, (b) force-pushing back is a UX gotcha, and (c) the regen wants the same forge environment the user is in (project-specific summarizers, language detection from manifests).

### Decision 8 — Sample prompts cheatsheet

`cheatsheets/welcome/sample-prompts.md` ships as a `tier: bundled` cheatsheet (per `cheatsheets-license-tiered`). It carries a `## Sample Prompts` H2 section containing a markdown list. The format inside the list:

```markdown
## Sample Prompts

> Curated prompts that showcase what an in-forge agent + ollama + the bundled
> Flutter / Nix / Flame defaults can do from cold start. The user's empty-project
> welcome screen displays the first three (or three random ones — see "Selection").

- **Build a Pong web app.** "Build me a single-page web Pong game using Flutter web and the Flame engine, with WASD vs arrow-keys two-player local play and a simple scoreboard."
- **Inventory for my business.** "Help me build an inventory app for my small business — items have a name, photo, quantity, and a 'reorder when below' threshold. Local-first, sqlite backend, Flutter UI."
- **Calculus tutor.** "Design a single-page web app that helps me understand derivatives — interactive graph, drag the function, see the derivative graph update live."
- **Roguelike weekend.** "Make me a tiny roguelike in Flutter + Flame: 20×20 grid, one player @, three monsters M, walls #, food F, hjkl movement."
- **Knowledge garden.** "I want a markdown wiki I run locally — files in a folder, a Flutter web frontend that renders them with hyperlinks between [[notes]]."
- **My day in three numbers.** "Build me an app where I log three numbers a day (mood, sleep hours, focus minutes) and it shows me a 30-day trend graph."

### Selection

The empty-project welcome flow displays the **first three** by default. The agent
MAY randomize selection if `RANDOM` is desired (`shuf -n 3` on the markdown list);
the user's direction was for "at least three, generic and significantly different
in domain." Three is a minimum; the cheatsheet may grow.

### Rationale per prompt

Each prompt was chosen to:
- Show a different domain (game / business / education / personal-tracking).
- Land cleanly on the methodology defaults (Flutter web, Flame for games, sqlite
  for storage, Nix for reproducibility) so a competent in-forge agent can
  converge a spec + implementation without external help.
- Be expressible in one sentence by AJ (the non-technical primary user).
```

**Rationale.** Putting sample prompts in a cheatsheet (rather than embedding them in the skill markdown) means: (a) the prompts can be edited without rebuilding the forge image — they go through the cheatsheet refresh path, (b) the cheatsheet's `last_verified` discipline applies (we re-evaluate every 90 days whether the prompts still showcase current capabilities), (c) the prompts are discoverable via the same `INDEX.md` path agents already know, (d) the cheatsheet → skill citation creates a `@cheatsheet welcome/sample-prompts.md` line in `bootstrap-readme-and-project.md`, making the dependency queryable.

### Decision 9 — README `requires_cheatsheets:` consumer

The YAML block under FOR ROBOTS lists per-project required cheatsheets. The `/startup` skill, after running the validator, parses this block and:

1. For each declared cheatsheet `<category>/<file>.md`, look up its tier via the existing `cheatsheets-license-tiered` tier classifier (host-side `cheatsheets/license-allowlist.toml`).
2. If `tier: bundled` AND present in `/opt/cheatsheets/`: ✓ hit. Continue.
3. If `tier: distro-packaged` AND `local:` path exists in image: ✓ hit. Continue.
4. If `tier: pull-on-demand` AND not already materialized: invoke the cheatsheet's `## Pull on Demand` recipe (per `cheatsheets-license-tiered`), materialize into `~/.cache/tillandsias/cheatsheets-pulled/<project>/...`. Emit a `cheatsheet-telemetry` event with `event = "readme-requires-pull"`, `triggered_by = "readme-requires_cheatsheets"`.
5. If the cheatsheet name is NOT present in `cheatsheets/license-allowlist.toml`'s known set AND no matching cheatsheet file exists anywhere: emit `WARN: README requires cheatsheet '<name>' but it is missing AND off-allowlist; consider adding it to license-allowlist.toml`. Continue. Do not block.

**Rationale.** Zero new infrastructure: the README simply declares its cheatsheet dependencies, and the existing tiering surface resolves them. The pull-on-demand path is the same one a hand-driven agent would invoke; making it README-driven means the cheatsheet ecosystem grows by README declarations, which are a natural place for "this project needs X" signals.

**Allowlist convergence**: the user's note about "as long as it's in our allowlisted domainlists then it should be retrievable" is the load-bearing constraint here — we do not auto-pull from arbitrary domains. The allowlist gates retrieval; off-allowlist references emit WARN so the user can promote the domain if they want.

### Decision 10 — `/status` skill behavior

Output is a single screen (≤ 30 lines), in this order:

```
[startup-routing] non-empty + good README → /status

## Project: tillandsias  (linux-next branch, last commit 61db7f1 2h ago)

### OpenSpec — open
- cheatsheet-methodology-evolution         proposal
- cheatsheets-license-tiered               design + specs (3 specs)
- forge-opencode-methodology-overhaul      tasks (4/12 done)

### Last 5 commits
61db7f1  archive 10 OpenSpec changes + sync specs to v0.1.170
e89184f  add cheatsheets/utils/tar.md
88da8e1  fix: bash/zsh maintenance terminals get welcome banner
74962c4  fix: tar+exclude source copy → 47 GB to ~17 MB
163e279  fix: launch browser at project URL + ship en_US.UTF-8 locale

### Last build's commit
0.1.169.226 → 0.1.170.0 (61db7f1, identical to HEAD)

### Recent README observations (last 5)
[2026-04-26 14:23 warn] summarize-cargo.sh missed [build-dependencies]
[2026-04-26 14:24 info] agent-curated ## Architecture refreshed
[2026-04-25 09:11 info] requires_cheatsheets pulled welcome/readme-discipline.md
[2026-04-24 18:02 info] regen produced clean output
[2026-04-24 11:38 info] regen produced clean output

### Suggested next action
→ Continue forge-opencode-methodology-overhaul: 4 of 12 tasks done.
   Run /opsx:apply forge-opencode-methodology-overhaul to resume.
```

**Suggested next action heuristic** (deterministic; no LLM call needed):

1. If any OpenSpec change has `tasks: in-progress`, suggest resuming it (oldest in-progress first).
2. Else if any OpenSpec change has `proposal: complete, design: missing`, suggest creating design.
3. Else if any OpenSpec change has `design: complete, specs: missing`, suggest creating specs.
4. Else if `git log` shows uncommitted work in `git status`, suggest committing.
5. Else: "ready for new work — what would you like to do?"

**Rationale.** Single-screen output is the load-bearing constraint — `/status` should be glanceable, not exhaustive. A deterministic heuristic for the suggested action means `/status` is fast (no LLM round-trip for the common case) and predictable (the user can rely on its judgment to be the same on consecutive invocations). The five-section structure mirrors the FOR ROBOTS section of README — same shape, same scan order.

### Decision 11 — Empty-project detection

Heuristic, applied by `/startup`:

```bash
is_empty_project() {
  local root="$1"
  cd "$root" || return 1
  local tracked file_count
  tracked="$(git ls-files 2>/dev/null | wc -l)"
  file_count="$(find . -mindepth 1 -maxdepth 2 -not -path './.git*' -not -path './.tillandsias*' | wc -l)"
  # Empty if: ≤3 tracked files (allows .gitignore + LICENSE + .gitkeep) AND no README.md
  if [ "$tracked" -le 3 ] && [ ! -f README.md ]; then
    return 0
  fi
  return 1
}
```

**Rationale.** `≤ 3 tracked files` because a freshly `git init`'d project that the user wants to populate often has just `.gitignore` + `LICENSE` + a `.gitkeep` or initial commit message. Requiring `no README.md` is the deciding signal — the moment the user (or an agent) has authored a README, the project is no longer "empty" in the bootstrap sense.

**Alternative considered.** Detect emptiness from absence of language manifests (no `Cargo.toml`, `package.json`, etc.). Rejected because (a) a project with a `flake.nix` but no source is still empty in the bootstrap sense, (b) the user might have committed a README first, language manifests later — we'd miss that.

### Decision 12 — README compliance check (validator contract)

`scripts/check-readme-discipline.sh` exits non-zero if any of these is missing/malformed:

| Check | Severity | What it does |
|---|---|---|
| File `README.md` exists at project root | ERROR | `[[ -f README.md ]]` |
| Line 1 is the auto-regen warning HTML comment | ERROR | exact-string match against `<!-- This file is auto re-generated, changes are ignored. Simply prompt away instead. -->` |
| `# FOR HUMANS` H1 present | ERROR | grep `^# FOR HUMANS$` |
| `_Last generated:_` line present and parseable as a date | ERROR | grep `^_Last generated: ` and `date -d "$(parse)"` |
| ASCII-art or fallback banner present (any code fence under FOR HUMANS) | ERROR | grep `^```` between `# FOR HUMANS` and `# FOR ROBOTS` |
| Whimsical description present (any prose paragraph under FOR HUMANS, not in a code fence) | WARN | non-empty paragraph between banner and FOR ROBOTS |
| `# FOR ROBOTS` H1 present | ERROR | grep `^# FOR ROBOTS$` |
| `## Tech Stack` H2 present under FOR ROBOTS | ERROR | grep |
| `## Build Dependencies` H2 present | ERROR | grep |
| `## Runtime Dependencies` H2 present | ERROR | grep |
| `## Security` H2 present | ERROR | grep |
| `## Architecture` H2 present | ERROR | grep |
| `## Privacy` H2 present | ERROR | grep |
| `## Recent Changes` H2 present | WARN | grep (warn because a fresh project may have no commits) |
| `## OpenSpec — Open Items` H2 present | WARN | grep (warn because OpenSpec may not be initialized yet) |
| `requires_cheatsheets:` YAML block present and parseable | WARN | parseable via `yq` (forge ships it) |
| Timestamp within last 7 days | WARN | `date -d "$(parsed)"` vs `date -u`; > 7 days = WARN |

**Output**: one line per check that did not pass, prefixed with `ERROR:` or `WARN:`. Final summary line: `<N> error(s), <M> warning(s)`. Exit code: number of errors (capped at 255).

**Rationale.** Errors are structural; warnings are content-quality. A README with all errors fixed but several warnings is still valid (`/startup` routes to `/status`); a README with any error is treated as "non-compliant" and routes to `/bootstrap-readme`. The check is fast (< 100ms typical) and deterministic. The `yq` dependency is already in the forge image (per `cheatsheets/utils/yq.md`).

### Decision 13 — Telemetry hooks

Three telemetry events join the existing `cheatsheet-telemetry` `lookups.jsonl` stream:

```jsonl
{"ts":"...","project":"my-app","cheatsheet":"welcome/readme-discipline.md","query":"startup-routing","resolved_via":"empty","event":"startup-routing","accountability":true,"spec":"project-bootstrap-readme"}
{"ts":"...","project":"my-app","cheatsheet":"welcome/readme-discipline.md","query":"readme-regen","resolved_via":"auto","event":"readme-regen","summarizers_invoked":["cargo","nix"],"chars_written":3421,"accountability":true,"spec":"project-bootstrap-readme"}
{"ts":"...","project":"my-app","cheatsheet":"welcome/sample-prompts.md","query":"empty-project welcome","resolved_via":"bundled","chars_consumed":1432,"event":"lookup","accountability":true,"spec":"project-bootstrap-readme"}
```

The events ride on the existing `cheatsheet-telemetry` EXTERNAL-tier producer infrastructure (per `cheatsheets-license-tiered` Requirement "cheatsheet-telemetry EXTERNAL log producer"). No new producer role, no new manifest.

**Rationale.** Reusing `cheatsheet-telemetry` rather than introducing a `readme-telemetry` producer means: (a) zero new infrastructure, (b) a single query path for "what did agents look up during this session" that includes README events, (c) the `cheatsheet-telemetry-analytics` v2 follow-up automatically picks up README events without separate handling.

## Risks / Trade-offs

| Risk | Mitigation |
|---|---|
| One extra commit per push clutters `git log` | Use `--no-edit` and a minimal subject line (`chore(readme): regenerate at <ts>`); convention to squash consecutive auto-regen commits during code review. The signal-to-noise stays high because regen commits are easily filterable (`git log --grep '^chore(readme):'`). |
| Pre-push hook fails and blocks the user's push | The hook always exits 0; failures fall through to a timestamp-only commit. The user's push always succeeds. Failures land in `<project>/.tillandsias/regenerate.log` for later debugging. |
| Project-local summarizer scripts as a supply-chain risk | Project-local summarizers live in the project's own git tree (`<project>/.tillandsias/summarizers/`), are version-controlled by the project owner, and only execute inside the project's own forge container (per `forge-cache-dual` isolation). The risk is the project owner's, not the forge's. |
| Summarizer drift if a tool changes its manifest format | Each summarizer cites its authoritative cheatsheet (`# @cheatsheet build/<tool>.md`); when the tool ships a breaking change, the cheatsheet is updated, which in turn flags the summarizer for refresh. The fingerprint-staleness warning on cheatsheets is the early-warning signal. |
| Humans accidentally edit README anyway | Header warning at line 1 is loud and explicit. The next regen overwrites without asking. v2 may add a pre-commit hook that refuses commits modifying only `README.md` (with `--no-verify` escape hatch). |
| `/startup` skill changes require a forge image rebuild | Skills are markdown files (≤ 100 lines each); image rebuild is fast (~ 2 min) and the forge bake-cache (per `forge-bake-nix`) keeps re-bakes incremental. Hot-reload of skills inside a running forge is out of scope. |
| Empty-project sample prompts become stale | The cheatsheet's 90-day staleness check (`agent-cheatsheets`) catches it; refresh is a one-cheatsheet edit. The structural-drift fingerprint applies trivially because the cheatsheet is bundled (`tier: bundled`). |
| The synthetic-first-prompt shim breaks on OpenCode upgrades | The shim writes to a known auto-prompt file; if OpenCode renames it, the shim falls back to a non-interactive `opencode --auto-prompt "/startup"` invocation. The fallback path is documented in the `default-image` spec delta. |
| `readme.traces` grows unbounded across years | Soft auditor rotation (truncate to newest 50%) per the same convention as `external-logs-layer`. Practical growth rate is ~1 entry per push, ~100 entries/year for an active project — well within reasonable bounds. |
| Agent-curated sections (`## Security`, `## Architecture`, `## Privacy`) drift silently | The validator requires presence, not freshness. The `readme.traces` ledger captures observations like "## Architecture is 4 days stale" via agent self-judgment during regen. v2 may add a per-section staleness warning based on git history of changed code paths. |
| `requires_cheatsheets:` references a typo'd cheatsheet | The validator parses the YAML; the consumer in `/startup` looks up each name; off-allowlist + missing names emit WARN with the typo'd name. The user sees the WARN and corrects on the next regen. |
| Two H1s (`# FOR HUMANS`, `# FOR ROBOTS`) confuse some markdown linters | Document in `cheatsheets/welcome/readme-discipline.md` that this is intentional; markdownlint can be configured to allow it (`MD025` rule disabled for README.md). GitHub renders both H1s correctly. |
| The user wants to override an entire FOR ROBOTS section permanently | Project-local override: the user can author `<project>/.tillandsias/readme-overrides.md` with section-by-section overrides; the dispatcher reads this and substitutes after auto-derivation. v1 ships without this; v2 adds it if demand emerges. (Out of scope; documented as future work.) |

## Migration Plan

### Phase 0 — This change (project-bootstrap-readme + project-summarizers)

1. Author `cheatsheets/welcome/readme-discipline.md` and `cheatsheets/welcome/sample-prompts.md` (both `tier: bundled`).
2. Author the four skill markdown files under `images/default/config-overlay/opencode/agent/`.
3. Author the six summarizer scripts under `images/default/summarizers/`.
4. Author `scripts/regenerate-readme.sh`, `scripts/check-readme-discipline.sh`, `scripts/install-pre-push-hook.sh` (all baked into `/usr/local/bin/` at image build time).
5. Extend `images/default/entrypoint-forge-opencode.sh` with the synthetic-first-prompt shim block.
6. Extend `flake.nix` `contents` to include the new files (per `feedback_embedded_image_sources`).
7. Add `cheatsheets/welcome/` as a recognized category in `cheatsheets/INDEX.md` regeneration.
8. Bump VERSION (`./scripts/bump-version.sh --bump-changes`).
9. Build forge image, smoke-test on Tillandsias itself.

### Phase 1 — Tillandsias self-application

1. Run `/bootstrap-readme` against Tillandsias (the project itself). Generate the first compliant README.md at the repo root. Commit.
2. Confirm the validator passes. Confirm the pre-push hook installs and runs cleanly on the next push.
3. Inspect the auto-derived sections: do `summarize-cargo.sh` and `summarize-nix.sh` produce useful output? File `readme.traces` observations for each gap.
4. Iterate on the summarizers based on real output. Re-bake forge image.

### Phase 2 — Adjacent projects

1. Apply to the projects in `~/src/`: `agents/`, `ai-way/`, `inat-observations-wp/`, `forge/`, `thinking-service/`. Each gets its first compliant README via `/bootstrap-readme`.
2. Tune any new summarizers needed (e.g., `summarize-pom-xml.sh` for Maven projects, dropped into per-project `.tillandsias/summarizers/` initially, promoted to `images/default/summarizers/` if useful generally).

### Phase 3 — Telemetry consumption

1. Once `cheatsheets/welcome/readme-discipline.md` has accumulated ~30 days of `cheatsheet-telemetry` events across projects, build the consumer (separate change `cheatsheet-telemetry-analytics`). Highlight: README regen events with `chars_written` ≪ historical mean (regression detector); README startup-routing events with `resolved_via = empty` clusters (which projects keep landing in the welcome flow without ever progressing — a UX signal).

### Phase 4 — Integration with `/opsx` workflow

1. After every `/opsx:apply` and `/opsx:archive`, the OpenSpec skills emit a hook that updates `## Recent Changes` directly (rather than waiting for the next push). Reduces the "README knows about open OpenSpec items" lag from "next push" to "next /opsx tick."

### Phase 5 — Allowlist auto-merge (depends on `cheatsheets-license-tiered` v3)

1. When the `cheatsheets-license-tiered` v3 ships agent-proposed allowlist changes, the README `requires_cheatsheets:` consumer can promote off-allowlist references to allowlist entries automatically (subject to the v3 review gate).

### Rollback

If the change goes badly: revert the four skill files (the OpenCode shim falls back to whatever was previously the default first-prompt behavior, which is "no auto-prompt"); remove the pre-push hook from any project where it caused issues (`rm <project>/.git/hooks/pre-push`); remove the auto-regen warning from any committed README files (manual one-line `sed`). Rollback is local — nothing in this change touches shared host state, the proxy, the git-service, or the inference container.

## Open Questions

1. **OpenCode auto-prompt mechanism.** Does OpenCode have an official "first user message" or "auto-prompt" file convention? If yes, which path? If no, what's the cleanest way to inject the synthetic `/startup` message — `opencode --auto-prompt`, stdin pipe before the interactive session, or a config.json field? Pre-implementation investigation needed.
2. **Banner regeneration cadence.** ASCII-art banner is regenerated on every push. Is that too volatile (banner mutates every commit, making the README diff noisy)? Alternative: banner is regenerated only when the project name changes OR every Nth commit (deterministic from commit-hash modulo). Default-decided to "regenerate every push" per user direction; flag for confirmation.
3. **Whimsical description authorship.** Who writes the one-paragraph description on first regen? The agent (LLM call to ollama/llama3.2:3b for a one-shot generation), or a `<!-- agent: please write a 2-sentence whimsical description here -->` placeholder that the agent fills on first interactive session? The latter is offline-friendly; the former is more "magical." Default-decided to placeholder for v1, agent-fills on first interaction; flag for review.
4. **`figlet` baked vs not.** Is `figlet` already in the forge image? If not, this change requires adding it (~ 200 KB). Alternative: use a tiny pure-bash banner generator (block-letter approach). Default-decided to add `figlet`; flag for confirmation.
5. **Pre-commit hook for README edits.** v1 does NOT add a pre-commit hook that refuses commits modifying only `README.md`. Should it? Pro: prevents accidental hand edits from being committed. Con: extra friction, `--no-verify` escape becomes the user's habit. Default-decided to omit in v1, revisit in v2 based on observed behavior; flag for opinion.
6. **Project-local README override mechanism.** v1 does not ship the `<project>/.tillandsias/readme-overrides.md` mechanism (Decision 13 risk-table). Should it ship in v1, or wait for demand? Default-decided to wait; flag for confirmation.
