# 2. Design — Blind Designer A

`[C]` = coincides with a hint I was involuntarily exposed to (see method.md);
do not count as independent agreement. `[verify]` = version-sensitive fact
recalled from memory. Obligation IDs in parentheses.

## 2.1 Shape in one paragraph

Three layers. **(1) The tray** — one small native Rust process, event-driven,
which owns the UI, the host keychain and the *intent* ("region up/down, forge
X open"). **(2) The substrate** — a Linux userland with rootless podman and a
`systemd --user` manager: the host itself on Linux, a dedicated VM on macOS, a
dedicated WSL2 distro on Windows. **(3) The region** — a fixed set of small
services plus N forges, expressed as Quadlet units (podman's systemd generator)
so that the *same unit files* define the region on all three platforms and
systemd, not the tray, supervises it. The tray renders units, flips targets and
listens to events; it never sits in a data path.

```
 host desktop                     substrate (Linux userland, rootless)
+-----------+   intent/events    +-----------------------------------------------+
| tray(Rust)|<------------------>| systemd --user: tillandsias-region.target     |
| keychain  |  D-Bus (L)         |  +--------+ +------+ +------+ +-----+ +-----+ |
| menu      |  podman API (M,W)  |  | edge   | | egress| | vault| | git | | llm | |
+-----------+                    |  +---+----+ +---+---+ +--+---+ +--+--+ +--+--+ |
   127.0.0.1:<port> ingress ----------->|          |  net: svc (internal)        |
                                 |   net: p-<id> (internal, isolated) per project|
                                 |  +-----------+   +-----------+                |
                                 |  | forge A   |   | forge B   |   ...          |
                                 |  +-----------+   +-----------+                |
                                 +-----------------------------------------------+
```

## 2.2 Tray process model (OVH-1,2,8,9; TRAY-*)

- **Language/stack:** Rust, single static-ish binary, no webview, no async
  runtime with a timer wheel ticking. Linux: StatusNotifierItem +
  `com.canonical.dbusmenu` over the session bus (`zbus`). macOS: `NSStatusItem`
  / `NSMenu` (`objc2`). Windows: `Shell_NotifyIconW` + popup menu
  (`windows-rs`), handles `TaskbarCreated`. One `Tray` trait, three backends,
  each < ~1.5k lines; no cross-platform GUI toolkit (they bring GTK or a
  browser and break OVH-1).
- **Threads:** main thread blocked in the native event loop; one worker thread
  blocked on a channel, woken only by (a) a menu action, (b) a substrate event,
  (c) a single-instance IPC message. **No periodic timers at all** (OVH-2).
  Anything that looks like polling (startup progress) is a blocking read on a
  stream with a deadline, alive only during a transition.
- **State:** an in-memory snapshot of the region rendered into the menu; the
  menu is built from the snapshot, never by asking podman (TRAY-5).
- **Single instance:** a lock + local socket (unix socket in
  `$XDG_RUNTIME_DIR`; named pipe on Windows); the same binary invoked as
  `tillandsias open <path>` forwards to the running instance (TRAY-7, LAU-1).
  CLI and tray are one binary — the CLI is the tray's test interface too.
- **Secrets custody:** long-lived credentials live only in the OS store —
  Secret Service (L), Keychain (M), Credential Manager/DPAPI (W) — and are
  released to the region only at region start (2.5).
- **Notifications:** native (`org.freedesktop.Notifications`,
  `UNUserNotificationCenter`, toast) for approvals (TRAY-8).
- **No tray available (TRAY-4):** the binary detects a missing
  StatusNotifierWatcher and stays fully usable via CLI; it waits for the
  watcher's bus name to appear (a D-Bus name-owner signal, not a poll).
- **Glue language:** project/region policy that changes often (egress
  allowlists per ecosystem, unit templates, capacity rules) lives in **Lua**
  evaluated by an embedded interpreter (`mlua`, vendored Lua 5.4, ~300 KB) in
  the tray at transition time only. No shell scripts, no Python anywhere on the
  host side: Windows has neither by default.

## 2.3 Substrate per platform (POD-*, OVH-3,5,6, LAU-3)

Common contract a substrate must provide: rootless podman >= 5.x `[verify]`
with Quadlet, netavark + aardvark-dns, cgroups v2 with cpu/memory/pids
delegated, `systemd --user`, and a way for the host to (a) place files, (b)
start/stop a target, (c) receive state events, (d) reach 127.0.0.1 ingress.

| | Linux | macOS | Windows |
|---|---|---|---|
| Userland | the host user session | dedicated VM `[C]` | dedicated WSL2 distro `[C]` |
| How provided | host podman, run with our own `--root/--runroot` + `CONTAINERS_STORAGE_CONF` so we have a private store (POD-3) `[C]` | `podman machine` named `tillandsias` (applehv/vfkit, or libkrun) `[verify]`; we do *not* use the user's default machine | `podman machine` named `tillandsias` on the WSL provider; own distro, automount of `/mnt/c` disabled, interop disabled (PRJ-3) |
| Tray → substrate control | systemd user manager over D-Bus (already connected for SNI) | podman REST API over the machine's forwarded unix socket; unit control via `podman machine ssh`-equivalent channel only at transitions | same, over named pipe |
| Events to tray | systemd `PropertiesChanged` signals + `sd_notify` status from units | podman `/events` stream filtered on our label, held only while region is up | same |
| "Stopped" means (OVH-3) | target stopped; zero processes | VM process absent | our distro terminated; we do not hold WSL's utility VM open |
| VM sizing | n/a | RAM = min(50% host, 2 GB + 1.5 GB x forge slots); memory ballooning on; sparse disk with TRIM | `.wslconfig` is global and the user's — we do **not** edit it; we recommend `autoMemoryReclaim` and report vmmem honestly (OVH-5) |
| Privilege at install | none; if subuid/subgid or cgroup delegation are missing we diagnose, we do not sudo | none `[verify]` | enabling WSL2/VM Platform needs admin and maybe a reboot — done once by the OS's own `wsl --install`, declared before download (LAU-3) |
| Arch | amd64, arm64 | arm64 (Intel: Q7) | amd64 (arm64: Q7) |

Why `podman machine` rather than a hand-rolled VM: it is the supported path,
it already solves socket forwarding, port forwarding (gvproxy), image updates
and Rosetta; a private VM is a second product to maintain. Cost: we inherit its
boot time and its opinions (Q13 asks what the incumbent does and why).

Why Quadlet/systemd as the supervisor: it gives restart policy, dependency
order, **socket activation** (the key to "little"), resource control and
journald on all three substrates for free, and it means the tray can die
without the region noticing (LAU-5). Cost: Linux hosts without systemd are
unsupported or need a fallback supervisor (Q14).

Idle ladder (resolves OVH-6 vs LAU-2): last forge stops → after 2 min the
on-demand services have exited by themselves (socket-activated, idle-exit) →
after 10 min `[P]` with zero forges a systemd timer *inside the substrate*
stops the target; on M/W the tray, on receiving that event, stops the
machine. The timer lives in the substrate, so the tray still has no timers.

## 2.4 Container topology and services (CLD-*, PRJ-2, AGT-*)

**One image for all services.** A single Go multi-call binary `regiond`
(`regiond edge|egress|vault|git|llm|log`), in one distroless image (~25 MB),
run as six containers with different entrypoints, read-only rootfs, all caps
dropped, `no-new-privileges`, distinct UIDs. One image = one pull, one
signature, shared page cache; six containers = six blast radii. Go because
these are network daemons where its HTTP/TLS/proxy libraries are the mature
choice; nothing in the region is bash or Python.

**Networks.** `svc` (internal): services only. `p-<id>` (internal, netavark
`isolate`): one per project, containing that forge plus the service
containers that forges may call (`edge`, `egress`, `git`, `llm`). `out`: the
only network with a route to the world; only `egress`, `git` (relay side) and
`llm` (upstream side) are on it. A forge has **no default route**. Forges
resolve only region names via aardvark; they have no external DNS (AGT-4).

| Service | Role | Listens for forges as | Always on? | Idle budget |
|---|---|---|---|---|
| `edge` | Ingress router. Binds `127.0.0.1:<port>` on host (via pasta/gvproxy/WSL localhost forwarding); routes `<forge>.<project>.localhost` → forge ports; serves the forge's terminal/editor/preview URLs; authenticates the human with a per-session cookie minted by the tray | — (inbound only) | yes | 15 MB |
| `egress` | Forward proxy, HTTP CONNECT + plain HTTP. Default deny; per-project allowlist by hostname/SNI; **no TLS interception** by default. Denials return a structured 403 body the agent can read and act on. Logs every decision | `http://egress.region:3128` | yes | 15 MB |
| `vault` | Identity + secrets. Holds upstream credentials **in memory only** (tmpfs, never on a volume), handed over by the tray from the OS keychain at region start. Mints short-lived per-forge tokens (workload identity) that the other services verify. Never reachable from a forge network | not reachable by forges | yes | 10 MB |
| `git` | Source mirror: bare repos on a volume, smart-HTTP. Forge clones/pushes here with its forge token. Upstream fetch on demand; upstream push relay applies policy (branch patterns, size, optional human approval) and uses the upstream credential obtained from `vault` | `http://git.region/<project>.git` | socket-activated | 0 when idle |
| `llm` | Inference gateway. OpenAI-compatible and Anthropic-compatible endpoints; swaps the forge token for the real provider key; per-project budgets, rate-limit backoff as structured errors; routes to remote providers or to a local model server | `http://llm.region/v1` | socket-activated | 0 when idle |
| `log` | Collects container stdout/err via journald, egress decisions and inference metering into a bounded ring (size- and age-capped), streamable to the tray/edge. Ephemeral with the region `[C]` | — | socket-activated | 0 when idle |
| `model` (optional) | Local model server (llama.cpp server). Only on hosts passing a capacity check; off by default on the floor host (XP-4) | via `llm` only | on demand | 0 when idle |
| `forge-<project>` | The tenant. Project-declared image; non-root; writable volume for the working copy; tmpfs home | — | per user intent | per-project cap |

Always-on idle set: edge + egress + vault ≈ 40 MB, well under OVH-4's 150 MB.
Socket activation is done by systemd `.socket` units in the substrate passing
the listening fd into the container (podman preserves activation fds
`[verify]`); the service exits after N idle seconds. This gives on-demand
start with **no container holding the podman socket** (POD-2, CLD-4).

**What the forge sees** (AGT-1,2,5) — plain environment, nothing else:

```
HTTP_PROXY=HTTPS_PROXY=http://egress.region:3128   NO_PROXY=.region
OPENAI_BASE_URL=http://llm.region/v1     OPENAI_API_KEY=$FORGE_TOKEN
ANTHROPIC_BASE_URL=http://llm.region     ANTHROPIC_API_KEY=$FORGE_TOKEN
git remote origin = http://git.region/<project>.git   (credential helper → $FORGE_TOKEN)
REGION_MCP=http://edge.region/mcp       # status, "request egress to host X", budgets
```

`$FORGE_TOKEN` is a podman secret mounted at start, valid only on that
project's network, for that project, until the forge stops. An unmodified
agent CLI believes it is talking to its provider with an API key; the key is
worthless outside the region. Exfiltrating it buys nothing; exfiltrating data
requires an allowlisted destination (AGT-3). Plain HTTP inside the region is
acceptable because each project network is isolated and single-tenant;
mTLS is a later hardening, not a launch need.

**How source gets in** (PRJ-1,3,4): the forge never bind-mounts the host
working tree. `tillandsias open <path>` reads the repo's remote, the `git`
service mirrors upstream (or, for a local-only repo, the tray pushes the
local repo into the mirror over the edge), the forge clones from the mirror.
The human pulls the agent's branches back from the mirror or from upstream.
This is the single biggest UX trade in the design: it buys host isolation and
identical behaviour on M/W (where cross-VM bind mounts are slow and leak
permissions) at the price of "my uncommitted files are not there". (Q9, Q12)

**Human access** (PRJ-7): `edge` serves a web terminal (ttyd-style, built into
`regiond edge`) and proxies whatever the forge exposes (a web editor, a dev
server preview) at `http://<name>.<project>.localhost:<port>` — `*.localhost`
resolves to loopback in browsers without touching hosts files. The tray menu
item "Open" launches the default browser on that URL. No tray-owned windows.

## 2.5 Lifecycle

**Cold start (fresh install).** (1) Preflight in Rust: substrate present and
in range? virtualization enabled? disk free >= cap? cgroup delegation?
subuid? Each failure maps to one plain sentence and one action (POD-4,6).
(2) M/W: create the dedicated machine. (3) Pull the `regiond` image and the
default forge image by digest from the manifest compiled into this tray
version; verify signatures (sigstore policy in `policy.json`) (POD-5). Pulls
are resumable per layer. (4) Render Quadlet units from Lua templates into the
substrate's unit dir; `daemon-reload`. (5) Start the target. Every step is
"check, then make true", so re-running after a crash converges (LAU-4).

**Warm start.** L: start target → edge/egress/vault up (< 2 s) → vault asks
the tray for credentials over the control channel → forge unit starts. M/W:
machine start first (the dominant cost; LAU-2's 30 s is mostly this).

**Credential hand-over.** The tray reads the OS keychain and streams secrets
to `vault` over a one-shot authenticated channel (unix socket on L; over the
machine's forwarded socket on M/W). `vault` keeps them in RAM. Region stop =
secrets gone. Nothing plaintext at rest inside the substrate `[C]`.

**Forge open / close.** Open = ensure project network, ensure mirror repo,
mint token, start `forge-<id>` unit with cgroup limits from the capacity
rule. Admission control: if free RAM < forge minimum, the tray says "stop
another forge first" instead of starting (CLD-7, XP-2). Close = stop unit;
working volume kept until "destroy".

**Reset (LAU-6).** Three depths, each a superset: *forge* (delete its
container + volume; mirror keeps pushed work), *region* (delete all our
containers, networks, volumes, units — selected by our label and our storage
root only), *substrate* (L: `rm -rf` our private storage root after
`podman unshare`-safe removal; M/W: `podman machine rm tillandsias`). Reset
must work when podman state is corrupt, so substrate reset never depends on a
healthy podman on M/W, and on L falls back to removing the private root
directly. Because our store is private, there is no path by which reset
touches the user's containers (POD-3). Keychain entries survive reset unless
the user picks "also sign out".

**Updates.** The tray binary carries a manifest {regiond digest, forge base
digest, machine image version, unit template version}. Tray self-update:
download, verify signature, atomic rename, apply on next tray start (never
mid-session). Region update: pull new digests side by side, restart services
one at a time at the next region start; previous digest kept for one version
as rollback. Update checks happen at tray start and on "region up" only —
no background timer (OVH-2). A running forge is never restarted by an update.

**Tray crash / logout / sleep.** Region continues under systemd (LAU-5).
On restart the tray rebuilds its snapshot from the substrate (list units /
containers by label) and resubscribes. After host sleep on M/W the event
stream may be dead: the tray re-syncs on the OS wake notification, an event,
not a poll.

## 2.6 Resource budgets (targets, floor host) `[P]`

| Item | Budget | Enforced by |
|---|---|---|
| Tray RSS / wakeups, region stopped | 15 MB / < 1 per min | design (no timers), CI gate |
| Tray RSS, region up | 20 MB | CI gate |
| Always-on services | 40 MB target, 150 MB cap, 0.5% core | `MemoryMax=`, `CPUWeight=` in units |
| On-demand services, each | 64 MB cap, idle-exit 120 s | units |
| Forge default | 2 GB RAM, 2 CPUs, 4096 pids, 10 GB volume | `--memory`, `--cpus`, `--pids-limit`, volume quota where the fs supports it (Q15) |
| Forge slots | floor(( host RAM - 2 GB OS reserve - VM tax ) / forge RAM): 1 on a 4 GB Linux floor host, 2 on 8 GB M/W | admission control in tray (Lua rule) |
| macOS VM | declared tax: ~250-400 MB resident idle guest `[verify by measurement]` | balloon + stop when idle |
| Windows | declared tax: vmmem as measured | distro terminate when idle |
| Disk | tray < 30 MB; base images < 1.5 GB; total cap default 20 GB, user-set | preflight + refusal to pull past cap; prune of our store only |
| Proxy/gateway latency | < 5 ms p50 added | bench in CI |

## 2.7 Failure modes

| Failure | Detection | Response |
|---|---|---|
| Podman missing / out of range | preflight | one sentence + install action; never auto-sudo |
| Rootless prerequisites missing on Linux (subuid, cgroup delegation, user namespaces disabled) | preflight probes | precise diagnosis; refuse to start rather than run degraded-insecure (POD-6) |
| No tray host on Linux desktop | watcher name absent | CLI works; one-time notification; wait on name-owner signal |
| VM/distro fails to boot; virtualization disabled; WSL not installed | machine start error classification | mapped message; "reset substrate" offered |
| Disk full / cap reached | preflight + ENOSPC classification on pull | stop pulling, offer prune of our store; never leave partial layers counted as valid |
| Service crash loop | systemd `StartLimit*` → unit failed event | icon "degraded", menu shows which service and last log line; forges stay up if their dependency is not the one down |
| `vault` restart (secrets lost from RAM) | vault emits "need credentials" event | tray re-supplies silently from keychain; if keychain locked, notification |
| Keychain locked / absent (headless Linux, no Secret Service) | error from OS API, with timeout | region starts without upstream credentials; mirror and inference show "sign-in needed"; never fall back to a plaintext file |
| Upstream provider rate limit / outage | `llm` classifies 429/5xx | structured error to agent with `retry_after`; tray shows provider state; no retry storm |
| Egress denied | proxy decision | structured 403 to the agent; coalesced notification "forge X wants host Y" with allow-once / allow-for-project |
| Corporate proxy / TLS-inspecting network | first upstream failure classification | `egress` chains to the host's configured proxy; custom CA accepted via tray setting only |
| Host sleep/resume, clock jump in VM | OS wake event; token expiry errors | re-sync; tokens are verified with leeway and re-minted |
| Tray killed mid-transition | next start | convergent re-run of the transition (LAU-4) |
| Forge OOM | cgroup OOM event | forge marked "out of memory", not auto-restarted in a loop; other forges unaffected |
| Port already in use on host | bind failure | pick next port from a small range; the menu always shows the real URL |
| Two OS users on one machine | per-user everything | no shared state; ports chosen per user |
| User's own podman pruned/reset | not affected (private store / machine) | — |
| Update fails verification | signature check | keep current, report; never run unverified |

## 2.8 Traceability (design element → obligations)

- No-timer native tray, no webview → OVH-1,2,9; TRAY-2,5
- Supervisor in substrate (systemd/Quadlet) → LAU-4,5; CLD-4; POD-1,2
- Private store / dedicated machine → POD-3; LAU-6
- Socket-activated multi-call `regiond` → OVH-4; CLD-3,4; POD-2
- Per-project isolated internal networks, no default route → PRJ-2; AGT-3,4; CLD-2
- Token-swapping `git` and `llm`, RAM-only `vault`, OS keychain → AGT-2,3,9
- Mirror instead of bind mount → PRJ-3,4; CLD-1,6; AGT-6
- `edge` on loopback with `*.localhost` → CLD-2; PRJ-7; TRAY-1
- Idle ladder in substrate → OVH-3,6 vs LAU-2
- Lua policy, digest manifest in tray → POD-5; XP-3; CLD-6

Obligations with **no** strong design answer yet: TRAY-4 on GNOME (we only
degrade to CLI), OVH-5 on Windows (we can report vmmem but not control it),
PRJ-5 disk quotas (filesystem-dependent), AGT-5 for agents that do not honour
base-URL or proxy environment variables.
