## Context

The forge container includes `gh` (GitHub CLI) and `git` but provides no guided way for users to authenticate. The Macuahuitl forge project solves this with an OpenCode skill that runs the device flow login. Tillandsias needs a similar skill but with a key difference: the authentication flow must run through `/bash-private` so that tokens and one-time codes are never exposed to AI agents.

## Goals / Non-Goals

**Goals:**
- Provide a `/gh-auth-login` skill that configures git identity and authenticates with GitHub
- Ensure auth tokens and one-time codes are invisible to AI agents (`agent_blocked: true` + `/bash-private`)
- Deploy skills from the image into the workspace at runtime (same pattern as Macuahuitl forge)
- Credentials persist across container restarts via the cache volume

**Non-Goals:**
- Supporting non-GitHub forges (GitLab, Gitea) in this change
- Implementing `/bash-private` itself (that is the forge-bash-skills change)
- Managing SSH keys (gh auth uses HTTPS tokens)

## Decisions

### D1: Skill deployment pipeline

Skills are stored at `images/default/skills/` in the source tree. At build time, `flake.nix` copies them into `/usr/local/share/tillandsias/opencode/` inside the image. At runtime, the entrypoint copies them to the project's `.opencode/` directory so OpenCode discovers them. This matches the pattern used by the Macuahuitl forge project.

### D2: Agent blocking via frontmatter

The skill uses `agent_blocked: true` in its YAML frontmatter. This tells OpenCode that the skill cannot be invoked by AI agents -- only by the human user typing `/gh-auth-login`. Combined with `/bash-private` for the actual auth flow, this ensures credentials never enter the AI context.

### D3: Git identity as part of the flow

The skill asks for `user.name` and `user.email` before authenticating. This ensures commits are properly attributed from the first push, avoiding the common "please tell me who you are" error that confuses new users.
