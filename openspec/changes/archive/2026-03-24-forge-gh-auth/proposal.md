## Why

The forge container has `gh` installed but no way for users to authenticate with GitHub. Without authentication, users cannot push/pull from private repos, create PRs, or interact with GitHub APIs. The authentication flow involves a one-time code and token that must remain private from AI agents.

## What Changes

- Add an OpenCode skill `/gh-auth-login` that guides users through GitHub authentication and git identity configuration
- The skill uses `/bash-private` for the actual auth flow so tokens and one-time codes are never visible to any AI agent or inference stack
- Update the entrypoint to deploy skills from the image to the project's `.opencode/command/` directory at runtime
- Update `flake.nix` to track the skills directory and copy it into the image at build time

## Capabilities

### New Capabilities
- `forge-skills`: OpenCode skill deployment pipeline (image build -> entrypoint copy -> OpenCode discovery)

### Modified Capabilities
- `default-image`: Entrypoint deploys bundled skills to the workspace at runtime

## Impact

- New: `images/default/skills/command/gh-auth-login.md` -- the skill definition
- Modified: `images/default/entrypoint.sh` -- copies skills from image to workspace
- Modified: `flake.nix` -- tracks skills directory, copies into image during build
- Credentials persist in `~/.cache/tillandsias/` via the mounted cache volume
