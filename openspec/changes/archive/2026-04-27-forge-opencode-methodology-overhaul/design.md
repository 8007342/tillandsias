## Context

Today's `images/default/config-overlay/opencode/instructions/methodology.md` is generic and abstract (36 lines). OpenCode agents receive no direction to run discovery tools (`tillandsias-inventory`), no map of where to find tool references (cheatsheets), no cache discipline explaining path semantics (ephemeral vs persistent), and no step-by-step OpenSpec workflow guidance.

Result: agents don't discover what's available, build artifacts pollute the workspace, and methodology remains theoretical until agents re-learn it from first principles.

## Goals / Non-Goals

**Goals:**
- First-turn discovery: agent learns to run `tillandsias-inventory`, read `$TILLANDSIAS_CHEATSHEETS/INDEX.md`, understand what tools are pre-installed
- Cache discipline: agent understands the four-category path model (shared cache, per-project cache, project workspace, ephemeral) and per-language env vars (12 of them) that redirect build artifacts away from git
- Nix-first for new projects: agent knows when to reach for Nix and how to declare deps in `flake.nix`
- OpenSpec workflow: agent knows when to scaffold a change, what each artifact is for, when to archive — actionable step-by-step with worked examples
- Modularized instructions: split into 4 focused sub-files to keep each under 200 lines, indexed from methodology.md

**Non-Goals:**
- Changing how OpenCode is invoked or configured
- Modifying config.json beyond adding 4 instruction file paths
- New tray-side features or prompts
- Rebuilding the forge image in this change (that's a separate forge rebuild step)

## Decisions

1. **Modularize into 4 sub-files, not mega-document**: Each sub-file addresses one problem (discovery, cache, nix, openspec). Keeps cognitive load low, makes updates surgical. Main methodology.md becomes an index/router (~15 lines).

2. **Action-first, not principle-first**: Each sub-file leads with "do this first" (run inventory, read cheatsheet index, etc.) before explaining why. Agents follow concrete steps before absorbing rationale.

3. **Cite cheatsheets explicitly in methodology files**: Link from each sub-file to relevant cheatsheets (`@cheatsheet` annotations). Makes the knowledge graph queryable and connects to the MCP cheatsheet server.

4. **Include 1–2 worked examples per sub-file**: Don't just say "set CARGO_TARGET_DIR"; show the agent what happens when they run `cargo metadata --format-version 1` and where the output dir resolves to.

5. **150–200 lines per sub-file**: Matches existing instruction files (flutter.md is 19 lines, model-routing.md is 36 lines). Four 200-line files are more scannable than one 800-line mega-doc.

## Risks / Trade-offs

**Risk: Cheatsheet references become stale**  
→ Mitigation: Each instruction file cites cheatsheet paths with `@cheatsheet`. When a cheatsheet moves or changes, a single grep reveals all downstream references. Citation traceability is baked in.

**Risk: Agents ignore instructions if they're verbose**  
→ Mitigation: Keep each sub-file to the length of existing instructions (20–40 lines of action, rest is examples/deep-dives). Agents skim; we lead with the action.

**Risk: New agents onboard onto the methodology without reading it**  
→ Mitigation: OpenCode's default_agent and small_model config ensure the methodology is front-and-center. The config.json lists all 5 instruction files. The MCP project-info tool can surface this on first attach.

**Risk: Nix-first advice doesn't apply to all languages/projects**  
→ Mitigation: nix-first.md says "when starting a NEW project, consider nix". Existing projects already have build systems; nix is an option, not a mandate.

## Migration Plan

1. Create 4 new sub-files under `images/default/config-overlay/opencode/instructions/`
2. Rewrite methodology.md as an index that points to the 4 sub-files
3. Update config.json to list all 5 instruction files (methodology.md is already there)
4. Validate cross-references: `openspec validate --change forge-opencode-methodology-overhaul`
5. Build the forge image (automated in the release workflow, not in this change)
6. Archive the change and sync delta specs to main specs

## Open Questions

- Should the worked examples in each sub-file be shell transcripts or pseudocode? Decided: pseudocode with `$ command` syntax (matches existing instructions)
- How verbose should the "why" section be in cache-discipline.md? Decided: 3–4 paragraphs; full depth lives in the cheatsheet
- Should openspec-workflow.md include a decision tree for "which artifact should I write next?" Decided: yes; include a simple flowchart-as-text
