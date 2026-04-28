# Forge Discovery

@trace spec:forge-opencode-onboarding, spec:forge-environment-discoverability
@cheatsheet runtime/cheatsheet-architecture-v2.md, agents/openspec.md

You've just attached to a development environment. Before writing code, discover what's available.

## Quick Start

1. Run `tillandsias-inventory` to list pre-installed tools and versions
2. Read `$TILLANDSIAS_CHEATSHEETS/INDEX.md` to see all knowledge references
3. Check `openspec/changes/` for in-flight work or open tasks
4. Only assume a tool is missing AFTER checking inventory

## The Inventory Command

```bash
$ tillandsias-inventory
```

This prints every tool installed in this forge:
- Language runtimes (Rust, Go, Python, Java, Node, etc.)
- Build tools (cargo, gradle, maven, npm, pnpm, nix, etc.)
- Utilities (jq, rg, git, gh, sqlite3, etc.)
- Versions pinned at image build time

**Don't guess if a tool exists.** `tillandsias-inventory | grep <tool>` is faster than trial-and-error.

## The Cheatsheet Index

```bash
$ cat $TILLANDSIAS_CHEATSHEETS/INDEX.md | rg <topic>
```

Cheatsheets are one-file-per-use-case snippets organized by category:
- `runtime/` — forge paths, caching, networking, container limits
- `languages/` — per-language idioms and version-specific gotchas
- `build/` — Cargo, Gradle, Nix, Maven (not tool READMEs — use-case slices)
- `utils/` — git, jq, ssh, curl (quick reference, not man pages)
- `agents/` — Claude Code, OpenCode, OpenSpec workflows
- `test/` — pytest, JUnit, Playwright patterns
- `architecture/` — event-driven, reactive, CRDT patterns
- `security/` — OWASP, threat models, secret management

Find a reference, read it, cite it in your code: `// @cheatsheet runtime/forge-paths-ephemeral-vs-persistent.md`

## OpenSpec Changes

Work often happens via OpenSpec changes. Check what's in flight:

```bash
$ openspec status
```

This shows:
- In-progress changes (proposal → design → specs → tasks)
- Archived changes (completed work, specs synced to main)
- Your next task if you're implementing an existing change

**Common workflow:**
- User proposes a feature → you implement the tasks
- You document work in OpenSpec specs
- Your code includes `@trace spec:<name>` annotations linking to those specs

See `cheatsheets/agents/openspec.md` for the full artifact lifecycle.

## Three Patterns

### Pattern 1: Implement a user-requested feature

User: "Add a login form"  
→ Check `openspec/changes/` for a proposal or design  
→ If none exists, create `openspec/changes/<feature>/proposal.md`  
→ Run through the workflow (design → specs → tasks → implement → archive)  
→ Cite `@trace spec:<name>` in code

### Pattern 2: Fix a bug

User: "The build is broken"  
→ Check inventory and cheatsheets for known limitations (`cheatsheets/runtime/runtime-limitations.md`)  
→ Reproduce the issue  
→ Create an OpenSpec change: `openspec/changes/fix-<issue>/proposal.md`  
→ Keep it focused (fix only the bug, no scope creep)

### Pattern 3: Refactor or optimize

User: "Cargo builds take 3 minutes"  
→ Consult `cheatsheets/runtime/forge-cache-architecture.md` — builds hitting the right cache?  
→ Consult `cheatsheets/build/cargo-optimization.md` — profile bottlenecks first  
→ Document changes in OpenSpec before optimizing

## Where to Look When Stuck

| Question | Answer lives in |
|----------|-----------------|
| "Is tool X installed?" | `tillandsias-inventory \| grep X` |
| "How do I use tool X?" | `cheatsheets/<category>/<X>.md` (use-case focused, not man pages) |
| "Where should I write files?" | `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md` |
| "How do I declare shared deps?" | `cheatsheets/runtime/forge-shared-cache-via-nix.md` |
| "What OpenSpec workflow step am I on?" | `cheatsheets/agents/openspec.md` |
| "What changes are in flight?" | `openspec status` or `ls openspec/changes/` |

## Sources of Truth

- `cheatsheets/runtime/cheatsheet-architecture-v2.md` — how cheatsheets are organized and queried
- `cheatsheets/agents/openspec.md` — when to create proposals, designs, specs, and tasks
