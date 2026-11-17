## Why

Operator, 2026-11-17: "how tf the forge is unable of creating pull requests
without your help? that's not working as expected :( file work and specs to
make that possible from the forges. The github token in the vault should have
all the necessary permissions."

A forge can push a work ref through the git mirror, but it cannot open the pull
request for it. Forges are credential-free by design, so `gh` has no auth, and
no host tool opens a PR. Today a host-side agent has to open every forge PR by
hand (order 2065-ccx9, reported 2026-11-09 by the demon_attack forge session).

## What Changes

- A new `github.*` group on the host tool socket (`host_tools.rs`, the lane the
  forge registers as the `host-browser` MCP server):
  - `github.pr_create {head, base, title, body, draft}` returns the PR URL and
    number, or a named refusal;
  - `github.pr_view {number}` and `github.pr_list {state?, head?}`, read-only.
- The host performs the API call with the Vault-held GitHub App user-to-server
  token (`secret/github/token`, the credential the mirror relay already uses).
  No token, no `gh auth login`, and no credential material enters the forge.
- The host fixes the scope, not the caller: the repository is the one the
  calling forge's project mirror relays to, and the forge cannot name a
  repository. `head` must already exist on GitHub.
- No merge, approve, review, ruleset, settings, workflow or branch-delete
  operation is exposed to forges, now or by alias.
- Opening a PR is NOT approval-gated by default (the operator wants it
  frictionless). It is shown as a curated tray event, journaled, and
  rate-limited. A host setting can flip it to gated (decision recorded in
  design.md).

## Impact

- Code: `crates/tillandsias-headless` (new `github_mcp` module beside
  `cloudflare_mcp`, a `GROUPS` row in `host_tools`, dispatch in the MCP socket
  handler), tray event surfaces on Linux, macOS and Windows.
- Specs: new capability `forge-github-pull-requests`. It interacts with
  `os-verified-approval-gates`, whose approval-gate table lists "opening a pull
  request into an integration branch" as cost-bearing. This change states the
  default for forge-opened PRs and the switch that restores gating.
- Licence merge gate (order 2094-h3rq, draft PR #1121): forges MAY open
  `licences/*` PRs through this tool, and no agent can ever merge them.
- Plan: order 2065-ccx9.
