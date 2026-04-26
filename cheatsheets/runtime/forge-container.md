---
tags: [forge, runtime, container, podman, sandbox, paths]
languages: []
since: 2026-04-25
last_verified: 2026-04-25
sources:
  - https://docs.podman.io/en/latest/markdown/podman-run.1.html
  - https://github.com/8007342/tillandsias/blob/main/images/default/Containerfile
authority: high
status: current
---

# Forge container — runtime contract

@trace spec:agent-cheatsheets

## Provenance

- Podman run reference (security flags `--cap-drop`, `--security-opt=no-new-privileges`, `--userns=keep-id`, ports, networking): <https://docs.podman.io/en/latest/markdown/podman-run.1.html>
- Tillandsias forge Containerfile (image layout source of truth): <https://github.com/8007342/tillandsias/blob/main/images/default/Containerfile>
- **Last updated:** 2026-04-25

**Version baseline**: Fedora Minimal 43, forge image built from `images/default/Containerfile`
**Use when**: starting any task inside the forge — this defines the rules of the sandbox you live in.

## Quick reference

| Layer | Path | Mutability | Survives container stop? |
|---|---|---|---|
| OS image | `/usr`, `/lib`, `/etc` (most), `/opt` | **read-only** | yes (image-state) |
| Cheatsheets | `/opt/cheatsheets/` | **read-only** | yes (image-state) |
| Agents | `/opt/agents/{claude,openspec,opencode}/` | **read-only** | yes (image-state) |
| Project workspace | `$HOME/src/<project>` | writable | **NO** (cleared on container stop unless committed and pushed via the enclave git mirror) |
| User caches | `$HOME/.cache/` | writable | NO |
| User config | `$HOME/.config/` | writable | NO |
| `/tmp` | `/tmp/` | writable (1777) | NO |

| Variable | Value | Why |
|---|---|---|
| `$TILLANDSIAS_CHEATSHEETS` | `/opt/cheatsheets` | discover cheatsheets without hardcoding the path |
| `$HOME` | `/home/forge` | always |
| `$USER` | `forge` (UID 1000) | matches host user via `--userns=keep-id` |
| `$PATH` | includes `/opt/agents/*/bin`, `/opt/flutter/bin`, `/opt/gradle/bin`, `/usr/local/bin`, `/usr/bin` | agents are pre-installed |

## Common patterns

### Pattern 1 — find what's installed

```bash
cat $TILLANDSIAS_CHEATSHEETS/INDEX.md | rg <topic>
```

The INDEX is grep-friendly. `rg python` returns the python language cheatsheet AND the pytest cheatsheet AND the pip/pipx/uv/poetry cheatsheets — every angle on Python is a separate file.

### Pattern 2 — work inside the project workspace

```bash
cd $HOME/src/<project>
# everything you do here can be lost on container stop unless committed
git status
git add -A
git commit -m "..."
git push  # goes through the enclave git mirror, NOT GitHub directly
```

Uncommitted changes are ephemeral. Commit early and often. The git push path goes through the in-enclave git service which authenticates to GitHub on your behalf.

### Pattern 3 — run a tool that's already installed

```bash
which <tool>             # confirm presence + path
<tool> --version         # confirm version pinned in the cheatsheet
cat $TILLANDSIAS_CHEATSHEETS/<category>/<tool>.md  # read the cheatsheet
```

`which` is shipped in the forge — use it before assuming a tool is missing.

### Pattern 4 — report a missing tool

```bash
mkdir -p .tillandsias/runtime-limitations
ls .tillandsias/runtime-limitations 2>/dev/null | sort -V | tail -1   # find highest NNN
# write RUNTIME_LIMITATIONS_<NNN+1>.md per cheatsheets/runtime/runtime-limitations.md
```

See `runtime/runtime-limitations.md` for the file format. The host picks up reports on next mirror sync.

### Pattern 5 — install something for THIS task only

You generally cannot. `microdnf install` requires root and the forge runs as UID 1000. `pip install` and `npm install -g` will try to write to `/usr/local/lib/...` which is read-only image-state. **Per-project** installs into virtual envs / project node_modules / cargo target dirs are fine — those land in `$HOME/src/<project>` (ephemeral but recoverable from git).

If you need a system-wide tool that isn't here, **don't workaround** — write a `RUNTIME_LIMITATIONS_NNN.md` so the human can decide whether to add it to the image.

## Common pitfalls

- **Editing files under `/usr` or `/opt`** — fails with EROFS or EACCES. These layers are image-state. Don't try `sudo`; the forge user has no sudo rights and there is no root password.
- **Running `microdnf install` / `dnf install`** — fails because the user isn't root AND because the image trims package metadata. This is intentional; the image is the toolbox.
- **Running `curl https://example.com` directly** — may fail because the forge's external network is restricted. Egress goes through the proxy at `proxy:3128` (HTTP) — set `HTTPS_PROXY=http://proxy:3128` if you must. Better: use the enclave's `git` mirror or the local `inference` host for what you need.
- **Persisting state outside `$HOME/src/<project>`** — anything in `~/.cache/`, `~/.config/`, or `/tmp` is gone on container stop. Treat them as scratch only. State that matters belongs in the project workspace (and in git).
- **`pip install --user`** — works in the sense that it doesn't write to `/usr`, but the result lives in `~/.local/` which is also ephemeral (it's under `$HOME` but not under `$HOME/src/<project>`). Use a project-local virtualenv instead, or `pipx run` for one-shot tool invocations.
- **Assuming `dnf` works** — Fedora minimal ships `microdnf` only. Many tutorials say `dnf install`; in this forge it's `microdnf install` (and even then, you don't have permission).
- **Mistaking the forge for a full Linux box** — no systemd, no cron, no journald (just plain stdout/stderr captured by podman), no `service` / `systemctl`. The forge is a process tree under conmon, not a full distro.
- **Trying to bind to ports < 1024** — the forge user is not root and rootless containers can't bind privileged ports. The forge's exposed range is `3000-3099/tcp`; use those for HTTP servers.
- **Network calls to GitHub** — go through the enclave git mirror (`git://git-service/<project>`) for clones/pushes, not directly to `github.com`. Authenticated calls to the GitHub REST API (e.g., `gh api`) are not available because the forge has no token. Anything credential-bearing belongs to the host — write a RUNTIME_LIMITATIONS report if you need to call it from inside the forge.

## See also

- `runtime/runtime-limitations.md` — how to report missing tools
- `runtime/networking.md` — enclave network details (proxy, git mirror, inference)
- `agents/openspec.md` — the workflow for proposing changes (including new image tools)
