---
id: selinux-silverblue
title: SELinux on Fedora Silverblue / Immutable OS
category: infra/security
tags: [selinux, silverblue, immutable, ostree, labels, contexts, containers]
upstream: https://docs.fedoraproject.org/en-US/fedora-silverblue/
version_pinned: "Fedora 43"
last_verified: "2026-03-30"
authority: official
---

# SELinux on Fedora Silverblue / Immutable OS

## Enforcing Mode

Silverblue ships with SELinux **enforcing** by default. Never set to permissive or disabled on production systems.

```bash
getenforce                          # Current mode (Enforcing/Permissive/Disabled)
sudo setenforce 1                   # Temporarily set enforcing (resets on reboot)
# Persistent: edit /etc/selinux/config — SELINUXTYPE=targeted, SELINUX=enforcing
```

Silverblue mounts `/etc` as writable, so `/etc/selinux/config` survives reboots.

## Core Label Types for Containers

| Label | Applies To | Purpose |
|---|---|---|
| `container_t` | Container processes | Default type for all podman/docker containers |
| `container_file_t` | Container-owned files | Files inside container layers and named volumes |
| `container_runtime_t` | Podman/CRI-O daemon | The engine process itself |
| `spc_t` | Super privileged containers | Unconfined domain for host-managing containers |
| `container_init_t` | Container entrypoint (systemd) | When container runs systemd as PID 1 |

Podman assigns each container a unique MCS label (e.g., `s0:c123,c456`) for isolation between containers.

## Volume Mount Labels: :z, :Z, and label=disable

```bash
# :z — shared label: relabels to container_file_t, all containers can access
podman run -v /host/path:/mnt:z ...

# :Z — private label: relabels with container-specific MCS category
#       ONLY that container instance can access
podman run -v /host/path:/mnt:Z ...

# label=disable — skip SELinux relabeling entirely
#       Use when the host path must keep its original label
podman run --security-opt label=disable -v /host/path:/mnt ...
```

**Caution with :Z** -- it relabels the host directory. Never use `:Z` on shared system paths (`/home`, `/var`, `/etc`), or you will lock out the host.

Named volumes (`podman volume create`) get `container_file_t` automatically and avoid relabeling issues entirely.

## Silverblue Filesystem Layout and SELinux

| Path | Writable | Notes |
|---|---|---|
| `/` | No | Immutable root via ostree |
| `/usr` | No | Read-only, part of the ostree commit |
| `/etc` | Yes | Writable overlay; merged on upgrades; SELinux config lives here |
| `/var` | Yes | Fully writable; persistent state across deployments |
| `/home` -> `/var/home` | Yes | Symlink; user data lives under /var |
| `/opt` -> `/var/opt` | Yes | Symlink to writable /var |
| `/usr/local` -> `/var/usrlocal` | Yes | Symlink to writable /var |

SELinux labels on `/usr` are baked into the ostree commit. Changes to `/etc` labels persist. Relabeling the entire filesystem (`fixfiles` / `restorecon -R /`) is rarely needed and works only on writable paths.

## rpm-ostree Layering and SELinux

```bash
rpm-ostree install <package>        # Layer an RPM; creates new deployment
rpm-ostree uninstall <package>      # Remove layered package
rpm-ostree status                   # Show deployments and layered packages
systemctl reboot                    # Required to activate new deployment
```

Layered packages get proper SELinux file contexts from the RPM's `file_contexts` data. If a layered service has denials, it likely needs a boolean or a policy module -- treat it the same as a traditional Fedora install.

## Toolbox and Distrobox SELinux Contexts

**Toolbox** containers run as `spc_t` (super privileged container). They mount the host home directory, `/dev`, `/proc`, `/sys`, and DBus sockets. SELinux effectively does not confine them -- this is intentional for development use.

```bash
# Verify toolbox SELinux context
ps -eZ | grep toolbox              # Shows unconfined_u:unconfined_r:spc_t:s0
```

**Distrobox** behaves similarly, running with `--security-opt label=disable` to bypass container confinement. Both approaches trade SELinux isolation for seamless host integration.

Standard (`container_t`) containers are fully confined. Toolbox/distrobox are not. Do not conflate the two security models.

## /proc and /sys Label Restrictions

Containers see a filtered view of `/proc` and `/sys`:

- `/proc/sys` is mounted read-only (masked in rootless containers)
- `/sys/fs/selinux` is not accessible from within containers
- SELinux commands (`chcon`, `restorecon`, `semanage`) fail inside standard containers
- Only `spc_t` containers (toolbox) can interact with host SELinux state

Rootless containers add further restrictions: user namespaces map UIDs, so even with correct SELinux labels, UID mismatches cause EACCES.

## Troubleshooting Denials

```bash
# Find recent AVC denials
sudo ausearch -m avc -ts recent

# Explain why a denial occurred
sudo ausearch -m avc -ts recent | audit2why

# Filter by container type
sudo ausearch -m avc -ts recent -c 'container'

# Show the SELinux context of a running container
podman inspect --format '{{.ProcessLabel}}' <container>

# Check a file's current label
ls -Z /path/to/file

# Manually relabel a path
sudo restorecon -Rv /path/to/directory

# Generate a custom policy module from denials
sudo ausearch -m avc -ts recent | audit2allow -M mypolicy
sudo semodule -i mypolicy.pp
```

## Common Denials with Rootless Containers

| Symptom | Cause | Fix |
|---|---|---|
| Permission denied on bind mount | Host file has wrong type (e.g., `user_home_t`) | Add `:z` or `:Z` to volume mount |
| Cannot write to volume | MCS label mismatch between containers | Use `:z` (shared) instead of `:Z` (private) |
| `chcon` fails inside container | `container_t` cannot relabel files | Relabel from host or use `label=disable` |
| Device access denied | `container_t` blocked from device nodes | Use `--device` flag and Udica policy if needed |
| Socket connect refused | Container MCS prevents cross-container IPC | Place socket on a `:z` shared volume |
| Home directory inaccessible | `:Z` was used on `/home` or `/var/home` | `sudo restorecon -Rv /var/home` to restore labels |
| Build cache permission errors | Overlay storage + SELinux conflict | Ensure `~/.local/share/containers/` has `container_file_t` |

## Quick Reference: Booleans

```bash
# List container-related booleans
getsebool -a | grep container

# Common toggles
sudo setsebool -P container_manage_cgroup on    # systemd in containers
sudo setsebool -P container_use_devices on      # GPU/device passthrough
sudo setsebool -P container_connect_any on       # bind any network port
```
