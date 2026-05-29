---
tags: [git, plan, ledger, stable-ids, append-only, upsert]
languages: [bash, yaml, markdown]
since: 2026-05-25
last_verified: 2026-05-25
sources:
  - methodology/distributed-work.yaml
  - methodology/multi-host-development.yaml
  - plan/issues/branch-and-coordination-canon-2026-05-25.md
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: true
---
# Concurrent Git — Plan Discipline

@trace methodology/distributed-work.yaml

**Use when**: you're writing or updating anything under `plan/`, `methodology/`, `openspec/`, or `cheatsheets/`.

## Provenance

- `methodology/distributed-work.yaml` — CRDT-inspired primitives
- `methodology/multi-host-development.yaml` — plan-write discipline rule
- **Last updated:** 2026-05-25

## The three iron rules

1. **All plan/-class writes go to `linux-next`.** Even from a Windows or macOS host. The plan ledger is single-branch by design.
2. **Stable IDs, semantic upserts.** Don't create a new file every time; find the matching ID block and append/update.
3. **Append-only events.** Never rewrite an event another agent wrote. Tombstone or supersede, never delete.

## File-type to write-style map

| File type | Style | Example |
|---|---|---|
| `plan.yaml` | Last-writer-wins on status fields; semantic upsert on tasks | `tasks[].status: completed` |
| `plan/index.yaml` | Same — status fields LWW with `progress_note` | `status: in_progress` + `progress_note: "..."` |
| `plan/steps/<id>.md` | Append-only sections; "Cycle log" or "Events" at the bottom | New section per checkpoint |
| `plan/issues/<id>.md` | Same | New section per event |
| `methodology/*.yaml` | Section-keyed; can edit a section in-place | Versioned per the file's own `version:` |
| `openspec/changes/<id>/*` | Edit in-place; commit chain tells the story | Per OpenSpec discipline |
| `cheatsheets/<cat>/<id>.md` | Edit in-place; `last_verified:` bumps | YAML frontmatter tracked |

## Quick reference — stable-ID upsert

Given a plan issue file with stable-ID blocks like:

```markdown
### Cycle 2026-05-25T03:43Z — INTEGRATED
...
```

To add the NEXT cycle, insert a new block ABOVE the most recent one (reverse-chronological):

```markdown
### Cycle 2026-05-25T05:43Z — INTEGRATED
...
[new content here]

### Cycle 2026-05-25T03:43Z — INTEGRATED
[existing content, untouched]
```

To update an existing item that you previously authored (within the cap of "latest 20 verbatim"), find the block by its ID/timestamp and add follow-up details inline OR append a sub-block.

## Quick reference — events list in a work-item file

```markdown
## Events

- type: claim
  ts: 2026-05-25T06:30:00Z
  agent_id: linux-tlatoani-fedora-claudia-cli-2026-05-25T06
  host: linux
  lease_id: a1b2c3d4e5f6
  expires_at: 2026-05-25T10:30:00Z

- type: progress
  ts: 2026-05-25T07:15:00Z
  agent_id: linux-tlatoani-fedora-claudia-cli-2026-05-25T06
  host: linux
  lease_id: a1b2c3d4e5f6
  note: "extracted dispatch fn; tests pass"
  partial_artifact_refs:
    - commit: 7f8455f6

- type: completed
  ts: 2026-05-25T09:30:00Z
  agent_id: linux-tlatoani-fedora-claudia-cli-2026-05-25T06
  host: linux
  lease_id: a1b2c3d4e5f6
  evidence_refs:
    - commit: a9adf59f
    - pr: "#2"
```

The fold of those 3 events → status `done`, last_agent linux-tlatoani-…, completed_at 09:30Z.

## Common patterns

### Pattern A — adding a new cycle entry to a reverse-chronological log

```bash
# from any host
git fetch origin --prune
git checkout linux-next && git pull --ff-only

# edit plan/issues/multi-host-integration-loop-2026-05-24.md
# add new "### Cycle <UTC>" section above the most recent one

git add plan/issues/multi-host-integration-loop-2026-05-24.md
git commit -m "chore(plan): multi-host integration cycle <UTC>"
git push origin linux-next || (git fetch && git rebase origin/linux-next && git push origin linux-next)
```

### Pattern B — tombstoning a superseded section (never delete)

```markdown
### Cycle 2026-05-25T01:43Z — SKIPPED (dirty working tree)

**SUPERSEDED 2026-05-25T05:43Z**: the dirty-tree skip pattern this cycle
recorded was rolled up into the methodology's "common pitfalls" entry
`dirty-tree-blocks-integration` (see
methodology/multi-host-development.yaml). Retained here for the chronology;
do not act on it.

[original content stays below]
```

Never `git rm` or remove text. Tombstoning preserves provenance.

### Pattern C — marking an existing status item in-place

In `plan/index.yaml`:

```yaml
    - id: foo-bar
      status: in_progress       # ← updated from "ready"
      progress_note: "linux host claimed 2026-05-25T06Z, lease a1b2c3d4e5f6; see plan/issues/foo-2026-05-25.md for events"
```

The `progress_note` tells subsequent readers WHAT changed and points at the events log.

## Common pitfalls

1. **`git add -A` from a dirty tree** — sweeps in session-local files, IDE state, lockfiles you don't want committed. Use explicit paths.
2. **Editing another agent's event entry** — append-only. Add yours; leave theirs alone.
3. **Splitting one stable ID across two files** — pick ONE canonical file per stable ID. Cross-references are fine; duplication is not.
4. **Forgetting the `progress_note` when changing a status** — leaves the next reader guessing why.
5. **Writing the same content into two issue files because you didn't search first** — see the macOS D6 / Windows D8 collision in `plan/issues/multi-host-integration-loop-2026-05-24.md` cycle `05:43Z`. Always grep before drafting.
6. **Pushing plan/ writes to a sibling branch** — they're stranded until someone merges. Always `linux-next` for plan/-class files.
7. **Forgetting to bump `last_verified:` on a cheatsheet edit** — the cheatsheet INDEX regeneration depends on it.

## See also

- `concurrent-git/branches.md` — branch destinations
- `concurrent-git/agent-handoff.md` — claim / progress / complete / release events
- `methodology/distributed-work.yaml` — full schema
