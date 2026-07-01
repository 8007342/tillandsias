# Post-login cloud project refresh + token storage verification

**Order 140** — filed 2026-06-30

## Observed

GitHub Login terminal ran successfully (clean prompts → "GitHub authentication
complete"). But after closing the terminal:
1. Remote projects were NOT listed in the menu
2. The GitHub Login item did not change to "GitHub: @user"
3. The STATUS chip continued oscillating (wire degraded/recovered)

## Root cause candidates

### A. Cloud refresh polling cadence (10 ticks = 5 minutes)
`refresh_cloud_projects` and `refresh_github_login` only run every 10 poll
ticks (every ~5 minutes). After GitHub Login succeeds, the user would need to
wait up to 5 minutes for the menu to reflect the new state. If the wire is
also oscillating, the slow poll may never successfully complete.

### B. Token not stored in Vault
`tillandsias-headless --github-login` writes to Vault at `secret/github/token`.
If Vault is unhealthy (not started, TLS not ready, token not provisioned), the
write silently fails. The GitHub Login terminal shows "GitHub authentication
complete" from the `gh` device flow, but the Vault write is a separate step.

To verify: `wsl -d tillandsias -u root -- vault kv get -mount=secret github/token`
(with VAULT_ADDR and VAULT_TOKEN set from the Vault service environment).

### C. GithubLoginStatusRequest not implemented in-VM
The headless may return `Error { Unsupported }` for `GithubLoginStatusRequest`
if the handler predates the request type. The `refresh_github_login` in the
tray silently leaves `login` at `LoggedOut`. The token may be stored but the
tray doesn't know.

### D. CloudRefreshRequest returns empty or Error
Even with a stored token, `CloudRefreshRequest → gh repo list` may fail if
the git-service container isn't running or `gh` isn't in the container PATH.

## Fix plan

1. **Immediate trigger**: After `MenuAction::GithubLogin` terminal closes
   (or after a delay), trigger `refresh_github_login` + `refresh_cloud_projects`
   immediately. Currently there is no completion signal from the terminal.
   **Short-term**: set the slow-poll interval to 1 tick (every 30s) for the
   first 5 ticks after tray startup or after a GithubLogin action, then
   revert to 10 ticks. This handles the "just logged in" case.
   **Long-term**: Phase 4 (PTY-over-vsock) will allow the headless to push
   a `LoginStateChanged` notification to the host, eliminating polling.

2. **Token verification**: Add `--verify-auth` flag to
   `tillandsias-headless --github-login` that exits 0 only if the Vault
   write succeeded. The terminal flow would show "Token stored ✓" or
   "Token storage failed — see tray log" instead of always "auth complete".

3. **In-VM handler audit**: Confirm `GithubLoginStatusRequest` and
   `CloudRefreshRequest` are handled by the current headless version.
   Add a specific log line in the headless when these requests arrive so
   the operator can see them in `tillandsias-tray --logs`.

## Exit criteria

- [ ] After GitHub Login, menu updates within 60s (not 5 minutes)
- [ ] `gh auth status` inside the git-service container returns logged-in
- [ ] Vault has `secret/github/token` with a valid token
- [ ] Remote projects list populates in the menu after login
- [ ] `GithubLoginStatusReply { logged_in: true, handle: "@user" }` observed
      in tray log after login
