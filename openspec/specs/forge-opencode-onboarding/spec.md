# forge-opencode-onboarding Specification

## Status

status: active

## Purpose
TBD - created by archiving change forge-opencode-methodology-overhaul. Update Purpose after archive.
## Requirements
### Requirement: First-turn environment discovery
The OpenCode agent MUST run discovery tools and consult knowledge references on first attachment to a forge container, before attempting work.

#### Scenario: Agent discovers available tools
- **WHEN** OpenCode starts in a new forge container
- **THEN** agent MUST run `tillandsias-inventory` to list pre-installed tools and their versions
- **THEN** agent MUST read `$TILLANDSIAS_CHEATSHEETS/INDEX.md` to understand what references are available

#### Scenario: Agent avoids assuming tool absence
- **WHEN** agent is unsure if a tool is installed
- **THEN** agent MUST run `which <tool>` or check inventory instead of guessing

### Requirement: Cache discipline guidance
The OpenCode instructions MUST explain the four-category path model (shared cache, per-project cache, project workspace, ephemeral) and provide per-language environment variable mappings to redirect build artifacts away from the project workspace.

#### Scenario: Agent redirects cargo build artifacts to per-project cache
- **WHEN** agent runs `cargo build` or similar in a Rust project
- **THEN** agent MUST know that `CARGO_TARGET_DIR` and `CARGO_HOME` are pre-set to `~/.cache/tillandsias-project/cargo/`
- **THEN** agent MUST confirm with `cargo metadata --format-version 1 | jq .target_directory`

#### Scenario: Agent redirects npm artifacts
- **WHEN** agent needs to install npm dependencies
- **THEN** agent MUST know `npm_config_cache` points to `~/.cache/tillandsias-project/npm/`
- **THEN** agent MUST verify cache location with `npm config get cache`

#### Scenario: Agent uses nix for shared deps
- **WHEN** agent needs a system library shared across multiple projects
- **THEN** agent MUST declare it in `flake.nix` (not by running `apt` or `yum` inside the forge)
- **THEN** agent MUST run `nix develop` host-side to populate `/nix/store/` (RO mount from forge)

### Requirement: Nix-first methodology for new projects
The OpenCode instructions MUST recommend Nix as the entry point for declaring shared dependencies and project-scoped build inputs, with guidance on `flake.nix` structure.

#### Scenario: Agent scaffolds a new project with nix
- **WHEN** user asks agent to create a new project
- **THEN** agent MUST create a `flake.nix` at the project root with `inputs.nixpkgs`, `devShells`, and runtime dependencies

#### Scenario: Agent cites cheatsheet for flake authoring
- **WHEN** agent writes a new `flake.nix`
- **THEN** agent MUST include `@cheatsheet build/nix-flake-basics.md` in code comments

### Requirement: OpenSpec workflow step-by-step
The OpenCode instructions MUST provide a paragraph-per-step OpenSpec workflow with clear triggers, artifact descriptions, and worked examples, so agents know when to create a proposal, design, specs, and tasks.

#### Scenario: Agent creates OpenSpec proposal
- **WHEN** user asks for a non-trivial feature or fix
- **THEN** agent MUST create `openspec/changes/<change-name>/proposal.md` describing the problem, goals, and impact
- **THEN** agent MUST know this artifact is blocking design and specs

#### Scenario: Agent creates OpenSpec design
- **WHEN** proposal is written
- **THEN** agent MUST create `design.md` with Context, Decisions, Risks, and Migration Plan sections
- **THEN** agent MUST know design is the gate before specs

#### Scenario: Agent creates OpenSpec specs
- **WHEN** design is written
- **THEN** agent MUST create `specs/<capability>/spec.md` with ADDED/MODIFIED/REMOVED Requirements and Scenarios
- **THEN** agent MUST know to cite cheatsheets under `## Sources of Truth`

#### Scenario: Agent creates OpenSpec tasks
- **WHEN** specs are written
- **THEN** agent MUST create `tasks.md` with numbered checklist of implementation work
- **THEN** agent MUST mark tasks complete as implementation proceeds

#### Scenario: Agent archives completed change
- **WHEN** all tasks are marked [x]
- **THEN** agent MUST run `openspec archive --change <name>` to sync delta specs to main specs
- **THEN** agent MUST know archived changes are the project's institutional memory

### Requirement: Cheatsheet-integrated methodology
The OpenCode instructions MUST cite cheatsheets throughout using `@cheatsheet <category>/<filename>.md` annotations, making the knowledge graph queryable and enabling agents to follow traces to deep references.

#### Scenario: Agent uses cheatsheet citations to drill down
- **WHEN** agent encounters unfamiliar tool or pattern in instructions
- **THEN** agent MUST follow `@cheatsheet runtime/forge-paths-ephemeral-vs-persistent.md` to deepen understanding
- **THEN** agent SHOULD search cheatsheets via MCP if needed: `cheatsheet.search("cache discipline")`

### Requirement: Modularized instruction files
The OpenCode `config.json` instructions list MUST include 5 files: methodology.md (index), forge-discovery.md, cache-discipline.md, nix-first.md, and openspec-workflow.md, each under 200 lines.

#### Scenario: Agent receives methodology.md as first-turn context
- **WHEN** OpenCode loads config.json
- **THEN** instructions[0] MUST be `/home/forge/.config-overlay/opencode/instructions/methodology.md`
- **THEN** methodology.md MUST be ~15 lines that index the other 4 files

#### Scenario: Agent reads focused sub-file for cache discipline
- **WHEN** agent needs to understand where to write build artifacts
- **THEN** agent MUST read `/home/forge/.config-overlay/opencode/instructions/cache-discipline.md` (not a 200-line mega-doc)

#### Scenario: Agent references discovery workflow
- **WHEN** agent starts work in a new project
- **THEN** agent MUST consult `/home/forge/.config-overlay/opencode/instructions/forge-discovery.md` for first-turn steps

## Sources of Truth

- `cheatsheets/agents/opencode.md` — OpenCode IDE and development patterns
- `cheatsheets/runtime/forge-container.md` — Forge container runtime and configuration

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:ephemeral-guarantee`

Gating points:
- Onboarding state is temporary; completed steps don't persist across restarts
- Deterministic and reproducible: test results do not depend on prior state
- Falsifiable: failure modes (leaked state, persistence) are detectable

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:forge-opencode-onboarding" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
