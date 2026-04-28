---
tags: [windows, wsl2, podman, container, rootless, cgroup-v2, fuse-overlayfs, networking, pasta, bridge, events, gpu]
languages: [bash, powershell]
since: 2026-04-28
last_verified: 2026-04-28
sources:
  - https://docs.podman.io/en/latest/markdown/podman.1.html
  - https://docs.podman.io/en/latest/markdown/podman-run.1.html
  - https://docs.podman.io/en/latest/markdown/podman-events.1.html
  - https://docs.podman.io/en/latest/markdown/podman-network.1.html
  - https://docs.podman.io/en/latest/markdown/podman-build.1.html
  - https://learn.microsoft.com/en-us/windows/wsl/wsl-config
  - https://learn.microsoft.com/en-us/windows/wsl/networking
  - https://learn.microsoft.com/en-us/windows/wsl/systemd
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: true
pull_recipe: see-section-pull-on-demand
---

# Podman in WSL2 — operational glue

@trace spec:agent-cheatsheets, spec:cross-platform, spec:windows-wsl-runtime, spec:podman-orchestration, spec:default-image

**Version baseline**: podman 5.x (Fedora 43); WSL2 on Windows 10 19044+ / Windows 11.
**Use when**: invoking podman INSIDE the `tillandsias` WSL distro from the Tillandsias Rust runner. Operational details that aren't in either generic podman docs or generic WSL docs — they live at the seam.

## Provenance

- <https://docs.podman.io/en/latest/markdown/podman.1.html> — rootless mode requirements (subuid/subgid, OverlayFS kernel, cgroup v2 default runtime)
- <https://docs.podman.io/en/latest/markdown/podman-run.1.html> — `--cap-drop`, `--security-opt`, `--userns`, `--memory`, `--rm`
- <https://docs.podman.io/en/latest/markdown/podman-events.1.html> — `--format json`, journald-as-source, the streaming protocol Tillandsias parses
- <https://docs.podman.io/en/latest/markdown/podman-network.1.html> — `network create --internal`, default `bridge` driver, aardvark-dns
- <https://docs.podman.io/en/latest/markdown/podman-build.1.html> — `-f Containerfile`, build context semantics, the `--security-opt label=disable` SELinux compat flag
- <https://learn.microsoft.com/en-us/windows/wsl/wsl-config> — `kernelCommandLine` for cgroup v2; `[boot] systemd=true`
- <https://learn.microsoft.com/en-us/windows/wsl/networking> — mirrored vs NAT, how port publishing works in each
- <https://learn.microsoft.com/en-us/windows/wsl/systemd> — systemd in WSL: enabling, what it provides
- **Last updated:** 2026-04-28

## The shape of things

Tillandsias' Rust runner on Windows runs every podman command via `wsl.exe -d tillandsias --user <forge|root> --exec podman …`. The seam introduces three operational concerns that don't exist on Linux/macOS:

1. **cgroup v2 opt-in** — the `--memory`/`--cpus` flags require it, and WSL2 doesn't enable it without the `kernelCommandLine` in `.wslconfig`.
2. **Storage backend** — `fuse-overlayfs` is required for rootless overlay; vfs is the slow fallback if it's missing.
3. **Networking layering** — podman's internal bridge inside the distro vs WSL's mirrored mode toward Windows.

Each is solved once at distro-build time + `--init` time; after that, podman invocations are platform-agnostic.

## cgroup v2 — the opt-in

Per `docs.podman.io/podman.1`:

> "When the machine is configured for cgroup V2, the default runtime is `crun`."

Per `docs.podman.io/podman-run.1`:

> "`--memory`, `-m=number[unit]` … This option is not supported on cgroups V1 rootless systems."

So: rootless `--memory=840m` (which Tillandsias' forge spec mandates) requires cgroup v2. WSL2 doesn't enable cgroup v2 by default — the kernel supports both v1 and v2, and v1 is unified by default. Force v2 via `.wslconfig`:

```ini
[wsl2]
kernelCommandLine = cgroup_no_v1=all systemd.unified_cgroup_hierarchy=1
```

Two flags. `cgroup_no_v1=all` disables v1 entirely. `systemd.unified_cgroup_hierarchy=1` tells systemd to use the unified (v2) hierarchy. Without BOTH, you'll see `mount` show `cgroup` (v1) instead of `cgroup2` (v2).

**Reboot semantics**: changes to `kernelCommandLine` require `wsl --shutdown` (NOT a Windows reboot). Tillandsias' `--init` checks `mount | grep cgroup2` after import and shutdowns the VM if the kernel cmdline didn't take.

```bash
# Verify cgroup v2 is active inside the distro:
wsl -d tillandsias -- mount | grep cgroup2
# Expected: 'cgroup2 on /sys/fs/cgroup type cgroup2 (rw,nosuid,...,memory_recursiveprot)'
# If you see 'cgroup on /sys/fs/cgroup' instead → wsl --shutdown then retry.
```

## Storage backend — fuse-overlayfs

`docs.podman.io/podman.1`:

> "The Overlay file system (OverlayFS) is not supported with kernels prior to 5.12.9 in rootless mode."

WSL2 kernels are well past 5.12.9 (the WSL2 kernel as of 2025 is in the 6.x series). So in principle, native kernel overlay should work rootless. In practice, **WSL2's filesystem semantics inside the ext4 vhdx interact poorly with native rootless overlay** — there are reports of EPERM at mount time. The reliable path is fuse-overlayfs, configured via `/etc/containers/storage.conf`:

```toml
[storage]
driver = "overlay"

[storage.options.overlay]
mount_program = "/usr/bin/fuse-overlayfs"
mountopt = "nodev,metacopy=on"
```

Per `containers-storage.conf(5)`: `mount_program` chooses the userspace helper. With `fuse-overlayfs`, podman uses FUSE to drive the overlay logic in userspace — slower than kernel overlay (~5-15% on heavy I/O) but reliable and rootless.

**If fuse-overlayfs is missing**, podman silently falls back to `vfs`. Symptom: `podman info --format '{{.Store.GraphDriverName}}'` reports `vfs`, image pulls take 2-3× longer, and disk usage is 2-3× higher (no layer dedup). Always `microdnf install fuse-overlayfs` in the distro build.

## subuid/subgid — rootless prerequisite

Per `docs.podman.io/podman.1`:

> "Podman can also be used as non-root user. When podman runs in rootless mode, a user namespace is automatically created for the user, defined in /etc/subuid and /etc/subgid."

> "It is required to have multiple UIDS/GIDS set for a user. Be sure the user is present in the files /etc/subuid and /etc/subgid."

For our `forge` user (uid 1000):

```
# /etc/subuid
forge:100000:65536

# /etc/subgid
forge:100000:65536
```

Range 100000-165535 maps host uid 100000-165535 to in-container uid 0-65535. Tillandsias' distro build script does:

```bash
useradd -u 1000 -m -s /bin/bash forge
usermod --add-subuids 100000-165535 forge
usermod --add-subgids 100000-165535 forge
```

`usermod --add-subuids` writes both files atomically. Without these, every rootless `podman run` errors with `"can't open /etc/subuid: no such file or directory"` or `"there might not be enough IDs available in the namespace"`.

## Networking — `pasta` vs `slirp4netns` vs `bridge`

`docs.podman.io/podman-run.1`:

> "**pasta**: use **pasta**(1) to create a user-mode networking stack. This is the default for rootless containers and only supported in rootless mode."

So rootless podman defaults to `pasta` (a TCP/UDP user-mode networking implementation). For our enclave use-case where containers must talk to each other via service names (`git-service`, `proxy`, `inference`), `pasta` is **insufficient** — it's a per-container user-mode stack, not a shared bridge.

Tillandsias' enclave needs:
- a **shared bridge** for forge ↔ git ↔ proxy ↔ inference traffic
- **DNS** for service-name resolution
- **`--internal`** flag on the forge-facing network so the forge has no host network access

This requires **rootful podman** for the bridge driver + aardvark-dns. The distro's systemd unit runs `podman` as root for the enclave network and ports; per-project forge containers run rootless via the `forge` user.

Setup at `--init` time:

```bash
# Inside the distro, as root:
podman network create \
  --driver bridge \
  --subnet 10.89.0.0/24 \
  --ipam-driver host-local \
  tillandsias-enclave

# Forge-facing network is internal (no egress except via proxy):
podman network create \
  --driver bridge \
  --subnet 10.90.0.0/24 \
  --internal \
  tillandsias-forge
```

Per `docs.podman.io/podman-network.1`:

> "`--internal` … Restrict external access of the network. When set, containers attached to the network will not be able to access the host or any external network."

Forge containers attach to BOTH `tillandsias-forge` (internal — for project agent code) AND `tillandsias-enclave` (for reaching git/proxy). The proxy container's egress is configured via its Squid allowlist; that's the only host-reachable container in the chain.

DNS: aardvark-dns is auto-installed alongside netavark (the `containers-storage.conf` already pinned). Container-to-container resolution `git push origin` (where origin = `git://git-service:9418/<project>`) works without agent-side direction — aardvark-dns answers `git-service` to the IP of the git container.

## Port publishing — `-p HOST:CONTAINER`

To expose a service to Windows, publish via `podman run -p`. The path:

1. `podman run -p 127.0.0.1:14000:4096 …` binds `127.0.0.1:14000` on the WSL VM's loopback.
2. WSL2 mirrored mode reflects WSL's `127.0.0.1` to Windows `127.0.0.1`. Per `learn.microsoft.com/networking`: *"Connect to Windows servers from within Linux using the localhost address `127.0.0.1`."* (also bidirectional under mirrored.)
3. Windows tray reaches `http://localhost:14000/<session>`. Done.

If on NAT mode (older WSL or user opt-out): `localhostForwarding=true` in `.wslconfig` provides the same effective reachability for VM→Windows. Tillandsias' `.wslconfig` keeps mirrored mode the default (already documented in `runtime/wsl2-isolation-boundary.md`).

**Don't publish to `0.0.0.0`** unless you mean to expose the service to your LAN. Always explicit-bind to `127.0.0.1` in `-p`.

## `podman events` — Tillandsias' lifecycle stream

Per `docs.podman.io/podman-events.1`:

> "Monitor podman events. By default, streaming mode is used, printing new events as they occur."

> "`--format json` … Output in JSON Lines format with one event per line."

The Rust runner's `PodmanEventStream` (in `crates/tillandsias-podman/src/events.rs`) reads:

```bash
wsl -d tillandsias --exec podman events --format json --filter event=start --filter event=die …
```

Two requirements for events to actually flow:

1. **`events_logger = "journald"`** in `/etc/containers/containers.conf` (already pinned in `runtime/fedora-minimal-wsl2.md`). Default on Linux is also journald; we make it explicit.
2. **systemd as PID 1 inside the distro** — `[boot] systemd=true` in `wsl.conf`. Without it, journald doesn't run, and events go nowhere.

If events stream stops mid-run (rare), the runner falls back to `podman ps --format json` polling at 2 s cadence. Same fallback as the Linux runner.

## Build context — the seam

`docs.podman.io/podman-build.1`:

> "Build a container image using a Containerfile. … `-f`, `--file=Containerfile` … specifies the Containerfile to use."

Tillandsias' build path on Windows:

```bash
wsl -d tillandsias --user root --exec \
  podman build \
    -t tillandsias-forge:v0.1.184.547 \
    -f /opt/build/forge/Containerfile \
    --security-opt label=disable \
    /opt/build/forge
```

The Containerfile + build context lives at `/opt/build/<svc>/` INSIDE the distro (baked at distro-build time per `runtime/fedora-minimal-wsl2.md`). `--security-opt label=disable` suppresses SELinux relabeling on bind-mounts when the host happens to have SELinux enforcing — irrelevant here (WSL2 distro doesn't have SELinux by default) but harmless and matches the Linux/macOS path.

**No host-side `podman build`** on Windows. The Linux/macOS path does `podman build` directly on the host. The Windows path does `wsl --exec podman build` — the same Containerfiles, same build context, just one extra hop.

## GPU passthrough into a podman container

The user-facing chain: `Windows GPU → /dev/dxg in WSL VM → /dev/dxg in podman container`.

Step 1: `[gpu] enabled=true` in `/etc/wsl.conf` exposes `/dev/dxg` to the distro. Microsoft Learn `wsl-config`: *"`true` … Allow Linux applications to access the Windows GPU via para-virtualization."*

Step 2: pass `/dev/dxg` into the container:

```bash
podman run \
  --device /dev/dxg \
  --volume /usr/lib/wsl:/usr/lib/wsl:ro \
  …
```

The volume mount is needed because the WSL DXG runtime libraries live at `/usr/lib/wsl/lib/` in the distro. Without the mount, the container has the device but no userspace driver.

**Verification**:

```bash
podman run --rm --device /dev/dxg --volume /usr/lib/wsl:/usr/lib/wsl:ro \
  fedora-minimal:43 ls /dev/dxg
# Expected: /dev/dxg
```

For NVIDIA-specific GPU compute (CUDA inside the container — used by ollama for inference): additionally install nvidia-container-toolkit on the host; configure podman with `--device nvidia.com/gpu=all`. Vendor docs only cover the docker path explicitly; the podman equivalent is **needs-prototype** before shipping. Tillandsias' inference container should fall back to CPU inference if GPU passthrough fails — same fallback as Linux.

## `wsl --exec` round-trip overhead

Every `wsl.exe -d tillandsias --exec podman …` invocation has ~10-20 ms of WSL relay overhead on top of the podman call itself. For `podman ps` (cheap, ~50 ms), this is a 20-40% overhead. For `podman build` (heavy, seconds), negligible.

Optimizations:

- **Long-running streams** (`podman events`, `podman logs -f`) pay the relay cost ONCE then stream. No per-line overhead.
- **Bulk operations** — prefer one `wsl --exec` running a multi-line shell that issues N podman commands over N separate `wsl --exec podman` invocations.
- **Spawn flag** — Tillandsias already passes `CREATE_NO_WINDOW` to suppress console flicker per `runtime/wsl-on-windows.md`.

## Common pitfalls

- **`podman --remote` does NOT work via `wsl --exec`** — `--remote` requires a unix socket the wsl-side daemon publishes; we don't run a podman service. Always invoke local `podman` directly through `wsl --exec`.
- **`pasta` vs `bridge` mismatch**: rootless podman defaults to pasta. If a user creates a network rootless and another rootful, they're invisible to each other. Tillandsias mitigates by running enclave networking ROOTFUL (one daemon view) and forge containers ALSO on the rootful daemon (run via `podman --remote=false`, default).
- **fuse-overlayfs missing → silent vfs fallback**. `podman info --format '{{.Store.GraphDriverName}}'` SHALL be `overlay` after `--init`. Spec assertion.
- **cgroup v2 not enabled → `--memory` silently ignored** on rootless. Symptom: forge container uses unbounded RAM, Tillandsias' RAM ceiling spec violated. Verify per the snippet above as part of `--init` smoke.
- **Networking-mode mismatch + port-publish**: `-p` works under both NAT and mirrored, but NAT requires `localhostForwarding=true` (default) while mirrored is automatic. If a user disabled both, port publishing silently doesn't reach Windows.
- **`--security-opt label=disable`** is needed only when the host (the WSL distro in this case) has SELinux enforcing AND the bind-mount source has the wrong context. WSL2 Fedora-minimal distro doesn't ship SELinux by default; the flag is harmless when SELinux is off, but flag it as a remove-when-prototyped item.
- **`podman events --filter event=…`** must match exact lifecycle event names — not all events the manpage documents have stable names across podman versions. Filter conservatively: `start`, `die`, `kill`, `health_status` are stable.
- **Image build cache cross-host**: podman's build cache lives in `/var/lib/containers/storage` (rootful) or `~/.local/share/containers/storage` (rootless). Both are inside the WSL distro's vhdx. Wiping the distro wipes the cache. Tillandsias' image-staleness detection (in `crates/tillandsias-podman/src/build.rs`) uses content hashes, so the cache wipe just costs one rebuild.
- **`wsl --exec` returns the wrapped command's exit code**, but if `wsl.exe` itself fails to launch (rare — usually a service problem), it returns 1 with no output. Tillandsias' runner distinguishes via `Output.status.code()` checks.

## Tillandsias `--init` flow against this seam

```text
1. wsl --import tillandsias … (creates the distro)
2. Read .wslconfig, ensure cgroup_no_v1=all + sparseVhd=true
3. wsl --shutdown (so kernelCommandLine takes effect)
4. Verify: wsl --exec mount | grep cgroup2
5. Verify: wsl --user forge --exec podman info | grep -q '^store.*overlay'
6. Create networks: wsl --user root --exec podman network create tillandsias-enclave + tillandsias-forge --internal
7. Build images: for svc in (proxy git router inference forge browser-chrome):
     wsl --user root --exec podman build -t tillandsias-$svc:vX -f /opt/build/$svc/Containerfile --security-opt label=disable /opt/build/$svc
8. Smoke: wsl --user forge --exec podman run --rm --cap-drop=ALL --security-opt=no-new-privileges --userns=keep-id fedora-minimal:43 echo OK
```

If any step fails, surface a remediation linking to this cheatsheet.

## See also

- `runtime/fedora-minimal-wsl2.md` — recipe for the distro this lives on; includes /etc/containers/{storage,containers}.conf
- `runtime/wsl2-isolation-boundary.md` — wsl.conf hardening including `[boot] systemd=true` and `[gpu] enabled=true`
- `runtime/wsl2-disk-elasticity.md` — vhdx that holds the podman storage; sizing and reclaim
- `runtime/podman-security-flags.md` — Linux-side companion (--cap-drop, --security-opt, --userns) — planned
- `runtime/wsl-on-windows.md` — `wsl --exec` mechanics, console flicker mitigation
- `runtime/wsl2-network-mirrored-mode.md` — networking specifics for the host↔VM↔container path — planned

## Pull on Demand

> Hand-curated, tracked in-repo (`committed_for_project: true`).
> Provenance: vendor primary sources only (docs.podman.io upstream,
> Microsoft Learn for WSL).
> Refresh cadence: when podman ships a new major (e.g. 5→6), when WSL
> changes default networking mode, or when fuse-overlayfs is replaced
> by a kernel-overlay-rootless path that's reliable in WSL2.
