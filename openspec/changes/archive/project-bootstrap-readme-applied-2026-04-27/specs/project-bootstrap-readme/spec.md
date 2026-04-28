# project-bootstrap-readme Specification

## ADDED Requirements

### Requirement: /startup skill — entrypoint and routing

The forge image SHALL ship a `/startup` skill at `~/.config/opencode/agent/startup.md` (installed by the OpenCode entrypoint shim from the image-baked source under `images/default/config-overlay/opencode/agent/startup.md`). The skill SHALL be auto-invoked by writing the synthetic first user message `run /startup` into OpenCode's auto-prompt path before `exec`-ing OpenCode. The skill SHALL detect project state and route to exactly one of three branch skills: `/bootstrap-readme-and-project` (empty project), `/bootstrap-readme` (non-empty + non-compliant README), or `/status` (non-empty + compliant README). The routing decision SHALL be visible in the OpenCode session log (the skill thinks aloud about which branch it took) and SHALL emit one `cheatsheet-telemetry` event with `event = "startup-routing"`, `resolved_via` ∈ `{empty, bootstrap-readme, status}`, `cheatsheet = "welcome/readme-discipline.md"`, `spec = "project-bootstrap-readme"`, `accountability = true`.

#### Scenario: Empty project routes to /bootstrap-readme-and-project

- **WHEN** `/startup` runs against a project where `git ls-files | wc -l ≤ 3` AND no `README.md` exists at the project root
- **THEN** `/startup` SHALL invoke `/bootstrap-readme-and-project`
- **AND** SHALL emit a `cheatsheet-telemetry` event with `resolved_via = "empty"`, `event = "startup-routing"`, `accountability = true`

#### Scenario: Non-empty project with non-compliant README routes to /bootstrap-readme

- **WHEN** `/startup` runs against a project where `is_empty_project()` returns false AND `scripts/check-readme-discipline.sh` exits with a non-zero error count
- **THEN** `/startup` SHALL invoke `/bootstrap-readme`
- **AND** SHALL emit a `cheatsheet-telemetry` event with `resolved_via = "bootstrap-readme"`, `event = "startup-routing"`

#### Scenario: Non-empty project with compliant README routes to /status

- **WHEN** `/startup` runs against a project where `is_empty_project()` returns false AND `scripts/check-readme-discipline.sh` exits 0 (zero errors; warnings are not fatal)
- **THEN** `/startup` SHALL invoke `/status`
- **AND** SHALL emit a `cheatsheet-telemetry` event with `resolved_via = "status"`, `event = "startup-routing"`

#### Scenario: User invokes a branch skill directly

- **WHEN** the user types `/status` (or any branch skill) directly in an interactive session, bypassing `/startup`
- **THEN** the branch skill SHALL run as a normal user-invokable command without re-routing
- **AND** no `event = "startup-routing"` telemetry SHALL be emitted (only the branch skill's own events fire)

### Requirement: Empty-project detection heuristic

The `is_empty_project()` function used by `/startup` SHALL apply the following deterministic heuristic against the project root: a project is considered empty if AND only if (a) `git ls-files | wc -l ≤ 3` (allowing `.gitignore`, `LICENSE`, and one `.gitkeep`-like file) AND (b) no `README.md` file exists at the project root. The presence of a `README.md` is the deciding signal — once a README exists (regardless of compliance), the project is NOT empty in the bootstrap sense.

#### Scenario: Freshly-init'd project with .gitignore and LICENSE counts as empty

- **WHEN** the project root contains exactly `.gitignore`, `LICENSE`, and a `.gitkeep` (3 tracked files) with no `README.md`
- **THEN** `is_empty_project()` SHALL return true

#### Scenario: Project with README counts as non-empty even if otherwise barren

- **WHEN** the project root contains only `README.md`
- **THEN** `is_empty_project()` SHALL return false (README presence overrides the file-count heuristic)

#### Scenario: Project with language manifests but no README counts as non-empty if file count exceeds threshold

- **WHEN** the project root contains `Cargo.toml`, `flake.nix`, `src/main.rs`, `Cargo.lock` (4 tracked files) and no `README.md`
- **THEN** `is_empty_project()` SHALL return false (file count exceeds 3 — project has real content)

### Requirement: /bootstrap-readme-and-project skill — empty-project welcome

The `/bootstrap-readme-and-project` skill SHALL produce a single-screen welcome flow consisting of (in order): (1) a project-name banner derived from the directory name, (2) the first three sample prompts read from `cheatsheets/welcome/sample-prompts.md`'s `## Sample Prompts` H2 section, (3) a one-screen summary of forge capabilities (Flutter, Nix, Flame, OpenSpec, the bundled languages and tools), and (4) the open question "what would you like to do?" without forcing any choice. The skill SHALL NOT auto-create a project scaffold (no `flutter create`, no `cargo init` on first attach). The skill SHALL emit one `cheatsheet-telemetry` event citing `cheatsheet = "welcome/sample-prompts.md"`, `event = "lookup"`, `resolved_via = "bundled"`, `chars_consumed` set to the bytes of the consumed sample-prompts section.

#### Scenario: Welcome screen renders banner and three sample prompts

- **WHEN** `/bootstrap-readme-and-project` runs against an empty project named `my-app`
- **THEN** the output SHALL contain a banner including `my-app`
- **AND** SHALL contain at least three prompts read from `cheatsheets/welcome/sample-prompts.md`
- **AND** SHALL end with an open prompt to the user (no forced choice)

#### Scenario: Cheatsheet consultation emits telemetry

- **WHEN** `/bootstrap-readme-and-project` reads the sample-prompts cheatsheet
- **THEN** one `cheatsheet-telemetry` event SHALL be appended to `lookups.jsonl` with `cheatsheet = "welcome/sample-prompts.md"`, `event = "lookup"`, `resolved_via = "bundled"`, `accountability = true`, `spec = "project-bootstrap-readme"`

#### Scenario: Skill does not auto-create a project

- **WHEN** `/bootstrap-readme-and-project` finishes
- **THEN** the project tree SHALL remain unchanged (no `pubspec.yaml`, `Cargo.toml`, etc. created without explicit user request)
- **AND** the skill output SHALL be the only side effect

### Requirement: /bootstrap-readme skill — non-empty bad-README flow

The `/bootstrap-readme` skill SHALL run when `scripts/check-readme-discipline.sh` reports one or more errors against the project's README. The skill SHALL: (1) print a one-line summary of the discipline gap (count of errors and warnings), (2) invoke `/usr/local/bin/regenerate-readme.sh` against the project root to auto-derive what can be derived, (3) preserve any `<!-- agent-curated -->` sections from the existing README verbatim (per the dispatcher's preservation contract), (4) leave `TODO:` placeholder text under any agent-curated section that does not yet exist, (5) print the post-regen state (which sections were auto-derived, which still need agent attention). Upon completion the skill SHALL append one entry to `<project>/.tillandsias/readme.traces` describing the regen outcome.

#### Scenario: Regen runs and produces a compliant README

- **WHEN** `/bootstrap-readme` runs against a project missing several FOR ROBOTS sections
- **THEN** `regenerate-readme.sh` SHALL be invoked
- **AND** the resulting `README.md` SHALL contain all H1 and H2 sections required by the validator
- **AND** the validator (re-run after regen) SHALL exit with zero errors

#### Scenario: Agent-curated sections preserved verbatim

- **WHEN** the existing README contains `## Architecture` followed by `<!-- agent-curated -->` and several paragraphs of prose
- **AND** `/bootstrap-readme` invokes the regenerator
- **THEN** the post-regen `## Architecture` section SHALL contain the same prose paragraphs unchanged
- **AND** ONLY auto-derived sections (Tech Stack, Build Dependencies, Runtime Dependencies, Recent Changes, OpenSpec Open Items) SHALL be replaced

#### Scenario: TODO placeholders for missing agent-curated sections

- **WHEN** the existing README is missing `## Privacy` entirely
- **AND** `/bootstrap-readme` runs the regenerator
- **THEN** the post-regen `## Privacy` section SHALL exist with a `<!-- agent-curated -->` marker AND a `TODO:` placeholder asking the agent to fill it in
- **AND** the structural validator SHALL accept the placeholder as present

### Requirement: /status skill — non-empty good-README snapshot

The `/status` skill SHALL produce a single-screen snapshot (≤ 30 lines) in this exact order: (1) header line `[startup-routing] non-empty + good README → /status` (only when invoked via `/startup`), (2) `## Project: <name>` line with branch + last-commit short-SHA + relative time, (3) `### OpenSpec — open` section listing in-flight changes from `openspec list`, (4) `### Last 5 commits` from `git log --oneline -5`, (5) `### Last build's commit` derived from `VERSION` and the last release tag (only shown when different from HEAD), (6) `### Recent README observations (last 5)` from `<project>/.tillandsias/readme.traces`, (7) `### Suggested next action` derived from a deterministic heuristic. The output SHALL fit on one terminal screen.

#### Scenario: Status output contains all six sections

- **WHEN** `/status` runs against a project with active OpenSpec changes, recent commits, and a populated `readme.traces`
- **THEN** the output SHALL contain `## Project:`, `### OpenSpec — open`, `### Last 5 commits`, `### Recent README observations`, and `### Suggested next action` sections in that order

#### Scenario: Suggested next action follows deterministic heuristic

- **WHEN** at least one OpenSpec change has tasks marked `in-progress`
- **THEN** the suggested next action SHALL be `Continue <change-name>: <X> of <Y> tasks done. Run /opsx:apply <change-name> to resume.` for the oldest in-progress change

#### Scenario: Suggested action falls through when no in-progress work

- **WHEN** no OpenSpec change has in-progress tasks AND no proposals are stuck without designs AND `git status` is clean
- **THEN** the suggested next action SHALL be `ready for new work — what would you like to do?`

#### Scenario: Output fits a single screen

- **WHEN** `/status` runs against any project
- **THEN** the printed output SHALL be ≤ 30 lines (single-screen constraint)

### Requirement: README.md structure (FOR HUMANS / FOR ROBOTS)

Every Tillandsias-managed project SHALL contain a `README.md` at the project root with a fixed structure: line 1 SHALL be the auto-regen warning HTML comment (`<!-- This file is auto re-generated, changes are ignored. Simply prompt away instead. -->`); line 2 SHALL be the trace annotation comment (`<!-- @trace spec:project-bootstrap-readme @cheatsheet welcome/readme-discipline.md -->`). The body SHALL contain TWO `# H1` sections in this order: `# FOR HUMANS` and `# FOR ROBOTS`. The `# FOR HUMANS` section SHALL contain a `_Last generated: <timestamp> <tz>_` italic line, an ASCII-art project banner inside a fenced code block, a whimsical one-paragraph description, and an install one-liner OR a releases URL. The `# FOR ROBOTS` section SHALL contain seven mandatory `## H2` subsections in this order: `## Tech Stack`, `## Build Dependencies`, `## Runtime Dependencies`, `## Security`, `## Architecture`, `## Privacy`, `## Recent Changes`, `## OpenSpec — Open Items`, followed by a fenced YAML code block declaring `requires_cheatsheets:`. The two-H1 design is intentional and overrides the single-H1-per-document markdown convention.

#### Scenario: Auto-regen warning on line 1

- **WHEN** the validator reads `README.md`
- **THEN** line 1 SHALL be the exact string `<!-- This file is auto re-generated, changes are ignored. Simply prompt away instead. -->`
- **AND** line 2 SHALL be the trace annotation comment

#### Scenario: Two H1s present in correct order

- **WHEN** the validator scans the README for H1 headers
- **THEN** it SHALL find `# FOR HUMANS` BEFORE `# FOR ROBOTS`
- **AND** no other `# ` H1 SHALL appear between or after them

#### Scenario: All seven mandatory H2s under FOR ROBOTS

- **WHEN** the validator inspects the section between `# FOR ROBOTS` and end-of-file
- **THEN** the H2 headers `## Tech Stack`, `## Build Dependencies`, `## Runtime Dependencies`, `## Security`, `## Architecture`, `## Privacy`, `## Recent Changes`, AND `## OpenSpec — Open Items` SHALL ALL be present
- **AND** the order SHALL match the spec

#### Scenario: requires_cheatsheets YAML block parseable

- **WHEN** the validator extracts the fenced YAML code block under FOR ROBOTS
- **THEN** the block SHALL parse via `yq` without error
- **AND** SHALL contain a top-level `requires_cheatsheets:` key whose value is a list of strings

### Requirement: README.traces JSONL accumulator

Every Tillandsias-managed project SHALL maintain `<project>/.tillandsias/readme.traces` as an append-only JSONL ledger of agent observations during README regen and validation. Each line SHALL be one JSON object with the schema `{ts: ISO 8601 with TZ, agent: string, observation: string, severity: enum(info|warn|regen-trigger), triggered_by: enum(regen|agent-curated-update|requires_cheatsheets-resolution|validator-warn)}`. The file SHALL be committed to git (per-project state, travels across machines). The file SHALL be append-only: no entry SHALL be edited or removed except via the auditor's in-place rotation (truncate to newest 50%) when the file exceeds an implementation-defined size cap.

#### Scenario: Schema validation per line

- **WHEN** any agent or script appends to `readme.traces`
- **THEN** the line SHALL be a single valid JSON object terminated by `\n`
- **AND** SHALL contain ALL of `ts`, `agent`, `observation`, `severity`, `triggered_by`
- **AND** `severity` SHALL be one of `info`, `warn`, `regen-trigger`
- **AND** `triggered_by` SHALL be one of `regen`, `agent-curated-update`, `requires_cheatsheets-resolution`, `validator-warn`

#### Scenario: Feedforward — last 50 entries fed to next regen

- **WHEN** `regenerate-readme.sh` is invoked
- **THEN** it SHALL read the latest 50 lines of `readme.traces` (if the file exists)
- **AND** print them to stderr at INFO level so the agent driving the regen sees prior observations

#### Scenario: Trace file committed to git

- **WHEN** the pre-push hook regenerates README and commits the result
- **THEN** any new lines appended to `readme.traces` during the regen SHALL also be `git add`-ed and included in the commit

#### Scenario: Append-only invariant under rotation

- **WHEN** the auditor rotates `readme.traces` because it exceeds the size cap
- **THEN** the rotation SHALL truncate to the newest 50% of bytes
- **AND** the rotation event SHALL itself be appended as one trace line with `severity = "info"` and `triggered_by = "regen"` describing the rotation

### Requirement: Pre-push git hook installation contract

The forge image SHALL ship `scripts/install-readme-pre-push-hook.sh` at `/usr/local/bin/install-readme-pre-push-hook.sh`. The `/startup` skill SHALL invoke this installer on every invocation; the installer SHALL be idempotent — it SHALL compute the SHA-256 of the canonical hook content and install (or re-install) `<project>/.git/hooks/pre-push` only when the SHA differs. The installed hook SHALL: (a) attempt `regenerate-readme.sh "$PROJECT_ROOT"`, (b) on success, `git add README.md` and `git commit --no-edit -m "chore(readme): regenerate at <ts>"` if the file changed, (c) on failure, fall back to a timestamp-only sed update of `_Last generated:_` and commit, (d) capture stderr to `<project>/.tillandsias/regenerate.log`, (e) ALWAYS exit 0 (never block the push). The user MAY bypass via standard `git push --no-verify`.

#### Scenario: Installer creates hook on first invocation

- **WHEN** `/startup` runs against a project where `<project>/.git/hooks/pre-push` does not exist
- **THEN** the installer SHALL create the file with executable permissions (`0755`)
- **AND** the file SHALL contain the canonical hook body including the `@trace spec:project-bootstrap-readme` annotation

#### Scenario: Installer is idempotent on subsequent invocations

- **WHEN** `/startup` runs against a project where the hook is already present at the canonical SHA
- **THEN** the installer SHALL NOT rewrite the file
- **AND** SHALL emit no observable side effect except a debug log line

#### Scenario: Installer re-installs when hook content drifts

- **WHEN** `/startup` runs against a project where `<project>/.git/hooks/pre-push` exists but its SHA differs from the canonical
- **THEN** the installer SHALL overwrite the file with the canonical content
- **AND** SHALL append a `readme.traces` entry with `severity = "info"` describing the re-install

#### Scenario: Hook never blocks the push

- **WHEN** the pre-push hook runs and `regenerate-readme.sh` fails (non-zero exit)
- **THEN** the hook SHALL fall back to the timestamp-only `sed` update path
- **AND** SHALL exit 0 unconditionally
- **AND** the push SHALL succeed regardless of regen outcome

### Requirement: README requires_cheatsheets consumer

The `/startup` skill SHALL parse the `requires_cheatsheets:` YAML block from the FOR ROBOTS section of `README.md` (when present) and resolve each declared cheatsheet via the `cheatsheets-license-tiered` tier classifier. For each entry: if `tier: bundled` AND the file is present in `/opt/cheatsheets/`, the skill SHALL register a hit and continue. If `tier: distro-packaged` AND the `local:` path exists in the image, the skill SHALL register a hit. If `tier: pull-on-demand` AND the cheatsheet is not yet materialized, the skill SHALL invoke the cheatsheet's `## Pull on Demand` recipe to materialize into `~/.cache/tillandsias/cheatsheets-pulled/<project>/`, AND emit a `cheatsheet-telemetry` event with `event = "readme-requires-pull"`, `triggered_by = "readme-requires_cheatsheets"`. If the cheatsheet name is NOT in `cheatsheets/license-allowlist.toml` AND no matching file exists anywhere, the skill SHALL emit a `WARN: README requires cheatsheet '<name>' but it is missing AND off-allowlist; consider adding it to license-allowlist.toml` and continue (NEVER block).

#### Scenario: Bundled cheatsheet hit from /opt/cheatsheets/

- **WHEN** `requires_cheatsheets:` declares `languages/rust.md` AND `/opt/cheatsheets/languages/rust.md` exists
- **THEN** `/startup` SHALL register a hit
- **AND** SHALL NOT emit a pull or warn event

#### Scenario: Pull-on-demand triggers materialization

- **WHEN** `requires_cheatsheets:` declares a `tier: pull-on-demand` cheatsheet that has not yet been materialized for the current project
- **THEN** `/startup` SHALL invoke the cheatsheet's `## Pull on Demand` recipe
- **AND** SHALL emit a `cheatsheet-telemetry` event with `event = "readme-requires-pull"`, `triggered_by = "readme-requires_cheatsheets"`, `pulled_url` set to the source URL

#### Scenario: Missing-and-off-allowlist emits WARN, never blocks

- **WHEN** `requires_cheatsheets:` declares `languages/cobol.md` AND no such file exists AND `cobol` is not present in `cheatsheets/license-allowlist.toml`
- **THEN** `/startup` SHALL emit a single WARN line naming the missing-and-off-allowlist cheatsheet
- **AND** SHALL continue execution (NOT block)
- **AND** SHALL append one `readme.traces` entry with `severity = "warn"`, `triggered_by = "requires_cheatsheets-resolution"`

### Requirement: Validator script contract

The forge image SHALL ship `scripts/check-readme-discipline.sh` at `/usr/local/bin/check-readme-discipline.sh`. The validator SHALL perform structural checks against `<project>/README.md` and emit one line per failed check, prefixed with `ERROR:` (structural failure) or `WARN:` (content-quality concern). The validator SHALL emit a final summary line `<N> error(s), <M> warning(s)`. The validator's exit code SHALL be the number of errors (capped at 255). The validator SHALL NOT grade content quality — it confirms the file's structural bones are present.

| Check | Severity |
|---|---|
| `README.md` exists at project root | ERROR |
| Line 1 is the exact auto-regen warning HTML comment | ERROR |
| `# FOR HUMANS` H1 present | ERROR |
| `_Last generated:_` line present and parseable as a date | ERROR |
| ASCII-art or fallback banner code fence present under FOR HUMANS | ERROR |
| Whimsical description (any prose paragraph) under FOR HUMANS | WARN |
| `# FOR ROBOTS` H1 present | ERROR |
| `## Tech Stack` H2 present | ERROR |
| `## Build Dependencies` H2 present | ERROR |
| `## Runtime Dependencies` H2 present | ERROR |
| `## Security` H2 present | ERROR |
| `## Architecture` H2 present | ERROR |
| `## Privacy` H2 present | ERROR |
| `## Recent Changes` H2 present | WARN |
| `## OpenSpec — Open Items` H2 present | WARN |
| `requires_cheatsheets:` YAML block parseable via `yq` | WARN |
| Timestamp within last 7 days | WARN |

#### Scenario: Compliant README exits 0

- **WHEN** `check-readme-discipline.sh` runs against a freshly-generated compliant README
- **THEN** the validator SHALL emit `0 error(s), 0 warning(s)` (or zero errors with some warnings)
- **AND** SHALL exit with code 0 (number of errors)

#### Scenario: Missing FOR ROBOTS section reports errors

- **WHEN** `check-readme-discipline.sh` runs against a README missing `# FOR ROBOTS` and all seven mandatory H2 subsections
- **THEN** the validator SHALL emit at least 8 `ERROR:` lines (one per missing structural element)
- **AND** SHALL exit with a code equal to the error count (capped at 255)

#### Scenario: Stale timestamp emits WARN, not ERROR

- **WHEN** `check-readme-discipline.sh` runs against a README whose `_Last generated:_` line is more than 7 days old
- **THEN** the validator SHALL emit one `WARN:` line about the stale timestamp
- **AND** SHALL NOT increment the error count

### Requirement: OpenCode entrypoint shim writes synthetic first prompt

`images/default/entrypoint-forge-opencode.sh` SHALL gain a block (just before the final `exec "$OC_BIN" "$@"`) that writes the synthetic first user message `/startup` to OpenCode's auto-prompt path. The preferred mechanism is to write to `~/.config/opencode/auto-prompt.md` (or whatever path OpenCode currently reads for an auto-injected first turn); the fallback mechanism is to invoke `opencode --auto-prompt "/startup"` (or pipe `/startup\n` to stdin) before `exec`-ing the interactive session. The shim SHALL NOT modify OpenCode's `config.json`. The shim SHALL be idempotent (writing the same content on every container start is acceptable and expected). The shim block SHALL carry an `# @trace spec:project-bootstrap-readme` annotation.

#### Scenario: Synthetic prompt written to auto-prompt path

- **WHEN** the OpenCode entrypoint runs to steady state
- **THEN** the auto-prompt file SHALL contain the single line `/startup`
- **AND** the shim SHALL have logged a single line at INFO level confirming the synthetic prompt was written

#### Scenario: Shim is idempotent across restarts

- **WHEN** the same forge container is restarted
- **THEN** the shim SHALL re-write the auto-prompt file with the same content
- **AND** SHALL NOT produce any error if the file already exists

#### Scenario: Shim does not touch other entrypoints

- **WHEN** the user attaches via `entrypoint-forge-claude.sh` or `entrypoint-terminal.sh`
- **THEN** no synthetic `/startup` prompt SHALL be written
- **AND** the v1 routing surface SHALL be exclusive to the OpenCode entrypoint

### Requirement: Telemetry events for routing, regen, and pull triggers

Three event shapes SHALL be appended to `cheatsheet-telemetry`'s `lookups.jsonl` (per `cheatsheets-license-tiered`'s EXTERNAL log producer requirement). Each event SHALL carry `accountability = true`, `spec = "project-bootstrap-readme"`, and `cheatsheet = "welcome/readme-discipline.md"` (or `welcome/sample-prompts.md` for the welcome-flow event).

| Event | Emitter | `event` | `resolved_via` | Extra fields |
|---|---|---|---|---|
| Startup routing decision | `/startup` skill | `startup-routing` | `empty` / `bootstrap-readme` / `status` | `query = "startup-routing"` |
| README regen invocation | `regenerate-readme.sh` | `readme-regen` | `auto` | `summarizers_invoked: [...]`, `chars_written: <N>` |
| README-required cheatsheet pull | `/startup` skill | `readme-requires-pull` | `pulled` | `triggered_by = "readme-requires_cheatsheets"`, `pulled_url`, `cheatsheet` (the pulled one) |

The events SHALL ride on the existing `cheatsheet-telemetry` EXTERNAL-tier producer infrastructure — no new producer role, no new manifest. Events SHALL NOT block any operation; failures to emit (e.g., disk full) SHALL be logged to `regenerate.log` but SHALL NOT propagate.

#### Scenario: Routing event emitted with full schema

- **WHEN** `/startup` decides to route to `/status`
- **THEN** one line SHALL be appended to `/var/log/tillandsias/external/cheatsheet-telemetry/lookups.jsonl`
- **AND** the JSON object SHALL contain `event = "startup-routing"`, `resolved_via = "status"`, `cheatsheet = "welcome/readme-discipline.md"`, `accountability = true`, `spec = "project-bootstrap-readme"`, `project = <name>`, `ts` in ISO 8601 UTC

#### Scenario: Regen event lists invoked summarizers

- **WHEN** `regenerate-readme.sh` finishes a regen that invoked `summarize-cargo.sh` and `summarize-nix.sh` and wrote 3421 chars
- **THEN** one event SHALL be appended with `event = "readme-regen"`, `summarizers_invoked = ["cargo", "nix"]`, `chars_written = 3421`, `resolved_via = "auto"`

#### Scenario: Pull-trigger event names the source URL

- **WHEN** `/startup` invokes a pull-on-demand recipe because `requires_cheatsheets:` referenced an unmaterialized cheatsheet
- **THEN** one event SHALL be emitted with `event = "readme-requires-pull"`, `triggered_by = "readme-requires_cheatsheets"`, `pulled_url` set to the upstream URL, `cheatsheet` set to the pulled cheatsheet's relative path

## Sources of Truth

- `cheatsheets/welcome/readme-discipline.md` — the README structural contract (FOR HUMANS / FOR ROBOTS), `readme.traces` schema, validator severity table; created by this change as the load-bearing reference.
- `cheatsheets/welcome/sample-prompts.md` — the curated empty-project sample prompts the welcome flow surfaces; created by this change.
- `cheatsheets/agents/opencode.md` — OpenCode skill / command file convention (`~/.config/opencode/agent/<name>.md` with `---\ndescription: ...\n---` frontmatter) that the four new skills follow.
- `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md` — confirms `<project>/.tillandsias/` is per-project bind-mounted (where `readme.traces` lives) and that the project workspace is the right home for `README.md` and `.git/hooks/`.
- `cheatsheets/runtime/cheatsheet-tier-system.md` — the tier classifier the `requires_cheatsheets` consumer uses to resolve declared cheatsheets.
- `cheatsheets/utils/jq.md` — `readme.traces` is JSONL, queryable via `jq -c`.
