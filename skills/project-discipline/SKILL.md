---
name: project-discipline
description: How THIS project wants its branches and pushes shaped — read its branch-discipline level (0 push to main freely; 1 integration branch + pull requests; 2 work refs into the integration branch), the drift between what it declares and what its history shows, which hooks it has installed, how to raise it, and the work format each hook refusal asks for. Every refusal that says "use /project-discipline for instructions" resolves here. Works for any project in a Tillandsias forge, not only Tillandsias.
license: MIT
metadata:
  author: tillandsias
---

# Project Discipline

A hook, the git mirror or the land tool refused your push, commit or branch
and said **"use /project-discipline for instructions"**. This skill tells you
what the project expects, why, and how to do the work in that shape.

It is generic: it reads THIS project's own seed and history. It assumes no
plan ledger, no gate and no landing queue — those belong to Tillandsias's own
skills (`join-the-fleet`, `advance-work-from-plan`), which a project at level 1
or 2 does not need.

## 1 — Ask the project first

Run these before anything else, from the project's checkout:

```bash
git fetch origin                               # the answers read refs AS OF THE LAST FETCH
tillandsias-plan discipline show               # the seed: level, per-rule enforcement, branches
tillandsias-plan discipline derive             # what the history shows, beside the seed
```

Read three lines out of it:

- `discipline: source=<seed|default> level=<n> …` — `source=default level=0`
  means the project has **no seed**: nothing refuses anything.
- `derived=<n> seed=<n|none> effective=<n>` — `effective` is what is
  actually enforced: the lower of the two.
- the `drift:` line (below), and any `note:` — `note: no refs/remotes/origin/*`
  means you have not fetched; fetch and ask again before believing a level 0.

For one ref: `tillandsias-plan discipline check-ref refs/heads/<branch>`.

## 2 — The ladder

The operator's rungs (ruling 2026-09-22, 1363-xp2v). A project climbs; it
never climbs down (levels are forward-only).

| Level | What it means | What you do |
|---|---|---|
| **0** | A fresh project. **Push to main freely.** | Commit and push to the default branch. Hooks at this level only ever *advise*. |
| **1** | An integration branch and pull requests. The default branch is protected. | Work on the integration branch for your platform (`discipline target --platform <p>`); the default branch advances only through a pull request. |
| **2** | Work refs into the integration branch. | Do each unit of work on `work/<id>` (the seed's `work_ref` grammar), push that ref, and let it land on the integration branch. |

Each rule also has an **enforcement**, independent of the level:
`advised` (silent), `warn` (prints, accepts), `enforced` (refuses).

## 3 — Drift: when the seed and the history disagree

`derive` observes the project (origin's HEAD, integration branches on origin,
work refs on origin, distinct committer hosts in the last 50 commits,
pull-request merges, installed hooks) and prints one of:

- `ok:discipline-derive:seed-matches-reality` — nothing to do.
- `drift:seed-ahead-of-reality` — the seed declares more than the history
  shows. Allowed (the project is opting in early), but its **enforced rules
  only warn** until the missing qualifier appears. The warning names the
  qualifier: e.g. `warn:discipline:default-branch-protected:seed-ahead-of-reality`
  means no integration branch or pull-request merge was observed yet.
- `drift:seed-behind-reality: discipline raise --to <n>` — the project has
  outgrown its declaration. Nothing is refused on the seed's behalf. Raise it
  (§4) so the hooks match how the project already works.

A qualifier you have not fetched is not observed. Fetch first.

## 4 — Raising the level

```bash
tillandsias-plan capabilities | grep -x discipline    # the verb exists
tillandsias-plan discipline raise --to <n>            # bumps the seed, installs that level's hooks
tillandsias-plan discipline install-hooks             # (re)install the hooks the seed's level needs
```

`raise` and `install-hooks` ship with the hook templates (order 1446-xqi6).
If your plan binary does not list them yet, edit
`.tillandsias/branch-discipline.yaml` by hand (`level:` and `enforcement:`),
commit it, and ask again with `discipline show`. Never lower `level:` — a seed
below a published level is refused at load (`refused:discipline-seed:level-regressed`).

Hooks install into a **repo-local** `core.hooksPath`, never a global one.

## 5 — What each hook refusal asks for

Every refusal carries a verdict, a `why:` line and a `remedy:` line:

```
refused:hook:<event>:<rule>:<enforcement>
why: …
remedy: this project at level <n> (<rule> <enforcement>) needs <requirement>; use /project-discipline for instructions
```

The verdict word is `refused` (enforced), `warn` or `advised`. A stub that
cannot run the plan binary answers `blocked:hook:<event>:no-plan-binary` and
refuses — rebuild or reinstall the plan binary; it never falls back to a
guess. Find your event below.

### `hook:pre-commit`

Runs before a commit is recorded. At level 2 it asks that code commits happen
on a `work/<id>` ref, not directly on the integration or default branch.
**Format:** `git switch -c work/<id> origin/<integration>` and commit there.

### `hook:post-commit`

Advisory at every level: it never refuses. At level 0 it notices when a
qualifier appears — e.g. `advised:hook:post-commit:multiple-committers` once
two committer identities are seen — and suggests raising (§4).
**Format:** nothing to change; read the advice and decide whether to raise.

### `hook:pre-push`

The early copy of the mirror's pre-receive, so a refusal costs seconds, not a
round trip. Level 1: a push to the default branch is refused
(`default-branch-protected`); push to your integration branch instead
(`discipline target --platform <p>` names it). Level 2 adds the ref grammar
(`ref-outside-grammar`): name branches `work/<id>`, an integration branch, or
a `salvage/<host>/<yyyymmdd>-<slug>` ref.
**Format:** `git push origin HEAD:refs/heads/<integration>` or
`git push origin HEAD:refs/heads/work/<id>`.

### `hook:post-merge`

Advisory: after a pull or merge it reports drift that the merge introduced
(new integration branches, new committer hosts) and whether the seed should
rise. It never refuses. **Format:** run `discipline derive` and act on its
`drift:` line.

### `hook:post-checkout`

Advisory: on switching branches it says which kind of ref you are on
(`integration`, `work-ref`, `default-branch`) and, at level 2, that work
belongs on a work ref. **Format:** create a work ref before committing.

### `hook:pre-receive`

Runs in the git **mirror** when your push arrives, and relays its refusal to
your push output. Same rules as `hook:pre-push`, applied authoritatively; the
mirror reads the seed from the integration branch's tree. If your local
pre-push passed but pre-receive refused, your checkout's seed differs from
the mirror's (`seed-drift`): fetch, merge the integration branch, retry.
**Format:** as `hook:pre-push`.

### `hook:post-receive`

Runs in the mirror after a push was accepted. It only logs or publishes
(e.g. the enforced level under `refs/tillandsias/discipline/*`); it cannot
refuse. **Format:** nothing to change.

## 6 — The work format, per level

- **Level 0.** Commit on the default branch and push it. Nothing else is asked.
- **Level 1.** `git switch <integration>`; commit; push the integration
  branch; open a pull request into the default branch when the work should
  ship. Never push the default branch.
- **Level 2.** `git switch -c work/<id> origin/<integration>`; commit; push
  `work/<id>`; it lands on the integration branch (by pull request, or by the
  project's landing tool); the default branch advances only by pull request
  from the integration branch.

## 7 — When the answer looks wrong

- `derived=0` on a project you know is busy → you have not fetched, or the
  checkout is shallow. `git fetch origin` (and `git fetch --unshallow` if
  needed), then derive again.
- A refusal you believe is mistaken → run `discipline check-ref` on the ref
  and `discipline derive --json`: every observation carries the exact git
  command that made it, so you can re-run it and see what the tool saw.
- `refused:discipline-seed:<reason>` on stderr → the seed file is malformed;
  the answers fall back to level 0 until it is fixed. The reason names the
  problem (`integration-equals-default`, `work-ref-regex`, `level-regressed`,
  `enforcement-vocabulary`).
