## Why

Today's Windows runtime layers a Tillandsias-managed `podman.exe` (host)
on top of a `podman machine` (a WSL VM running podman) on top of `gvproxy`
(NAT). Three process boundaries to reach a forge container. The recent
windows-native-build smoke test exposed the cost: the control socket is
gated to `cfg(unix)` (Unix domain sockets don't traverse `gvproxy`
cleanly), the router profile cannot launch on Windows, the
`--add-host alias:host-gateway` workaround is needed because the
podman-machine DNS bridge isn't reachable from forge containers, and
each `wsl --exec podman` round-trip carries the wsl.exe relay overhead.

The user's directive (verbatim):

> Our move to WSL should replace PODMAN entirely. Our forge, inference,
> proxy, git mirror, everything, are now WSL images.

This change rebuilds the Windows runtime around `wsl.exe` only —
no podman on the Windows host, no podman-machine, no podman in any
distro. Each enclave service becomes a WSL distro. The container image
build path stays in podman (on Linux/macOS hosts and in CI), but on
Windows we extract the resulting OCI rootfs to a tarball and `wsl --import`
it. `podman run` becomes `wsl --distribution <name> --user <uid> --exec ...`.

This is bold and the prototype confirmed it is feasible — with
explicit, documented compromises around network namespace sharing.

## Prototype findings (validated 2026-04-26 → 2026-04-27 on this windows-next host)

1. **Image conversion is mechanical**:
   `podman create --name tmp <image> /bin/true; podman export tmp -o rootfs.tar`
   produces a tarball that `wsl --import <name> <vhdx_dir> rootfs.tar
   --version 2` accepts. Forge image (6.3 GB) imported cleanly; running
   `wsl -d <name> -- bash -c 'cat /etc/os-release'` returned
   `NAME="Fedora Linux"` and the entire `/opt/agents/`,
   `/opt/cheatsheets-image/`, `/usr/local/sbin/{claude,opencode,openspec}`
   tree intact.
2. **`wsl --user forge --cd /mnt/c/Users/.../project --exec`**
   replaces `podman run --user 1000:1000 -w /home/forge/src ...` exactly:
   the process runs as uid 1000 with the chosen working directory.
3. **Windows paths are accessible at `/mnt/c/...`** without any
   bind-mount setup. Replaces every `-v <hostpath>:<container>` mount.
4. **`unshare`, `capsh`, `prctl`, cgroup-v2 mounts, tmpfs, all
   namespaces** are available inside any imported distro — these are
   kernel features, not container-runtime features.
5. **All distros share ONE Linux network namespace.** Verified directly
   on this machine: forge distro and proxy distro reported identical
   `eth0` (IP `172.25.55.216/20`, MAC `00:15:5d:9b:52:49`). This is
   the dealbreaker for "one distro = one isolated network" — and the
   *unblocker* for "all enclave services see each other on
   `127.0.0.1:port`".
6. **Inter-distro loopback works**:
   forge distro `python3 -m http.server 14000` was reachable from the
   proxy distro via `wget http://127.0.0.1:14000/` in the same WSL VM.
   This is the path for proxy/git/inference connectivity from the
   forge.
7. **Hyper-V firewall (`firewall=true` in `.wslconfig`) is inbound only**
   — controls LAN access to WSL services. Does not provide per-distro
   outbound policy. forge-offline isolation must be enforced inside the
   shared namespace using uid-based iptables `-m owner --uid-owner` or
   per-process `unshare --net`.
8. **Resource budget is per-VM, not per-distro**. `.wslconfig`
   `[wsl2] memory=8GB processors=4` applies to the single Hyper-V VM
   that hosts every distro for the logged-in Windows user. Per-service
   `--memory=64m` becomes per-cgroup `memory.max=64M` inside the shared
   VM (cgroup-v2, `nsdelegate`).
9. **`wsl.exe` does NOT provide**: an event stream, container `inspect
   --format json`, `--rm` semantics, `network create --internal`,
   SIGTERM-grace-then-SIGKILL, per-launch bind mounts (Windows mounts
   come from `/mnt/<drive>` namespace; explicit per-launch bind mounts
   need to happen inside the distro).

## What Changes

### New: a runtime abstraction in tillandsias-podman (renamed)

- **NEW** `crates/tillandsias-runtime/` (replaces `tillandsias-podman`
  semantically; the crate alias stays for one release for backwards
  compatibility, then renames).
- **NEW** `Runtime` trait with the operations the rest of the codebase
  needs: `image_exists`, `image_build`, `image_export_to_tar`,
  `service_create`, `service_start`, `service_stop`,
  `service_running`, `service_exec`, `service_remove`, `events_stream`.
- **NEW** `PodmanRuntime` struct implementing `Runtime` against the
  `podman` CLI (today's behaviour, used on Linux + macOS).
- **NEW** `WslRuntime` struct implementing `Runtime` against `wsl.exe`
  (used on Windows only).
- **MODIFIED** `crates/tillandsias-podman/src/lib.rs` (until the rename
  ships) — re-exports `Runtime`, `default_runtime()`, and platform
  glue. `default_runtime()` returns `PodmanRuntime` on Linux/macOS,
  `WslRuntime` on Windows.

### New: WSL-native image build pipeline (Microsoft's documented procedure)

The conceptual mapping is the cornerstone:

> **A podman image on Linux is a WSL distro on Windows.** Same
> upstream container image (Fedora-container, Alpine, etc.) on both
> sides; different runtime-tool unwrap on each.

We follow Microsoft Learn / *Import any Linux distribution to use with
WSL* (<https://learn.microsoft.com/en-us/windows/wsl/use-custom-distro>,
fetched 2026-04-26, ms.date 2021-09-27, updated 2025-08-06):

> "First you'll need to obtain a tar file that contains all the Linux
> binaries for the distribution. You can obtain a tar file in a variety
> of ways, two of which include: Download a provided tar file. ...
> Find a Linux distribution container and export an instance as a tar
> file."
>
> "Once you have a tar file ready, you can import it using the command:
> `wsl.exe --import <Distro> <InstallLocation> <FileName> [Options]`"

Per-service base, mirroring today's Containerfile `FROM` lines:

| Service       | Upstream base                       | Source                                                      |
|---------------|-------------------------------------|-------------------------------------------------------------|
| forge         | `fedora-minimal:43` container image | `registry.fedoraproject.org/fedora-minimal:43` via skopeo  |
| proxy         | Alpine minirootfs                   | `dl-cdn.alpinelinux.org/.../alpine-minirootfs-x.y.z-x86_64.tar.gz` (direct download) |
| git           | Alpine minirootfs                   | direct download                                             |
| inference     | `fedora-minimal:43` + ollama        | skopeo + ollama install (matches Linux/macOS Containerfile)|
| router        | Alpine minirootfs + caddy           | direct download + `apk add caddy`                           |
| enclave-init  | Alpine minirootfs + iptables        | direct download + `apk add iptables`                        |

**No podman, no docker, no buildah on the Windows host.** Tarball
acquisition uses:

- **direct download** for Alpine (Alpine ships signed minirootfs
  tarballs as a first-class artifact — Microsoft's doc explicitly
  cites this as the recommended source).
- **skopeo** (a single CLI binary, no daemon, ~25 MB, available for
  Windows) for Fedora-container and any other container-registry-only
  source. `skopeo copy docker://registry.fedoraproject.org/fedora:43
  oci:/tmp/fedora-43:latest` extracts the OCI layer set, which
  `lib-common.sh` flattens into a single rootfs tarball.

Pipeline structure:

- **NEW** `scripts/wsl-build/` directory:
  - `lib-common.sh` — shared helpers: `wsl_import_temp`, `wsl_run_in`,
    `wsl_copy_into`, `wsl_export_and_unregister`. Wraps `wsl.exe`
    invocations.
  - `bases.sh` — fetches the upstream base tarballs:
    - Alpine via direct download from `dl-cdn.alpinelinux.org`
      (SHA-256 verified against Alpine's published checksums).
    - Fedora via `skopeo copy docker://...` then layer-flatten.
    - Cached under `~/.cache/tillandsias/wsl-bases/`.
  - `build-forge.sh` — imports the Fedora 43 base as a temp distro,
    runs each `RUN dnf install`, `COPY`, `USER 1000:1000` equivalent
    from `images/default/Containerfile` imperatively via
    `wsl --exec`, then `wsl --export`s the result. Output tarball
    is the WSL forge image.
  - `build-proxy.sh`, `build-git.sh`, `build-inference.sh`,
    `build-router.sh` — same shape, Alpine bases.
- **NEW** Windows `--init` flow calls each `build-<service>.sh` to
  produce the tarball, then `wsl --import`s it to
  `%LOCALAPPDATA%\Tillandsias\WSL\<service>`.
- **The Containerfile is preserved** as canonical documentation and
  the source of truth that the Linux/macOS path consumes via podman.
  The bash build script is a hand-translation; a CI parity verifier
  diffs the WSL-tarball contents against the podman-built tarball
  (under a Linux toolbox build) and fails when the two diverge.
- **Linux and macOS continue to use podman** for image builds — the
  canonical toolchain for OCI images. Only Windows takes the
  WSL-native build path.

### Why this beats `podman build → podman export`

- One tool on Windows: `wsl.exe`. No `winget install RedHat.Podman`,
  no podman-machine init, no gvproxy in the data path.
- One tarball format: WSL2-native. No OCI-layer flattening step.
- Build cache is the WSL distro itself: `wsl --export` between RUN
  steps preserves intermediate state for incremental rebuilds (the
  same way podman/buildkit caches layers, just expressed in the WSL
  primitives we already use at runtime).
- Provenance lives in the build script, traceable line-by-line to
  the Containerfile. Tampering with the rootfs has the same audit
  trail it does today.

### Tray binary: WslRuntime implementation

- **NEW** `crates/tillandsias-runtime/src/wsl.rs` — `wsl.exe` driver.
  Verbs:
  - `wsl --import <distro> <vhdx_dir> <tarball> --version 2`
  - `wsl --distribution <distro> --user <user> --cd <wd> --exec <cmd>`
  - `wsl --terminate <distro>`
  - `wsl --unregister <distro>`
  - `wsl --list --verbose --format json`
  - process management: track each running `wsl --exec` PID
    Windows-side; SIGTERM via `Stop-Process` if needed.
- **NEW** event stream emulator: poll `wsl --list --running` every
  500 ms, diff against last seen, emit synthesized `start` / `stop`
  events on the channel that today's `podman events` populates.
  Latency higher than podman events (~500 ms vs ~10 ms); acceptable
  for the tray state machine.
- **NEW** "ephemeral session" semantics: the WSL distro is the
  *image*; per-attach we mint a one-shot service identity by
  cloning the distro (`wsl --export | wsl --import` with a different
  name), running the entrypoint inside it, and `wsl --unregister`-ing
  it on stop. `--rm`-equivalent. Cost: ~1-2 s per attach for the
  copy-on-write export/import.

### Enclave network

- The enclave becomes "loopback inside the shared WSL2 network namespace
  on Windows": every service binds 127.0.0.1:<port>. Service discovery
  drops the alias names — `proxy:3128` becomes `127.0.0.1:3128`, etc.
- **NEW** `enclave-init` distro: the smallest distro we ship (Alpine,
  ~22 MB), boots first on Windows, runs `iptables -m owner` rules
  enforcing forge-offline (drop OUTPUT for uid in [forge_min, forge_max]
  except to 127.0.0.0/8 and the proxy-allowed CIDR). Tears down on
  enclave shutdown.
- **MODIFIED** `crates/tillandsias-core/src/container_profile.rs`:
  `ContainerProfile` gains an optional `egress_uid` field. WslRuntime
  reads this when applying the egress firewall via `enclave-init`.

### Forge offline enforcement (the spec-critical piece)

The `forge-offline` capability spec is non-negotiable: forge containers
have ZERO direct internet access. With shared netns, this is enforced
two ways simultaneously:

1. **iptables uid-owner rules** (set up by `enclave-init` at WSL VM
   boot): drop OUTPUT to non-loopback, non-internal-CIDR for the forge
   uid range. Verified at runtime with `iptables -L OUTPUT -v` and a
   smoke test (forge tries to `curl https://example.com` → fails with
   "Network is unreachable"; forge tries `curl http://127.0.0.1:3128`
   → succeeds).
2. **Per-process `unshare --net`** when the agent process spawns:
   the entrypoint enters a fresh net namespace with only a
   loopback interface, then binds in the parent's lo via
   `nsenter`-style trick to keep loopback connectivity. Defense in
   depth: even if iptables fails to load, the agent process still
   can't reach the internet.

### Image build for Windows: WSL-native, podman is gone

For `--init`, Tillandsias on Windows builds each enclave service from
a base rootfs tarball pulled directly from upstream (Fedora cloud-base
for forge/git, Alpine minirootfs for proxy/router, `nixos/nix` rootfs
for inference). The build is imperative — each `RUN` from the
Containerfile becomes a `wsl --distribution <temp> -- <command>` call;
each `COPY` becomes a Windows-side `cp` into the distro's `/mnt/c/`-
visible workspace. After all steps complete, `wsl --export <temp>` produces
the tarball that becomes the runtime distro. The Containerfile remains
as documentation; the build script is the source of truth for the
WSL-native path.

Linux and macOS continue to use podman for image builds (where it is
the canonical, well-supported toolchain). Only Windows changes.

### Capabilities

#### Modified Capabilities

- `cross-platform`: WSL distros replace podman containers as the unit
  of execution on Windows. The runtime abstraction lives in
  `crates/tillandsias-runtime`. The control socket can resume on
  Windows because both the tray and the forge run inside the same
  Linux kernel (the WSL VM); the socket lives at
  `\\wsl$\<service>\run\tillandsias\control.sock` and is reachable
  from Windows-side AF_UNIX clients (verification pending — see
  open question 1).
- `podman-orchestration`: scoped to non-Windows targets. The trait
  the rest of the codebase consumes is `Runtime`, not `Podman`.
- `enclave-network`: the Windows enclave network is the shared WSL2
  Linux network namespace, with services on 127.0.0.1:<port>. The
  Linux/macOS enclave remains the podman bridge with DNS aliases.
  Service discovery in tray code consults the runtime: podman
  returns `proxy:3128`; WSL returns `127.0.0.1:3128`.
- `forge-offline`: defense-in-depth on Windows — iptables
  uid-owner egress drop AT VM init plus `unshare --net` at process
  spawn. On Linux/macOS, `--cap-drop=ALL` plus
  `--network=enclave-internal` continue to enforce the same property
  through podman.

## Impact

- **New crate**: `crates/tillandsias-runtime/` with `Runtime` trait,
  `PodmanRuntime`, `WslRuntime`.
- **Renamed (eventually)**: `crates/tillandsias-podman/` →
  `crates/tillandsias-runtime/`. Backwards-compat re-export for one
  release.
- **Modified call sites**: every `podman_cmd()` /
  `podman_cmd_sync()` consumer in `src-tauri/src/` now goes through
  `default_runtime()`. Surface area: `launch.rs`, `handlers.rs`,
  `init.rs`, `runner.rs`, `mirror_sync.rs`, `event_loop.rs`. About
  ~150 call sites.
- **New script**: `scripts/build-wsl-distro.sh`.
- **Tray init flow**: after podman builds, also `wsl --import` for
  every enclave image on Windows.
- **Resource model**: per-distro `--memory` is enforced via cgroup-v2
  inside each distro by the entrypoint. Global VM budget set in
  `.wslconfig`.
- **First-launch UX**: detect `~/.wslconfig` missing the cgroup-v2
  kernel command line, prompt the user to update + `wsl --shutdown`.
- **Storage footprint**: bigger than today (each distro has its own
  VHDX, ~2-7 GB), offsets the savings from removing the
  podman-machine VM.
- **Network UX**: `localhost:8080` from the Windows browser still
  reaches the router because of `localhostForwarding=true` (default
  in `.wslconfig`).
- **Cross-platform parity**: Linux/macOS code path unchanged. Windows
  now runs a different runtime backend behind the same trait.
- **Tests**: integration test stub (`crates/tillandsias-runtime/tests/wsl_smoke.rs`)
  that imports a tiny tarball, runs a command, unregisters. Marked
  `#[cfg(target_os = "windows")]` and `#[ignore]` by default.

## Sources of Truth

- `docs/strategy/wsl-only-feasibility.md` — feasibility analysis;
  this change implements its Option 4 (with the security mitigations
  the report flagged).
- `docs/cheatsheets/runtime/wsl/architecture-isolation.md` —
  shared-network-namespace claim verified by the prototype.
- `docs/cheatsheets/runtime/wsl/wslconfig-tunables.md` — VM-wide
  resource limits and firewall keys.
- `docs/cheatsheets/runtime/wsl/cli-surface.md` — `wsl.exe`
  inventory used to design WslRuntime.
- `openspec/specs/forge-offline/spec.md` — the contract this change
  must continue to honor.
- `openspec/specs/enclave-network/spec.md` — the contract this change
  modifies (per-platform realisation differs).

## Open Questions (resolve in design.md before /opsx:apply)

1. **`\\wsl$\<distro>\run\...\control.sock` accessibility from Win32
   `connect(2)`** — the prototype did not verify this. If 9P does not
   surface AF_UNIX endpoints to Win32 callers, fall back to a
   per-distro tiny relay (`socat UNIX-LISTEN:... EXEC:wsl --exec`).
2. **iptables uid-owner reliability under WSL2's kernel** — verify
   that uid-based egress drop actually fires when the agent process
   runs as a non-root user inside the forge distro.
3. **`enclave-init` distro lifecycle** — should it be auto-started by
   the tray at every Tillandsias launch, or persist across reboots
   via `wsl.conf [boot] command=...`?
4. **Image build dependency** — for Phase 1, podman-machine stays as
   the image builder; for Phase 2 we want Linux-toolbox cross-build
   from CI shipping tarballs as release assets. Is that one change
   or two?
5. **Multi-project concurrency** — today multiple forges per project,
   plus multiple projects, can run simultaneously. With the "ephemeral
   distro per attach" design, the tray needs to manage many distros at
   once. `wsl --list` enumeration cost? `wsl --import` time at scale?
6. **Inference distro ollama persistence** — ollama models are GBs.
   Today they live in the inference container's volume. With WSL,
   they live in the inference distro's VHDX. Re-importing after an
   image update would lose them. Solution: keep ollama state on a
   bind-mount from `/mnt/c/Users/<user>/AppData/Local/Tillandsias/ollama/`,
   independent of the distro lifecycle.
