# OpenSpec Methodology

## Overview

OpenSpec enforces monotonic convergence: specs and implementation move toward each other with every change, never apart. The spec trail is institutional memory and proof of work. This cheatsheet covers the workflow, trace annotations, convergence health, and divergence prevention.

@trace spec:spec-traceability

## Workflow Quick Reference

### The Three Commands

| Step | Command | Produces | When |
|------|---------|----------|------|
| 1. Create | `/opsx:ff` | proposal.md, design.md, specs/\*/spec.md, tasks.md | Start of every change |
| 2. Implement | `/opsx:apply` | Code changes with `@trace` annotations | After artifacts exist |
| 3. Archive | `/opsx:archive` | Moves change to `archive/`, syncs delta specs to main | After implementation is verified |

Post-archive: `./scripts/bump-version.sh --bump-changes` to increment the change count.

### When to Use What

| Situation | Command | Notes |
|-----------|---------|-------|
| New feature or large fix | `/opsx:ff` | Full artifacts: proposal, design, specs, tasks |
| Continue existing change | `/opsx:apply` or `/opsx:continue` | Pick up where you left off |
| Verify before archiving | `/opsx:verify` | Confirms spec-implementation alignment |
| Sync specs without archiving | `/opsx:sync` | Updates main specs from delta specs |
| Explore/investigate first | `/opsx:explore` | Thinking partner before committing to a change |
| Batch archive | `/opsx:bulk-archive` | Multiple completed changes at once |

### Lightweight vs Full Changes

| Criteria | Lightweight (skip design.md) | Full |
|----------|------------------------------|------|
| Lines changed | < 50 | >= 50 |
| Architectural decisions | None | Any non-obvious choice |
| New capabilities | No | Yes |
| Alternatives considered | Zero | One or more |
| Example | Dead code removal, typo fix, trace annotation | Enclave architecture, token rotation |

Lightweight changes still require: proposal.md, tasks.md, `@trace` annotations. Only design.md is optional.

## Trace Annotations

### Format by Context

| Context | Format | Example |
|---------|--------|---------|
| Rust source | `// @trace spec:<name>` | `// @trace spec:native-secrets-store` |
| Bash scripts | `# @trace spec:<name>` | `# @trace spec:forge-launch` |
| Docs/cheatsheets | `@trace spec:<name>` | `@trace spec:spec-traceability` |
| Log events | `spec = "<name>"` field | `info!(spec = "secret-rotation", "token refreshed")` |
| Multiple specs | Comma-separated | `// @trace spec:enclave-network, spec:proxy-container` |
| Commit messages | GitHub search URL | `https://github.com/8007342/tillandsias/search?q=%40trace+spec%3ASPECNAME&type=code` |

### Density Guidelines

| Target | Traces | Rationale |
|--------|--------|-----------|
| Module header | 1 per primary spec | Establishes ownership |
| Architectural decisions | 1 per non-obvious choice | Links "why" to spec |
| Security enforcement | 1 per boundary | Audit trail |
| Plumbing/utilities | 0 | Don't annotate boilerplate |
| Tests | 0 | Tests verify, not implement |
| Overall coverage target | ~20% of code | Only where decisions live |

Good density example: `handlers.rs` has 2.1 traces per function. Not every function needs a trace -- only those enacting spec decisions.

### Canonical Trace Lookup

Use GitHub search URLs as the canonical way to find all code implementing a spec. These are always live and never go stale (unlike line numbers in TRACES.md):

```
https://github.com/8007342/tillandsias/search?q=%40trace+spec%3A<SPECNAME>&type=code
```

## Convergence Health (Audit Snapshot)

### Current Metrics

| Metric | Value | Health |
|--------|-------|--------|
| `@trace` annotations | 273 across codebase | Good |
| Rust files with traces | 27 / 46 (59%) | Acceptable |
| Best trace density | handlers.rs: 2.1 per function | Excellent |
| Changes archived | 142 in ~14 days | High velocity |
| Same-day turnarounds | 79 (56%) | Fast iteration |
| Main specs with zero traces | 12 / 34 (35%) | Needs work |
| Ghost/orphan trace names | 8 | Needs cleanup |
| Unsynced archived specs | 4 | Needs sync |
| Stale TRACES.md entries | 1 (proxy-container) | Minor |

### Specs Needing Traces (Zero Coverage)

These 12 main specs have no `@trace` references in code. Prioritize by implementation maturity:

| Priority | Action |
|----------|--------|
| Implemented but untraced | Add traces on next touch |
| Planned/future | No action until implemented |
| Archived/deprecated | Consider removing from main specs |

### Ghost Traces (Referenced but No Main Spec)

8 trace names appear in code but have no corresponding `openspec/specs/<name>/spec.md`. Either:
1. Create the missing spec, or
2. Update the trace to reference the correct spec name

## Common Divergence Patterns

| Pattern | Symptom | Detection | Fix |
|---------|---------|-----------|-----|
| Spec rot | Spec describes behavior code no longer implements | `/opsx:verify` | Update spec or revert code |
| Ghost traces | `@trace spec:X` but no `specs/X/` exists | Search for orphan names | Create spec or fix trace name |
| Unsynced archives | Delta spec archived but not synced to main | Check archive README.md presence | Run `/opsx:sync` retroactively |
| TRACES.md drift | Line numbers stale after edits | Manual inspection | Use GitHub search URLs instead |
| Security boundary divergence | Implementation adds/removes protections not in spec | Code review against spec | Update spec first, then code |
| Multi-agent overlap | Two changes modify same spec without coordination | Check active changes for same spec | Sequence changes, don't parallelize |

## Optimization Rules of Thumb

### Process Efficiency

| Rule | Rationale |
|------|-----------|
| < 50 lines and no design decisions? Skip design.md | Reduce ceremony for trivial fixes |
| Use GitHub search URLs, not line numbers | Always live, never stale |
| Run `/opsx:verify` before every archive | Catches divergence before it's locked in |
| Archive changes same-day when possible | 56% already do -- keep this velocity |
| Break large features into 3-5 independent changes | Each converges independently |

### Maintenance

| Rule | Rationale |
|------|-----------|
| Add traces when you touch a file, not in bulk | Organic growth, less churn |
| Fix ghost traces when discovered | Don't let orphans accumulate |
| Archive README.md is optional but useful | 70% currently lack one -- not blocking |
| openspec/ directory is 3.6MB | Consider branch-archiving old changes if it grows past 10MB |
| Schedule periodic `/opsx:verify` passes | Prevents silent spec drift |

### Automation Opportunities

| Opportunity | Effort | Impact |
|-------------|--------|--------|
| Pre-commit hook: validate `@trace spec:X` names against `specs/` | Low | Catches ghost traces at commit time |
| CI check: specs with zero traces report | Low | Visibility into coverage gaps |
| Active change timeout warning (> 7 days) | Medium | Prevents abandoned changes |
| Automated TRACES.md from GitHub search | Medium | Eliminates line-number drift entirely |

## Failure Modes

| Scenario | What happens | Recovery |
|----------|-------------|----------|
| Spec modified without user approval | Convergence breaks -- code may implement wrong behavior | Revert spec change; re-discuss with user |
| Archive without `/opsx:verify` | Divergence locked into archive | Re-open change, fix divergence, re-archive |
| Parallel agents modify same spec | Merge conflicts in spec files; potential contradictions | Sequence agents; review merged spec for coherence |
| Ghost trace accumulation | Traces point nowhere; misleading audit trail | Periodic cleanup pass; pre-commit validation |
| openspec/ grows unbounded | Slows git operations, wastes disk | Move old archives to `openspec-archive` branch |

## Related

**Specs:**
- `openspec/specs/spec-traceability/spec.md` -- trace annotation requirements

**Source:**
- `CLAUDE.md` -- canonical OpenSpec and trace rules
- `openspec/changes/` -- active changes
- `openspec/changes/archive/` -- completed changes
- `openspec/specs/` -- main specs (source of truth)

**Cheatsheets:**
- `docs/cheatsheets/logging-levels.md` -- how `@trace` appears in log output
