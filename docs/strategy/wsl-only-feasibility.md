# WSL-only feasibility for the Tillandsias enclave on Windows

@trace spec:cross-platform, spec:podman-orchestration, spec:enclave-network

> **Status**: Investigation report, 2026-04-26. Recommendation pending prototype validation.
> **Author**: Claude Opus (1M context) for the Tillandsias project.
> **Companion cheatsheets**: `docs/cheatsheets/runtime/wsl/{architecture-isolation,networking-modes,wslconfig-tunables,systemd-and-cgroups,cli-surface}.md` — verbatim provenance for every WSL claim made below.

## TL;DR

**Recommendation: do NOT drop podman on Windows. Instead, move from "podman.exe on Windows host driving podman-machine over gvproxy" to "podman running inside a Tillandsias-managed WSL distro, driven by `wsl --exec podman` from the host"** — i.e., Architecture Option 2 below ("Podman-in-WSL"). This collapses one process boundary (Windows-host podman.exe ↔ podman-machine), unlocks Unix-domain control sockets across the boundary, and keeps every spec primitive Tillandsias depends on. A pure WSL-without-podman design (Option 4) is **not feasible** for the enclave-network requirement: Microsoft documents that all WSL2 distros share the same network namespace, and `wsl.exe` exposes no equivalent of `podman network create --internal`, no event stream, no bind-mount on launch, and no graceful-stop-then-kill primitive. The work to recreate those inside a single WSL distro is exactly the work podman already does — there is no win in doing it ourselves.

The three load-bearing findings:

- **WSL2 distros share one Linux network namespace by default** (Microsoft Learn / `about`, fetched 2026-04-26): "Linux distributions running via WSL 2 will share the same network namespace ... but have their own PID namespace, Mount namespace, User namespace, Cgroup namespace, and `init` process." This kills the "four enclave services = four distros" hypothesis on its own.
- **The `wsl.exe` CLI is missing primitives Tillandsias actually uses every launch** (Microsoft Learn / `basic-commands`, fetched 2026-04-26): no event stream, no `inspect --format json`, no `network create`, no `--rm`, no SIGTERM-with-grace-then-SIGKILL, no per-command bind mounts. We would have to implement all of that inside Tillandsias.
- **Putting podman *inside* a WSL distro Tillandsias controls is strictly better than today's `podman machine`**: it gives us a Unix-domain socket (control-socket spec), eliminates the gvproxy NAT layer that `--add-host alias:host-gateway` currently works around, and removes the `cfg(unix)` gate on `mount_control_socket` (cheatsheet `runtime/networking.md`).

## Methodology

What I did, in order:

1. Read the spec corpus to enumerate the podman primitives Tillandsias depends on:
   `openspec/specs/{enclave-network,podman-orchestration,proxy-container,forge-offline,git-mirror-service,inference-container,cross-platform}/spec.md`.
2. Read the actual `podman run` argument generator and the podman CLI wrapper:
   `src-tauri/src/launch.rs:27` (`build_podman_args()`),
   `crates/tillandsias-podman/src/lib.rs` (`podman_cmd()`),
   `crates/tillandsias-podman/src/client.rs`,
   `crates/tillandsias-podman/src/launch.rs`,
   `crates/tillandsias-podman/src/events.rs`.
3. Read the existing Windows-related delta (`openspec/changes/windows-native-build/{proposal,design,tasks}.md`) and the runtime cheatsheets that document the contract (`cheatsheets/runtime/{networking,forge-container,forge-paths-ephemeral-vs-persistent}.md`).
4. Pulled authoritative WSL2 documentation via WebFetch on 2026-04-26:
   - `https://learn.microsoft.com/en-us/windows/wsl/about` (page `ms.date: 2025-05-19`, `updated_at: 2025-06-10`)
   - `https://learn.microsoft.com/en-us/windows/wsl/networking` (page `ms.date: 2024-07-16`, `updated_at: 2025-12-09`)
   - `https://learn.microsoft.com/en-us/windows/wsl/wsl-config` (page `ms.date: 2025-07-31`, `updated_at: 2025-12-09`)
   - `https://learn.microsoft.com/en-us/windows/wsl/systemd` (page `ms.date: 2025-01-13`, `updated_at: 2025-06-10`)
   - `https://learn.microsoft.com/en-us/windows/wsl/basic-commands` (page `ms.date: 2025-12-01`, `updated_at: 2025-12-09`)
   - `https://learn.microsoft.com/en-us/windows/wsl/use-custom-distro` (page `ms.date: 2021-09-27`, `updated_at: 2025-08-06`)
   - `https://man7.org/linux/man-pages/man7/network_namespaces.7.html`
   - `https://man7.org/linux/man-pages/man7/cgroups.7.html`
   - `https://man7.org/linux/man-pages/man1/systemd-nspawn.1.html`
   - `https://podman.io/docs/installation` and `https://docs.podman.io/en/stable/markdown/podman-machine.1.html`
   - `https://github.com/containers/podman/discussions/22961` (cgroup-v2 in WSL2)
   - `https://blog.richy.net/2025/06/16/wsl2.html` (third-party recipe; verify before quoting authoritatively)
5. Extracted verbatim quotes into five cheatsheets under `docs/cheatsheets/runtime/wsl/` so future readers do not have to re-fetch.
6. Built the inventory and capability mapping below.

## Inventory: what podman gives Tillandsias today

The exhaustive list of podman primitives the codebase uses, with criticality.

### Image lifecycle

| Primitive | Used at | Criticality |
|---|---|---|
| `podman --version` (probe) | `crates/tillandsias-podman/src/client.rs:30` | startup-critical |
| `podman machine list/init/start` | `client.rs:39-126`, `init_machine`, `start_machine` | Win/macOS startup-critical |
| `podman image exists <tag>` | `client.rs:150` | convenience |
| `podman pull <image>` | `client.rs:159`, `launch.rs:114` | not used in default path (we build local) |
| `podman build -t <tag> -f <Containerfile> <ctx>` | `client.rs:316`, `src-tauri/src/handlers.rs:2977` (Windows path) | startup-critical (forge build) |
| `podman load -i <tarball>` | `client.rs:361` (used by Nix build path) | convenience |
| `podman images --format` | `handlers.rs:2545` | housekeeping |
| `podman rmi <tag>` | `handlers.rs:2580` | housekeeping |
| `podman image prune -f` | `handlers.rs:2598` | housekeeping |

### Container lifecycle

| Primitive | Used at | Criticality |
|---|---|---|
| `podman run [-d|-it] --rm --name --init --stop-timeout=10 --userns=keep-id --cap-drop=ALL --security-opt=no-new-privileges --security-opt=label=disable [+...] <image>` | `src-tauri/src/launch.rs:27` (`build_podman_args`), `client.rs:438` | **security-critical** |
| `podman exec <name> <cmd>` | `handlers.rs:693, 943, 2211` (health probes inside enclave containers) | startup-critical |
| `podman stop -t <secs> <name>` | `client.rs:249`, `crates/.../launch.rs:140` (graceful stop, 10 s grace) | shutdown-critical |
| `podman kill [--signal] <name>` | `client.rs:279`, `crates/.../launch.rs:154` | shutdown-critical |
| `podman rm -f <name>` | `client.rs:301`, `handlers.rs:1357,3270` | shutdown-critical |
| `podman ps -a --filter name=^<prefix> --format json` | `client.rs:215`, `events.rs:154`, `handlers.rs:1311` | event/state critical |
| `podman events --format json --filter type=container` | `crates/.../events.rs:84` (live state stream) | **event-loop critical** |
| `podman inspect <name> --format json` | `client.rs:177` | state-critical |
| `podman info --format json` | `events.rs:141` (machine readiness probe) | startup-critical |

### Networking

| Primitive | Used at | Criticality |
|---|---|---|
| `podman network exists <name>` | `client.rs:382` | enclave-critical |
| `podman network create <name> --internal` | `client.rs:393` | **security-critical** (egress firewall) |
| `podman network rm -f <name>` | `client.rs:420` | shutdown-critical |
| `--network=tillandsias-enclave:alias=<svc>` | `handlers.rs:266,611,876,2142` (per-service alias) | enclave-critical |
| `--network=podman` (dual-home for proxy) | `handlers.rs:636` | enclave-critical |
| `--add-host <alias>:host-gateway` | `launch.rs:309-311` (Windows/macOS workaround for gvproxy DNS) | **Windows-current** |
| `--publish 127.0.0.1:<P>:4096` (loopback-only) | `launch.rs:197` | spec-critical (web mode) |
| `--publish 3128:3128` etc. (port-mapping fallback on podman-machine) | `handlers.rs:629-632` | Windows/macOS fallback |

### Mounts

| Primitive | Used at | Criticality |
|---|---|---|
| `-v <host>:<container>[:ro|:rw][,Z]` | `launch.rs:325-332,361-377,395-396,444-449,460-462` | spec-critical |
| `--tmpfs=<path>:size=<N>m,mode=<oct>` | `launch.rs:124-141` (forge hot path budget) | spec-critical (RAM-only ephemerality) |
| `--read-only` | `launch.rs:91-93` | hardening |
| Control-socket bind mount (Unix-only today) | `launch.rs:441-455` | router-profile-critical (Linux/macOS only) |
| Token-file bind mount (`-v <token>:/run/secrets/github_token:ro`) | `launch.rs:391-420` | secrets-critical |

### Security

| Primitive | Used at | Criticality |
|---|---|---|
| `--cap-drop=ALL` | `launch.rs:73`, `crates/.../launch.rs:38` | **non-negotiable** |
| `--security-opt=no-new-privileges` | `launch.rs:74` | **non-negotiable** |
| `--userns=keep-id` | `launch.rs:75` | **non-negotiable** |
| `--security-opt=label=disable` | `launch.rs:76` | non-negotiable (SELinux compatibility) |
| `--init` | `launch.rs:69` | reaping-critical |
| `--rm` | `launch.rs:67` | ephemerality-critical |
| `--stop-timeout=10` | `launch.rs:70` | shutdown-critical |
| `--pids-limit=<N>` | `launch.rs:83` | hardening |

### Resources

| Primitive | Used at | Criticality |
|---|---|---|
| `--memory=<N>m` | `launch.rs:147` | RAM-only-tmpfs-spec critical |
| `--memory-swap=<N>m` (= memory, swap-disable) | `launch.rs:148` | RAM-only-tmpfs-spec critical |
| `--device /dev/dri/...` (GPU) | `crates/.../gpu.rs` via `detect_gpu_devices()` | inference-critical |

### Lifecycle hooks / event subscription

| Primitive | Used at | Criticality |
|---|---|---|
| `podman events --format json` (live JSON stream) | `events.rs:84` | **tray state machine critical** |
| Backoff fallback `podman ps`+`podman info` | `events.rs:140-220` | already implemented for podman-machine outages |

### Misc shell-outs to the podman ecosystem

| Primitive | Used at | Criticality |
|---|---|---|
| `buildah rm --all` (post-build cleanup, Windows path) | `handlers.rs:2992` | housekeeping |
| `pkill -TERM -f conmon.*--name tillandsias-` (Linux straggler reaper) | `handlers.rs:4546` | shutdown-critical (Linux only) |

This is the **requirements list** the WSL-only design must satisfy. No primitive on this list is optional — the security hardening flags are spec-mandatory non-negotiables (`spec:podman-orchestration` Requirement: Security-hardened container defaults), the event stream drives the tray's state machine, the internal network is the egress firewall.

## Capability mapping: podman primitive → WSL alternative

For each primitive above, what's reachable inside WSL2 today.

| Podman primitive | WSL2 native CLI equivalent | Linux-kernel-feature equivalent reachable from inside a WSL distro | Effort | Citation |
|---|---|---|---|---|
| `podman run --cap-drop=ALL` | none | `capset(2)` after `unshare --user --map-root-user` | low | learn.microsoft.com/about (User namespace per distro) |
| `--security-opt=no-new-privileges` | none | `prctl(PR_SET_NO_NEW_PRIVS,1)` | low | kernel docs |
| `--userns=keep-id` | none | `unshare --user` with subuid/subgid map | low | learn.microsoft.com/about |
| `--security-opt=label=disable` | n/a | n/a — SELinux not enforced under WSL | trivial | blog.richy.net/2025-06-16 (AppArmor reported broken; SELinux not present) |
| `--init` | none | tini, dumb-init, `--init` flag in nspawn | low | systemd-nspawn(1) |
| `--rm` (ephemerality) | none — `wsl --import` is long-lived; `wsl --unregister` is destructive | overlayfs+tmpfs over a base rootfs, or chroot from VHDX-as-image | medium | learn.microsoft.com/use-custom-distro |
| `--stop-timeout=10` (graceful SIGTERM-then-SIGKILL) | `wsl --terminate` is immediate-kill | systemd `TimeoutStopSec=`, or our own SIGTERM-then-wait-then-SIGKILL | low | learn.microsoft.com/basic-commands |
| `--pids-limit` | none | `pids` cgroup-v2 controller | low after cgroup-v2 enable | cgroups(7) |
| `--memory` / `--memory-swap` | `[wsl2] memory=` is **VM-wide, not per-container** | `memory` cgroup-v2 controller | medium (requires cgroup-v2 kernelcmdline) | cgroups(7), wslconfig docs |
| `--read-only` | none | `mount -o remount,ro /` | low | kernel mount(8) |
| `--tmpfs=<path>:size=<N>m,mode=<oct>` | none | `mount -t tmpfs -o size=<N>,mode=<oct> tmpfs <path>` | low | kernel tmpfs |
| `-v <host>:<container>[:ro]` | none on `wsl` cmdline | bind mount via `mount --bind`; for cross-distro mounts use 9P / `\\wsl$\` | medium | learn.microsoft.com/wsl-config |
| Control-socket bind mount (host AF_UNIX) | none — Windows AF_UNIX exists but not bridged into WSL | inside one distro: full Linux AF_UNIX semantics; cross-host: `socat` + AF_VSOCK or hvsocket | medium | (no MS doc for hvsocket from WSL2 user space — needs prototype) |
| `--network=enclave --internal` | none | `ip netns add` + veth pair + bridge + `iptables -A FORWARD -j DROP` | medium-high | network_namespaces(7) |
| `--add-host alias:host-gateway` | none | edit `/etc/hosts` or DNS injection inside the distro | low | (used today; works) |
| `--publish 127.0.0.1:<P>:4096` (loopback-bound port forward to host) | NAT mode auto-forwards via `localhostForwarding=true`; mirrored mode via `127.0.0.1` | `iptables -t nat -A PREROUTING -d 127.0.0.1 -p tcp --dport <P> -j DNAT --to <enclave-IP>:4096` | low | learn.microsoft.com/networking, /wsl-config |
| `podman build` | none | `buildah` / `nix` / `docker` / `umoci` inside the distro | low | (already happens inside Linux toolbox) |
| `podman load -i <tarball>` | `wsl --import <name> <path> <tarball>` (semantically: rootfs from tar) | `tar xf <tarball>` into a directory used as overlay lower | full | learn.microsoft.com/use-custom-distro |
| `podman pull` | none | `skopeo copy docker://... oci-archive:` then unpack | low | (skopeo on enclave host) |
| `podman ps -a --format json` | `wsl --list --verbose` is text | `pgrep` / `cat /sys/fs/cgroup/...` for live containers | medium | (no JSON option in wsl.exe) |
| `podman events --format json` | **none — no event stream API** | inotify on `/sys/fs/cgroup/<container>/cgroup.events` (`populated` flips on emptiness) | high — must implement | (no MS doc for `wsl events`; inotify on cgroups.events is the kernel pattern) |
| `podman inspect --format json` | none | introspect from inside (read `/proc/<pid>/...` ; cat `/etc/...`) | medium | — |
| `podman network create --internal` | **none** | full Linux netns + veth + iptables script (≈100-200 LoC of bash) | high | network_namespaces(7) |
| `podman network rm` | none | `ip link del veth*; ip netns del <ns>` | low | iproute2 |
| `--device /dev/dri/...` (GPU passthrough) | `[gpu] enabled=true` in `wsl.conf` (default `true`) | DRI render node bind mount inside the namespace | low | learn.microsoft.com/wsl-config |
| `pkill conmon` straggler reaper | n/a (different runtime) | n/a (Linux-only today; not needed under different runtime) | n/a | — |
| AppArmor / SELinux confinement | none | **broken under WSL2** | dealbreaker for that capability — but we don't depend on it | blog.richy.net/2025-06-16 |

**Bottom line of the mapping**: every podman *security* primitive maps to an in-distro Linux primitive. Every podman *lifecycle* primitive (events, inspect, ps in JSON, ephemeral run, graceful stop, network create) is **missing at the `wsl.exe` boundary** and would have to be reinvented if we drop podman.

## Architecture options

### Option 1 — Status quo: `podman.exe` on Windows host driving `podman machine`

Today's design.

- **Pros**: works; spec-complete on Linux/macOS; Windows reuses 95% of the Linux code.
- **Cons**:
  - The `podman machine` is itself a WSL distro called `podman-machine-default`. We cross *two* process boundaries on every container op: Windows host → podman.exe → gvproxy/HVSOCK → WSL podman service → conmon → container. Each boundary is a place state can desync.
  - Control-socket (`mount_control_socket`) is gated to `cfg(unix)` because Windows AF_UNIX doesn't translate into a WSL bind mount through gvproxy. Windows can't run the router profile (`openspec/changes/windows-native-build/proposal.md` confirms this is documented behavior, not a regression).
  - Enclave DNS doesn't work through gvproxy → we ship `--add-host alias:host-gateway` as a workaround (`launch.rs:307-312`).
  - `podman.exe` install is an external dependency (`winget install RedHat.Podman`) and Tillandsias install code (`scripts/install.ps1`) has to manage both the Windows binary and the machine VM.

### Option 2 — Podman-in-WSL: drop `podman.exe` on Windows, run podman inside a Tillandsias-owned WSL distro

Tillandsias ships a minimal WSL distro tarball (Fedora-based, identical to today's `tillandsias-builder` toolbox). On install:

```powershell
wsl --install --no-distribution            # Microsoft Store WSL with no default distro
wsl --import tillandsias <path> <tarball>  # ship our own, don't rely on podman-machine-default
```

Tillandsias's podman client wrapper changes from `Command::new("podman")` to `Command::new("wsl").args(["--distribution", "tillandsias", "--exec", "podman", ...])`. The podman service runs as a systemd unit inside our distro (`[boot] systemd=true` per `wsl.conf`).

- **Pros**:
  - **One process boundary collapses**. Windows host calls `wsl --exec podman ...`, podman runs in the same kernel as the containers it spawns. No gvproxy NAT layer.
  - **Control socket works**. The tray writes its socket file inside the WSL distro filesystem (e.g., `/run/tillandsias/control.sock`) — accessible to the host as `\\wsl$\tillandsias\run\tillandsias\control.sock` *and* native to the forge containers. The `cfg(unix)` gate on `mount_control_socket` can be removed for Windows.
  - **Enclave DNS works natively**. We're inside one distro, so `--network=tillandsias-enclave --network-alias=proxy` resolves through podman's own DNS plugin. The `--add-host alias:host-gateway` workaround can be retired on Windows.
  - **Install simplifies**. Tillandsias ships a single WSL tarball as part of its installer; no `winget install RedHat.Podman` dependency. The user gets a versioned distro just like the current `tillandsias-builder` toolbox on Linux.
  - **Macros preserve**. `build_podman_args()` is unchanged. The only diff is in the `podman_cmd()` factory — it produces `wsl.exe --distribution tillandsias --exec podman ...` on Windows and `podman` directly on Linux/macOS.
  - **All security primitives preserved**. We're calling the same podman binary that runs on Linux today. `--cap-drop=ALL`, `--userns=keep-id`, `--security-opt=no-new-privileges`, `--security-opt=label=disable` (no-op under WSL but harmless), `--init`, `--rm`, `--pids-limit`, `--memory`, `--memory-swap`, `--tmpfs`, `--read-only` — all flow through unchanged. cgroup-v2 must be enabled in `.wslconfig` (see `wslconfig-tunables.md`).
  - **Event stream preserved**. `podman events --format json` runs inside the distro just like it does on Linux; we read it back through `wsl --exec`.
- **Cons**:
  - Adds ~200 MB to the installer (the WSL distro tarball — same as today's podman-machine-default but ours).
  - We have to maintain a Tillandsias WSL distro image (we already build forge / proxy / git / inference; this is one more, conceptually like our `tillandsias-builder` toolbox).
  - The `wsl --exec` indirection adds ~20 ms of latency per podman call (cold-start of the wsl.exe relay process — measurable in CI but invisible in tray operations).
  - Volume mounts of host paths (`C:\Users\...`) work via `/mnt/c/Users/...` and DrvFs; this is the same as today's podman-machine. No worse, no better.
- **What changes in the codebase**:
  - `crates/tillandsias-podman/src/lib.rs::find_podman_path()` and `podman_cmd()` — emit `wsl.exe --distribution tillandsias --exec podman` instead of `podman.exe` on Windows.
  - `crates/tillandsias-podman/src/client.rs::has_machine()` / `init_machine()` / `start_machine()` — replace with `ensure_distro()` that imports the bundled tarball if absent.
  - `src-tauri/src/control_socket/mod.rs` — drop the Windows stub, implement the AF_UNIX server inside the distro (the tray writes the socket via `\\wsl$\tillandsias\...`, or — cleaner — runs a tiny relay inside the distro). The control-socket path resolver returns a WSL-namespace path on Windows.
  - `src-tauri/src/launch.rs` — remove the `cfg(unix)` gate on the `mount_control_socket` block.
  - `scripts/install.ps1` — replace the podman winget install with `wsl --install --no-distribution; wsl --import tillandsias ...`.
- **Effect on macOS path**: none. macOS keeps using podman-machine on a QEMU-based VM; this option only changes Windows.
- **Effect on Linux path**: none.

### Option 3 — Hybrid: managed WSL distro + control-plane via vsock or Named Pipes

Like Option 2, but adds a Tillandsias-owned control plane that does not rely on `wsl --exec`. The tray exposes a Named Pipe on Windows and a tiny Rust daemon inside the distro listens on a vsock or hvsocket and bridges the two. The daemon also exposes the podman REST API (which podman ships and supports — `podman system service --time=0`) over the same channel.

- **Pros**:
  - No `wsl --exec` per call: a persistent socket connection, much lower latency for high-frequency ops (events stream, inspect-on-state-change).
  - Cleaner Rust-only IPC; no shell escaping.
  - Symmetrical: the same daemon can bridge the control-socket Named Pipe ↔ AF_UNIX as a side effect.
- **Cons**:
  - Ships a new persistent daemon. More moving parts.
  - hvsocket from a WSL2 user-space distro is *not officially documented* by Microsoft for end-user code (kernel supports it; libraries are sparse). Needs prototype validation.
  - Reinventing the podman API client. Tillandsias today uses `Command` + JSON parsing of CLI output; switching to the REST API is a refactor, not a one-liner.
- **What changes**: the `podman_cmd()` factory becomes a connection pool; `podman events` becomes a websocket-style stream; control-socket becomes a multiplex over the same channel.
- **Effect on macOS / Linux**: macOS would continue using CLI; Linux would too. Or we could unify on the REST API everywhere, which is a much larger refactor.

### Option 4 — WSL-native: drop podman entirely, four distros = four enclave services

The user's hypothesis: each enclave service (proxy, git, forge, inference) is its own WSL distro. Tillandsias drives `wsl --import` / `wsl --terminate` / `wsl --unregister`.

- **Pros**:
  - **Simplest mental model on paper.** No podman dependency. Tillandsias's Windows-side code becomes a `wsl.exe` driver.
  - Native Windows AF_UNIX socket support (Windows 10 1803+) means the control socket might just work between the tray and `\\wsl$\<distro>\...`.
- **Cons that are dealbreakers**:
  - **WSL2 distros share one network namespace.** Verbatim from Microsoft Learn `about` (fetched 2026-04-26): *"Linux distributions running via WSL 2 will share the same network namespace, device tree (other than `/dev/pts`), CPU/Kernel/Memory/Swap, `/init` binary, but have their own PID namespace, Mount namespace, User namespace, Cgroup namespace, and `init` process."* The whole *point* of the enclave network is that forge containers cannot reach the internet directly — only proxy can. If proxy and forge are sibling distros, forge can bind to `0.0.0.0:80` and reach the internet through whatever NIC the VM has. To get isolation we'd have to recreate the enclave with `ip netns` *inside one distro* — exactly what podman already does.
  - **`wsl.exe` does not expose an event stream.** Microsoft Learn `basic-commands` documents no `wsl events` verb. The tray's state machine (`crates/tillandsias-podman/src/events.rs`) reads `podman events --format json` continuously to drive UI state. Without it, we fall back to the exponential-backoff `podman ps` polling loop the events module has as a fallback — reasonable for outages, not for the hot path.
  - **`wsl.exe` does not expose `inspect` in JSON.** Fetched `basic-commands` shows `wsl --list --verbose` only emits text in UTF-16 LE. Anything Tillandsias does with `serde_json::from_str(stdout)` today against `podman ps` / `podman inspect` would have to be replaced with parsing of human-readable text.
  - **`wsl --terminate` is SIGKILL-equivalent.** Tillandsias's spec'd shutdown is SIGTERM with 10 s grace, then SIGKILL (`crates/tillandsias-podman/src/launch.rs:140-157`). The wsl.exe CLI offers one immediate kill. We'd need a side-channel "please shut down" signal into each distro.
  - **`wsl --import` is long-lived; there is no `--rm`.** Each enclave service "container" would persist its filesystem in a VHDX. Forge's spec is *ephemeral root, RAM-only, lost on stop* (`spec:forge-offline`, `spec:forge-hot-cold-split`). To preserve that, every forge launch would have to `wsl --import` from a clean tarball *and* `wsl --unregister` on stop — a heavy operation, with no kernel-enforced ephemerality. Compare with `--rm --tmpfs=/home/forge/src` today, which is enforced by the kernel and free.
  - **No event-driven log capture.** `podman logs` is missing; we'd have to journalctl-via-`wsl --exec` and stream ourselves.
  - **Bind mounts are not first-class.** `wsl.exe` has no equivalent of `-v`. Per-launch mounts must be configured by an in-distro startup hook (read a launch config file, then `mount --bind`). Doable but adds moving parts.
  - **Effort to recreate `--cap-drop=ALL`, `--userns=keep-id`, `--no-new-privileges`** — must wrap every entrypoint in `unshare --user --map-root-user` + `prctl` + `capsh --drop=all`. Doable but every container's entrypoint becomes a 30-line bash prelude. We'd be inventing podman-lite in shell.
  - **AppArmor/SELinux unavailable** — same as Option 2. Not a regression.
- **Net**: the user's hypothesis is wrong on the central question (network isolation), and the work to recreate even half of podman's primitives at the WSL CLI layer is a substantial multi-week project for *no functional gain* over Option 2.

## Security analysis

Walking the spec'd security flags through each option.

| Flag / property | Option 1 (today) | Option 2 (podman-in-WSL) | Option 3 (hybrid) | Option 4 (WSL-native) |
|---|---|---|---|---|
| `--cap-drop=ALL` | enforced by podman | enforced by podman | enforced by podman | must wrap entrypoint with `capsh --drop=all` (we own this) |
| `--security-opt=no-new-privileges` | enforced by podman | enforced by podman | enforced by podman | must wrap with `prctl(PR_SET_NO_NEW_PRIVS)` |
| `--userns=keep-id` | enforced by podman | enforced by podman | enforced by podman | must `unshare --user --map-root-user` |
| `--init` (PID-1 reaper) | tini | tini | tini | tini binary in entrypoint |
| `--rm` (ephemeral) | enforced | enforced | enforced | not native to wsl; must `wsl --unregister` after each session |
| `--read-only` | enforced | enforced | enforced | `mount -o remount,ro` in entrypoint |
| `--tmpfs=<path>:size=...,mode=...` | kernel-enforced size cap | kernel-enforced (cgroup-v2 via wslconfig) | kernel-enforced | kernel-enforced |
| `--memory` / `--memory-swap` | enforced by memory cgroup | enforced (after cgroup-v2 enable) | enforced | enforced (must set cgroup ourselves) |
| `--pids-limit` | enforced by pids cgroup | enforced (after cgroup-v2 enable) | enforced | enforced |
| Enclave network egress firewall | `podman network create --internal` | same | same | **must build by hand** with netns + iptables |
| AppArmor confinement | enforced (Fedora host) | absent | absent | absent |
| SELinux confinement | available (Fedora host) | absent | absent | absent |

**Honest reading**: Options 2 and 3 *preserve every spec-mandatory security flag*. Option 4 makes us reinvent every one of them in shell, with no kernel-enforced backstop if the wrapper script breaks. AppArmor/SELinux are absent under all WSL2 options — but they're a defense-in-depth bonus on Fedora, not a spec mandate.

## Parity gaps that this would close

The user's framing: "Today on Windows we lose ...". Mapping each loss to whether each option fixes it.

| Gap on Windows today | Option 1 (status quo) | Option 2 (podman-in-WSL) | Option 3 (hybrid) | Option 4 (WSL-native) |
|---|---|---|---|---|
| Control socket gated to `cfg(unix)` (`launch.rs:441`) | no | **yes** — control socket lives inside the distro | yes — vsock bridge | yes — Windows AF_UNIX directly into `\\wsl$\...` |
| Router profile (depends on control socket) cannot launch | no | **yes** | yes | yes |
| Enclave isolation degraded — gvproxy NAT between podman-machine and forge | no — workaround `--add-host alias:host-gateway` | **yes** — single distro, podman manages netns | yes | partially — must DIY netns isolation |
| Credential bridge to host keyring (D-Bus is Linux-only) | the `secrets-management` change already routes around D-Bus by writing the token to `ctx.token_file_path` and bind-mounting it `:ro` (`launch.rs:391-419`). Windows uses the Credential Manager via Rust's `keyring` crate. | unchanged | unchanged | unchanged |
| Event stream reliability | reasonable (events from podman-machine) | **better** (one less process boundary) | best (persistent socket) | broken (no equivalent) |
| `mount_control_socket` works on Windows | no | **yes** | yes | yes |
| Tray ↔ forge state sync latency | medium (gvproxy in path) | low | lowest | medium |

## Risk assessment

**Option 2 risks (the recommended path):**

- **`wsl --exec` latency.** Each `wsl --exec` invocation spawns the wsl.exe relay process (~10-20 ms cold start on Windows 11). For high-frequency calls (`podman ps` once per state-machine tick), this is observable. Mitigation: keep a long-running shell open via `wsl --distribution X bash -c 'cat > /tmp/cmds; xargs ...'`-style helper, or move to Option 3's persistent socket if latency becomes a hot-path issue. Today's tray is fine; CI throughput might want a different pattern.
- **Bundled distro maintenance.** We have to keep a Tillandsias-WSL-distro tarball updated with the same care as our forge/proxy/git/inference images. This is one more container image, conceptually. The build pipeline already has `tillandsias-builder` toolbox; the new tarball is a sibling.
- **cgroup-v2 enablement requires `.wslconfig` edit.** First-launch UX: detect cgroup-v2 absent → write `kernelCommandLine=cgroup_no_v1=all systemd.unified_cgroup_hierarchy=1` to `~/.wslconfig` → prompt user for `wsl --shutdown`. Doable but invasive.
- **Multi-user Windows hosts.** WSL2 is per-Windows-user. If the user `bullo` runs Tillandsias under their session and their distro is named `tillandsias`, another Windows user can't share it. Same as today's podman-machine.
- **Mirror/NAT mode user choice.** If the user has set `networkingMode=mirrored` for unrelated reasons, our distro inherits it. Mirrored mode shouldn't break anything (we don't depend on NAT-specific semantics) but should be tested.

**Option 4 risks (the rejected path), in order of severity:**

1. **Enclave network isolation gone** — already explained.
2. **Event stream gone** — would force us to deepen the `events.rs` exponential-backoff fallback as the *primary* path, not a degraded mode. Tray UX becomes laggy.
3. **Spec violations latent** — `--cap-drop=ALL` gets re-implemented in shell, easy to forget on a new entrypoint, no compile-time check.
4. **Cargo cult risk** — once we do this, we're divergent from the Linux/macOS code by far more than we are today. Two codebases to maintain.

**Cross-platform parity drift (all options):**

- Option 1: today, Linux is the reference; macOS and Windows have deltas. Drift is bounded.
- Option 2: same — Windows joins macOS in the "podman-in-VM" pattern, which macOS already does. Linux stays with native podman. Drift increases marginally (the `wsl --exec` indirection is in `podman_cmd()` only).
- Option 3: similar to Option 2, plus a new Rust daemon to maintain.
- Option 4: drift explodes — Windows code path bears no resemblance to Linux or macOS.

## Cost / effort estimate

I am guessing on these — calibrate against your team's velocity. Mark "(guess)" where uncertain.

| Option | Engineer-weeks | Confidence |
|---|---|---|
| **Option 1**: nothing changes | 0 | high |
| **Option 2**: podman-in-WSL — `podman_cmd()` indirection, distro tarball build, control-socket path resolver, installer change, cgroup-v2 wslconfig writer, tests | **3-5 weeks** (guess) | medium |
| **Option 3**: Option 2 + persistent vsock daemon + REST API client | **6-9 weeks** (guess) | medium-low (vsock from WSL2 user space is not well-documented; possible weeks lost to libc-level prototyping) |
| **Option 4**: WSL-native — recreate netns enclave, event stream, lifecycle hooks, security wrappers, ephemeral rootfs | **10-16 weeks** (guess), and the deliverable is *less* secure and *less* feature-complete than today | low (lots of unknowns, several genuinely hard sub-problems) |

## Recommendation

**Adopt Option 2: Podman-in-WSL.** The user's intuition is right that the current Windows architecture (`podman.exe` → gvproxy → podman-machine) has friction. The fix is to *collapse one boundary*, not *remove podman*. Specifically:

1. We cannot drop podman because the four enclave services depend on `network create --internal`, the tray state machine depends on `podman events --format json`, the security spec depends on six podman flags and one event subscription primitive, and the forge ephemerality spec depends on `--rm` + `--tmpfs`. None of these have a `wsl.exe` equivalent.
2. We *can* drop `podman.exe-on-Windows`. Instead of installing podman on the Windows host (winget) and managing podman-machine via the host CLI, ship a Tillandsias-owned WSL distro that runs podman as a systemd service, and drive it from the host with `wsl --exec podman ...`. This is what podman-machine does today — except the distro is ours, the version is pinned, and we delete one process boundary (the `podman.exe ↔ gvproxy ↔ machine-podman` hop).
3. The single largest win is: **the control socket works on Windows**. The tray writes its socket inside the WSL distro filesystem; both the tray (via `\\wsl$\tillandsias\...`) and forge containers (via `mount_control_socket=true` bind mount) see the same AF_UNIX node. The `cfg(unix)` gate in `launch.rs` and `control_socket/mod.rs` collapses to a `cfg(any(unix, target_os = "windows"))` once the WSL path resolver is in place. Router profile launches on Windows for the first time.
4. The second-largest win is: **`--add-host alias:host-gateway` retires on Windows**. Containers in the enclave use `proxy:3128`, `git-service:9418`, `inference:11434` directly through podman's enclave-network DNS. Linux and Windows behave identically.

The user's *underlying* belief — "WSL alone is sufficient" — is correct in the narrow sense that we don't need a podman-machine VM separate from a Tillandsias-managed WSL distro. It is incorrect in the broader sense that we don't need podman: we do, because podman is the only thing that gives us internal-network egress firewalling, event streams, ephemeral rootfs, and battle-tested security flag enforcement in one binary. Re-implementing those primitives on top of `wsl.exe` is months of work that produces a less-secure, less-debuggable result.

## Migration path

Phased, each phase independently shippable behind a feature flag (`TILLANDSIAS_RUNTIME=podman-machine|podman-in-wsl`).

**Phase 1 — distro tarball build pipeline (1 week)**
- New `images/wsl-host/` directory with `Containerfile` (Fedora minimal + podman + systemd-sysv + tillandsias entrypoint).
- New `scripts/build-wsl-distro.sh` produces a tarball with `podman build → podman save → tar conversion`.
- Output: `tillandsias-host-v<version>.tar` ~250 MB.
- Risk: low. We already build `tillandsias-builder` with similar tooling.

**Phase 2 — `podman_cmd()` indirection on Windows (1 week)**
- Modify `crates/tillandsias-podman/src/lib.rs::podman_cmd()` to emit `wsl.exe --distribution tillandsias-host --exec podman ...` on Windows when the `podman-in-wsl` runtime is selected.
- Add `ensure_distro()` to import the bundled tarball if absent (replacing `init_machine`).
- Behind feature flag — `podman-machine` path stays as the default until Phase 4.
- Tests: every existing podman test that uses `podman_cmd()` should pass through unchanged on Linux/macOS; Windows gets a new test that asserts the args contain `wsl.exe --distribution tillandsias-host --exec podman`.

**Phase 3 — control socket over `\\wsl$\` (2 weeks)**
- Tray writes the socket inside the WSL distro at `/run/tillandsias/control.sock` (via `wsl --exec` + a tiny socket-server binary baked into the distro tarball, OR by relying on Windows-side `\\wsl$\tillandsias-host\run\tillandsias\control.sock` AF_UNIX accessibility, *which needs prototype confirmation*).
- Drop the `cfg(unix)` gate in `src-tauri/src/control_socket/mod.rs` and `src-tauri/src/launch.rs::compute_run_args`.
- Verify `mount_control_socket=true` profiles launch on Windows.

**Phase 4 — installer cutover and default flip (1 week)**
- `scripts/install.ps1`: replace `winget install RedHat.Podman; podman machine init` with `wsl --install --no-distribution; wsl --import tillandsias-host ...`.
- Default `TILLANDSIAS_RUNTIME=podman-in-wsl` on Windows.
- Documentation: rewrite `docs/cross-platform-builds.md` Windows section.

**Phase 5 — cgroup-v2 enablement helper (0.5 week)**
- On first launch, detect `[wsl2] kernelCommandLine` absent or missing `cgroup_no_v1=all systemd.unified_cgroup_hierarchy=1`; offer to write it; prompt user to `wsl --shutdown`.

**Phase 6 — retirement of `--add-host alias:host-gateway` on Windows (0.5 week)**
- Remove the `if ctx.use_port_mapping` branch in `launch.rs:307-312` for the `podman-in-wsl` runtime.
- The enclave network DNS resolution works natively now.

Total: **~6 calendar weeks** with one engineer, slack included, assuming Phase 3 prototyping doesn't surface a hvsocket-style surprise.

## Open questions

These need prototype validation before committing.

1. **Does Windows-side `\\wsl$\tillandsias-host\path\to\sock` work as an AF_UNIX endpoint connectable from a Win32 process?** Microsoft documents 9P file access via the `\\wsl$\` UNC path. Whether AF_UNIX socket files are usable through 9P (Plan 9 protocol) by `connect(2)` is *not documented*; needs prototype. If not, fallback is a small relay process inside the distro.
2. **What is the actual cold-start latency of `wsl --exec podman events`?** Estimate: 20-40 ms, but the events stream is long-lived so this matters once. Measure on a representative Windows 11 host.
3. **Does cgroup-v2 + systemd-as-PID-1 + podman-rootless inside our distro produce the same memory enforcement we get on Linux?** Test: `podman run --memory=64m alpine sh -c 'a=$(printf "x%.0s" {1..100000000}); echo $a'` should OOM-kill in WSL2 just as on bare-metal Linux. If not, our `--memory` is a no-op and the spec's RAM-only-tmpfs guarantee is broken.
4. **Does `[gpu] enabled=true` in `wsl.conf` plus `--device /dev/dri/...` from podman-in-WSL pass through Intel/AMD/NVIDIA GPUs to the inference container?** The Microsoft DxCore + WSLg path is documented for graphics; for ROCm/CUDA there is `nvidia-docker`-style integration, but compose-from-scratch needs prototype.
5. **What is the install footprint?** Tarball ~250 MB; uncompressed VHDX ~600 MB; plus the `wsl --install` core ~150 MB. Compare to today's Podman (~120 MB) + machine VM (~1.2 GB). Probably equivalent or better.
6. **Can we share one Tillandsias-WSL distro across multiple Windows users on a multi-seat install?** Probably not — WSL is per-user. Same as today.

## Sources of Truth

Verbatim provenance for every claim in this report lives in the cheatsheets:

- `docs/cheatsheets/runtime/wsl/architecture-isolation.md` — what WSL2 shares vs. isolates between distros.
- `docs/cheatsheets/runtime/wsl/networking-modes.md` — NAT vs. mirrored, DNS tunneling, Hyper-V firewall.
- `docs/cheatsheets/runtime/wsl/wslconfig-tunables.md` — every key in `.wslconfig` and `wsl.conf`, with defaults.
- `docs/cheatsheets/runtime/wsl/systemd-and-cgroups.md` — kernel primitives reachable inside one distro.
- `docs/cheatsheets/runtime/wsl/cli-surface.md` — the `wsl.exe` verb inventory, mapped against podman primitives.

Microsoft Learn pages (all fetched 2026-04-26):

- <https://learn.microsoft.com/en-us/windows/wsl/about>
- <https://learn.microsoft.com/en-us/windows/wsl/networking>
- <https://learn.microsoft.com/en-us/windows/wsl/wsl-config>
- <https://learn.microsoft.com/en-us/windows/wsl/systemd>
- <https://learn.microsoft.com/en-us/windows/wsl/basic-commands>
- <https://learn.microsoft.com/en-us/windows/wsl/use-custom-distro>

Linux man pages and kernel references (fetched 2026-04-26):

- <https://man7.org/linux/man-pages/man7/network_namespaces.7.html>
- <https://man7.org/linux/man-pages/man7/cgroups.7.html>
- <https://www.man7.org/linux/man-pages/man1/systemd-nspawn.1.html>

Podman documentation (fetched 2026-04-26):

- <https://podman.io/docs/installation>
- <https://docs.podman.io/en/stable/markdown/podman-machine.1.html>
- <https://github.com/containers/podman/discussions/22961> (cgroup-v2 in WSL2)
- <https://blog.richy.net/2025/06/16/wsl2.html> (third-party recipe — verify on first prototype)

Tillandsias source citations (commit `924ce3d`, branch `main`):

- `src-tauri/src/launch.rs:27` — `build_podman_args()`.
- `src-tauri/src/handlers.rs:266,611,876,2142` — enclave network alias usage.
- `src-tauri/src/control_socket/mod.rs` — `cfg(unix)` gate.
- `crates/tillandsias-podman/src/lib.rs:24-107` — `find_podman_path()`, `podman_cmd()`.
- `crates/tillandsias-podman/src/client.rs` — full podman CLI surface.
- `crates/tillandsias-podman/src/events.rs:84,140` — event stream + backoff fallback.
- `crates/tillandsias-podman/src/launch.rs:30-92` — security flag application.
- `openspec/changes/windows-native-build/proposal.md` — current Windows delta and the `mount_control_socket` Named Pipes follow-up note.
