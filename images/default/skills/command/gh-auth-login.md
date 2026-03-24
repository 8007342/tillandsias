---
description: Authenticate with GitHub and configure git identity
agent_blocked: true
---

# /gh-auth-login

Authenticate with GitHub using `gh auth login` and configure your git identity.

**IMPORTANT**: This command uses `/bash-private` for the authentication flow. The auth tokens and one-time codes are NEVER visible to any AI agent or inference stack.

## Steps

1. Ask the user for their git identity:
   - `user.name` (their name for commits)
   - `user.email` (their email for commits)

2. Configure git:
   ```bash
   git config --global user.name "<name>"
   git config --global user.email "<email>"
   ```

3. Run the GitHub authentication flow in private mode:
   Use the `/bash-private` command to run:
   ```
   /bash-private gh auth login
   ```
   This opens a browser-based auth flow. The one-time code and token are only visible to the user, never to agents.

4. Verify authentication:
   ```bash
   gh auth status
   ```

5. Configure git to use GitHub CLI for credential storage:
   ```bash
   gh auth setup-git
   ```

## Notes
- Credentials persist in `~/.cache/tillandsias/` (mounted volume)
- Subsequent forge runs will already be authenticated
- Run `/gh-auth-login` again to re-authenticate or change accounts
