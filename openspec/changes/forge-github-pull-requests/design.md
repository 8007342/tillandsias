## Context

- Host tools reach forges over one lane socket served by
  `crates/tillandsias-headless`. `host_tools.rs` keeps the group index, and
  `cloudflare_mcp.rs` is the closest precedent: a table of cloud API tools
  using a host-held credential, read-only by default. `handle_mcp_jsonrpc`
  dispatches `tools/call`.
- The GitHub credential is a GitHub App user-to-server access token obtained
  through the device flow (`--github-login`, `GITHUB_APP_CLIENT_ID`). It is
  stored in Vault at `secret/github/token` with its refresh token and rotated
  every 8 hours by the resident scheduler (`vault_bootstrap.rs`, order
  1461-8tyy; spec:gh-auth-script). The mirror relay pushes with it, and
  `cloud.usage` already reads the API with it.

## Credential permissions (must be verified, not assumed)

A user-to-server token can do only what BOTH the App's granted permissions
AND the signed-in user allow, and only on repositories where the App is
installed. Opening a PR (`POST /repos/{o}/{r}/pulls`) needs the App permission
**Pull requests: write** (plus Contents: read, implied by the Contents: write
that the mirror push already proves). A working push proves Contents: write
and the installation. It does NOT prove Pull requests: write.

The operator believes the token has that permission. The implementation's
first task is a real call: `GET /repos/{o}/{r}/pulls?per_page=1` (read), then
one draft PR opened and closed on a scratch ref, recording the
`X-Accepted-GitHub-Permissions` response header. If the permission is missing,
the fix is an App permission change that the operator accepts on GitHub
(installation re-approval), not a new token type. Until then the tool refuses
with `github_permission_missing: pull_requests=write`.

## Decisions

1. **Host-side call, forge credential-free.** The forge sends only
   `{head, base, title, body, draft}`. The host resolves the repo, reads the
   token from Vault per call, and returns `{url, number, state, draft}`.
2. **Repository from the mirror, never the caller.** The repo is the
   `owner/name` of the calling forge's project mirror upstream. Any `repo`,
   `owner` or URL argument is rejected (`unknown_argument`), not ignored.
3. **Head must already be on GitHub.** The host checks
   `GET /repos/{o}/{r}/branches/{head}` first and refuses with
   `head_not_on_github` and a hint to push through the mirror. Cross-fork
   heads (`user:branch`) are refused.
4. **Base is an existing branch of the same repo.** Anything else is refused.
5. **No write surface beyond opening.** No merge, approve, review submit,
   close, label, ruleset, settings, workflow dispatch or ref deletion. A test
   enumerates `tools/list` and fails on any `github.*` name outside
   `{pr_create, pr_view, pr_list}`.
6. **Not gated by default; visible; rate-limited.** The operator wants opening
   a PR to be frictionless. Each successful open emits a curated tray event
   ("demon_attack opened pull request #N: <title>") through the existing
   curated-event channel, plus a journal line. Default limits: 5 opens per
   forge instance per hour and 20 per project per day. Over the limit, the
   call returns `state: rate_limited` with `retry_after_s` (the shape of the
   image-build retry ruling).
   **Operator-flippable:** a host setting `github.pr_create.approval =
   none | gated` (default `none`). `gated` routes the call through the
   os-verified-approval-gates broker (`awaiting_approval`, with a fresh OS
   human-presence check per the approval-human-gate spec). While the setting
   is `none`, it overrides, for forge-opened PRs only, the approval-gate
   table's row "opening a pull request into an integration branch".
7. **Duplicate open is idempotent.** If an open PR already exists for
   `head`→`base`, the call returns it with `existing: true` instead of a 422.
8. **Licence PRs.** `licences/*` heads open like any other. Merging stays a
   human web-UI action (order 2094-h3rq).

## Risks

- The token lacks Pull requests: write. The tool refuses clearly, and an exit
  criterion requires a real call.
- A prompt-injected agent spams PRs. Mitigated by the rate limit, tray
  visibility and the switch to gated.
- The body is untrusted text on a public repo. Mitigated by a length cap
  (64 KiB) and refusing credential-shaped strings (reuse the token-prefix
  redactor).
