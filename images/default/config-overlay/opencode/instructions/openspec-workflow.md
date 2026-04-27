# OpenSpec Workflow

@trace spec:agent-source-of-truth
@cheatsheet agents/openspec.md

Every non-trivial change (new feature, fix, refactor) goes through OpenSpec. This ensures work is traceable, reversible, and converges toward specification.

## When to Use OpenSpec

**Use OpenSpec for:**
- New features (anything that touches multiple files or adds behavior)
- Bug fixes (document why it was broken, how it's fixed)
- Refactors (explain the architectural change)
- Configuration changes (Containerfile, config.json, flake.nix edits)

**Skip OpenSpec for:**
- Typo fixes (one line, obvious intent)
- Comment-only changes (no behavior change)
- Moving existing files (no logic change)

If unsure, default to OpenSpec. It's faster to skip than to retrofit.

## The Five-Step Workflow

```
Proposal → Design → Specs → Tasks → Implement → Archive
```

Each step builds on the previous. You do the steps in order.

### Step 1: Create the Proposal

```bash
$ openspec new change --name my-feature
```

Creates `openspec/changes/my-feature/proposal.md`. Write:
- **Why**: What problem does this solve?
- **What Changes**: What files are created/modified/removed?
- **Impact**: Who/what is affected?
- **Sources of Truth**: What cheatsheets informed this?

**Example:**
```markdown
## Why
Users can't search posts by tag. The search index is missing the tags column.

## What Changes
- MODIFIED posts table schema to include tags column
- NEW search index on tags
- MODIFIED search API to query the index

## Impact
Search API changes — frontend must pass `?tags=foo` instead of relying on full-text.
```

**Time: 5–10 minutes. Don't overthink it.**

### Step 2: Write the Design

```bash
$ openspec instructions design
```

Creates `design.md`. Write:
- **Context**: What's the current state? Constraints?
- **Goals / Non-Goals**: What does this achieve and exclude?
- **Decisions**: Key technical choices (why X over Y?). Consider alternatives.
- **Risks / Trade-offs**: What could go wrong? How to mitigate?
- **Migration Plan**: Steps to deploy and rollback (if applicable).

**Example:**
```markdown
## Context
Posts table has no index on tags. Full-text search is slow (60ms per query).

## Decisions
1. Add tags column to posts table (not a junction table) — tags are small, fits inline
2. Use a btree index (not full-text) — btree is fast for exact tag match, simple to add
3. Alter the table live (no downtime) — not a new table, so no backfill pause

## Risks
- Table lock during ALTER — mitigated by online ALTER syntax (MySQL 8.0+)
- Index bloat if tags grow — mitigate by setting max length and pruning old posts quarterly
```

**Time: 15–30 minutes. Focus on the "why" not the "how".**

### Step 3: Write the Specs

```bash
$ openspec instructions specs
```

Creates `specs/<capability>/spec.md` (one per capability). Write:
- **ADDED Requirements**: New behavior (each with scenarios)
- **MODIFIED Requirements**: Changed behavior (copy the original requirement, edit it)
- **REMOVED Requirements**: Deleted features (include reason and migration path)
- **Sources of Truth**: Cite cheatsheets that informed this spec

Scenario format:
```
#### Scenario: User searches by tag
- **WHEN** user enters ?tags=python in search
- **THEN** API queries the tags index
- **THEN** results return posts where tags LIKE 'python' within 5ms
```

**Important**: Each requirement MUST have at least one scenario. Scenarios are the basis for tests.

**Example full spec:**
```markdown
## ADDED Requirements

### Requirement: Tag index on posts table
The posts table SHALL have a btree index on the tags column.

#### Scenario: Index exists
- **WHEN** the schema is deployed
- **THEN** `SHOW INDEXES FROM posts` lists an index on tags

#### Scenario: Index improves search latency
- **WHEN** user searches with ?tags=python
- **THEN** query executes in <10ms (previously 60ms)

## Sources of Truth

- `cheatsheets/data/mysql-indexing.md` — when to use btree vs full-text
- `cheatsheets/database/zero-downtime-migrations.md` — online ALTER syntax
```

**Time: 20–40 minutes per capability. One spec per feature.**

### Step 4: Create the Task List

```bash
$ openspec instructions tasks
```

Creates `tasks.md`. Write a numbered checklist:

```markdown
## 1. Database Schema

- [ ] 1.1 Write SQL migration to add tags column
- [ ] 1.2 Write SQL migration to create index
- [ ] 1.3 Test migrations with rollback

## 2. API

- [ ] 2.1 Modify search handler to use new index
- [ ] 2.2 Add ?tags query parameter to docs

## 3. Tests

- [ ] 3.1 Unit test: index exists after migration
- [ ] 3.2 Integration test: search by tag returns correct posts
```

**Each task should be completable in 30 minutes or less.** If it takes longer, split it.

**Time: 10–20 minutes.**

### Step 5: Implement

For each task:
1. Do the work (write code, run tests, update docs)
2. Verify it matches the spec
3. Mark the task complete: `- [ ]` → `- [x]`
4. Add `@trace spec:<name>` annotations to link code to specs

**Example:**
```rust
// @trace spec:tag-index
// Queries the tags index added in the tag-index spec
pub fn search_by_tag(tag: &str) -> Result<Vec<Post>> {
    db.query("SELECT * FROM posts WHERE tags LIKE ?", [tag])
        .fetch_all()
}
```

**Time: Depends on feature. Usually 1–4 hours.**

### Step 6: Validate and Archive

Before finishing:

```bash
$ openspec validate
```

Checks:
- All specs exist
- All cheatsheet citations resolve
- All scenarios are testable
- All tasks are marked [x]

Then:

```bash
$ openspec archive --change my-feature
```

This:
- Moves the change to `openspec/changes/archive/`
- Syncs delta specs to main specs in `openspec/specs/`
- Updates the project's spec index

**Time: 5 minutes.**

## Decision Tree

| Situation | What to do |
|-----------|-----------|
| New project proposal | `openspec new change --name my-project` (proposal only, no design/specs yet) |
| Adding a feature to existing project | `openspec new change` with full workflow (proposal → design → specs → tasks → implement) |
| Fixing a bug | `openspec new change --name fix-<issue>` with design explaining root cause and fix |
| Refactoring (no behavior change) | `openspec new change --name refactor-<module>` with design explaining why |
| Changing config/infrastructure | `openspec new change --name config-<change>` with specs documenting new behavior |

## Common Mistakes

❌ **Implementing before designing**  
→ Specs are source of truth. Code that diverges from spec is a bug.  
→ Always design first, code second.

❌ **Forgetting @trace annotations**  
→ Code with no trace is invisible to accountability logs.  
→ Add `@trace spec:<name>` near every function implementing a spec.

❌ **Missing Sources of Truth in specs**  
→ Cheatsheets are the knowledge baseline.  
→ Every new spec cites ≥1 cheatsheet under `## Sources of Truth`.

❌ **Archiving incomplete work**  
→ Run `openspec status` — all tasks must be marked [x].  
→ `openspec archive` fails if any task is incomplete.

❌ **One giant proposal instead of bite-sized changes**  
→ Split large features into multiple OpenSpec changes.  
→ Each change converges independently (smaller review surface, easier to revert).

## Quick Reference

| Command | What it does |
|---------|-------------|
| `openspec new change --name X` | Create proposal for change X |
| `openspec instructions design` | Show design template |
| `openspec instructions specs` | Show spec template |
| `openspec instructions tasks` | Show task template |
| `openspec status` | Show % complete, what's blocked |
| `openspec validate` | Lint all artifacts |
| `openspec archive --change X` | Archive X, sync specs to main |

## Sources of Truth

- `cheatsheets/agents/openspec.md` — the full workflow and artifact lifecycle (this is the executive summary)
