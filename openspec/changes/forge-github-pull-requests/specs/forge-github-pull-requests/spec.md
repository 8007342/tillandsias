## ADDED Requirements

### Requirement: forges open pull requests through a host tool

The host tool socket SHALL offer `github.pr_create` taking `head`, `base`,
`title`, `body` and `draft`, and SHALL return the pull request's URL and
number, or a named refusal. The host SHALL make the GitHub API call with the
Vault-held GitHub credential; no token SHALL enter the forge.

#### Scenario: a pushed work ref becomes a pull request

- **WHEN** a forge has pushed `work/x` through its project mirror and calls
  `github.pr_create {head: "work/x", base: "linux-next", title, body,
  draft: true}`
- **THEN** the reply carries a `https://github.com/<owner>/<repo>/pull/<n>`
  URL, and the PR exists on GitHub as a draft

#### Scenario: the forge holds no credential

- **WHEN** the forge environment, filesystem and the tool reply are scanned
  for GitHub token prefixes
- **THEN** none is found

### Requirement: the repository is fixed by the host

The tool SHALL act only on the repository the calling forge's project mirror
relays to, and SHALL reject any argument naming a repository, owner or URL.

#### Scenario: another repository cannot be named

- **WHEN** a forge calls `github.pr_create` with a `repo` argument
- **THEN** the call is refused with `unknown_argument` and no API request is
  made

### Requirement: the head must already be on GitHub

The tool SHALL refuse a `head` that does not exist as a branch of the mirror's
GitHub repository, or that names another fork.

#### Scenario: an unpushed ref is refused

- **WHEN** `head` names a branch never pushed through the mirror
- **THEN** the reply is `head_not_on_github` with a hint to push first

### Requirement: merging is never exposed to forges

The `github.*` group SHALL contain only `pr_create`, `pr_view` and `pr_list`.
No tool SHALL merge, approve, submit a review, change rulesets or settings,
dispatch a workflow or delete a ref.

#### Scenario: the surface is enumerated

- **WHEN** a test lists `tools/list` from the host socket
- **THEN** the only `github.*` names are `github.pr_create`, `github.pr_view`
  and `github.pr_list`

#### Scenario: a licence pull request opens but is not merged by an agent

- **WHEN** a forge opens a PR whose head is `licences/<id>`
- **THEN** it is opened, and no host tool can merge it

### Requirement: reads are read-only and scoped

`github.pr_view {number}` and `github.pr_list {state?, head?}` SHALL issue only
GET requests against the same fixed repository.

#### Scenario: a read makes no write

- **WHEN** `github.pr_view` and `github.pr_list` are called against a fake API
- **THEN** the fake records only GET requests

### Requirement: opening is visible and rate-limited, not gated by default

A successful open SHALL emit a curated tray event naming the project and PR
number, and SHALL be journaled. Opens SHALL be rate-limited per forge instance
and per project, returning `rate_limited` with `retry_after_s`. A host setting
`github.pr_create.approval` SHALL default to `none`. Set to `gated`, it SHALL
route each open through the os-verified approval broker.

#### Scenario: the operator sees the open

- **WHEN** a forge for project `demon_attack` opens PR #12
- **THEN** the tray shows "demon_attack opened pull request #12" with its title

#### Scenario: the sixth open in an hour waits

- **WHEN** one forge instance opens a sixth PR within an hour
- **THEN** the reply is `rate_limited` with `retry_after_s` and no API request
  is made

#### Scenario: the operator turns gating on

- **WHEN** the setting is `gated` and a forge calls `github.pr_create`
- **THEN** the reply is `awaiting_approval` and no API request is made until
  the operator approves

### Requirement: a missing permission is named

If GitHub refuses for lack of the Pull requests permission, the tool SHALL
return `github_permission_missing` naming `pull_requests=write`, not a generic
error.

#### Scenario: a 403 is translated

- **WHEN** the fake API returns 403 with `X-Accepted-GitHub-Permissions:
  pull_requests=write`
- **THEN** the reply is `github_permission_missing: pull_requests=write`
