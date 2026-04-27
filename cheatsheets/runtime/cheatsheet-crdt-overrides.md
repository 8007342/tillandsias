---
tags: [meta, cheatsheet-system, crdt, override, project-committed, shadow, discipline]
languages: []
since: 2026-04-27
last_verified: 2026-04-27
sources:
  - https://en.wikipedia.org/wiki/Conflict-free_replicated_data_type
  - https://hal.inria.fr/inria-00609399v2/document
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: false
---

# Cheatsheet CRDT overrides — project-committed shadows

@trace spec:cheatsheets-license-tiered, spec:agent-cheatsheets
@cheatsheet runtime/cheatsheet-tier-system.md

**Use when**: You're committing a project-specific cheatsheet under `<project>/.tillandsias/cheatsheets/` that overrides a forge-bundled cheatsheet at the same path.

## Provenance

- Wikipedia, Conflict-free replicated data type: <https://en.wikipedia.org/wiki/Conflict-free_replicated_data_type> — the data-type family this discipline derives its semantics from
- Shapiro et al., "A comprehensive study of Convergent and Commutative Replicated Data Types" (INRIA, 2011): <https://hal.inria.fr/inria-00609399v2/document> — the original CRDT survey
- `openspec/specs/cheatsheets-license-tiered/spec.md` — normative spec (see "CRDT override discipline" requirement)
- `openspec/changes/archive/2026-04-27-cheatsheets-license-tiered/design.md` Decision 10 — full rationale and worked example
- **Last updated:** 2026-04-27

## Quick reference — the four fields

| Field | What it states | Required when |
|---|---|---|
| `shadows_forge_default` | Relative path of the forge-bundled cheatsheet being shadowed (e.g., `cheatsheets/languages/jdk-api.md`) | The project cheatsheet's path matches a forge-bundled one |
| `override_reason` | "this project doesn't FOO because BAR" — the *why* | `shadows_forge_default` is set |
| `override_consequences` | What affordability is given up by taking this path — the *cost* | same |
| `override_fallback` | What to do if the override conditions don't apply — the *recovery* | same |

**No silent shadowing.** When a project-committed cheatsheet shadows a same-pathed forge-bundled cheatsheet, all four fields are MANDATORY. The validator emits ERROR if any one is missing or empty. At runtime, the agent reading the override sees ALL THREE fields surfaced before the cheatsheet body — the override is reasoned, not silent.

This is the core of treating cheatsheets as a CRDT — meaning converges across replicas (forge default + project override + agent-generated refinement) by structured discipline, not by precedence rules.

## Common patterns

### Worked example — JDK 17 LTS pin shadowing forge default JDK 21

Forge default at `/opt/cheatsheets-image/languages/jdk-api.md` documents JDK 21. The project pins JDK 17 LTS (e.g., for Android Gradle Plugin 8.x compatibility). Project commits at `<project>/.tillandsias/cheatsheets/languages/jdk-api.md`:

```yaml
---
tier: pull-on-demand
summary_generated_by: agent-generated-at-runtime
committed_for_project: true
last_verified: 2026-04-26
source_urls:
  - https://docs.oracle.com/en/java/javase/17/docs/api/

shadows_forge_default: cheatsheets/languages/jdk-api.md
override_reason: |
  This project pins JDK 17 LTS rather than the forge default JDK 21,
  because our deployment target (Android Gradle Plugin 8.x) does not
  yet support JDK 21 bytecode. We need the JDK 17 API surface, not 21.
override_consequences: |
  Agents working on this project MUST NOT use JDK 21-only APIs
  (java.util.HexFormat, pattern matching for switch, sealed-class
  enhancements, etc.). Code that compiles on the forge default may
  fail at our deployment gate.
override_fallback: |
  If the agent encounters a JDK 21 example in upstream documentation
  that this cheatsheet does not cover, it SHOULD: (1) check whether
  the API is back-portable to JDK 17 (most java.lang/java.util additions
  are not), (2) if not, find the JDK 17 equivalent or open a project
  issue tagging "java-21-blocker", (3) NOT silently use the JDK 21
  idiom assuming the forge default applies.
---

# JDK 17 LTS API quick reference (project override)
…
```

### Runtime behavior — banner + override callout

At forge launch, `populate_hot_paths()` merges `<project>/.tillandsias/cheatsheets/` into `/opt/cheatsheets/` (tmpfs view) AFTER copying `/opt/cheatsheets-image/`. The merge detects shadows and emits one banner line per active shadow:

```
[cheatsheet override] languages/jdk-api.md → project version (reason: JDK 17 LTS pin)
```

The runtime renderer also injects a callout block at the top of the shadowed cheatsheet's body inside `/opt/cheatsheets/`:

```markdown
> [!OVERRIDE]
> **shadows_forge_default**: cheatsheets/languages/jdk-api.md
>
> **override_reason**: This project pins JDK 17 LTS rather than the forge default JDK 21…
> **override_consequences**: Agents MUST NOT use JDK 21-only APIs…
> **override_fallback**: If the agent encounters a JDK 21 example…
```

The agent reads this BEFORE the cheatsheet body. Override semantics are surfaced, never assumed.

## Common pitfalls

- **Declaring `shadows_forge_default` without all three override fields** — validator ERROR. The four fields are a unit; missing any one triggers a structural failure.
- **Empty `override_fallback`** — the most-overlooked field, and the most important. Without a fallback, the agent has no recovery semantics for cases the override didn't foresee. Validator ERROR on empty.
- **Treating override as "project always wins, end of story"** — the override fields make the trade auditable. The agent reasons WITH the override rather than blindly applying it. Wrong frame: "project's version is correct". Right frame: "project deviates HERE for THESE reasons; here's how to recover".
- **Cross-project shadowing** — impossible. `forge-cache-dual` per-project isolation prevents project A from shadowing into project B's tmpfs view. Each project sees its own `<project>/.tillandsias/cheatsheets/` merged on top of the forge default; another project's overrides are invisible.
- **Forgetting the runtime callout** — the spec requires `populate_hot_paths()` to inject the `> [!OVERRIDE]` block at the top of the rendered cheatsheet body. Implementers SHALL preserve this — silent overrides defeat the discipline.
- **Override-discipline drift** — the four fields are agent-authored at REFINED time. They can rot as project decisions change. Pair the override with a `last_verified` discipline (refresh the override fields when project context changes substantially).

## See also

- `runtime/cheatsheet-tier-system.md` — three tiers (override discipline applies regardless of tier)
- `runtime/cheatsheet-frontmatter-spec.md` — full v2 schema; the four fields are documented under "CRDT override discipline"
- `runtime/cheatsheet-lifecycle.md` — REFINED state in the convergence loop
- `runtime/forge-hot-cold-split.md` — `populate_hot_paths()` is the merge point
- `runtime/forge-cache-dual.md` (if exists) — per-project isolation invariant
