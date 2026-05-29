---
tags: [algorithm, sorting, complexity, data-structures]
languages: []
since: 2026-05-19
last_verified: 2026-05-19
sources:
  - https://en.wikipedia.org/wiki/Sorting_algorithm
  - https://en.wikipedia.org/wiki/Comparison_sort
authority: community
status: draft
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---

# Sorting comparison

@trace spec:agent-cheatsheets

**Use when**: choosing a sort strategy before applying algorithms that require ordered input, especially binary search, merge phases, and deterministic output.

## Provenance

- Wikipedia, "Sorting algorithm": <https://en.wikipedia.org/wiki/Sorting_algorithm>
- Wikipedia, "Comparison sort": <https://en.wikipedia.org/wiki/Comparison_sort>
- **Last updated:** 2026-05-19

## Quick reference

| Sort | Average | Worst | Stable | Use when |
|---|---:|---:|---|---|
| Merge sort | O(n log n) | O(n log n) | yes | stable ordering or linked/external data |
| Quicksort | O(n log n) | O(n^2) | no | in-memory average-case speed |
| Heapsort | O(n log n) | O(n log n) | no | bounded extra memory and worst-case guard |
| Insertion sort | O(n^2) | O(n^2) | yes | tiny or nearly sorted inputs |
| Counting/radix sort | O(n + k) | O(n + k) | varies | bounded integer/key domains |

## Common patterns

### Sort before binary search

```text
items = sort(items)
index = binary_search(items, target)
```

Sorting once pays off when many lookups follow. For one lookup, a linear scan may be simpler and faster.

### Preserve input order on ties

Use a stable sort when equal keys carry secondary meaning, such as chronological events with equal priority.

### Avoid sorting when a heap is enough

Use a heap or selection algorithm for top-k queries; full sort is unnecessary if only the first few items matter.

## Common pitfalls

- **Sorting inside a loop** - sort once, then reuse the ordered structure.
- **Assuming stability** - language default sorts differ; check before relying on tie order.
- **Comparator not transitive** - inconsistent comparators can panic, loop, or return nondeterministic order.
- **Binary search on unsorted input** - the result is meaningless even if tests pass accidentally.

## See also

- `algorithms/binary-search.md` - ordered input is the precondition for binary search

## Pull on Demand

### Source

This is a compact anchor cheatsheet. Pull the linked references when implementation work requires language-specific sorting APIs, stability guarantees, or proof details.

- **Upstream URL(s):**
  - `https://en.wikipedia.org/wiki/Sorting_algorithm`
  - `https://en.wikipedia.org/wiki/Comparison_sort`
- **Archive type:** single-page references
- **Expected size:** `<1 MB`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/algorithms/sorting-comparison`
- **License:** reference-docs
- **License URL:** `https://foundation.wikimedia.org/wiki/Policy:Terms_of_Use`

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/algorithms/sorting-comparison"
mkdir -p "$TARGET"
cp cheatsheets/algorithms/sorting-comparison.md "$TARGET/index.md"
```

### Generation guidelines (after pull)

1. Check the target language's sort stability and comparator contract before choosing an algorithm.
2. Prefer library sorts unless the problem explicitly needs a custom data structure or complexity proof.
