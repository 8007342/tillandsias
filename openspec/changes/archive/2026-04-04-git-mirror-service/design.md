## Context

Phase 1 established the enclave network and proxy. Forge containers now route HTTP through the proxy but still receive GitHub credentials via bind mounts and mount project files directly. Phase 2 introduces the git mirror service — a dedicated container that owns credentials and serves code through `git daemon`. This is the critical step that makes forge containers credential-free.

@trace spec:git-mirror-service

## Goals / Non-Goals

**Goals:**
- Bare mirror repos for every project, persisted at `~/.cache/tillandsias/mirrors/<project>/`
- `git daemon` serving mirrors on the enclave network via `git://` protocol
- D-Bus forwarding for host keyring access (GitHub credentials)
- Auto-push to remote via post-receive hook
- Project initialization: handle git repos (with/without remote) and non-git directories
- Credential refresh: `gh auth login` runs in git service container
- Multiple forge containers per project, each with independent clone
- `--log-git` accountability window

**Non-Goals:**
- Removing credential mounts from forge (Phase 3)
- Git LFS support (future)
- Multi-remote support (future — only `origin` for now)
- Conflict resolution UI (agents handle merge discipline)

## Decisions

### D1: Alpine + git + gh for minimal image
**Choice**: Alpine 3.20 with git, gh CLI, and bash. ~10-15MB.
**Rationale**: git daemon and gh auth are the only tools needed. No dev tools, no agents. Minimal attack surface.

### D2: Mirror stored at `~/.cache/tillandsias/mirrors/<project>/`
**Choice**: Host filesystem via bind mount, not a podman volume.
**Rationale**: Survives container destruction. Inspectable by user. Same cache directory pattern as proxy cache.

### D3: git daemon with `--export-all --enable=receive-pack`
**Choice**: git daemon in read-write mode on enclave network.
**Rationale**: Forge containers need both clone (read) and push (write). `receive-pack` enables push. The enclave network is trusted (only Tillandsias containers). `--export-all` avoids per-repo `git-daemon-export-ok` files.

### D4: post-receive hook for auto-push
**Choice**: Server-side hook in the bare mirror that pushes to origin after every receive.
**Rationale**: Transparent — coding agent does `git push`, mirror receives, hook pushes to GitHub. No extra commands. If push fails (expired credentials), the commits are safe in the mirror.

### D5: One git service container per project
**Choice**: Each project gets its own git service container (`tillandsias-git-<project>`).
**Rationale**: Simpler than a multi-repo daemon. Container lifecycle tied to project. Mirror volume is per-project.

### D6: Non-git directories get auto-initialized
**Choice**: If project dir is not a git repo, auto-run `git init` + initial commit before creating mirror.
**Rationale**: Users who `mkdir myproject/` and start working should have the same experience as cloning a GitHub repo. The mirror abstraction requires git.

## Risks / Trade-offs

- **[Mirror sync lag]** → Mirror fetches from remote on git service start. Periodic fetch every 5 minutes. Forge can trigger on-demand fetch.
- **[post-receive hook fails]** → Commits safe in mirror. Credential refresh via tray "GitHub Login" fixes it. `--log-git` shows the failure clearly.
- **[Large repos slow to mirror]** → Initial `git clone --mirror` may take time. Show progress in tray. Subsequent starts reuse existing mirror.
- **[Non-git project edge case]** → Auto-init creates `.git/` in user's directory. This is intentional — the enclave requires git.
