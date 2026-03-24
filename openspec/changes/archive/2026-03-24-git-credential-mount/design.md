## Context

Forge containers use `--rm` so all container-local state is destroyed on stop. Project source and cache survive via volume mounts, but git configuration and GitHub CLI credentials live outside those paths. Without persistence, every new container requires manual `gh auth login` and `git config --global user.name/email`.

## Goals / Non-Goals

**Goals:**
- Persist git identity (`~/.gitconfig`) and GitHub CLI auth (`~/.config/gh`) across container lifecycles
- Use the existing cache directory as the host-side storage location
- Keep the security posture unchanged (credentials stay local, no network exfiltration)

**Non-Goals:**
- SSH key management (future change)
- Credential encryption at rest (host filesystem permissions suffice for now)
- Supporting arbitrary credential providers beyond git and gh

## Decisions

### D1: Store secrets under cache directory

Place secrets in `~/.cache/tillandsias/secrets/{gh,git}/` rather than a separate config path. This keeps all container-related persistent state in one tree and means `Destroy` can optionally clean credentials along with other cache data.

### D2: Pre-create mount targets in entrypoint

The entrypoint ensures `~/.config/gh` and `~/.gitconfig` exist before any tool tries to read them. This avoids errors when the host-side directories are empty on first run (podman creates them as directories if they don't exist, but tools may expect files).

### D3: Both code paths get the same mounts

The tray-mode `build_run_args` (handlers.rs) and CLI-mode `build_run_args` (runner.rs) both add the same volume mounts. This ensures credential persistence works identically regardless of how the user launches an environment.
