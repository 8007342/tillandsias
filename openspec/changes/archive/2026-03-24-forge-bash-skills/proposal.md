## Why

The forge container runs OpenCode as the primary interface, but users sometimes need to drop into a raw bash shell — to run build commands, inspect files, install tools, or debug issues that OpenCode can't handle. There is currently no way to do this without detaching from the container and running `podman exec` manually.

More critically, certain operations involve secrets (GitHub auth tokens, SSH passphrases, API keys) that must never be visible to the AI agent. Today there is no mechanism to run a command inside the forge container while guaranteeing the output stays out of the AI conversation context.

## What Changes

- **New skill file** `images/default/skills/command/bash.md` — OpenCode `/bash` skill that opens an interactive bash shell or runs a one-shot command in the project directory
- **New skill file** `images/default/skills/command/bash-private.md` — OpenCode `/bash-private` skill that runs bash in a private session where output is never visible to AI agents

Both skills are marked `agent_blocked: true` in their frontmatter, ensuring only the human user can invoke them.

## Capabilities

### New Capabilities
- `forge-skills`: OpenCode slash command skills for the forge container — `/bash` for interactive shell access and `/bash-private` for agent-invisible private sessions

### Modified Capabilities
<!-- None — these are new skill files, no existing code is changed -->

## Impact

- New files: `images/default/skills/command/bash.md`, `images/default/skills/command/bash-private.md`
- No Rust code changes — skills are markdown definitions consumed by OpenCode
- No changes to the Containerfile or entrypoint
- Image rebuild required to include the new skill files (or they can be volume-mounted for development)
