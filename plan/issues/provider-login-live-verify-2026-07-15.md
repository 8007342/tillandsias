# Live Verify: Provider Login Device Flows (2026-07-15)

## Findings
- `--codex-login` and `--claude-login` succeeded previously and completed the device flow.
- `--agy-login` succeeded:
  - Output indicates it built the missing images and bootstrapped Vault.
  - Antigravity CLI was successfully downloaded and installed to `/home/forge/.local/bin/agy`.
  - The login flow succeeded and wrote device credentials to Vault.
- Relaunch without reprompt: 
  - Verified. Launched Antigravity in the forge from the tray; it didn't reprompt for login and successfully entered the TUI.
- Meta-orchestration:
  - Antigravity successfully running the `/meta-orchestration` skill inside the podman enclave (`tillandsias-tillandsias-forge-antigravity` container confirmed running).

### Agy Auth Surface Findings
- Command used: `tillandsias --agy-login`
- Credential file path: Expected `~/.gemini/antigravity-cli/antigravity-oauth-token` or similar mapped into Vault and injected via `ANTIGRAVITY_TOKEN` environment variable.
- Finding on proxy CA: `[trust] WARNING: runtime proxy CA is not mounted; using vendor roots only` (This is tracked via `optimization/login-container-proxy-ca-not-mounted-2026-07-15.md`).
