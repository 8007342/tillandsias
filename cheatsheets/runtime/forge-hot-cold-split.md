---
tags: [forge, hot-path, ramdisk, tmpfs, memory, mounts, methodology]
languages: []
since: 2026-04-27
last_verified: 2026-04-27
sources:
  - https://man7.org/linux/man-pages/man5/tmpfs.5.html
  - https://docs.podman.io/en/stable/markdown/podman-run.1.html
authority: high
status: current
---

# Forge hot/cold filesystem split

@trace spec:forge-hot-cold-split

**Use when**: You need to understand which forge paths are RAM-backed, what the size caps are, how to verify mounts from inside the container, and what the pitfalls are.

## Provenance

- <https://man7.org/linux/man-pages/man5/tmpfs.5.html> — tmpfs(5) man page: `size=` option semantics, `mode=` option, default 50%-of-RAM behavior when no size is specified
- <https://docs.podman.io/en/stable/markdown/podman-run.1.html> — podman-run(1): `--tmpfs` flag syntax, mount options (size=, mode=), example `--tmpfs /tmp:rw,size=787448k,mode=1777`
- **Last updated:** 2026-04-27

## Quick reference — canonical HOT mount list

| Mount path | Size cap | Mode | Purpose |
|---|---|---|---|
| `/opt/cheatsheets/` | 8 MB | 0755 | Agent knowledge bank — populated from `/opt/cheatsheets-image/` at entrypoint |
| `/home/forge/src/<project>/` | ~1024 MB (dynamic) | 0755 | Project source — re-cloned from git mirror at every attach |
| `/tmp/` | 256 MB | 1777 | Bounded scratch — cap prevents OOM, not a performance hotpath |
| `/run/user/1000/` | 64 MB | 0700 | XDG runtime dir — D-Bus socket, systemd user session files |

**Key rule**: HOT = RAM-backed tmpfs. EXTREMELY EXPENSIVE resource. "Maybe a hot path" = HARD NO. Default decision is COLD.

COLD paths (disk-backed):
- `/nix/store/` — shared cache (RO), content-addressed, host-managed
- `/home/forge/.cache/tillandsias-project/` — per-project build artifact cache
- `/var/log/tillandsias/` — container logs

## Common patterns

### Verify mount type from inside the forge

```bash
# List all tmpfs mounts — should show all four HOT paths
findmnt -t tmpfs -no TARGET,SIZE,OPTIONS

# Check a specific path
findmnt /opt/cheatsheets -no FSTYPE,SIZE
# expect: tmpfs  8M

findmnt /tmp -no FSTYPE,SIZE
# expect: tmpfs  256M

findmnt /run/user/1000 -no FSTYPE,SIZE
# expect: tmpfs  64M
```

### Inspect the cheatsheets population

```bash
# Confirm cheatsheets were copied from the image layer into RAM
wc -l "${TILLANDSIAS_CHEATSHEETS:-/opt/cheatsheets}/INDEX.md"

# Count total cheatsheet files
find "${TILLANDSIAS_CHEATSHEETS:-/opt/cheatsheets}" -name '*.md' | wc -l

# Quick disk usage of the hot mount
du -sh "${TILLANDSIAS_CHEATSHEETS:-/opt/cheatsheets}"
# expect: < 1M (current corpus ~636KB)
```

### Check available space on a hot mount

```bash
# Human-readable — confirm cap is enforced
df -h /tmp
# SIZE column should show ~256M

df -h /opt/cheatsheets
# SIZE column should show ~8M

# All tmpfs mounts at once
df -ht tmpfs
```

## Common pitfalls

- **Writing large files to /tmp without checking the cap** — the cap is 256 MB (not 50% of host RAM like uncapped tmpfs). `dd if=/dev/urandom of=/tmp/big bs=1M count=512` will fail with ENOSPC at ~256 MB. Use the per-project cache for large intermediates that need to survive or `/tmp` only for genuinely throwaway scratch under 256 MB.

- **Expecting writes to /opt/cheatsheets to survive container stop** — `/opt/cheatsheets/` is a tmpfs. Anything written there is gone on stop. The canonical source is `/opt/cheatsheets-image/` (image lower layer), repopulated at every entrypoint start by `populate_hot_paths()`. Never write agent-facing knowledge here; put it in the image at build time.

- **Expecting writes to /home/forge/src/<project> to survive** — the project source directory is also on tmpfs (RAM-backed). Uncommitted work is lost on container stop, literally at the byte level. Commit and push to the git mirror before stopping.

- **Attempting to disable or resize tmpfs from inside the container** — the mounts are set by `podman --tmpfs` at launch time. There is no `mount -o remount,size=512m /tmp` available from inside the container (requires `CAP_SYS_ADMIN`, which is dropped). If you need more scratch space, use the per-project cache.

- **Assuming /run/user/1000 behaves like a full systemd session** — the forge is not a full systemd user session. `/run/user/1000/` exists and is tmpfs-backed (for tools that probe `XDG_RUNTIME_DIR`), but systemd user services are not running. D-Bus socket may not be present; don't rely on it.

- **Confusing /tmp size with host RAM** — uncapped tmpfs defaults to 50% of host RAM (tmpfs(5)). The forge caps /tmp at 256 MB intentionally. `df /tmp` shows the cap, not host RAM.

## See also

- `runtime/forge-paths-ephemeral-vs-persistent.md` — full path taxonomy (shared cache, per-project cache, workspace, ephemeral), Hot vs Cold section
- `runtime/forge-container.md` — broader runtime contract, security flags, enclave network
- `runtime/forge-shared-cache-via-nix.md` — why the shared (COLD) nix store is the right place for shared deps
