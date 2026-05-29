---
tags: [git, multi-host, branches, coordination]
languages: [bash]
since: 2026-05-25
last_verified: 2026-05-25
sources:
  - methodology/multi-host-development.yaml
  - methodology/distributed-work.yaml
  - plan/issues/branch-and-coordination-canon-2026-05-25.md
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: true
---
# Concurrent Git — Branches

@trace methodology/multi-host-development.yaml, plan/issues/branch-and-coordination-canon-2026-05-25.md

**Version baseline**: branch canon decided 2026-05-25
**Use when**: starting any work session on any platform host, or any time you're unsure which branch a given change belongs on.

## Provenance

- `methodology/multi-host-development.yaml` — the methodology rule
- `plan/issues/branch-and-coordination-canon-2026-05-25.md` — the canonical decision record
- **Last updated:** 2026-05-25

## Canonical branch names

| Host | Branch | Notes |
|---|---|---|
| Linux | `linux-next` | Also the integration branch + sole `plan/` write target |
| Windows | `windows-next` | |
| macOS | `osx-next` | NOT `macos-next` — grandfathered name |
| Released | `main` | PR from `linux-next` only |

## What goes where

| Kind of change | Branch | Why |
|---|---|---|
| `plan/**`, `methodology/**`, `openspec/**`, `cheatsheets/**`, top-level `.md` tombstones | **`linux-next` ALWAYS, from any host** | One ledger branch, no merge conflicts on coordination state |
| Linux-specific code | `linux-next` directly | Linux is the native host + integration branch |
| Windows-specific code (`crates/tillandsias-windows-tray/**`, `crates/tillandsias-vm-layer/src/wsl*`) | `windows-next` | Integration loop merges to `linux-next` every 2h |
| macOS-specific code (`crates/tillandsias-macos-tray/**`, `crates/tillandsias-vm-layer/src/vz*`) | `osx-next` | Same — loop merges |
| Shared crates (control-wire, host-shell, vm-layer recipe/materialize/cache) | Author's own platform branch first | Cross-platform check happens on Linux integration |
| Release tag | `main` only, after manual `gh workflow run release.yml` | Per CLAUDE.md / methodology/versioning.yaml |

## Quick reference

```bash
# Start a session — figure out where you are
git branch --show-current
git status --short --branch

# Fetch everything (always do this first)
git fetch origin --prune

# See sibling heads (cross-host situational awareness)
git ls-remote origin refs/heads/main refs/heads/linux-next refs/heads/windows-next refs/heads/osx-next

# Pull your own platform branch
git checkout <your-platform-branch>     # e.g. windows-next
git pull --ff-only origin <your-platform-branch>

# Write to plan/ from a non-linux host: hop to linux-next
git stash --include-untracked            # save your platform work
git checkout linux-next
git pull --ff-only origin linux-next
# ...edit plan/issues/<file>...
git add plan/issues/<file>
git commit -m "docs(plan): <subject>"
git push origin linux-next
git checkout <your-platform-branch>
git stash pop
```

## Common patterns

### Pattern 1 — start of session (any host)

```bash
git fetch origin --prune
git status --short --branch                 # must be clean before integration work
git checkout linux-next && git pull --ff-only
git ls-remote origin refs/heads/main refs/heads/linux-next refs/heads/windows-next refs/heads/osx-next
# record observed sibling heads in your active plan/ entry
```

### Pattern 2 — push code to your platform branch

```bash
git checkout windows-next   # or osx-next
git pull --ff-only origin windows-next
# ...edit code...
git add crates/tillandsias-windows-tray/src/...
git commit -m "feat(windows-next): <what>"
git push origin windows-next
```

### Pattern 3 — push a plan/ note FROM a non-linux host

The plan/ branch is ALWAYS `linux-next`. Don't put plan/ notes on `windows-next` / `osx-next`.

```bash
git stash --include-untracked      # save in-flight code work
git fetch origin --prune
git checkout linux-next && git pull --ff-only
# ...edit plan/issues/<file>...
git add plan/issues/<file>
git commit -m "docs(plan): <subject>"
git push origin linux-next
git checkout windows-next          # back to your code branch
git stash pop
```

### Pattern 4 — release-time PR

```bash
# This is a USER action, not an agent action.
# Agents may recommend a release in plan/ but never trigger it.
# When the user is ready:
#   1. Merge PR (linux-next → main) via the GitHub UI / `gh pr merge 2`
#   2. Tag: ./scripts/bump-version.sh --bump-build (or whatever is current per methodology/versioning.yaml)
#   3. Trigger release: gh workflow run release.yml -f version="X.Y.Z"
#   4. Smoke-test all 3 platforms.
```

## Common pitfalls

1. **Saying `macos-next` instead of `osx-next`** — wrong branch name. The branch is `osx-next`. This is on purpose.
2. **Pushing platform code directly to `linux-next`** — short-circuits the integration loop's isolation checks. Only Linux-host code + cross-cutting docs go to `linux-next` directly.
3. **Writing `plan/` to `windows-next` / `osx-next`** — splits the coordination ledger across branches. ALWAYS push plan/ writes to `linux-next`.
4. **`git push --force` to a platform branch with sibling traffic** — destroys other hosts' work. NEVER force-push.
5. **`git add -A` with a dirty tree** — stages files you didn't mean to (session-local artifacts, IDE state, lockfiles). Always stage by explicit path.
6. **`gh pr create` while PR #2 is open** — no, push to `linux-next` and PR #2 updates automatically.
7. **Forgetting to fetch before claiming work** — you may draft something a sibling host already drafted. See `agent-handoff.md`.

## See also

- `concurrent-git/agent-handoff.md` — how to claim, resume, and release work
- `concurrent-git/plan-discipline.md` — what `plan/` writes look like
- `methodology/multi-host-development.yaml` — the methodology rule
- `methodology/distributed-work.yaml` — CRDT-inspired primitives
