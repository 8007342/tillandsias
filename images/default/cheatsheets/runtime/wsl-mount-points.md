---
title: WSL2 mount points and 9p drvfs
description: Where Windows drives appear inside WSL2 distros, and how mounts differ from podman bind-mounts
tags: [wsl, windows, mount, drvfs, 9p, fs]
since: WSL2
last_verified: 2026-04-28
authority: high
status: current
tier: pull-on-demand
pull_recipe: see-section-pull-on-demand
sources:
  - https://learn.microsoft.com/en-us/windows/wsl/wsl-config
  - https://learn.microsoft.com/en-us/windows/wsl/filesystems
  - https://learn.microsoft.com/en-us/windows/wsl/release-notes
  - https://github.com/microsoft/WSL/blob/master/README.md
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
---

# WSL2 mount points and 9p drvfs

@trace spec:cross-platform, spec:windows-wsl-runtime, spec:git-mirror-service
@cheatsheet runtime/wsl-on-windows.md, runtime/wsl-daemon-patterns.md

**Use when**: writing code that crosses the Windows↔Linux filesystem boundary in WSL2 — anything that translates `C:\Users\...` to `/mnt/c/...`, mounts host paths into a distro, or shares files across distros (mirrors, caches, sockets).

## Provenance

- [WSL configuration](https://learn.microsoft.com/en-us/windows/wsl/wsl-config) — Microsoft Learn (canonical `/etc/wsl.conf` and `.wslconfig` reference)
- [WSL filesystem and mount support](https://learn.microsoft.com/en-us/windows/wsl/filesystems) — Microsoft Learn (drvfs, 9p, automount semantics)
- [WSL release notes](https://learn.microsoft.com/en-us/windows/wsl/release-notes) — Microsoft Learn (track changes to mount behaviour across versions)
- [WSL GitHub repo](https://github.com/microsoft/WSL/blob/master/README.md) — Microsoft (issue tracker, current implementation)

**Last updated:** 2026-04-28

## Quick reference

### Default automount (no `/etc/wsl.conf` overrides)

| Windows path | Inside WSL2 distro | Backing FS |
|--------------|--------------------|------------|
| `C:\` | `/mnt/c/` | drvfs over 9p |
| `D:\` | `/mnt/d/` | drvfs over 9p |
| Network share `\\server\share` | `/mnt/wsl/...` (manual mount) | 9p |

Verified by inspecting `mount` output inside any default-config distro:

```
$ mount | grep -E '/mnt/[a-z]'
C:\ on /mnt/c type 9p (rw,noatime,aname=drvfs;path=C:\;uid=0;gid=0;...)
```

The 9p protocol is what WSL2 uses to bridge between the Linux VM and Windows host. drvfs is the legacy WSL1 driver name kept as the `aname` parameter. **Both names refer to the same Windows-side mount mechanism in WSL2.**

### Customisation via `/etc/wsl.conf`

```ini
[automount]
enabled = true        # default; auto-mount Windows drives
root = /mnt/          # default mount root; can be e.g. "/" to skip the /mnt/<drive> prefix
options = "metadata,uid=1000,gid=1000,umask=22,fmask=11"
```

If `root = /`, drives appear as `/c/`, `/d/`, etc. (mirrors Cygwin/Git Bash convention).
**Tillandsias relies on the default `root = /mnt/`.**

### `/mnt/wsl/` is special

| Path | Purpose |
|------|---------|
| `/mnt/wsl/` | Shared tmpfs visible to ALL distros in the same WSL2 session |
| `/mnt/wsl/<distro>/` | Per-distro additions (used by some integrations) |
| `/mnt/wslg/` | WSLg X11/Wayland integration mounts |

Tillandsias does NOT currently use `/mnt/wsl/` — its cross-distro coordination goes through `/mnt/c/...` (host-fs path, visible from every distro).

## How mounts differ from podman bind-mounts

| Aspect | podman `-v <host>:<container>:ro,Z` | WSL2 drvfs `/mnt/c/...` |
|--------|-------------------------------------|--------------------------|
| Path | Arbitrary, configured per-mount | Fixed at `/mnt/<drive>/...` per drive |
| Per-container | Yes (each container has its own bind) | No (every distro sees `/mnt/c/...` automatically) |
| Read-only flag | `:ro` | Mount with custom `options =` in wsl.conf only |
| SELinux relabel `:Z` | Yes | N/A (Windows fs) |
| Permission semantics | Container user → host user via `--userns` | Always reports `root:root` unless `metadata` option is set; ownership baked at mount time |
| Performance | Native FS speed | 9p is slower than native ext4 — fine for source code, slow for `node_modules` install |

This means **podman's mount-by-mount isolation does not translate to WSL2** — every distro sees every drive automatically. Tillandsias relies on this for cross-distro file sharing (e.g. the bare git mirror at `/mnt/c/.../mirrors/<project>` is visible to forge, git, and proxy distros simultaneously).

## Ownership / permissions on /mnt/c

drvfs reports owner as `root:root` even for files the Windows user wrote. Two consequences:

1. **`git` refuses to operate** on `/mnt/c/...` repos because of dubious ownership. Workaround: `git config --global --add safe.directory <path>` per-repo.
2. **Cannot `chown`** files on /mnt/c without enabling the `metadata` mount option in `wsl.conf`:
   ```ini
   [automount]
   options = "metadata,uid=1000,gid=1000,umask=22,fmask=11"
   ```
   Then `wsl --shutdown` and restart distros to apply.

Tillandsias uses the `safe.directory` workaround (in `clone_project_from_mirror` and the post-receive hook) and does not require the `metadata` option.

## Translating paths in code

```rust
// Windows: C:\Users\bullo\src\test1  →  /mnt/c/Users/bullo/src/test1
fn windows_path_to_wsl_mnt(p: &Path) -> Result<String, String> {
    let s = p.to_string_lossy();
    let bytes = s.as_bytes();
    if bytes.len() >= 3 && bytes[1] == b':' && (bytes[2] == b'\\' || bytes[2] == b'/') {
        let drive = (bytes[0] as char).to_ascii_lowercase();
        let rest = s[2..].replace('\\', "/");
        Ok(format!("/mnt/{drive}{rest}"))
    } else {
        Err(format!("Path is not a Windows drive path: {}", s))
    }
}
```

Never hardcode `/mnt/c/...` — always derive from the Windows path. The user might have their data on `D:` or another drive.

## Common pitfalls

| Pitfall | Symptom | Fix |
|---------|---------|-----|
| Hardcoded `/mnt/c/` | Breaks for users on D: drive | Use `windows_path_to_wsl_mnt()` |
| `wsl --import` to `\\?\C:\...` extended path | "Hostname contains invalid characters" | Use plain `C:\path\...` for the install dir |
| Symlinks on /mnt/c | Resolved to Windows links (`.lnk` files) | Use Linux-fs (`/home/...`) for symlink-heavy work |
| node_modules / pip installs on /mnt/c | 10-100x slower than native | Install in `/home/<user>/...` (forge does this for working trees) |
| `chmod` on /mnt/c | Silently no-op (mode bits not stored) | Enable `metadata` in wsl.conf if needed; or live with default modes |
| File watcher not firing | inotify on /mnt/c is best-effort | Use polling or move work to native fs |
| Locale issues with non-ASCII paths | drvfs uses UTF-8 but Windows API may not | Test with names containing accents/emoji |

## See also

- `cheatsheets/runtime/wsl-on-windows.md` — wsl.exe CLI surface
- `cheatsheets/runtime/wsl-daemon-patterns.md` — running daemons inside distros
- `cheatsheets/languages/bash.md` (Git Bash on Windows section) — `cygpath` for the host-side translation

## Pull on Demand

### Source

This cheatsheet covers WSL2 filesystem integration, mount points, drvfs/9p protocol, and path translation between Windows and Linux.

### Materialize recipe

```bash
#!/bin/bash
# Generate WSL2 mount point reference
cat > wsl2-mounts-reference.md <<'EOF'
# WSL2 Mount Points Quick Reference

## Default Automount
- C:\ → /mnt/c/ (drvfs over 9p)
- D:\ → /mnt/d/ (drvfs over 9p)
- Network shares → /mnt/wsl/ (manual mount)

## Key Differences
- drvfs reports all files as root:root (git needs safe.directory)
- chmod and symlinks are best-effort
- /mnt/c is 10-100x slower than native /home
- inotify is best-effort on /mnt/c

## Path Translation
Windows: C:\Users\user → Linux: /mnt/c/Users/user
Use wslpath -a for automatic translation
EOF
```

### Generation guidelines

This cheatsheet covers WSL2 filesystem behavior from Microsoft documentation. Regenerate after:
1. WSL2 major version updates
2. Changes to drvfs or 9p protocol behavior
3. New mount option support

### License

License: CC-BY-4.0 (https://creativecommons.org/licenses/by/4.0/) Source material from Microsoft Learn (public documentation).
Last materialized: 2026-05-03
