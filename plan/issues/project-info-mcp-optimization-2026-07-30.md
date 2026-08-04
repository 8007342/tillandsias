# optimization: project-info MCP server — bugs, gaps, and new endpoint proposals

- Date: 2026-07-30
- Class: optimization (tooling; in-forge agent efficiency)
- Filed by: forge container (meta-orchestration cycle 2026-07-30T16:40Z)
- Evidence: tested all 8 project-info endpoints against known facts from the previous meta-orch cycle; compared call counts vs traditional tools across 8 common scenarios.

## Bugs found

### Bug 1: `search_code` glob is basename-only, not full-path

When `glob = "plan/index.yaml"` is passed, **no matches are returned** even though the file exists and contains the pattern. The glob matcher appears to strip the directory component and compare only the basename (`index.yaml`) against the basename of each file. `glob = "*.sh"` matches nothing in subdirectories for the same reason — it looks for literal `*.sh` as a basename match.

**Evidence**:
- `search_code(pattern="_THS", glob="help.sh")` → finds `images/default/help.sh` ✓ (basename match)
- `search_code(pattern="_THS", glob="images/default/help.sh")` → "No matches found" ✗ (path prefix not matched)
- `search_code(pattern="status: ready", glob="plan/index.yaml")` → "No matches found" ✗ (path prefix not matched)
- `search_code(pattern="_THS", glob="*.sh")` → "No matches found" ✗ (no recursive glob)
- `search_code(pattern="_THS", glob="**/*.sh")` → "No matches found" ✗ (no `**` support)

**Impact**: `search_code` is effectively unusable for project-level searches. Every meta-orch cycle needs to find content in specific files (plan/index.yaml, scripts/*.sh, etc.), but search_code cannot target them.

### Bug 2: No file-glob / find-by-name tool

There is no endpoint to find files by glob pattern (equivalent to `glob("**/*.rs")` or `glob("images/**")`). This is the most common single tool call in any meta-orch cycle.

### Bug 3: `project_structure` is depth-limited with hard caps

Max 100 entries, max depth 3. The Tillandsias repo has ~2500+ files — depth 3 skips most of the tree. The primary use case (getting oriented in a subdirectory) is not served because `project_structure` starts from root.

## Benchmark: project-info vs traditional tools (8 scenarios)

| Scene | project-info calls | Traditional calls | Winner |
|---|---|---|---|
| Project detection | 2 (`project_type` + `project_info`) | 3 (`bash uname` + `bash git branch` + `read Cargo.toml`) | project-info (folds 2 bash calls) |
| File find by glob | **0 — missing tool** | 1 (`glob`) | Traditional |
| Content search (recursive) | **broken** (glob no recursion) | 1 (`grep`) | Traditional |
| Read file header | 1 (`file_summary`) | 1 (`read`) | Tie — but file_summary also returns line count |
| Directory listing | 1 (`project_structure`) | 1 (`read dir`) | Tie — but read shows all entries |
| Git status | **0 — missing tool** | 1 (`bash git status`) | Traditional |
| Sibling projects | 1 (`sibling_projects`) | 1 (`bash ls ~/src/`) | Tie |
| File search by type | **0 — missing tool** | 1 (`glob`) | Traditional |

**Net savings in a typical meta-orch cycle**: project-info could save ~2-3 bash calls (host detection, project-type queries) but the missing/broken features mean it currently ADDS calls (need to fall back to traditional tools for glob, grep, git-status).

## Proposed new endpoints

These would make project-info a genuine call-folder that replaces multiple traditional tool calls with one.

### 1. `find_files(glob: str)` — file glob search

Equivalent to the existing `glob` tool. Most common single operation in any cycle:

```json
{
  "name": "find_files",
  "arguments": {
    "pattern": "**/*.sh",
    "path": "images/"
  }
}
```

**Saves**: replaces `glob()` calls. Folds `project_structure` for targeted queries.

### 2. `grep_code(pattern: str, path: str, include: str)` — recursive content search

A fixed version of `search_code` with proper path-glob matching. The `glob` parameter should use standard recursive glob semantics (`*.sh` matches only root, `**/*.sh` matches recursively, `plan/index.yaml` matches by full path).

**Saves**: replaces `grep()` calls. Current `search_code` is a liability since it silently returns no results.

### 3. `git_status()` — working tree status

Returns parsed `git status --porcelain` as structured data (list of {path, status, staged_status}). This is checked at the start and end of every meta-orch cycle.

**Saves**: replaces `bash(git status)` calls (at least 2 per cycle).

### 4. `read_file(path: str, offset: int, limit: int)` — full file reading

The current `file_summary` only returns the first N lines. A proper file-read endpoint (matching the `read` tool's capabilities with offset/limit) would save the fallback to traditional `read` calls.

**Saves**: replaces `read()` calls when you need more than the first N lines.

### 5. `plan_query(filter: dict)` — structured plan/index.yaml access

A query endpoint that returns structured plan packets matching a filter (status, capability_tags, owner_host). This is what meta-orch `worker drain` spends the most calls on — finding eligible packets.

```json
{
  "name": "plan_query",
  "arguments": {
    "status": "ready",
    "capability_tags": ["forge"],
    "limit": 10
  }
}
```

**Saves**: replaces `grep("plan/index.yaml", "status: ready")` + context reads. This alone would save 3-5 calls per cycle.

## Verifiable closure

1. `search_code(glob="plan/index.yaml", pattern="packet_id:")` returns results (bug 1 fix)
2. `find_files(pattern="**/*.sh")` returns nested `.sh` files (new endpoint)
3. A forge meta-orch cycle using project-info for all 8 scenes needs FEWER total tool calls than one using only traditional tools (current state: MORE)
