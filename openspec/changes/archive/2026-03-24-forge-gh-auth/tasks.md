## 1. Skill File

- [x] 1.1 Create `images/default/skills/command/gh-auth-login.md` with `agent_blocked: true` frontmatter
- [x] 1.2 Skill asks for git identity (user.name, user.email) and configures git
- [x] 1.3 Skill uses `/bash-private` for the `gh auth login` flow
- [x] 1.4 Skill verifies auth with `gh auth status` and runs `gh auth setup-git`

## 2. Entrypoint Integration

- [x] 2.1 Update `images/default/entrypoint.sh` to copy skills from `/usr/local/share/tillandsias/opencode/` to project `.opencode/`

## 3. Nix Build Integration

- [x] 3.1 Add `images/default/skills` as a tracked Nix path in `flake.nix` so changes trigger rebuild
- [x] 3.2 Copy skills directory into the image at `/usr/local/share/tillandsias/opencode/` in `fakeRootCommands`
