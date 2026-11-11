# design.md — minimum-moving-parts architecture (Designer B)

Obligation IDs refer to `obligations.md`. Q-numbers refer to `questions.md`.

## 0. The design in one paragraph

Two programs and one image family. **`tillandsias`** is a single Rust binary that
is the tray icon, the CLI, and the reconciler; it holds no state of its own and
runs nothing in the background. **`gateway`** is a single static Rust binary in a
tiny container; it is the only supporting service and the only border crossing
of the region: egress proxy, git relay with credential injection, model-API
relay with credential injection, and the agent-facing API. **`forge`** is one
prebuilt, signed image per architecture, instantiated once per project on its
own internal network. State lives in exactly three places: the host OS keyring
(secrets), podman itself (labels, volumes), and a small config directory.
Everything is pulled by digest; nothing is built on the user's machine.

```
 HOST DESKTOP
 +--------------------------------------------------------------------+
 |  tillandsias (tray + CLI, Rust, no timers)        OS keyring        |
 |      |  argv -> podman            ^ one blocked read (only while up)|
 |      v                            |                                 |
 |  [substrate: Linux = host | macOS = podman machine VM | Win = WSL2] |
 |  +--------------------------------------------------------------+  |
 |  |  REGION (all objects labelled io.tillandsias.region=<name>)   |  |
 |  |                                                              |  |
 |  |   net: edge (has route out)                                  |  |
 |  |      +-----------+                                           |  |
 |  |      |  gateway  |--- 127.0.0.1:<port> control (token) ------+--+--> tray
 |  |      +-----------+                                           |  |
 |  |        |       |          one internal network per project   |  |
 |  |   net: p-alpha (internal)        net: p-beta (internal)      |  |
 |  |      +-----------+                 +-----------+             |  |
 |  |      | forge     |                 | forge     |             |  |
 |  |      | alpha     |                 | beta      |             |  |
 |  |      +-----------+                 +-----------+             |  |
 |  |      vol: alpha-work, alpha-home   vol: beta-work, beta-home |  |
 |  |      vol: cache (shared, content-addressed, read-mostly)     |  |
 |  +--------------------------------------------------------------+  |
 +--------------------------------------------------------------------+
```

## 1. Tray process model

### 1.1 One binary, three faces

`tillandsias` with no arguments is the tray. `tillandsias <verb>` is the CLI
(`up`, `down`, `open`, `status`, `doctor`, `uninstall`). Both call the same
library functions. The CLI is the fallback surface where no tray exists (O-B3)
and is the test harness for every measure. There is no separate daemon and no
IPC protocol between tray and CLI: each invocation reconciles against podman,
which is the shared source of truth, under a file lock.

Why no daemon: on Linux podman is daemonless and containers are supervised by
`conmon`, so they outlive whoever started them. A daemon of ours would exist
only to remember things podman already remembers. That fails O-J1's test
applied to ourselves, and fails O-A3.

### 1.2 Native tray, no toolkit

| Platform | Mechanism | Crates (Rust) | Consequence |
|---|---|---|---|
| Linux | StatusNotifierItem + DBusMenu over the session bus | `zbus` (or `ksni`) | No GTK/Qt linked. Blocks on the D-Bus socket. GNOME needs the AppIndicator extension; detect absence and say so (O-B3). |
| macOS | `NSStatusItem` + `NSMenu` | `objc2`, `objc2-app-kit` | Standard run loop; no timers installed. `LSUIElement` app, no Dock icon. |
| Windows | `Shell_NotifyIconW` + popup menu on a message-only window | `windows` | `GetMessage` loop blocks; handle `TaskbarCreated` to re-add the icon after Explorer restarts. |

No webview, no Electron, no cross-platform GUI framework. The menu is the whole
UI; anything richer is delegated to things the OS already has (terminal,
browser, notification centre). This is what makes O-A2 and O-A5 reachable.

### 1.3 The no-timer rule

The tray has two modes.

- **Dormant** (no cloud running): one thread blocked in the platform event
  loop. No timers, no sockets, no child processes. State shown is "stopped",
  which is true by construction because the tray is the only launcher and it
  verified on startup (one `podman ps --filter label=...` at launch, only if the
  substrate is already running; it never starts a VM just to look).
- **Attached** (cloud running): additionally one thread blocked on a single
  long-lived read from the gateway's control stream (section 4.4). The gateway
  pushes state changes and approval requests; the tray never polls. If the
  stream drops, the icon moves to "attention" and the tray retries with capped
  exponential backoff (max interval 60 s, stops after the cloud is confirmed
  down).

Menu contents are computed when the menu is opened, not kept fresh.
Opening the menu while dormant costs zero subprocesses (stopped is known);
while attached it reads the last pushed state.

### 1.4 What the tray does on a click

`reconcile(desired) -> actions`: read desired state (which projects should be
up) from `config.toml`; read actual state from podman by label; compute the
difference; run podman commands; report. It is a pure function over two
snapshots plus a short list of imperative steps, which is what makes launch
idempotent (O-C3) and makes crash recovery the same code path as launch.

Long operations (pull, VM boot) run on a worker thread that exists only for the
duration of the operation; progress goes to the icon/tooltip and a native
notification on completion or failure.

### 1.5 How the tray talks to podman

By executing `podman` with `--format json` (through the substrate adapter in
section 5), not by speaking the REST API over a socket.

- The call rate is a handful per user action, so process-spawn cost is irrelevant.
- It is the one interface that is identical for local podman, `podman --remote`, and `wsl.exe --exec podman`.
- It avoids requiring `podman.socket` to be enabled on Linux, and avoids holding an idle connection.
- Cost accepted: JSON output schemas drift between podman versions. Mitigation: a version floor (O-G4), a single typed parsing module, and `doctor` running a schema canary. Q9.

### 1.6 User interaction with a forge

"Open <project>" launches the user's terminal emulator running
`podman exec -it <forge> <agent>` (through the substrate adapter). The agent is
visible, interactive, and interruptible in a window the user already knows how
to use (O-I5), and we ship no terminal, no multiplexer UI and no web front end.
Inside the forge the agent runs under a small session holder so closing the
window detaches instead of killing (section 3.2). Q13.

## 2. State: where it lives, and nothing else

| State | Home | Why there |
|---|---|---|
| Secrets (git token, model-provider keys) | Host OS keyring: Secret Service (Linux), Keychain (macOS), Credential Manager (Windows). Rust `keyring` crate. | Already encrypted at rest, already unlocked by the user's login, already has a UI. No vault container, no unseal, no recovery procedure. |
| Desired state, project list, allowlists | `config.toml` in the platform config dir. Human-editable, small. | |
| Installed release manifest (tray version, image digests, signatures) | `release.toml` next to the binary, plus `release.prev.toml`. | Rollback is "use the previous file". |
| Actual state | podman: containers, networks, volumes, all carrying `io.tillandsias.*` labels. | One query answers "what exists"; one filter removes everything (O-F4). |
| Project work in progress | `<project>-work` volume (a git clone). | Section 3.3. |
| Per-project tool installs, agent session history | `<project>-home` volume. | Survives forge recreation; deleted with the project. |
| Download/build caches | one `cache` volume. | Disposable by definition. |

If the keyring is unavailable (headless Linux without Secret Service), the
product refuses to store credentials and says so; it does not fall back to a
plaintext file.

## 3. Container topology

### 3.1 The gateway: the one supporting service

One Rust static binary (musl), in a `scratch`-based image of roughly 10 MB,
running read-only, with all capabilities dropped, as a non-root user. It listens
on each project network and has the only route out of the region.

It has four functions. Each is listed with the obligation that pays for it and
the reason it is not a separate container.

| Function | Pays for | What it does |
|---|---|---|
| Egress proxy | O-E1, O-I3 | HTTP `CONNECT` proxy with a per-project allowlist of host names. No TLS interception. A denied host gets an immediate `403` whose body is machine- and human-readable (`{"denied":"example.org","how":"request_egress"}`). Also the only DNS answerer for forges: project networks are `--internal`, so there is no other path. |
| Git relay | O-H1, O-H5, O-I2 | Smart-HTTP git endpoint per project. Fetch and push are forwarded to the project's real remote with the credential injected at the gateway. Push is restricted to a ref namespace (default `refs/heads/forge/*`); pushes to protected refs are refused with a message. For projects with no remote, the backend is a bare repository in a gateway volume, and the host fetches from it. |
| Model relay | O-I1, O-I2 | Reverse proxy at `/llm/<provider>/` that adds the provider API key and forwards. Agents are pointed at it with their standard base-URL environment variables. The key never enters a forge. |
| Region API | O-J2, O-B2 | Small HTTP/JSON API for agents (section 6) and a control stream for the tray. |

Why one container and not four: on the floor host (O-G1) each extra container
costs a `conmon`, a network namespace, an image, a start-order dependency, and
a failure mode. The four functions share one need (per-project identity plus
policy plus a credential) and one trust level (they all sit on the border). The
separation-of-privilege argument against combining them is real and is answered
inside the process instead: the proxy path never has access to credential
memory (credentials are held by the relay modules behind a narrow internal
interface), the binary is memory-safe Rust with no shell and no dynamic
loading, and the container has a read-only root and no capabilities. If a
security review rejects this, the split is mechanical: same binary, started
twice with different `--role` flags. That is the designed escape hatch, and it
does not need to be taken in advance.

Credentials reach the gateway as podman secrets created from the keyring at
`up` time and mounted on tmpfs; they are removed at `down`. On macOS and
Windows this means secrets exist inside the VM only while the cloud is up.

Per-project identity: the gateway identifies the calling forge by the network
interface the connection arrived on (one network per project), not by a token
the agent could copy to another forge. No per-forge secret is needed at all.

### 3.2 The forge

One image family, `forge:<release>` for `amd64` and `arm64`, pulled by digest.
Contents: a mainstream distro base, git, common language toolchains via a
version manager that installs on demand into the home volume, and the supported
agent CLIs. Q10 and Q12 decide what "common" and "supported" mean; until then
the image is deliberately a base plus on-demand tools rather than everything
preinstalled, which keeps O-D2 reachable.

Run configuration (all as `podman run` flags; no compose file, no pod, no kube YAML):

- `--network p-<project>` (internal), proxy variables pointing at the gateway.
- `--userns=keep-id`-style mapping, non-root user, `--cap-drop=all`, `--security-opt no-new-privileges`, read-only root, tmpfs `/tmp`.
- `--memory`, `--cpus`, `--pids-limit` from the budget in section 7 (O-I4).
- Mounts: `<project>-work` at `/work`, `<project>-home` at `/home/forge`, `cache` at `/cache`. **No host bind mounts.**
- PID 1 is `forge-init`, a small Rust binary: reaps zombies, clones the project into `/work` on first start, keeps a persistent pseudo-terminal session so the agent survives the terminal window closing, and exits cleanly on SIGTERM. It replaces what would otherwise be an entrypoint shell script plus a multiplexer.

### 3.3 Why the project is cloned in, not mounted in

This is the largest deliberate departure from the obvious design, so the
reasoning is spelled out.

Bind-mounting the host checkout is what a developer expects, and on Linux it
works well. On macOS it crosses virtiofs and on Windows it crosses the 9p
bridge to the NTFS side, where file-heavy operations (dependency installs,
builds, `git status` on a big tree) are slower by a large factor, file-watch
events are unreliable, and permissions and case sensitivity differ. That would
give three different products, and the slowest one on exactly the hosts least
able to afford it (O-G1, O-G3, O-H2).

Cloning into a volume makes the forge filesystem native on all three
platforms, makes the agent physically unable to alter the user's working tree
(O-H4, O-H5), and makes "what did the agent do" a `git log` on a branch. The
costs are real: the user sees results after a push rather than live, and
uncommitted host changes are not visible to the agent. Mitigations: "Open"
offers to push the current host branch into the relay first; `forge/*`
branches show up on the user's remote or as a local remote named `tillandsias`.
If Q11 comes back "live edits in the host tree are required", the fallback is a
bind mount on Linux only and a documented performance warning elsewhere; the
rest of the design does not change.

### 3.4 Services considered and cut

| Candidate | Verdict | Reason |
|---|---|---|
| Secrets vault container | Cut | The OS keyring already is one, for a single-user desktop. A vault adds unseal, backup and recovery duties that the user never asked for. |
| Local container registry | Cut | Pull by digest from the public registry; podman's store is the cache. |
| Image build service / local builds | Cut | Low-end hosts cannot afford builds, and local builds destroy reproducibility (O-H2). Customisation goes into the home volume, not into images. |
| Separate DNS service | Cut | The proxy resolves names; forges need no resolver beyond the gateway alias that podman's network DNS provides. |
| Separate git mirror container | Folded into gateway | It needs the same credential and the same per-project identity as the relay. |
| Log aggregation / metrics stack | Cut | `podman logs` on demand; `doctor` assembles a bundle. Nothing collects continuously. |
| Local inference server | Optional add-on, off by default | Contradicts the floor host. If enabled it is one more container behind `/llm/local/`, so the agent interface does not change. |
| Web dashboard | Cut | The tray is the UI. |
| Message bus between agents | Cut | Git is the coordination medium. Not implied by the promise. |
| Reverse proxy for forge web previews | Deferred | `expose_port` in the API maps a forge port to host loopback through the gateway; no separate ingress container. |
| Our own VM manager on macOS | Cut for v1 | Section 5.2. |
| Pods / systemd quadlets / kube YAML | Cut | Plain containers with labels are sufficient; quadlets are Linux-only and would split the lifecycle code. |

## 4. Lifecycle

### 4.1 States

`absent -> provisioned -> stopped -> running -> stopped`, per region; forges
have `absent -> created -> running -> stopped`. "Attention" and "failed" are
overlays with a reason string, not states.

### 4.2 Cold start (first launch after install)

1. `doctor` preflight: substrate present and at version floor, free disk, RAM class. Refuse early with one sentence if not.
2. Substrate provision (macOS/Windows only; section 5). Slowest step; resumable.
3. Verify and pull images by digest from `release.toml` (gateway then forge). Layer pulls resume; a partial pull is not an error state.
4. Create labelled networks and volumes; create secrets from the keyring (prompting for a git credential and a model credential if absent, through the tray's native dialog or the provider's device-code flow in the browser).
5. Start gateway; wait for its health endpoint; attach control stream.
6. Create and start the forge; `forge-init` clones through the relay.
7. Open the terminal.

Budget on the comfortable host with a 50 Mbit/s link: dominated by roughly 1.5 GB of
image download, so minutes; stated honestly in the progress text. Offline cold
start is impossible by construction and says so.

### 4.3 Warm start

Images present, substrate provisioned. Linux: `podman start` gateway and forge;
target under 5 s. macOS: boot machine (target under 15 s), then as Linux.
Windows: start distro (target under 10 s), then as Linux. Reopening a running
forge is just the terminal exec, under 1 s.

### 4.4 Control stream (tray and gateway)

The gateway publishes one port on host loopback, bound to `127.0.0.1` with a
random port recorded in a container label, protected by a bearer token created
at `up` and stored in the keyring. The tray opens one server-sent-events stream
and blocks on it. Events: `state`, `approval_request`, `notify`, `forge_exit`.
The tray answers approvals with a single POST. A loopback TCP port is used
because a unix socket does not cross the VM boundary on two of the three
platforms; one mechanism everywhere beats the best mechanism on one.

### 4.5 Stop

"Stop" runs `podman stop` on forges (SIGTERM, 10 s grace so the agent session
is saved), then the gateway, removes secrets, then stops the substrate VM/distro
on macOS/Windows. The host is back in the O-A3 state. Quitting the tray while a
cloud runs asks once: "Leave running" or "Stop and quit" (default per Q4).

An optional idle rule, evaluated by the gateway (which is awake anyway), not by
the tray: no attached terminal and no agent process activity for N minutes
leads to a `notify` suggesting stop. It never stops work on its own.

### 4.6 Snapshot versus rebuild

Rebuild, always. A forge container is cattle: on every release change, or on
"Reset forge", it is removed and created again from the image; `/work` and
`/home/forge` volumes carry over. There is no checkpoint/restore (CRIU is not
dependable rootless and absent on two substrates), no committing of running
containers to images (unreproducible, and grows without bound), and no VM
snapshotting.

"Snapshot" in the user's sense, meaning "get me back to where I was", is met by
three cheap things: git for source, the home volume for tools and agent
history, and the content-addressed cache volume so reinstalling dependencies
is fast. A "Reset project environment" action deletes the home volume as well.
The recreate path is exercised on every update, so it cannot rot.

### 4.7 Updates

- A release is one manifest: tray version, image digests per architecture, minimum substrate versions, signature.
- Check: only when the user opens the menu and the last check is more than a day old, or on an explicit click. One HTTPS GET of a small file. No background updater (O-A3, O-K4).
- Apply: download new binary and manifest, verify signature, pull new images while the old cloud keeps running, then swap at the next `up` (or immediately if the user says so). Binary replacement is atomic rename; on Windows the running executable is renamed aside first.
- Rollback: `release.prev.toml` and the previous binary are kept until the new release has completed one successful `up`. Old images are removed only after that.
- Where a platform package manager installed us (Flatpak, Homebrew, winget), self-update is disabled and the manager owns the binary; images still follow the manifest. Q15.

## 5. Per-platform substrate

A substrate is anything that implements one trait:

```rust
trait Substrate {
    fn ensure_ready(&self, progress: &dyn Progress) -> Result<()>; // provision + start
    fn podman(&self, args: &[&str]) -> Command;                    // how to invoke podman
    fn interactive(&self, args: &[&str]) -> Command;               // same, with a TTY, for the terminal
    fn stop(&self) -> Result<()>;                                  // return host to idle
    fn is_running(&self) -> bool;                                  // must be cheap and must not start anything
}
```

Everything above this trait is platform-independent. This is the entire
portability layer.

### 5.1 Linux

- `podman()` is the host's rootless podman. `ensure_ready` checks version floor, subuid/subgid ranges, cgroup v2 delegation (needed for `--memory`/`--cpus` rootless), and a usable network backend. `stop` is a no-op.
- We use the user's podman store with our label and name prefix, not a private store (Q7). Private `--root` is the alternative if isolation from the user's own containers is required; cost is duplicated base layers.
- No systemd units. Containers get `--restart=no`: after a reboot the cloud is down until the user launches it, which is what O-A3 requires. An "open at login" preference adds a standard autostart entry for the tray only.
- Immutable distros work unchanged since nothing is installed into the OS.
- Installing podman itself is not our job on Linux; `doctor` prints the distro's one-line install command.

### 5.2 macOS

- v1: a dedicated podman machine named `tillandsias` (`podman machine init/start/stop`), using the Apple hypervisor provider, with the podman client and its VM helpers bundled inside the app bundle so the user installs one thing. `podman()` is the bundled client with `--connection tillandsias`.
- Why not our own Virtualization.framework VM: it would mean owning a guest OS image, its updates, a host-guest control channel, port forwarding and time sync. Podman machine is exactly that, maintained by someone else. Writing our own is the single largest block of complexity available in this product and nothing in the obligations requires it. It becomes earned only if measurement shows podman machine cannot meet O-C1 or O-A4, or if bundling is blocked on licensing or size grounds (Q16).
- Machine sizing set at init from host RAM (section 7). No host directories are shared into the VM (section 3.3), which removes the file-sharing layer from the performance and failure picture.
- The VM runs only while a cloud is up. `is_running` checks for the machine's process, without invoking anything that would start it.
- Apple silicon is primary; Intel Macs run the amd64 images on the same path. Q9.
- Distribution: signed and notarised app bundle; the hypervisor entitlement is on the bundled helper.

### 5.3 Windows

- A dedicated WSL2 distro named `tillandsias`, created with `wsl --import` from a small root filesystem tarball we publish (a minimal distro with podman preinstalled, around 150 MB), verified against the manifest. `podman()` is `wsl.exe -d tillandsias --exec podman ...`. No podman needs to be installed on the Windows side, and there is no client/server version skew to manage.
- Why not podman machine here: on Windows it is itself a WSL distro plus a Windows client; importing our own distro is the same thing with one fewer installed product and one fewer version pairing. (This is an asymmetry with macOS and is deliberate: on each platform the choice is "fewest things we own that are not already there". On Windows the VM manager is already there, namely WSL.)
- Keepalive: WSL terminates an idle distro when no process started from the Windows side is attached, regardless of containers running inside (verify current behaviour; Q17). While a cloud is up, the tray therefore holds one `wsl.exe -d tillandsias --exec sleep infinity`-equivalent child (a tiny `hold` subcommand of our own binary inside the distro). When the tray exits with "leave running", the holder is started detached instead.
- Memory: the WSL2 VM is shared by all the user's distros and its limits live in the user's global `.wslconfig`. We do not edit that file. We bound our own usage with per-container cgroup limits and recommend `autoMemoryReclaim` in `doctor` if it is off. This means O-D3 on Windows is enforced at container level, not VM level; recorded as a platform difference under O-G3.
- Networking: the gateway's loopback port relies on WSL's localhost forwarding (default NAT mode) or mirrored mode; `doctor` tests it with a real round trip.
- Prerequisites: the WSL feature and a recent WSL from the Store/winget. Enabling the feature needs administrator rights and possibly a reboot; this is the one unavoidable elevated step (O-F2) and happens in the installer, never at run time.
- `stop` is `wsl --terminate tillandsias`. Never `wsl --shutdown`, which would kill the user's other distros (O-F3).
- ARM64 Windows: same path with arm64 images.

### 5.4 Where the three differ, on purpose

| Concern | Linux | macOS | Windows |
|---|---|---|---|
| Who provides the kernel | host | podman machine VM | WSL2 VM (shared with user) |
| Idle cost when stopped | none | none (VM off) | none (distro terminated) |
| Hard memory ceiling for the cloud | cgroup per container | VM size plus cgroups | cgroups only |
| Elevated step | none | none | enabling WSL feature |
| Extra process while up | none | VM helper processes | one keepalive child |

## 6. Agent-facing service interface

Design rule: an agent should need **no Tillandsias-specific knowledge** for the
common path. Git, HTTP and model calls work through standard environment
variables. The explicit API is only for things that have no standard.

### 6.1 Implicit interface (environment in every forge)

| Variable | Value | Effect |
|---|---|---|
| `HTTPS_PROXY`, `HTTP_PROXY`, `NO_PROXY` | `http://gateway:3128`, `gateway` | All egress mediated. |
| git `url.<relay>.insteadOf` in system gitconfig | project remote rewritten to `http://gateway:8080/git/<project>.git` | Fetch and push work with no credential helper. |
| `ANTHROPIC_BASE_URL`, `OPENAI_BASE_URL`, and equivalents | `http://gateway:8080/llm/<provider>` | Agents authenticate with a placeholder key; the real one is added at the gateway. |
| `TILLANDSIAS_API` | `http://gateway:8080/v1` | Entry point for the explicit API. |
| `TILLANDSIAS_PROJECT`, `TILLANDSIAS_RELEASE` | identifiers | For logs and bug reports. |

`gateway` resolves via the project network's built-in DNS alias. Plain HTTP
inside the region is acceptable because each project network has exactly two
members (forge and gateway); there is nobody to eavesdrop.

### 6.2 Explicit API (v1, JSON over HTTP, also exposed as MCP tools)

| Call | Purpose | Approval |
|---|---|---|
| `GET /v1/status` | Who am I, which release, budgets, current allowlist, relay ref policy, time. The first thing an agent reads. | none |
| `POST /v1/egress/request {host, reason}` | Ask for a host to be allowlisted. Blocks until the human answers in the tray, or returns `pending` with an id. | human |
| `POST /v1/ports/expose {port, label}` | Map a forge port to a host loopback port so the human can open a preview. Returns the URL. | human, once per project |
| `POST /v1/notify {level, text}` | Put one line in front of the human (native notification, rate-limited). | none |
| `GET /v1/events` | Server-sent stream: policy changes, pending shutdown notice. | none |

The same five operations are offered as an MCP server at `/mcp` (streamable
HTTP) and preconfigured for the agents in the image, so agents discover them as
tools without reading documentation. One implementation, two encodings.

Error contract: every refusal carries `code`, a one-sentence `message`, and
`remedy` naming the call or the human action that would change the outcome. An
agent must never have to infer policy from a timeout (O-I3).

Versioning: path-versioned; a release may add calls, never change the meaning
of an existing one within `v1`; `status` lists capabilities so agents test for
features rather than for versions.

Deliberately absent: container control ("start another container for me"),
host file access, reading secrets, calling other forges. Each would be a hole
in O-E1 or O-E3. If nested containers are needed for a project's tests, that is
a forge feature (rootless podman inside the forge), not a gateway call. Q18.

## 7. Resource budgets

| Item | Budget | Enforced by |
|---|---|---|
| Tray, dormant | 0 timers; at most 20 MB PSS Linux, 30 MB macOS/Windows; 1 thread blocked | design (no runtime), CI measure |
| Tray, attached | plus 1 blocked thread, plus at most 2 MB | same |
| Tray binary | at most 15 MB stripped | CI size check |
| Gateway | at most 30 MB RSS under load from 3 forges; at most 0.5% core idle; image at most 15 MB | `--memory=64m`, measure |
| Forge image | at most 1.5 GB compressed per architecture | release check |
| Forge, default limits | memory = min(4 GB, 40% of RAM); cpus = max(1, cores - 1); pids 2048 | podman flags |
| Concurrent forges | floor(RAM_GB / 4), minimum 1; beyond that, launch is refused with a reason | reconciler |
| macOS VM | memory = clamp(50% of RAM, 2 GB, 8 GB); cpus = cores - 1; disk 40 GB sparse | machine init |
| Disk at rest | images at most 3 GB; Windows root filesystem at most 500 MB; per-project volumes shown with sizes in the menu | `doctor` |
| Floor host (2 cores, 4 GB) | one forge, 1.5 GB memory limit, warning shown at first launch | reconciler |

The numbers are proposals to be replaced by measurements; the structure (every
budget has an enforcing mechanism and a measure) is the design.

## 8. Failure modes

| Failure | Detection | Behaviour | User sees |
|---|---|---|---|
| Podman missing or too old (Linux) | `doctor` at launch | Refuse | One sentence with the install command |
| No tray host (GNOME without extension) | No StatusNotifierWatcher on the bus | Run; fall back to CLI plus a notification explaining | "No tray available; use `tillandsias open`" |
| Tray crashes while cloud is up | Next tray start finds labelled containers | Reattach; nothing was lost (O-C5) | Icon returns in "running" |
| Gateway crashes | Control stream drops; forges get connection refused | Fail closed (O-J3). `--restart=on-failure:3` on the gateway only; after that, "failed" | "Gateway stopped; forges are offline. Restart?" |
| Forge OOM-killed | `forge_exit` event with reason | Do not auto-restart (it would loop); work volume intact | "Forge <p> ran out of memory (limit 4 GB)" with a raise-limit action |
| Disk full in VM or host | Preflight plus pull error classification | Stop the pull, keep partials, offer cache clear | Sizes and one action |
| Network lost mid cold start | Pull error | Resume on retry; no cleanup needed | "Paused; will resume" |
| Network lost while running | Proxy errors are explicit to the agent | Forge keeps working offline; pushes queue in the relay's bare repo (if local mirror enabled, Q6) | Icon unchanged; agent gets readable errors |
| Credential expired or revoked | Relay gets 401 upstream | Relay returns a clear error to git; `approval_request` to tray to re-authenticate | "Git login expired" |
| Keyring locked or absent | Keyring call fails | Refuse to start services needing secrets; never fall back to plaintext | "Unlock your keyring" |
| VM will not boot (macOS) | `ensure_ready` timeout | One automatic recreate of the machine (it holds nothing precious except volumes; see next row), then fail | Reason plus "Reset substrate" |
| Substrate reset destroys volumes | by design | Volumes hold only clones, tools and caches; unpushed commits are the exposure. The relay keeps a copy of every pushed ref; forge-init pushes a WIP ref on clean stop | Reset dialog states exactly what is lost |
| WSL feature absent or old | `doctor` | Refuse with the exact command | One sentence |
| WSL distro terminated underneath us | Control stream drops and `is_running` false | Mark stopped; relaunch converges | "Stopped by Windows; start again?" |
| Sleep/resume | Stream drop then reconnect | Backoff reconnect; VM clocks resync is the substrate's job, checked by gateway `status.time` skew | Nothing unless it fails |
| Port collision on loopback | Random port, retried | Transparent | Nothing |
| podman JSON schema drift | Typed parse failure | Fail the action with the podman version in the message; never guess | "Unsupported podman X.Y" |
| Half-finished update | Manifest swap is last | Old release still intact | Nothing, or "update will retry" |
| Agent tries to reach a blocked host | Proxy 403 | Agent may call `egress/request` | Approval prompt with host and reason |
| Agent deletes its own work tree | n/a | Committed work is in git; pushed work is in the relay | Nothing |
| Two tray instances | Lock file plus single-instance check | Second exits after signalling the first to show its menu | Nothing |

## 9. Languages and build

- Rust for all three of our binaries (`tillandsias`, `gateway`, `forge-init`) in one workspace with a shared types crate, so the API structs the agent sees and the ones the tray parses are the same source.
- No shell scripts in the product path. The forge entrypoint is `forge-init`; installers use each platform's native format.
- Lua: one considered use, user-editable per-project hooks (`on_create`, `on_open`) run by `forge-init` in an embedded interpreter. Not included in v1; a `[setup] run = ["cmd", "arg"]` list in the project's config covers the known need without a second language. Listed so it is a decision, not an omission.
- Go: none of ours. Podman and its helpers are Go and are consumed as-is.
- Images are built and signed in the release pipeline only. User machines pull.

## 10. What v1 is, in a list

1. `tillandsias` binary: tray, CLI, reconciler, three substrate adapters, keyring access, updater.
2. `gateway` image: proxy, git relay, model relay, API.
3. `forge` image with `forge-init`.
4. Windows root filesystem tarball; macOS app bundle with the podman client.
5. One manifest format, one config file.

That is the whole inventory. Anything not on this list needs an obligation
before it is added.
