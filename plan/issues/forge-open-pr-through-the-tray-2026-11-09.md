# A forge-side "open PR" path through the tray (order 2065-ccx9)

Filed 2026-11-09 from the demon_attack forge session (demon-attack-3e),
relayed by macuahuitl-fedora.

## Context

The session had no `gh` auth. That is by design: forges are credential-free,
and this packet does NOT ask for a GitHub token in the forge.

## Ask

Give the forge a way to ask the tray to open a pull request for a branch the
forge has pushed through the git mirror: head ref, base, title and body.
The tray uses the operator's credential host-side, and the forge gets back
the PR URL or a refusal. The operator should see what is being opened,
through the tray's approval surface, before it is created.

## Closure

From a forge, an agent opens a draft PR for a pushed work ref without any
credential in the forge, and the request appears in the tray first.

## Operator direction, 2026-11-17 (verbatim)

"how tf the forge is unable of creating pull requests without your help?
that's not working as expected :( file work and specs to make that possible
from the forges. The github token in the vault should have all the necessary
permissions."

## Design (2026-11-17)

Spec and design: `openspec/changes/forge-github-pull-requests/`. In summary:

- The host tool socket gains `github.pr_create {head, base, title, body,
  draft}`, plus read-only `github.pr_view` and `github.pr_list`. The host calls
  GitHub with the Vault token, and the forge stays credential-free.
- The repository is the forge's project mirror upstream; the forge cannot name
  one. `head` must already be on GitHub.
- Merge, approve, rulesets and settings are never exposed. `licences/*` PRs
  can be opened but never merged by an agent (order 2094-h3rq, PR #1121).
- Approval: this supersedes the 2026-11-09 ask that the tray show the request
  before it is created. Opening is NOT gated by default. It is shown as a
  curated tray event ("demon_attack opened pull request #N"), journaled, and
  rate-limited. The operator can flip `github.pr_create.approval` to `gated`.

## Credential

`secret/github/token` holds a GitHub App user-to-server token (device flow,
`GITHUB_APP_CLIENT_ID`, rotated every 8 h). Opening a PR needs the App
permission Pull requests: write. Mirror pushes prove only Contents: write and
the installation, so the permission must be checked with a real call before
it is relied on.

## Exit criteria (each fails on today's code)

1. A real call with the Vault token (`GET /repos/{o}/{r}/pulls`, then one
   draft PR opened and closed) succeeds, and the packet records the
   `X-Accepted-GitHub-Permissions` header. Today nobody has made that call.
2. From a forge, `github.pr_create` returns a PR URL for a pushed work ref.
   Today the tool does not exist (`tools/list` has no `github.*`).
3. `tools/list` has exactly `github.pr_create`, `github.pr_view` and
   `github.pr_list` under `github.*`, and none of them can merge. Today there
   are none.
4. A `repo` argument is refused with `unknown_argument`, and an unpushed head
   is refused with `head_not_on_github`.
5. A successful open shows a curated tray event naming the project and PR
   number, and a sixth open within an hour from one forge returns
   `rate_limited`.
