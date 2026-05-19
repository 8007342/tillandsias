---
tags: [patterns, gof, strategy, design]
languages: []
since: 2026-05-19
last_verified: 2026-05-19
sources:
  - https://en.wikipedia.org/wiki/Strategy_pattern
  - https://refactoring.guru/design-patterns/strategy
authority: community
status: draft
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---

# GoF Strategy pattern

@trace spec:agent-cheatsheets

**Use when**: selecting one interchangeable algorithm or policy at runtime without branching throughout the caller.

## Provenance

- Wikipedia, "Strategy pattern": <https://en.wikipedia.org/wiki/Strategy_pattern>
- Refactoring.Guru, "Strategy": <https://refactoring.guru/design-patterns/strategy>
- **Last updated:** 2026-05-19

## Quick reference

| Role | Responsibility |
|---|---|
| Context | Owns workflow and calls the strategy |
| Strategy interface | Defines the operation contract |
| Concrete strategy | Implements one algorithm or policy |
| Selection logic | Chooses strategy from config, inputs, or environment |

## Common patterns

### Replace branching with a strategy map

```text
strategies = {
    "fast": FastSearch(),
    "accurate": AccurateSearch(),
}
result = strategies[mode].run(input)
```

### Keep strategy state explicit

Pass dependencies into the strategy constructor. Avoid strategies that secretly read global state.

### Test strategies through the same contract

Shared contract tests catch inconsistent edge-case behavior across implementations.

## Common pitfalls

- **Over-abstracting one implementation** - wait until there are real alternative policies.
- **Leaking strategy details into context** - the caller should not know concrete internals.
- **Different error semantics per strategy** - normalize failures at the interface boundary.

## See also

- `patterns/gof-observer.md` - event notification pattern often paired with policy selection
- `algorithms/binary-search.md` - example of an algorithm that might be selected as a strategy

## Pull on Demand

### Source

This is a compact anchor cheatsheet. Pull the linked pattern references when implementation work needs diagrams, variants, or language examples.

- **Upstream URL(s):**
  - `https://refactoring.guru/design-patterns/strategy`
  - `https://en.wikipedia.org/wiki/Strategy_pattern`
- **Archive type:** single-page references
- **Expected size:** `<1 MB`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/patterns/gof-strategy`
- **License:** mixed-reference-docs
- **License URL:** `https://en.wikipedia.org/wiki/Wikipedia:Copyrights`

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/patterns/gof-strategy"
mkdir -p "$TARGET"
cp cheatsheets/patterns/gof-strategy.md "$TARGET/index.md"
```

### Generation guidelines (after pull)

1. Introduce a strategy only when multiple real policies share a stable contract.
2. Keep error semantics consistent across strategies.
