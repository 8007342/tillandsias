# Branch + Coordination Canon — 2026-05-25

trace: methodology/multi-host-development.yaml, methodology/distributed-work.yaml, plan/issues/multi-host-integration-loop-2026-05-24.md, plan/issues/control-socket-protocol-convergence-2026-05-25.md, plan/issues/tray-convergence-coordination.md

Status: **CANON** as of 2026-05-25T06:00Z. Supersedes any earlier informal
guidance. Cited by `methodology/distributed-work.yaml` and the cheatsheets
under `cheatsheets/concurrent-git/`.

## 1. Branch names — canonical spellings

| Host | Platform branch | NOT a valid name |
|---|---|---|
| Linux | `linux-next` | — |
| Windows | `windows-next` | — |
| macOS | `osx-next` | `macos-next` (incorrect; tombstone-only) |
| Released | `main` | — |

Decision: `osx-next` stays. `methodology/multi-host-development.yaml`
already declares `platform_branches.macos: osx-next`. The name predates the
Apple branding shift from OS X → macOS and is grandfathered for stability.
Any agent or doc that says "macos-next" is wrong and should be corrected to
`osx-next`. (User raised the confusion on 2026-05-25; canonising here so it
stops biting.)

## 2. Where work lands

| Kind of work | Branch destination | Rationale |
|---|---|---|
| **Linux-host code** (`tillandsias-headless`, GTK tray, Linux-specific bits) | `linux-next` directly | Linux is the native runtime and integration branch. |
| **Windows-host code** (`tillandsias-windows-tray`, `vm-layer::wsl`, etc.) | `windows-next` first, then merged into `linux-next` by the integration loop | Keeps Windows churn isolated until tests/checks settle on Linux integration. |
| **macOS-host code** (`tillandsias-macos-tray`, `vm-layer::vz`, etc.) | `osx-next` first, then merged into `linux-next` by the integration loop | Same as Windows. |
| **Shared crates / protocol** (`tillandsias-control-wire`, `tillandsias-host-shell`, `tillandsias-vm-layer`'s shared modules) | Author's own platform branch first; loop integrates | Lets author validate locally; integration tests on Linux. |
| **`plan/` writes** (issues, steps, ledgers, status reports) | **`linux-next` directly, ALWAYS** | One ledger branch; eliminates merge conflicts on coordination state. Any host writing `plan/` checks out `linux-next` (or its local equivalent), commits, pushes. |
| **`methodology/`, `openspec/changes/`, `openspec/specs/`** | `linux-next` directly | Cross-cutting normative content; same reasoning as plan/. |
| **`cheatsheets/` (agent-facing)** | `linux-next` directly | Baked into forge image; central authority. |
| **Release tagging** | `main` only, after merge of `linux-next` → `main` and after the manual release workflow (`gh workflow run release.yml -f version=…`). | Per CLAUDE.md and `methodology/versioning.yaml`. |

## 3. Release flow

```
windows-next  ─┐
                ├─→  linux-next  ─→  main  ─→  release workflow  ─→  smoke tests
osx-next      ─┘    (integration       (manual                       (per-platform
                     loop merges       merge after all              verification)
                     every 2h)         green)
```

Constraints:

- Nothing reaches `main` except via PR from `linux-next` (today: PR #2).
- Release workflow is `workflow_dispatch` only — never auto-triggered.
- A release happens when the user (not an agent) decides; agents may
  *recommend* a release in `plan/` but never trigger it.
- Each release SHOULD be followed by a smoke-test pass on all 3 platforms
  before being declared shipped. The smoke-test plan is tracked in a
  per-release plan issue (`plan/issues/release-smoke-<version>.md`).

## 4. The macOS-direct-commit anomaly (2026-05-25)

Background: between 2026-05-25T03Z and 05Z, the macOS host pushed multiple
commits (`74f0ebd2`, `70c7c2a0`, `3db11291`, `3cd90335`, etc.) **directly
to `linux-next`**, never through `osx-next`. The `origin/osx-next` ref has
not moved since the 2026-05-24 alignment.

Decision: **ratify for `plan/` writes; correct for code.**

- `plan/` writes directly to `linux-next` from ANY host is the canonical
  rule (§2 above). macOS doing this is correct.
- macOS-host code commits (touching `crates/tillandsias-macos-tray/**`,
  `crates/tillandsias-vm-layer/src/vz.rs`, etc.) **SHOULD** route through
  `osx-next` so the integration loop can run isolation checks. macOS direct
  pushing code to `linux-next` short-circuits the loop's safety net.
- Enforcement: advisory only for now; the integration loop will note
  direct-to-linux-next code commits from non-linux hosts in its ledger so
  the user can spot drift.

## 5. Author identity convention

We now have 3 host identities sharing one email:

| Host | git user.name | email |
|---|---|---|
| Linux | `Tlatoāni` (macron) | `bulloncito@gmail.com` |
| macOS | `Tlatoani` (no macron) | `bulloncito@gmail.com` |
| Windows | `bullo` | `bulloncito@gmail.com` |

This is fine and intentional — it lets `git log --author=` filter per
host without changing git config. The integration loop should NOT try to
canonise these; treat them as the host signature.

## 6. Plan-write discipline (one-paragraph version, expanded in cheatsheet)

When any host writes to `plan/`:
1. `git fetch origin && git checkout linux-next && git pull --ff-only` first.
2. Edit the target file with a stable-ID-keyed semantic upsert (append a
   dated cycle entry to a log file; or update the matching ID block in
   an existing issue).
3. Stage ONLY the `plan/` files you intended to touch (`git add
   plan/issues/<file>`). Never `git add -A` from a dirty tree.
4. Commit with `chore(plan): <subject>` or `docs(plan): <subject>`.
5. Push to `origin/linux-next`. On rejection, `git fetch && git rebase
   origin/linux-next` and re-push (up to 3 retries).
6. If your host code work is on a separate branch (`windows-next` /
   `osx-next`), switch back to it after the plan push.

## 7. Open follow-ups

- `methodology/multi-host-development.yaml` gets a §6 (Plan-write
  discipline) and a §7 (Common pitfalls from integration loop learnings).
- `methodology/distributed-work.yaml` (new) formalizes the CRDT-inspired
  principles backing the work-item schema.
- Cheatsheets under `cheatsheets/concurrent-git/` translate this canon
  into copy-pasteable shell snippets for agents.
- Event entry `methodology/event/032-distributed-work-methodology-refresh.yaml`
  records this refactor for cold-start agents.
