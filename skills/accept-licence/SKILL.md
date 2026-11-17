---
name: accept-licence
description: Accept a third-party licence for a model or tool whose terms are outside the permissive list (non-commercial, share-alike, seat thresholds, OpenRAIL use restrictions, Llama community terms, Fish Audio research licence). Opens ONE pull request in the agreeing project (head licences/<licence-id>) carrying the acknowledgement record, the obligations spec, the licence text verbatim with its pinned sha256 and a plain-language summary, and hands the user ONE GitHub URL; the human pressing Merge in the GitHub web UI is the approval. Never merges. Use when a fetch is refused with licence_acknowledgement_required, or when a project adds a restricted artefact. Works for any project in a Tillandsias forge.
license: MIT
metadata:
  author: tillandsias
  trace: order:2094-h3rq, order:1956-ecpb, order:1954-dvz9, spec:third-party-licence-consent
---

# Accept a licence

Tillandsias records consent; it does not enforce the licence and it does not
restrict the user. In the operator's words: "users should durably record
their consent to the third party license", and the skill "parses the license
and turns it into a spec for the agreeing project".

The approval is a HUMAN MERGE in the GitHub web UI (operator direction
2026-11-16; spec `os-verified-approval-gates/specs/approval-merge-gate`).
Zero setup: no key, no enrolment, no terminal, no copying. You prepare one
pull request; the user reads it and presses Merge, or closes it to decline.

## Hard rules

- You only OPEN the PR. Never run `gh pr merge`, `gh pr review --approve`,
  `gh api ... /merge`, or GraphQL `mergePullRequest`, and never ask another
  agent to. The bash policy refuses them (`refused:bash-policy:no-agent-merge`:
  a merge naming a `licences/` head, any merge whose head resolves to
  `licences/`, and any merge whose head it cannot resolve);
  a refusal is the design, not an obstacle to route around.
- Never click through gated terms, and never accept research-only terms
  (`licence_forbids_use`) on anyone's behalf: say so and stop.
- The licence text is quoted byte for byte. If its sha256 is not the pinned
  one, stop; a record against other bytes is worthless.

## When this runs

- A request was refused with
  `licence_acknowledgement_required: <repo>/<file> licence <id> (<obligations>)`
  or `consent_required: ...`.
- A project is adding an artefact whose row lives in
  `images/models/licence-register-restricted.tsv`.
- The user says something vague ("yo lets accept the fish and higgs
  licences"): resolve the names to register rows yourself. Never ask the user
  for ids, slugs, scope, use or expiry; propose the defaults (use `non-sale`,
  expiry `standing` for the operator's own projects, scope
  `project:<name>`).

## 1. Read the row and pin the text

Find the artefact's row in `images/models/licence-register-restricted.tsv`
(repo, revision, file, sha256, licence id, obligation classes,
`licence_sha256`). Fetch the licence text at the PINNED revision (for a
Hugging Face repo, `https://huggingface.co/<repo>/resolve/<revision>/<LICENSE file>`)
and hash it. If the row's hash is `pending:<url>`, or the artefact has no row
yet, pin it first in Tillandsias (its own small PR) and say so; do not open
the project PR against an unpinned text.

The obligation classes and their verbatim clauses come from
`licence_consent::obligations_for`; a licence not in that table is one
obligation, `review`.

## 2. Render the pull request

One PR per licence TEXT, in the PROJECT repo (not Tillandsias):

- head `licences/<licence-id>`, base the project's default branch (the gate
  reads the merged record there);
- `licences/acknowledgements/<licence-id>--<artefact-slug>.yaml` (one file per
  licence TEXT, so several licences on one repo never share a file), exactly as
  `Acknowledgement::to_yaml` writes it (`strength: github-merge`,
  `signature: ""`; `signed_at` is when the PR was opened);
- `openspec/specs/third-party-licence-<id>/spec.md`, as
  `licence_consent::obligations_spec` writes it;
- `licences/texts/<id>.md`, the licence bytes unchanged;
- the PR body: a heading, "Pressing Merge on this pull request is your
  acceptance", the plain-language promises (one short sentence each, words a
  non-lawyer understands: "You will not sell anything made with this voice
  model"), scope/use/expiry, the file table, the pinned hash and source URL,
  each obligation with its verbatim clause, and the full licence in a
  collapsed block.

`licence_consent::licence_pr` is the reference renderer and refuses a text
whose hash is not the pinned one. To preview without touching GitHub (a DRY
RUN, always offer it first to a new user or a new licence):

```bash
TILLANDSIAS_LICENCE_PR_DRY_RUN=<out dir> \
TILLANDSIAS_LICENCE_PR_DRY_RUN_TEXT=<licence file> \
TILLANDSIAS_LICENCE_PR_DRY_RUN_URL=<source url> \
TILLANDSIAS_LICENCE_PR_DRY_RUN_LICENCE=<licence id> \
TILLANDSIAS_LICENCE_PR_DRY_RUN_REPO=<artefact repo> \
TILLANDSIAS_LICENCE_PR_DRY_RUN_SCOPE=project:<name> \
TILLANDSIAS_LICENCE_PR_DRY_RUN_HOST=<host> \
TILLANDSIAS_LICENCE_PR_DRY_RUN_PROMISES=<one promise per line> \
cargo test -p tillandsias-headless --features host-services --bin tillandsias licence_pr_dry_run -- --ignored
```

It writes `pr-meta.txt`, `pr-body.md` and `files/` under the out dir.

## 3. Open it and hand over ONE link

In the project checkout: create the `licences/<id>` branch from the default
branch, add the three files, commit (trailer
`Licence-Acknowledgement: <licence id> <licence_sha256>`), push the branch,
then

```bash
gh pr create --base <default branch> --head licences/<id> --title "<title>" --body-file pr-body.md
```

Tell the user, in one or two plain sentences: what the licence lets them do,
what they promise, and "open this link and press Merge to accept, or Close to
decline: <PR URL>". Then stop. Do not poll, nudge, or merge.

## 4. After the user merges

Re-run the refused request. When the project has a git mirror on the host
(`tillandsias-git-<project>`), the host gate reads the record from the
mirror's default branch and admits it only when a GitHub PR merge put it
there (committer `GitHub`, a GitHub signature header, subject `Merge pull
request #N from <owner>/licences/<id>`), unchanged since, AND GitHub's API
confirms PR #N merged at that sha. Without GitHub reachable it admits
nothing ("retry when GitHub is reachable"): the mirror accepts forge pushes,
so the bytes alone could be forged. Nothing in the forge chooses where the
gate reads; it is host state. Tell the user which PR admitted what. An open
PR, a merge made outside GitHub, or a record edited after its merge admits
nothing. The mirror has to have fetched the merge first. Weights are fetched
to that user's cache only; never bundled in an image or a release.

## A licence that incorporates another

Higgs Audio v2's licence incorporates the Meta Llama 3 Community License by
reference, and through it the Llama 3 Acceptable Use Policy. Its PR quotes
all three texts, each with its pinned sha256 (the dry run
takes `TILLANDSIAS_LICENCE_PR_DRY_RUN_INCORPORATED=<id>|<url>|<file>`
lines), and the promises name the Llama terms in plain words.

## Known gaps

- A host agent holding the operator's GitHub token can merge through the
  API, and GitHub records that exactly as it records a web-UI merge
  (measured; see the spec). The hook, keeping that token out of agent reach,
  and the stronger Worker + WebAuthn level are the mitigations. Do not claim
  more than "a GitHub merge happened".
- A SQUASH merge's commit does not name its head branch, so offline the gate
  cannot tell a squashed `licences/` PR from any other squashed PR that adds
  the record; it relies on the online confirmation for those.

## The SSHSIG records

Records signed through the tray (`signature: |`, orders 2022-ygqj/89hm/hn2k)
in the host's acknowledgement dir still verify by their signature against
the host's enrolled signers, with or without a mirror; an UNSIGNED record
admits only through the merge gate. The operator's standing grant of
2026-11-01 ("For our own projects we shall have a standing approval to use
all of those free models, we'll not be selling any of those assets") is the
seed records in `licences/acknowledgements/`; it does not cover Demucs, Fish
S2-Pro or Higgs v2, which are acknowledged per project.
