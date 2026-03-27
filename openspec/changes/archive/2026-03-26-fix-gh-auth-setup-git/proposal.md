## Why

`git push` inside forge containers prompts for username/password because git doesn't know about gh's OAuth token. The `hosts.yml` with the token is mounted, but git's `credential.helper` is not configured to use `gh`. Running `gh auth setup-git` bridges this gap.

Additionally, OpenCode (AI agent) can read the raw OAuth token at `~/.config/gh/hosts.yml` — the `opencode.json` config has no filesystem restrictions.

## What Changes

### Phase 1: Bridge gh auth → git
- Add `gh auth setup-git` to `images/default/entrypoint.sh` after secrets dir setup
- Non-interactive, fails silently if gh not installed

### Phase 2: Deny OpenCode access to secrets
- Configure `opencode.json` with deny rules for `~/.config/gh/` and `~/.config/tillandsias-git/`
- AI agent can use `git push` (via credential helper) but cannot read the raw token

## Capabilities

### New Capabilities
### Modified Capabilities

## Impact

- **Modified**: `images/default/entrypoint.sh` — 3 lines added
- **Modified**: `images/default/opencode.json` — deny rules for secret paths
- Requires forge image rebuild to take effect
