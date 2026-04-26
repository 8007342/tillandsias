---
tags: [algorithm, search, divide-and-conquer, sorted-arrays, complexity]
languages: []
since: 2026-04-25
last_verified: 2026-04-25
sources:
  - https://en.wikipedia.org/wiki/Binary_search
  - https://www.cs.usfca.edu/~galles/visualization/Search.html
authority: community
status: current
---

# Binary search

@trace spec:agent-cheatsheets

## Provenance

- Wikipedia, "Binary search": <https://en.wikipedia.org/wiki/Binary_search> (CC-BY-SA 4.0)
- USFCA Algorithm Visualisations (Galles), "Searching": <https://www.cs.usfca.edu/~galles/visualization/Search.html> — visual reference
- Originating description: D.E. Knuth, *The Art of Computer Programming*, Vol. 3 §6.2.1 (book — citation only, not URL)
- **Last updated:** 2026-04-25

## Use when

You have a **sorted** array (or any indexable, monotonic structure) and need O(log n) lookup. If the input isn't sorted, sort first — but consider whether a hash table (O(1) avg) is the better data structure entirely.

## Quick reference

| Property | Value |
|---|---|
| Time | O(log₂ n) — halves the search space each step |
| Space | O(1) iterative, O(log n) recursive (call stack) |
| Precondition | Array must be sorted in the order being searched |
| Returns | Index of target, or insertion point (varies by variant) |

## Common patterns

### Pattern 1 — iterative, returns index or `-1`

```text
function binary_search(arr, target):
    lo, hi = 0, len(arr) - 1
    while lo <= hi:
        mid = lo + (hi - lo) / 2          // avoid (lo+hi) overflow
        if arr[mid] == target: return mid
        if arr[mid] < target:  lo = mid + 1
        else:                   hi = mid - 1
    return -1
```

### Pattern 2 — `lower_bound` (first index where `arr[i] >= target`)

```text
function lower_bound(arr, target):
    lo, hi = 0, len(arr)                  // note: hi = len, not len-1
    while lo < hi:
        mid = lo + (hi - lo) / 2
        if arr[mid] < target: lo = mid + 1
        else:                  hi = mid
    return lo
```

Returns `len(arr)` if every element is < target. Useful for insertion-sort-into-sorted-array, range queries, deduplication boundaries.

### Pattern 3 — predicate-based (binary search on answer)

```text
// Find smallest x such that predicate(x) is true, over a monotonic predicate.
function find_smallest(lo, hi, predicate):
    while lo < hi:
        mid = lo + (hi - lo) / 2
        if predicate(mid): hi = mid
        else:               lo = mid + 1
    return lo
```

Works on integers, floats (with epsilon), or any monotonic search space — not just arrays.

## Common pitfalls

- **Integer overflow** — `(lo + hi) / 2` can overflow for large indices. Use `lo + (hi - lo) / 2`. The classic Java/JDK bug from 2006: <https://research.google.com/archive/2006/06/extra-extra-read-all-about-it-nearly.html>
- **Off-by-one in the bounds** — `hi = len(arr)` (exclusive) for `lower_bound`-style; `hi = len(arr) - 1` (inclusive) for the basic find. Mixing styles in the same loop is the most common bug.
- **Unsorted input** — silent wrong-answer. Validate or assert sortedness in debug builds.
- **NaN / partial ordering** — float arrays with NaN have no total order; binary search is undefined. Strip NaN first.
- **Duplicates** — basic binary search returns ANY matching index, not the first or last. Use `lower_bound` / `upper_bound` if you need a specific occurrence.
- **Empty array** — `lo = 0, hi = -1`, loop never enters, returns -1 — correct, but verify the variant you wrote handles it.

## Language stdlib equivalents

- C++: `std::lower_bound`, `std::upper_bound`, `std::binary_search`
- Java: `java.util.Collections.binarySearch`, `java.util.Arrays.binarySearch`
- Python: `bisect.bisect_left`, `bisect.bisect_right`
- Rust: slice `binary_search`, `binary_search_by`, `partition_point`
- Go: `sort.Search`

Always prefer stdlib unless you have a specific reason — the edge cases (overflow, duplicates, NaN) are already handled.

## See also

- `algorithms/sorting-comparison.md` — needed to make binary search applicable
- `algorithms/tree-traversal-bfs-dfs.md` — search on non-array structures
- `patterns/gof-strategy.md` — when search-strategy needs to vary at runtime
