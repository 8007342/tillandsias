## 1. Verify the credential (first, with real calls)

- [ ] 1.1 With the Vault token at `secret/github/token`, call
      `GET /repos/{o}/{r}/pulls?per_page=1` and record the status and
      `X-Accepted-GitHub-Permissions`.
- [ ] 1.2 Open and close one draft PR on a scratch pushed ref, and record the
      result in the 2065-ccx9 packet. If GitHub refuses, file the App
      permission change (Pull requests: write) as an operator ask and stop.

## 2. Host tool

- [ ] 2.1 Write the failing tests first: `tools/list` contains
      `github.pr_create` (fails today), the surface enumeration,
      `unknown_argument` for `repo`, `head_not_on_github`, GET-only reads,
      the 403 translation and the rate limit.
- [ ] 2.2 Add a `github_mcp` module in `crates/tillandsias-headless`, modelled
      on `cloudflare_mcp` (with a fake-API base URL override for tests).
- [ ] 2.3 Resolve the repository from the calling forge's project mirror
      upstream, and read the token from Vault on each call.
- [ ] 2.4 Add the `github.*` row to `host_tools::GROUPS` and the dispatch.
- [ ] 2.5 Make opening idempotent: return an existing open PR for the same
      head and base.

## 3. Visibility and policy

- [ ] 3.1 Emit a curated tray event and a journal line on each open (Linux,
      macOS and Windows trays).
- [ ] 3.2 Add the rate limiter (5 per forge instance per hour, 20 per project
      per day) with `retry_after_s`.
- [ ] 3.3 Add the host setting `github.pr_create.approval = none | gated`.
      `gated` routes through the os-verified-approval-gates broker.

## 4. Proof

- [ ] 4.1 From a real forge, push `work/<x>` through the mirror and call
      `github.pr_create`. The reply URL opens a draft PR on GitHub.
- [ ] 4.2 A credential scan of the forge finds no GitHub token prefix.
