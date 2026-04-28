---
tags: [windows, wsl2, fedora, podman, container, recipe, image-build, rootless, subuid, fuse-overlayfs, cgroup-v2]
languages: [bash, powershell]
since: 2026-04-28
last_verified: 2026-04-28
sources:
  - https://learn.microsoft.com/en-us/windows/wsl/use-custom-distro
  - https://learn.microsoft.com/en-us/windows/wsl/wsl-config
  - https://docs.podman.io/en/latest/markdown/podman.1.html
  - https://docs.podman.io/en/latest/markdown/podman-run.1.html
  - https://docs.podman.io/en/latest/markdown/podman-build.1.html
  - https://github.com/containers/storage/blob/main/docs/containers-storage.conf.5.md
  - https://github.com/containers/common/blob/main/docs/containers.conf.5.md
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: true
pull_recipe: see-section-pull-on-demand
---

# Fedora-minimal WSL2 distro — recipe for hosting podman

@trace spec:agent-cheatsheets, spec:cross-platform, spec:windows-wsl-runtime, spec:chromium-browser-isolation, spec:default-image, spec:podman-orchestration

**Version baseline**: Fedora 43 (current GA at time of writing); podman 5.x; WSL2 on Windows 10 19044+ / Windows 11.
**Use when**: building the single `tillandsias` WSL2 distro that hosts podman and runs every Tillandsias container (forge, proxy, git, router, inference, browser-chrome) inside it. The Windows arm of `spec:windows-wsl-runtime`.

## Provenance

- <https://learn.microsoft.com/en-us/windows/wsl/use-custom-distro> — `wsl --import` from a tarball; the `podman create + podman export` recipe for converting an OCI image to a WSL rootfs
- <https://learn.microsoft.com/en-us/windows/wsl/wsl-config> — `[boot] systemd=true`, `[experimental] sparseVhd`, `kernelCommandLine` for cgroup v2
- <https://docs.podman.io/en/latest/markdown/podman.1.html> — rootless mode, subuid/subgid requirement, OverlayFS kernel version requirement, cgroup v2 default runtime is crun
- <https://docs.podman.io/en/latest/markdown/podman-run.1.html> — `--cap-drop`, `--security-opt`, `--userns`, `--rm`, `--memory` (cgroup v2)
- <https://docs.podman.io/en/latest/markdown/podman-build.1.html> — `podman build -f <Containerfile>`
- <https://github.com/containers/storage/blob/main/docs/containers-storage.conf.5.md> — `storage.conf` `mount_program=fuse-overlayfs`
- <https://github.com/containers/common/blob/main/docs/containers.conf.5.md> — `containers.conf` `events_logger`, `runtime`
- **Last updated:** 2026-04-28

## Why this distro exists (one-line)

Tillandsias' Windows-runtime model is `WindowsHost > tray.exe + ONE WSL distro > podman > containers`. This distro IS that one WSL distro: minimal Fedora userland + podman/crun/fuse-overlayfs/aardvark-dns/netavark/systemd, pre-configured for rootless containers and the Tillandsias enclave. All other images (forge, proxy, git, router, inference, browser-chrome) are **podman images built and run INSIDE this distro** at `--init` time, not separate WSL distros.

## Source rootfs choice

The WSL `--import` command takes a rootfs tarball. Microsoft documents two acceptable construction paths:

> "First you'll need to obtain a tar file that contains all the Linux binaries for the distribution. You can obtain a tar file in a variety of ways, two of which include: Download a provided tar file. … Find a Linux distribution container and export an instance as a tar file." — `use-custom-distro`

We use the second path: `registry.fedoraproject.org/fedora-minimal:43` as the base, customize via `microdnf install`, then `podman create + podman export` the result to a tarball. The final tarball is ~250 MB compressed and lands at `images/tillandsias-distro/tillandsias-distro.tar`, ready for `wsl --import` by the installer.

## Build script: `scripts/wsl-build/build-tillandsias-distro.sh`

This script supersedes the per-service `build-forge.sh`/`build-git.sh`/`build-proxy.sh`/`build-router.sh`/`build-inference.sh`/`build-enclave-init.sh` from the prior architecture (those become podman images built INSIDE this distro at `--init` time, not separate WSL distros). Runs on a Linux/macOS dev host with podman, OR on Windows itself with podman in `podman-machine-default`.

```bash
#!/usr/bin/env bash
# @trace spec:windows-wsl-runtime, spec:default-image, spec:cross-platform
# @cheatsheet runtime/fedora-minimal-wsl2.md
# Builds tillandsias-distro.tar from fedora-minimal:43 + podman stack.

set -euo pipefail

OUT_DIR="${1:-target/wsl}"
mkdir -p "$OUT_DIR"

# Build the customized rootfs in a build container we'll throw away.
BUILD_CONTAINER="$(podman create \
  registry.fedoraproject.org/fedora-minimal:43 \
  /bin/sh -c 'true')"

# Layer 1: install podman + supporting userland.
podman start --attach "$BUILD_CONTAINER" >/dev/null 2>&1 || true
podman exec --user root "$BUILD_CONTAINER" microdnf install -y \
    podman crun fuse-overlayfs \
    aardvark-dns netavark \
    systemd systemd-sysv \
    iproute iputils ca-certificates \
    util-linux shadow-utils \
    --setopt=install_weak_deps=False \
  || true

# Layer 2: create the unprivileged "forge" user with subuid/subgid for rootless podman.
# Per docs.podman.io/podman.1: "It is required to have multiple UIDS/GIDS set for a
# user. Be sure the user is present in the files /etc/subuid and /etc/subgid."
podman exec --user root "$BUILD_CONTAINER" /bin/sh -c '
  useradd -u 1000 -m -s /bin/bash forge
  usermod --add-subuids 100000-165535 forge
  usermod --add-subgids 100000-165535 forge
'

# Layer 3: ship the Tillandsias hardening profile as /etc/wsl.conf.
# See cheatsheets/runtime/wsl2-isolation-boundary.md for the rationale.
podman cp images/tillandsias-distro/wsl.conf \
  "$BUILD_CONTAINER:/etc/wsl.conf"

# Layer 4: ship containers/storage.conf + containers/containers.conf.
podman cp images/tillandsias-distro/storage.conf \
  "$BUILD_CONTAINER:/etc/containers/storage.conf"
podman cp images/tillandsias-distro/containers.conf \
  "$BUILD_CONTAINER:/etc/containers/containers.conf"

# Layer 5: bake the per-service Containerfiles + build context.
# These will be `podman build`-ed INSIDE the distro at `tillandsias --init` time.
podman cp images/forge      "$BUILD_CONTAINER:/opt/build/forge"
podman cp images/proxy      "$BUILD_CONTAINER:/opt/build/proxy"
podman cp images/git        "$BUILD_CONTAINER:/opt/build/git"
podman cp images/router     "$BUILD_CONTAINER:/opt/build/router"
podman cp images/inference  "$BUILD_CONTAINER:/opt/build/inference"
podman cp images/browser-chrome "$BUILD_CONTAINER:/opt/build/browser-chrome"

# Export.
podman export "$BUILD_CONTAINER" -o "$OUT_DIR/tillandsias-distro.tar"
podman rm "$BUILD_CONTAINER"

ls -la "$OUT_DIR/tillandsias-distro.tar"
```

## Configuration files baked into the distro

### `/etc/wsl.conf`

See full content in `runtime/wsl2-isolation-boundary.md`. Closes drvfs, interop, $PATH leak; keeps GPU + systemd; ships our own `/etc/resolv.conf`.

### `/etc/containers/storage.conf`

Pin the OverlayFS backend to fuse-overlayfs explicitly. Per `containers-storage.conf(5)`: `mount_program` chooses the helper for OverlayFS. Without it, podman may default to vfs (slow + space-inefficient) or unconfigured overlay (kernel mounts only work as root).

```toml
# @trace spec:windows-wsl-runtime, spec:default-image
# @cheatsheet runtime/fedora-minimal-wsl2.md
# Pin overlay backend so podman doesn't fall back to vfs in rootless mode.
# Per docs.podman.io/podman.1: "The Overlay file system (OverlayFS) is not
# supported with kernels prior to 5.12.9 in rootless mode." WSL2 kernel is
# always well past this. fuse-overlayfs is the userspace helper for rootless.

[storage]
driver = "overlay"
graphroot = "/var/lib/containers/storage"   # rootful default
runroot = "/run/containers/storage"

[storage.options]
additionalimagestores = []

[storage.options.overlay]
mount_program = "/usr/bin/fuse-overlayfs"
mountopt = "nodev,metacopy=on"
```

### `/etc/containers/containers.conf`

```toml
# @trace spec:windows-wsl-runtime, spec:default-image
# @cheatsheet runtime/fedora-minimal-wsl2.md

[engine]
events_logger = "journald"      # so `podman events --format json` round-trips through systemd
runtime = "crun"                # cgroup v2 default per docs.podman.io/podman.1
cgroup_manager = "systemd"      # ditto

[network]
default_network = "tillandsias-enclave"   # matches Linux/macOS naming

[containers]
# Default security flags for `podman run` IF caller doesn't override.
# Tillandsias' Rust runner ALWAYS passes these explicitly anyway, so this
# is belt-and-suspenders.
default_capabilities = []        # equivalent to --cap-drop=ALL
no_hosts = false                 # leave default; we control DNS via aardvark-dns
seccomp_profile = "/usr/share/containers/seccomp.json"   # default seccomp
userns = "auto"                  # rootless gets auto userns
```

### subuid/subgid

Per `docs.podman.io/podman.1`: *"Podman can also be used as non-root user. When podman runs in rootless mode, a user namespace is automatically created for the user, defined in /etc/subuid and /etc/subgid."*

Pre-populated by the build script for uid 1000 (forge user):

```
# /etc/subuid
forge:100000:65536
```

```
# /etc/subgid
forge:100000:65536
```

`usermod --add-subuids 100000-165535 forge` writes both. The 65536 range (mapping host uid 100000-165535 to in-container uid 0-65535) is the documented default and matches most distro packaging.

## cgroup v2 — required for `--memory`, `--cpus` in rootless

Per `docs.podman.io/podman-run.1`: `--memory` "is not supported on cgroups V1 rootless systems". Tillandsias' enclave spec mandates `--memory=840m` for forge, `--memory=192m` for proxy, etc. Therefore cgroup v2 is mandatory.

WSL2 supports cgroup v2 but requires opt-in via the host's `.wslconfig`:

```ini
# @trace spec:windows-wsl-runtime, spec:cross-platform
# (this lives in %UserProfile%\.wslconfig — host-side, not in the distro)
[wsl2]
kernelCommandLine = cgroup_no_v1=all systemd.unified_cgroup_hierarchy=1
```

Confirms cgroup v2 is unified inside the distro: `mount | grep cgroup2` should show `cgroup2 on /sys/fs/cgroup`. Per `docs.podman.io/podman.1`: *"When the machine is configured for cgroup V2, the default runtime is `crun`."* — matches our `containers.conf`.

## systemd in WSL

Per Microsoft Learn `wsl-config`, `[boot] systemd=true` enables systemd as PID 1. This is required for:

- `podman events --format json` (uses journald → events_logger=journald)
- the `--rm` lifecycle for long-running containers (systemd reaps zombies)
- the per-distro nftables rule loader for `tillandsias-browser-chrome` (see `runtime/wsl-browser-isolation.md`)

`microdnf install systemd systemd-sysv` is the package set; `systemd-sysv` provides `/sbin/init`. Without `systemd=true` in `wsl.conf`, the distro's PID 1 is `init(tillandsias-distro)` — a tiny WSL shim, not systemd.

## Verification — quick smoke after `wsl --import`

```powershell
wsl --import tillandsias %LOCALAPPDATA%\Tillandsias\WSL\tillandsias `
  %LOCALAPPDATA%\Tillandsias\stage\tillandsias-distro.tar --version 2

# Confirm cgroup v2:
wsl -d tillandsias -- mount | findstr cgroup2
# Expected: 'cgroup2 on /sys/fs/cgroup type cgroup2'

# Confirm podman version + storage backend:
wsl -d tillandsias -- podman version
wsl -d tillandsias -- podman info --format '{{.Store.GraphDriverName}}'
# Expected: overlay (with mount_program = fuse-overlayfs)

# Confirm subuid/subgid for the forge user:
wsl -d tillandsias --user forge -- podman info --format '{{.Host.IDMappings}}'
# Expected: non-empty UID/GID mappings starting at 100000

# Smoke: rootless run with the spec security flags
wsl -d tillandsias --user forge -- \
  podman run --rm --cap-drop=ALL \
    --security-opt=no-new-privileges \
    --userns=keep-id \
    fedora-minimal:43 echo OK
# Expected: OK
```

If any of the above fail, the distro tarball is broken — re-run `build-tillandsias-distro.sh` and `wsl --import` again.

## Common pitfalls

- **Default WSL `init` is NOT systemd.** Without `[boot] systemd=true` in `wsl.conf`, podman's events logger silently fails to reach journald and `podman events` returns nothing.
- **`microdnf` lacks weak-deps suppression by default**. Pass `--setopt=install_weak_deps=False` or your distro tarball doubles in size from `Recommends:` chains.
- **`fuse-overlayfs` must be installed**, not just declared in `storage.conf`. Without the binary, podman silently falls back to `vfs` (correct but slow + 2-3× disk usage).
- **`cgroup_no_v1=all` requires `wsl --shutdown`** to take effect. Tillandsias' `--init` flow detects "no current cgroup-v2" via `mount | grep cgroup2` and prompts the user; bare-metal rebooting Windows is NOT required.
- **`crun` not `runc` is the cgroup v2 default**. Per `docs.podman.io/podman.1`. Don't `microdnf install runc` — Fedora 43 ships `crun` and `containers.conf` references it.
- **`podman create + podman export` flattens layers**. Good for WSL `--import` (which wants a single tar), but means you can't update the distro by `podman pull` of a newer base — you re-run the build script.
- **`registry.fedoraproject.org/fedora-minimal:43` size** is ~150 MB. Adding podman + crun + fuse-overlayfs + aardvark-dns + netavark + systemd brings the rootfs to ~250 MB compressed. The `--import` step expands to ~600 MB on first run; sparse-VHD reclaims as containers come and go.
- **Don't bake images into the distro tarball.** The Containerfiles and build context go in `/opt/build/<service>/`; actual `podman build` happens at `tillandsias --init` time inside the user's installed distro. This keeps the shipped tarball small and lets the user's machine produce locally-valid images.
- **subuid/subgid range collisions** on multi-user Windows machines: if the user already has another rootless-podman setup, the 100000-165535 range may collide with another distro's mapping. Tillandsias' `--init` flow can detect this via reading `/etc/subuid` after `--import` and shifting the range; not done in v1.
- **No `runc` fallback** unless you ALSO `microdnf install runc` and update `containers.conf`. We don't ship runc; if cgroup v2 isn't enabled, the container start will surface a clear "cgroup v2 required" error rather than silently falling back to a less-capable runtime.

## Tillandsias `--init` flow against this distro

Once the distro is imported, `tillandsias --init` builds the per-service podman images INSIDE it:

```powershell
# Pseudocode
foreach ($svc in @("proxy", "git", "router", "inference", "forge")) {
    $tag = "tillandsias-$svc:v$version"
    wsl -d tillandsias --user root -- \
      podman build -t $tag -f /opt/build/$svc/Containerfile /opt/build/$svc
}
```

Each `podman build` produces an image stored in the distro's `containers-storage`. They're then run with the spec security flags by `tray_spawn::ensure_<svc>_running` from the Rust side. No new WSL distro needed per service — that was the old (rejected) architecture.

## See also

- `runtime/wsl2-isolation-boundary.md` — the wsl.conf knobs cited here are documented exhaustively there
- `runtime/wsl-on-windows.md` — `wsl --import` semantics, drvfs gotchas, console flicker mitigation
- `runtime/podman-in-wsl2.md` — podman quirks under WSL2 (cgroup v2, fuse-overlayfs, subuid/subgid in detail) — planned
- `runtime/wsl2-disk-elasticity.md` — vhdx growth, sparse, `--manage --resize` — planned
- `runtime/secrets-management.md` — credential isolation rationale; why we don't put secrets on this distro's filesystem
- `runtime/windows-installer-prereqs.md` — installer's WSL2 hard-requirement check that runs BEFORE `wsl --import`
- `runtime/wsl-browser-isolation.md` — applies the hardening to the chromium-browser-isolation spec

## Pull on Demand

> Hand-curated, tracked in-repo (`committed_for_project: true`).
> Provenance: vendor primary sources only (Microsoft Learn, docs.podman.io,
> github.com/containers/common, github.com/containers/storage, Fedora
> Project).
> Refresh cadence: when Fedora ships a new minor (43→44), when podman
> ships a new major version, when WSL adds new wsl.conf keys, or when the
> overlay storage driver semantics change.
