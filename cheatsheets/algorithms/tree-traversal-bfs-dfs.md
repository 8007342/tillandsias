---
tags: [algorithm, graph, tree, traversal, bfs, dfs]
languages: []
since: 2026-05-19
last_verified: 2026-05-19
sources:
  - https://en.wikipedia.org/wiki/Breadth-first_search
  - https://en.wikipedia.org/wiki/Depth-first_search
authority: community
status: draft
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---

# Tree traversal: BFS and DFS

@trace spec:agent-cheatsheets

**Use when**: walking tree or graph-shaped data where binary search does not apply because children are linked rather than indexable in sorted order.

## Provenance

- Wikipedia, "Breadth-first search": <https://en.wikipedia.org/wiki/Breadth-first_search>
- Wikipedia, "Depth-first search": <https://en.wikipedia.org/wiki/Depth-first_search>
- **Last updated:** 2026-05-19

## Quick reference

| Traversal | Data structure | Finds shortest unweighted path | Typical use |
|---|---|---|---|
| BFS | queue | yes | levels, nearest match, fanout scans |
| DFS preorder | stack or recursion | no | serialization, parent-before-child work |
| DFS postorder | stack or recursion | no | cleanup, delete children first, dependency teardown |
| DFS inorder | recursion | no | sorted walk of binary search trees |

## Common patterns

### BFS level walk

```text
queue = [root]
while queue is not empty:
    node = queue.pop_front()
    visit(node)
    queue.push_back(node.children)
```

### Iterative DFS

```text
stack = [root]
while stack is not empty:
    node = stack.pop()
    visit(node)
    stack.push(node.children in reverse order)
```

### Track visited nodes for graphs

Trees do not need a visited set, but graphs do. Add one before traversing anything with shared nodes or cycles.

## Common pitfalls

- **Recursive DFS on deep trees** - can overflow the call stack; use an explicit stack for untrusted depth.
- **Forgetting visited state** - graph traversal without it loops forever on cycles.
- **Using DFS for shortest path** - BFS gives shortest paths only for unweighted graphs.
- **Mutating children while iterating** - snapshot child lists if traversal changes the tree.

## See also

- `algorithms/binary-search.md` - use for sorted indexable data, not linked trees

## Pull on Demand

### Source

This is a compact anchor cheatsheet. Pull the linked traversal references when implementation work needs variants, proofs, or language-specific code.

- **Upstream URL(s):**
  - `https://en.wikipedia.org/wiki/Breadth-first_search`
  - `https://en.wikipedia.org/wiki/Depth-first_search`
- **Archive type:** single-page references
- **Expected size:** `<1 MB`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/algorithms/tree-traversal-bfs-dfs`
- **License:** reference-docs
- **License URL:** `https://foundation.wikimedia.org/wiki/Policy:Terms_of_Use`

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/algorithms/tree-traversal-bfs-dfs"
mkdir -p "$TARGET"
cp cheatsheets/algorithms/tree-traversal-bfs-dfs.md "$TARGET/index.md"
```

### Generation guidelines (after pull)

1. Decide whether the structure is a tree or graph before choosing visited-state behavior.
2. Prefer iterative traversal for untrusted depth.
