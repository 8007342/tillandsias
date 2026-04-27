# Forge Container Runtime

@trace spec:agent-source-of-truth

**Version baseline**: Fedora 43 minimal + hand-curated toolset (see images/default/Containerfile)  
**Use when**: Understanding what the forge container can do, where files live, how to avoid common runtime traps

## Provenance

- https://docs.fedoraproject.org/en-US/fedora-silverblue/ — Fedora immutable OS foundation
- https://github.com/containers/podman/docs — Podman container runtime
- https://docs.docker.io/engine/storage/ — Layer storage and overlay2 semantics
- **Last updated:** 2026-04-27

## Quick reference

| Boundary | Path | Mutable? | Persisted? | Purpose |
|----------|------|----------|-----------|---------|
| Workspace | `$HOME/src/<project>` | ✅ Yes | ✅ Yes | Project code, edits, uncommitted work |
| User config | `$HOME/.config/` | ✅ Yes | ✅ Yes | Agent config, CLI flags, preferences |
| Cache | `$HOME/.cache/` | ✅ Yes | ✅ Yes | Build artifacts, downloaded models, pip cache |
| System / tools | `/usr`, `/opt`, `/bin` | ❌ No | ❌ Read-only (image) | Fedora base + baked tools (compilers, CLI, agents) |
| Cheatsheets | `/opt/cheatsheets/` | ❌ No | ❌ Read-only (image) | Tool/language references — write `RUNTIME_LIMITATIONS_NNN.md` if missing |

## Common patterns

**Checking what tools are available:**
```bash
# List all baked executables
ls /usr/bin /usr/local/bin /opt/*/bin 2>/dev/null | sort | uniq

# Check a specific tool version
python3 --version
cargo --version
gh --version
```

**Consulting the cheatsheets:**
```bash
# List all available cheatsheets
cat $TILLANDSIAS_CHEATSHEETS/INDEX.md

# Search for a specific topic
cat $TILLANDSIAS_CHEATSHEETS/INDEX.md | rg python

# Read a cheatsheet
cat $TILLANDSIAS_CHEATSHEETS/languages/python.md
```

**Understanding the mutable overlay:**
```bash
# Your workspace — safe to edit, committed to git
cd $HOME/src/<project>
git add file.txt
git commit -m "work in progress"

# Config — per-user preferences
mkdir -p $HOME/.config/myapp
echo "theme=dark" > $HOME/.config/myapp/config.toml

# Cache — ephemeral, OK to lose
pip install --cache-dir $HOME/.cache/pip-deps numpy
```

## Common pitfalls

❌ **Trying to install new system packages**: The forge is Fedora minimal + curated tools only. `dnf install <pkg>` will fail with permission errors (image is read-only). → Write a `RUNTIME_LIMITATIONS_NNN.md` report instead. The host operator decides if the tool belongs in the image.

❌ **Storing mutable code in `/opt` or `/usr/local/src`**: These are image-layer—edits vanish when the container stops. → Always work in `$HOME/src/<project>`.

❌ **Assuming `set -e` behavior in all shells**: The forge runs bash and zsh in non-strict mode by default. → Always add `set -euo pipefail` at the top of scripts.

❌ **Binding a host directory into the forge**: The forge is intentionally offline and credential-free. Bind-mounts from the host break `spec:forge-offline`. → Use git mirror + proxy for outbound access, which is safely mediated.

❌ **Writing to `/tmp` for long-term storage**: The temp directory is ephemeral per podman process. → Keep persistent files in `$HOME/.cache/` or `$HOME/src/`.

## See also

- `runtime/networking.md` — Network isolation, proxy, git mirror, inference service
- `runtime/runtime-limitations.md` — How to report missing tools
- `agents/claude-code.md` — Claude Code launcher and config
