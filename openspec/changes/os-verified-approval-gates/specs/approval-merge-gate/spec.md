## ADDED Requirements

<!-- @trace order:2094-h3rq -->

### Requirement: a licence is accepted by a human merging its pull request

Operator direction 2026-11-16: the accept-licence skill SHALL be zero-setup.
It SHALL open ONE pull request in the PROJECT repository, head
`licences/<licence-id>`, base the project's default branch, carrying the
acknowledgement record (`licences/acknowledgements/<licence-id>--<artefact-slug>.yaml`), the
obligations spec (`openspec/specs/third-party-licence-<id>/spec.md`), the
licence text verbatim (`licences/texts/<id>.md`) whose sha256 is the record's
`licence_sha256`, and a plain-language summary of what the user promises. It
SHALL give the user ONE URL. The human pressing Merge in the GitHub web UI IS
the approval; no signature, key or enrolment is required on this path.

The head is `licences/<licence-id>` (one branch per licence) and the base is
the default branch, because the admit gate reads the merged record on the
default branch; a long-lived `licences` branch would never be what the gate
reads.

#### Scenario: the skill opens, never merges

- **WHEN** the skill has rendered the pull request
- **THEN** it runs `gh pr create` and prints the PR URL
- **AND** it never runs `gh pr merge`, `gh pr review --approve`, or any merge
  API call

#### Scenario: the licence text is pinned

- **WHEN** the licence text fetched for the PR hashes to anything but the
  register's `licence_sha256`
- **THEN** nothing is rendered and no PR is opened

#### Scenario: a file under several licences

- **WHEN** the register lists one file under several licences (Higgs Audio
  v2: `boson-higgs-audio-2-community`, `meta-llama-3-community`,
  `meta-llama-3-acceptable-use-policy`)
- **THEN** the skill opens one PR per licence, each writing its own
  `<licence-id>--<artefact-slug>.yaml`, so no two PRs write one file
- **AND** the gate admits the file only when every one of those licences is
  acknowledged

### Requirement: the admit gate admits only a record merged into the default branch

The gate's source SHALL be chosen from HOST state only. When the project's
git mirror (`tillandsias-git-<project>`, `/srv/git/<project>`) answers
through the host's podman, the gate SHALL read merged records from the
mirror's default branch (`HEAD`), never from a working tree, and SHALL admit
one only when the last first-parent commit on that branch that added or
modified it is a GitHub pull-request merge: committer
`GitHub <noreply@github.com>`, a `gpgsig` header, and the subject
`Merge pull request #<n> from <owner>/licences/<id>` (or a squash subject
ending `(#<n>)`), AND GitHub's API (`gh api repos/<owner>/<name>/pulls/<n>`)
says the PR is merged at that merge sha. No environment variable, forge
request or forge-written file SHALL choose or override the source.

GitHub's confirmation is REQUIRED for a mirror-read record because the
mirror accepts forge pushes (relayed upstream), and a forge can push a
commit whose committer name and `gpgsig` header merely LOOK like GitHub's;
nothing offline verifies GitHub's signing key. So when GitHub is unreachable
a mirror-read record admits nothing, with a remedy to retry; the gate never
reports a pass it could not check. The admission SHALL carry PR number,
merge sha, merged_at (the merge commit's committer date) and merged_by (from
GitHub's answer).

A mirror that answers but whose default branch cannot be resolved SHALL
refuse; it SHALL NOT fall back. With no mirror, and for records in the
host's acknowledgement dir, the SSHSIG gate is unchanged: a SIGNED record
verifies against the host's enrolled signers, and an UNSIGNED record admits
nothing outside the merge gate.

#### Scenario: an open pull request admits nothing

- **WHEN** the record is on `licences/<id>` and checked out in the working
  tree, but the PR is not merged
- **THEN** the gate refuses with `licence_acknowledgement_required`

#### Scenario: an agent-made merge is not a GitHub merge

- **WHEN** the record reached the default branch in a merge commit an agent
  made and pushed (land-queue shape: committer `land-queue`, unsigned)
- **THEN** the gate refuses

#### Scenario: a record edited after its merge

- **WHEN** a later direct commit on the default branch changes the record
- **THEN** the gate refuses: the merge no longer vouches for those bytes

#### Scenario: GitHub unreachable

- **WHEN** a structurally perfect merge is read from the mirror and GitHub
  cannot confirm it
- **THEN** the gate refuses and says to retry when GitHub is reachable

### Requirement: agents never merge a licence pull request

The PreToolUse bash policy (`tillandsias-plan policy classify-bash --hook`,
rule `no-agent-merge`; coordinator ruling 2026-11-17) SHALL refuse
`gh pr merge` whose selector names a `licences/` head from its words alone.
Every other merge form — `gh pr merge <number|url|branch>` or with no
selector, the REST `pulls/<n>/merge` endpoint with any method or flags
(through `gh api` or an HTTP client), and GraphQL `mergePullRequest` /
`enablePullRequestAutoMerge` — SHALL be allowed ONLY after the hook resolves
the pull request's head through `gh` (bounded by a 10 s timeout), and SHALL
be refused when that head starts with `licences/`. The hook SHALL FAIL
CLOSED: a lookup that fails, times out, returns an empty head, or cannot be
formed (a GraphQL call that does not spell its pull request's node id)
refuses, with the remedy "retry when GitHub is reachable". The `gh` the hook
runs is the one on the hook process's PATH; no environment variable
overrides it.

#### Scenario: the lookup fails

- **WHEN** an agent runs `gh pr merge 12` and the head lookup fails
- **THEN** the hook refuses with `refused:bash-policy:no-agent-merge`

#### Scenario: the release skill's merge

- **WHEN** the release skill runs `gh pr merge <n>` for a
  `release/version-bump-*` PR and GitHub answers
- **THEN** the hook allows it

### Requirement: KNOWN GAP, a squash merge does not name its head

A squash merge's commit subject is the PR title with `(#<n>)`; it does not
name the head branch. Offline, the gate SHALL NOT claim a squashed record
came from a `licences/` PR; the online confirmation (merged at that sha) is
what binds the record to PR #<n>, and the gate does not yet check that PR's
head ref.

#### Scenario: a squash-merged record

- **WHEN** a record reached the default branch in a squash merge
- **THEN** the admission names PR #<n> from the subject and relies on
  GitHub's confirmation; it makes no claim about the head branch

### Requirement: KNOWN GAP, a host agent holding the operator token can merge

The gate SHALL NOT claim to tell a human merge from a token merge, and this
gap SHALL stay stated here until the stronger level below ships.

A HOST agent with access to the operator's GitHub user token (the token
Vault hands the tray, or the host `gh` login) can merge a licence PR through
the API or `gh pr merge <number>`. GitHub then records exactly what a web-UI
merge records. Measured on 8007342/tillandsias, 2026-11-17:

```
$ gh api repos/8007342/tillandsias/issues/990/events --jq '.[]|select(.event=="merged")|{event,actor:.actor.login,commit_id,created_at,performed_via_github_app}'
{"actor":"8007342","commit_id":"8351a0f3ff4552b6ec0daadc3984e2a2d341f91c","created_at":"2026-11-07T10:09:38Z","event":"merged","performed_via_github_app":null}
$ gh api repos/8007342/tillandsias/commits/8351a0f3ff4552b6ec0daadc3984e2a2d341f91c --jq '{committer:.commit.committer, gh_committer:.committer.login, verification:{verified:.commit.verification.verified,reason:.commit.verification.reason}}'
{"committer":{"date":"2026-11-07T10:09:38Z","email":"noreply@github.com","name":"GitHub"},"gh_committer":"web-flow","verification":{"reason":"valid","verified":true}}
```

PR 990 is a release version bump, which the merge-to-main-and-release skill
merges with `gh pr merge` (skills/merge-to-main-and-release/SKILL.md:399; an API merge, through the token). Its merge
commit is committed by `web-flow`, GitHub-signed and `verified`, and its
merged event's actor is the token's user with `performed_via_github_app`
null: the same fields a web-UI merge carries. So `web-flow` and a valid
GitHub signature distinguish "merged on GitHub" from "merged locally and
pushed", but NOT "a human pressed Merge" from "the token called the API".
`merged_by` names the token's user either way: PR 1120, which land-queue
merged locally and pushed (committer `land-queue`, unsigned), also reports
`mergedBy: 8007342`.

Mitigations, none of which closes the gap:

- the `no-agent-merge` hook refusal (forge and host agents under Claude
  Code; another harness does not run it);
- keep the operator's GitHub user token out of agent reach, or scope the
  token agents use so it cannot merge in project repos;
- the gate's GitHub-merge check, which refuses every merge made outside
  GitHub (an agent pushing its own merge commit).

The stronger level, later: a Cloudflare Worker that performs the merge only
after a WebAuthn assertion from the operator's device, with branch
protection requiring that Worker's check, so a token alone cannot merge.

#### Scenario: an admission does not overstate its evidence

- **WHEN** the gate admits a record under the merge gate
- **THEN** its evidence says a GitHub pull-request merge happened, with the
  PR number, merge sha and merged_at, and names merged_by only from the
  online check
- **AND** nothing in the admission claims a human pressed the button
