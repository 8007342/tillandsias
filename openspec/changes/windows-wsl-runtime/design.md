# Design: windows-wsl-runtime

## Context

Prototype work on this branch (windows-on-wsl, 2026-04-26 → 2026-04-27)
validated the core mechanism: a podman OCI image converts to a WSL
distro by `podman export | wsl --import`, and `wsl --user --cd --exec`
gives us the same effective process model as `podman run --user -w`.
The architectural cost is that all WSL distros share one Linux network
namespace (Microsoft Learn, fetched 2026-04-26: *"Linux distributions
running via WSL 2 will share the same network namespace, device tree
... CPU/Kernel/Memory/Swap, /init binary"*). This design treats that
as a feature for inter-service connectivity (proxy/git/inference live
on `127.0.0.1:port`) and a constraint for forge-offline (egress
firewalling must be either uid-based in the shared namespace, or
re-namespaced via `unshare --net` at process spawn).

## Locked Decisions

### D1. Replace `tillandsias-podman` with a `Runtime` trait + two backends

Rust trait, two implementations, all consumers go through the trait.
Linux/macOS use `PodmanRuntime`; Windows uses `WslRuntime`. The crate
keeps its directory name (`tillandsias-podman`) for one release for
upgrade ergonomics; sources move to a `runtime/` module. Public API:

```rust
pub trait Runtime: Send + Sync {
    fn name(&self) -> &'static str; // "podman" | "wsl"
    fn image_exists(&self, tag: &str) -> Result<bool>;
    fn image_export_to_tar(&self, tag: &str, out: &Path) -> Result<()>;
    fn service_create(&self, spec: &ServiceSpec) -> Result<ServiceHandle>;
    fn service_start(&self, h: &ServiceHandle) -> Result<()>;
    fn service_stop(&self, h: &ServiceHandle, grace: Duration) -> Result<()>;
    fn service_running(&self, h: &ServiceHandle) -> Result<bool>;
    fn service_exec(&self, h: &ServiceHandle, exec: &ExecSpec) -> Result<ExitStatus>;
    fn service_remove(&self, h: &ServiceHandle) -> Result<()>;
    fn events_stream(&self) -> Box<dyn Iterator<Item = Event>>;
    fn list_services(&self, prefix: &str) -> Result<Vec<ServiceHandle>>;
}
```

`ServiceSpec` carries the contract (image, mounts, env, user,
working_dir, network_aliases, egress_uid for forge), with each backend
translating to its native flags. `ServiceHandle` is the opaque
identity (podman: container ID; wsl: distro name).

**Why this shape**: the rest of the codebase already speaks "service"
(via `ContainerProfile`); we don't expose container-runtime jargon in
the trait. The test harness can implement `MockRuntime` for unit
tests. The trait is sync; async IO inside (event streaming, podman
exec) lives behind `tokio::task::spawn_blocking` at the call site —
we already do this for `podman_cmd_sync`.

### D2. Image build is WSL-native on Windows; no podman, anywhere in the build chain

The Containerfile is a layered description of how to turn a base
rootfs into a runtime image. Podman/Buildah implements that layering
through OCI layer extraction + diff. We can implement the *same
semantic transformation* using only `wsl.exe` plus a small set of
single-binary tools (skopeo for OCI registry pulls, no daemon).

**No podman, no docker, no buildah, no podman-machine on the Windows
host. Ever.** The Windows build path acquires upstream rootfs tarballs
directly and applies the Containerfile transformations in a temp WSL
distro.

Per-service base — same upstream container image as Linux/macOS:

| Service   | Upstream base               | Acquisition                                                    |
|-----------|-----------------------------|----------------------------------------------------------------|
| forge     | `fedora:43` container image | `skopeo copy docker://registry.fedoraproject.org/fedora:43 oci:./fedora-43` then layer-flatten |
| proxy     | Alpine minirootfs           | direct download from `dl-cdn.alpinelinux.org/alpine/v<x.y>/releases/x86_64/alpine-minirootfs-<x.y.z>-x86_64.tar.gz`, SHA-256 verified |
| git       | Alpine minirootfs           | direct download (same source)                                  |
| inference | Alpine minirootfs + ollama  | direct download + `apk add curl` + ollama install              |
| router    | Alpine minirootfs + caddy   | direct download + `apk add caddy`                              |
| enclave-init | Alpine minirootfs        | direct download + `apk add iptables`                           |

skopeo runs without a daemon, ships as a single ~25 MB Windows binary,
and is the canonical tool for pulling OCI images into a flat
filesystem (Red Hat / containers-org maintained, in-tree at
`github.com/containers/skopeo`). Microsoft Learn's *use-custom-distro*
explicitly cites "find a Linux distribution container and export an
instance as a tar file" as a supported path; skopeo is the daemonless
realization of that step.

```
# Pseudocode for scripts/wsl-build/build-forge.sh

1. base_tar = $(bases.sh fedora-43)         # skopeo copy + layer
                                             # flatten, cached under
                                             # ~/.cache/tillandsias/wsl-bases/

2. wsl --import tillandsias-build-forge \
       %LOCALAPPDATA%\Tillandsias\WSL\build-forge \
       $base_tar --version 2

3. # Each `RUN` in the Containerfile becomes:
   wsl -d tillandsias-build-forge -- bash -lc 'dnf install -y python3 ...'
   wsl -d tillandsias-build-forge -- bash -lc 'pipx install ...'
   ...

4. # Each `COPY` becomes:
   #   - On Windows side, cp the source files into a staging
   #     directory under /mnt/c/.../staging/
   #   - Inside the distro, run `cp -a /mnt/c/.../staging/foo /target`
   wsl -d tillandsias-build-forge -- cp -a /mnt/c/.../entrypoint-forge-claude.sh /usr/local/bin/

5. # `USER 1000:1000` is encoded in a sidecar JSON
   # (target/wsl/<service>.meta.json) the tray reads and applies at
   # `wsl --user` invocation time.

6. # `RUN dnf clean all` and similar cleanup steps run as the last
   # phase to shrink the resulting tarball.

7. wsl --export tillandsias-build-forge $out_tar
   wsl --unregister tillandsias-build-forge
```

For Alpine-based services the build is shorter (no skopeo, just direct
download + `apk add`). `bases.sh` caches the verified base tarball
under `~/.cache/tillandsias/wsl-bases/{alpine-3.20,fedora-43}.tar` so
repeat builds skip the network round-trip.

**Build-step parallelism**: each Containerfile RUN inside one `wsl
-d --exec` is its own process. We do not get podman's layer caching
for free; instead, we cache the *whole intermediate distro* between
build steps that might fail. After step N, `wsl --export` to a
checkpoint; if step N+1 fails and the user retries, resume from the
checkpoint instead of rebuilding from base.

**Source of truth**: the Containerfile remains in
`images/default/Containerfile` as documentation and as the canonical
spec the Linux/macOS path consumes. The WSL-native build script is
hand-translated. We add a verifier (`scripts/wsl-build/verify-parity.sh`)
that diffs the final WSL tarball against the podman-built tarball
under a Linux toolbox build, and fails CI when they diverge in
content paths or contents.

**Why hand-translate, not parse**: parsing Containerfile syntax in
shell is fragile (line continuations, embedded HEREDOC, ARG
substitution, `${var:+default}`, multi-stage builds). A 200-line bash
script that mirrors the Containerfile structure 1:1 is more
maintainable than a Containerfile interpreter we'd own. When the
Containerfile changes, the bash script gets the same edit.

Linux and macOS continue to use podman for builds — that's the
canonical toolchain for OCI images and is well-tested. Only Windows
deviates.

### D3. Loopback service discovery on Windows

On Linux/macOS:
- proxy → `proxy:3128` via podman bridge DNS
- forge → speaks `proxy:3128`
- All container DNS aliases resolve via the enclave bridge.

On Windows:
- proxy distro binds 127.0.0.1:3128
- forge distro speaks `127.0.0.1:3128` (same Linux netns)
- No DNS aliases needed (and they would be confusing because all
  distros share /etc/hosts).

The `Runtime` trait exposes `service_address(&self, service: &str,
port: u16) -> SocketAddr` so call sites get the right address per
backend. The forge entrypoint reads
`TILLANDSIAS_PROXY_URL=$(tillandsias-services proxy 3128)` instead of
hardcoding `proxy:3128`. (`tillandsias-services` already exists; we
extend it to consult the runtime.)

### D4. forge-offline: defense in depth, two enforcement layers

**Layer 1 — uid-based iptables egress drop in the shared namespace**:
At WSL VM boot, the `enclave-init` distro (Alpine, ~22 MB, has
iptables installed) runs:

```bash
# Drop OUTPUT to non-loopback, non-internal-CIDR for forge uid range.
iptables -A OUTPUT -m owner --uid-owner 2000-2999 -d 127.0.0.0/8 -j ACCEPT
iptables -A OUTPUT -m owner --uid-owner 2000-2999 -j DROP
```

This is in the shared netns so it applies once and covers every WSL
distro. The forge distros run their entrypoint as a uid in the
2000-2999 range (set per-launch by the tray when issuing
`wsl --user uid=2003 --exec ...`). proxy/git/inference run as
different uids outside that range, so they're unaffected.

**Layer 2 — `unshare --net` at process spawn**: the forge entrypoint,
before exec'ing the agent, does:

```bash
exec unshare --net --setuid 2003 --setgid 2003 -- \
  /bin/setpriv --reuid 2003 --regid 2003 --clear-groups --no-new-privs -- \
  /opt/agents/.../entrypoint.sh
```

This puts the agent in a new net namespace where only `lo` exists.
We then plumb a peer into it via a `socat` relay on a Unix socket
(forge speaks the relay socket; relay translates to TCP to the proxy
in the parent namespace). Belt and braces: even if iptables fails
to load, the agent process literally has no network device that
reaches the internet.

**The tray verifies both layers** at launch via a smoke probe:

1. Run `curl --max-time 2 https://example.com` inside the forge
   pre-attach. Must fail.
2. Run `curl --max-time 2 http://127.0.0.1:3128` inside the forge
   pre-attach. Must succeed.

If either probe disagrees with expectation, the tray refuses to attach
and surfaces a "forge-offline integrity check failed" notification.

### D5. Service lifecycle = ephemeral distro per attach

`--rm` semantics in podman become "clone the image distro on attach,
unregister on detach":

```bash
# attach
wsl --export tillandsias-forge "$TMPDIR/forge-$session.tar"
wsl --import "tillandsias-forge-$session" "$DATA/$session" "$TMPDIR/forge-$session.tar" --version 2
wsl --distribution "tillandsias-forge-$session" --user 2003 --cd "/mnt/c/..." --exec /opt/agents/entrypoint.sh

# detach
wsl --terminate "tillandsias-forge-$session"
wsl --unregister "tillandsias-forge-$session"
```

Cost on the prototype machine: `wsl --export` + `wsl --import` of a
6.3 GB forge image takes ~30-60 s. That's too slow for a tray UX
expectation of "Attach Here" being instant.

Mitigation: WSL2 supports `--vhd <basevhd.vhd>` import (copy-on-write
VHDX from a base, no full export). Quote pending — `learn.microsoft
.com/wsl/use-custom-distro` discusses VHDX import. Phase 1 ships the
slow path; Phase 2 switches to copy-on-write VHDX cloning, target <2 s.

### D6. Resource limits via cgroup-v2 sub-cgroups

Each distro runs systemd as PID 1 (set
`[boot] systemd=true` in the distro's `wsl.conf`). systemd creates
cgroup-v2 hierarchies. The entrypoint creates a sub-cgroup
`tillandsias-attach.slice` and writes `memory.max=8G`,
`pids.max=4096`, etc., per the profile. cgroups apply to the
sub-tree.

The VM-wide ceiling lives in `.wslconfig`:
`[wsl2] memory=10GB processors=6` (set by the tray's first-launch
helper).

### D7. `tillandsias --init` on Windows: WSL-only from day one

Concrete flow on a freshly installed Windows host (WSL2 enabled,
no podman, no docker):

```
1. For each enclave service in {enclave-init, proxy, git, inference, router, forge}:
     1a. scripts/wsl-build/build-<service>.sh produces
         target/wsl/tillandsias-<service>.tar (skopeo for forge,
         direct Alpine download for the rest; cached bases reused).
     1b. wsl --import tillandsias-<service> \
                       %LOCALAPPDATA%\Tillandsias\WSL\<service> \
                       target/wsl/tillandsias-<service>.tar \
                       --version 2.
     1c. write target/wsl/<service>.meta.json next to the tarball:
         { "default_uid": 1000, "service_port": 3128, "user": "forge" }.

2. enclave-init runs once at WSL VM cold boot
   (registered via [boot] command in its wsl.conf), applying the
   uid-based iptables egress drop in the shared netns.

3. The tray, once Phase 5 lands, reads each <service>.meta.json
   and routes start/stop through Runtime::service_*().
```

There is no Phase-1-vs-Phase-2 fallback to podman-machine. The
single supported Windows path is wsl-only. CI artefacts (Phase 9
in tasks.md) replace the local skopeo+download pipeline with a
"download a pre-built tarball from a GitHub release" step, but that
is an *acceleration* of the same path, not a replacement that
re-introduces podman.

### D8. Event stream is poll-based on Windows

`wsl.exe` has no event stream. We poll `wsl --list --running` every
500 ms; diff against last seen; emit synthesized `start` / `stop`
events. Latency budget for the tray state machine: 500 ms is fine
for menu chip updates; for the "container ready" critical path we
use the existing health check (HTTP probe / file presence).

## Verification (prototype, 2026-04-26 → 2026-04-27)

```
podman create --name tmp tillandsias-forge:v0.1.170.249 /bin/true
podman export tmp -o /tmp/forge.tar  # 6.3 GB
mkdir -p $LOCALAPPDATA/Tillandsias/WSL/forge
wsl --import tillandsias-forge-poc \
    $LOCALAPPDATA/Tillandsias/WSL/forge \
    /tmp/forge.tar --version 2
# operation completed successfully

wsl -d tillandsias-forge-poc -- bash -c 'cat /etc/os-release | head -3'
# NAME="Fedora Linux"
# VERSION="43 (Container Image)"

wsl -d tillandsias-forge-poc --user forge -- bash -c 'id; pwd'
# uid=1000(forge) gid=1000(forge)
# /mnt/c/Users/bullo/src/tillandsias  (inherited cwd!)

# Inter-distro loopback verified: forge listener on 127.0.0.1:14000
# reachable from proxy distro via wget.
# Both distros report identical eth0 IP/MAC: 172.25.55.216 / 00:15:5d:9b:52:49
```

## Out of Scope (follow-up changes)

- Cross-build tarball CI distribution (Phase 2; removes
  podman-machine on Windows).
- Linux/macOS migration to the same `Runtime` trait shape — design
  considers it but doesn't require it. Linux native podman performance
  is already best-in-class.
- Named-pipe-based control plane on Windows. With WSL distros
  sharing the kernel as the tray's host (the tray runs on Windows; the
  forge runs in WSL), the control socket lives at
  `/run/tillandsias/control.sock` *inside the WSL VM*. Win32
  connect-to-AF_UNIX-via-9P is the prototype unknown; if it doesn't
  work, a tiny in-VM relay daemon adds ~300 LOC.
- Multi-Windows-user support. WSL is per-user; multi-seat installs
  would each have their own WSL VM and Tillandsias state. Same as
  today.
