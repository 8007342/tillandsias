---
tags: [windows, wsl, wsl2, runtime, enclave, no-podman]
languages: [bash, powershell]
since: 2026-04-27
last_verified: 2026-04-27
sources:
  - https://learn.microsoft.com/en-us/windows/wsl/use-custom-distro
  - https://learn.microsoft.com/en-us/windows/wsl/basic-commands
  - https://github.com/containers/skopeo
  - https://alpinelinux.org/downloads/
  - https://registry.fedoraproject.org/
authority: high
status: current
---

# WSL on Windows — runtime model

@trace spec:cross-platform, spec:enclave-network, spec:forge-offline
@cheatsheet runtime/forge-container.md, runtime/windows-native-dev-build.md

## Provenance

- "Import any Linux distribution to use with WSL" — <https://learn.microsoft.com/en-us/windows/wsl/use-custom-distro> — fetched 2026-04-26.

  > "First you'll need to obtain a tar file that contains all the Linux binaries for the distribution. You can obtain a tar file in a variety of ways, two of which include: Download a provided tar file. ... Find a Linux distribution container and export an instance as a tar file."

  > "Once you have a tar file ready, you can import it using the command: `wsl.exe --import <Distro> <InstallLocation> <FileName> [Options]`"

- "Basic commands for WSL" — <https://learn.microsoft.com/en-us/windows/wsl/basic-commands> — fetched 2026-04-26.

  > "`wsl --user <Username>` — To run WSL as a specified user, replace `<Username>` with the name of a user that exists in the WSL distribution."

  > "`wsl --terminate <Distribution Name>` — To terminate the specified distribution, or stop it from running."

- skopeo (daemonless OCI registry client) — <https://github.com/containers/skopeo> — confirmed Windows binary release ~25 MB, supports `skopeo copy docker://... oci:<dir>` for non-daemon image extraction.

- Alpine minirootfs — <https://alpinelinux.org/downloads/> — confirmed signed `alpine-minirootfs-<x.y.z>-x86_64.tar.gz` published per release with SHA-256 sidecars.

- **Last updated**: 2026-04-27

**Use when**: working on Tillandsias for Windows. The Windows path uses WSL2 distros directly, with no podman/docker. A "podman image" on Linux corresponds 1:1 to a "WSL distro" on Windows.

## The mapping

| Linux/macOS (podman)              | Windows (WSL)                                                  |
|-----------------------------------|----------------------------------------------------------------|
| podman image (`tillandsias-forge`) | WSL distro (`tillandsias-forge`)                              |
| `podman create + export`          | `wsl --import <name> <install-dir> <tarball> --version 2`      |
| `podman run --rm`                 | clone distro on attach, `wsl --unregister` on detach           |
| `podman exec -u 1000 -w /x cmd`   | `wsl -d <name> --user 1000 --cd /x --exec cmd`                 |
| `podman stop`                     | `wsl --terminate <name>`                                       |
| `podman rm`                       | `wsl --unregister <name>`                                      |
| `podman ps -a`                    | `wsl --list --verbose`                                         |
| `podman events`                   | (none — poll `wsl --list --running` every 500 ms)              |
| `--network=enclave-internal`      | shared netns + uid-based iptables drop in enclave-init distro  |
| `--cap-drop=ALL`                  | `unshare --net --setuid` in entrypoint                         |
| `-v /host:/dest`                  | `/mnt/c/...` (DrvFs, automatic, no per-launch flag)            |
| `--memory=8g`                     | cgroup-v2 `memory.max` written by entrypoint inside the distro |

## Build pipeline (Windows-only, no podman)

Each enclave service is built natively in WSL, never via podman:

| Service       | Base                    | Built by                                      |
|---------------|-------------------------|-----------------------------------------------|
| forge         | Fedora 43 (container)   | `scripts/wsl-build/build-forge.sh`            |
| proxy         | Alpine minirootfs       | `scripts/wsl-build/build-proxy.sh`            |
| git           | Alpine minirootfs       | `scripts/wsl-build/build-git.sh`              |
| inference     | Alpine minirootfs       | `scripts/wsl-build/build-inference.sh`        |
| router        | Alpine minirootfs       | `scripts/wsl-build/build-router.sh`           |
| enclave-init  | Alpine minirootfs       | `scripts/wsl-build/build-enclave-init.sh`     |

```bash
# Acquire base, ONCE per host (cached under ~/.cache/tillandsias/wsl-bases/):
scripts/wsl-build/bases.sh alpine-3.20      # direct download from dl-cdn.alpinelinux.org
scripts/wsl-build/bases.sh fedora-43        # skopeo copy docker://registry.fedoraproject.org/fedora:43

# Build a service:
scripts/wsl-build/build-proxy.sh            # produces target/wsl/tillandsias-proxy.tar
```

The Containerfile under `images/<service>/` remains the source of truth: each `RUN`/`COPY` in it has a 1:1 line in the build script.

## Quick reference — verbs Tillandsias issues

```powershell
# Import a service distro (--init time):
wsl.exe --import tillandsias-proxy `
  $env:LOCALAPPDATA\Tillandsias\WSL\proxy `
  target\wsl\tillandsias-proxy.tar --version 2

# Run an agent inside a forge clone (--rm-equivalent):
wsl.exe --export tillandsias-forge "$env:TEMP\forge-$session.tar"
wsl.exe --import "tillandsias-forge-$session" `
  "$env:LOCALAPPDATA\Tillandsias\Sessions\$session" `
  "$env:TEMP\forge-$session.tar" --version 2
wsl.exe -d "tillandsias-forge-$session" --user 2003 `
  --cd /mnt/c/Users/bullo/src/myproject --exec /opt/agents/entrypoint.sh

# Detach:
wsl.exe --terminate "tillandsias-forge-$session"
wsl.exe --unregister "tillandsias-forge-$session"
```

## forge-offline on Windows

All distros share **one Linux network namespace** (Microsoft Learn confirms). forge-offline-ness is enforced two ways simultaneously:

1. **Layer 1 — uid-based iptables egress drop**, applied once at WSL VM cold-boot by the `enclave-init` distro:
   ```
   iptables -A OUTPUT -m owner --uid-owner 2000-2999 -d 127.0.0.0/8 -j ACCEPT
   iptables -A OUTPUT -m owner --uid-owner 2000-2999 -j DROP
   ```
   forge agents always run as a uid in `[2000, 2999]`. proxy/git/inference run as uids outside that range.

2. **Layer 2 — `unshare --net`** when the entrypoint exec's the agent: the agent process gets a fresh net namespace whose only interface is `lo`. A `socat` relay plumbs the agent's loopback to the proxy in the parent namespace.

The tray runs a smoke probe before every attach — if `curl https://example.com` succeeds OR `curl http://127.0.0.1:3128/health` fails, the tray refuses to attach.

## Common pitfalls

- **Don't expect per-distro network isolation**. They share netns. Every distro's `eth0` has the same IP and MAC. Use uid scoping instead.
- **`wsl --terminate` is SIGKILL**. No grace period. Run a shutdown command inside the distro first.
- **`wsl --import` of a 6 GB tarball takes ~30-60 s.** For ephemeral session distros, prefer the future copy-on-write VHDX path; the slow path is the Phase 1 fallback.
- **Bind mounts are not first-class.** Windows paths come through `/mnt/c/...` automatically; per-launch `-v` does not exist.
- **`localhost:8080` from Windows browser reaches the WSL service** because of `localhostForwarding=true` (default). LAN access requires `firewall=false` in `.wslconfig`.
- **There is NO event stream.** Tray polls `wsl --list --running` at 500 ms cadence to synthesize `start`/`stop` events.
- **A "WSL distro" is not a "container".** No `--cap-drop`, no `--security-opt`, no `--userns`. All hardening is done inside the distro by the entrypoint via `unshare`, `setpriv`, `capsh`, etc.

## See also

- `cheatsheets/runtime/windows-native-dev-build.md` — host-side build of the tray binary itself (rustup + sidecar staging).
- `cheatsheets/runtime/forge-container.md` — what the forge environment provides agents (same on Linux and Windows).
- `docs/cheatsheets/runtime/wsl/architecture-isolation.md` — Microsoft Learn deep-dive on the shared-namespace constraint.
- `docs/cheatsheets/runtime/wsl/cli-surface.md` — full `wsl.exe` verb inventory.
