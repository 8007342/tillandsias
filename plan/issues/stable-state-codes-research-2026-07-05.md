# Stable state codes for host/vm/guest/podman event-driven status — research packet

- class: research
- filed: 2026-07-05
- owner: any
- pickup_role: any
- status: done
- trace: spec:runtime-diagnostics-stream, spec:headless-mode, spec:macos-native-tray, spec:podman-idiomatic-patterns

events:
  - type: claim
    ts: "2026-07-06T18:07:02Z"
    agent_id: "macos-Tlatoanis-MacBook-Air-codex-20260706T1807Z"
    host: macos
    lease_id: "stable-state-codes-research-20260706T1807Z"
    expires_at: "2026-07-06T22:07:02Z"
  - type: completed
    ts: "2026-07-06T18:13:19Z"
    agent_id: "macos-Tlatoanis-MacBook-Air-codex-20260706T1807Z"
    host: macos
    lease_id: "stable-state-codes-research-20260706T1807Z"
    evidence:
      - "Research result section below defines the finite state code set."
      - "Event mapping section specifies observable-stream integration."
      - "Tray message map keeps each chip string <= 37 chars."

## Problem

Tillandsias currently has too many ad hoc UI strings and error renderings:

- tray chip text can describe the same failure differently depending on host
- VM, guest, and podman state are not represented by one stable finite model
- some surfaces still infer state from repeated probes or stale labels
- user-facing text and machine-facing state are coupled too tightly

The user requirement here is:

- no polling loops for state discovery
- state must arrive through observable stream channels
- the user-facing chip must stay tiny
- stable codes must exist so finite-state transitions are unambiguous
- a single state code should map to a short curated message on each host

## Research scope

Define a cross-layer status model that covers:

- host tray
- VM lifecycle
- guest headless
- podman lifecycle
- Linux podman backend states where relevant

The research needs to identify:

1. The minimal finite set of canonical state codes.
2. Which layer owns each code.
3. Which codes are terminal versus transitional.
4. Which codes are user-visible versus internal-only.
5. Which codes should emit events on state change.
6. How error codes should remain stable across releases.
7. How the tray should translate codes into short, curated text.

## Desired properties

- Codes are stable and documented.
- Codes are finite and enumerable.
- Codes are layered, not overloaded.
- State changes are event-driven and observable.
- UI strings are derived from codes, not from raw error text.
- Short messages can include emoji, but remain terse.
- The same code should render consistently on macOS, Windows, and Linux.

## Candidate taxonomy to validate

- host/bootstrap states
- VM materialization states
- guest boot states
- guest auth/login states
- podman/container readiness states
- transport states
- terminal / menu rendering states
- failure states with stable error codes

## Research result - 2026-07-06

The existing tree already has three partial state models:

- `tillandsias_control_wire::VmPhase`:
  `Provisioning`, `Starting`, `Ready`, `Draining`, `Stopping`, `Failed`.
- `tillandsias_host_shell::lifecycle::LifecyclePhase`: the same VM phases
  plus `Idle`, owned by the host tray before a VM exists.
- `tillandsias_host_shell::menu_state::MenuState`: ad hoc UI fields
  (`status_text`, `podman_ready`, `login_runtime_ready`, `GithubLoginState`,
  local/cloud project vectors) rendered into the tray menu and clamped to
  `TRAY_STATUS_CHIP_MAX_CHARS = 37`.

The missing piece is a stable, finite code layer between raw runtime events and
UI strings. The code should be the data model; the tray string should be a
derived rendering.

## Proposed code shape

Use stable lower-case dotted codes:

```text
<domain>.<state>
<domain>.err.<stable-reason>
```

Rules:

- Domains are finite and owned: `host`, `vm`, `guest`, `podman`, `auth`,
  `cloud`, `forge`, `transport`.
- State codes are release-stable. A code can be deprecated, but must not be
  reused with different meaning.
- Error codes use the same namespace with `.err.` and a reason that names the
  failing boundary, not the current English message.
- UI strings, tooltips, logs, and diagnostics derive from the code plus optional
  detail fields. Raw errors never become chip text.
- The event payload carries at least: `code`, `source`, `terminal`,
  `user_visible`, `detail`, `timestamp`, and a monotonic per-source `seq`.

Rust landing point:

```rust
pub enum RuntimeStatusCode {
    HostIdle,
    HostStarting,
    VmProvisioning,
    VmStarting,
    VmReady,
    VmDraining,
    VmStopping,
    VmFailed,
    GuestStarting,
    GuestControlReady,
    GuestFailed,
    PodmanStarting,
    PodmanReady,
    PodmanDegraded,
    AuthGithubLoggedOut,
    AuthGithubReady,
    AuthGithubFailed,
    CloudRefreshing,
    CloudReady,
    CloudFailed,
    ForgeLaunching,
    ForgeReady,
    ForgeFailed,
    TransportConnecting,
    TransportReady,
    TransportFailed,
}
```

The enum names are implementation names; the stable external string remains the
dotted code. The initial implementation can live in `tillandsias-host-shell`
because both macOS and Windows trays already depend on it. When server-push
messages land, `tillandsias-control-wire` should expose the serializable event
shape and host-shell should keep only rendering helpers.

## Finite state set

| Code | Owner | Terminal | User-visible | Existing source |
|---|---|---:|---:|---|
| `host.idle` | host tray | yes | yes | `LifecyclePhase::Idle` |
| `host.starting` | host tray | no | yes | app launch / auto boot |
| `host.quitting` | host tray | no | yes | Quit handler before drain |
| `vm.provisioning` | vm layer | no | yes | `VmPhase::Provisioning` |
| `vm.starting` | vm layer | no | yes | `VmPhase::Starting` |
| `vm.ready` | vm layer | yes | yes | `VmPhase::Ready` |
| `vm.draining` | vm layer | no | yes | `VmPhase::Draining` |
| `vm.stopping` | vm layer | no | yes | `VmPhase::Stopping` |
| `vm.err.failed` | vm layer | yes | yes | `VmPhase::Failed` |
| `guest.starting` | headless | no | yes | vsock listener not ready yet |
| `guest.control.ready` | headless | yes | yes | Hello/HelloAck ready |
| `guest.err.bootstrap` | headless | yes | yes | bootstrap/init failure |
| `guest.err.control-wire` | headless | yes | yes | unsupported/failed wire op |
| `podman.starting` | podman backend | no | yes | socket wait / service boot |
| `podman.ready` | podman backend | yes | yes | `podman_ready == true` |
| `podman.degraded` | podman backend | no | yes | non-fatal service warning |
| `podman.err.unavailable` | podman backend | yes | yes | socket/service absent |
| `podman.err.container` | podman backend | yes | yes | permanent container failure |
| `auth.github.logged-out` | headless/auth | yes | yes | `GithubLoginState::LoggedOut` |
| `auth.github.ready` | headless/auth | yes | yes | `GithubLoginState::LoggedIn` |
| `auth.github.err.failed` | headless/auth | yes | yes | gh/vault auth failure |
| `cloud.refreshing` | headless/auth | no | yes | `CloudRefreshRequest` in flight |
| `cloud.ready` | headless/auth | yes | yes | `CloudRefreshReply` success |
| `cloud.err.failed` | headless/auth | yes | yes | cloud refresh failure |
| `forge.launching` | headless/podman | no | yes | agent launch requested |
| `forge.ready` | headless/podman | yes | yes | container session attached |
| `forge.err.failed` | headless/podman | yes | yes | launch/foreground failure |
| `transport.connecting` | host tray | no | internal | vsock/hvsocket open attempt |
| `transport.ready` | host tray | yes | internal | secure/plain opener success |
| `transport.err.unreachable` | host tray | yes | yes | connect timeout/refused |
| `transport.err.secure-handshake` | host tray | yes | yes | secure channel mismatch |

Internal-only retry/backoff details should be fields on the event, not more
codes. Examples: `attempt=3`, `backoff_ms=800`, `container=tillandsias-proxy`.

## Event mapping

The target flow is event-driven:

1. Host tray emits `host.*` before and after VM lifecycle calls.
2. VM layer maps `LifecyclePhase` and `VmPhase` into `vm.*`.
3. In-guest headless emits `guest.*`, `podman.*`, `auth.*`, `cloud.*`, and
   `forge.*` when its internal state changes.
4. Trays subscribe once and fold events into `MenuState`.
5. `MenuState.status_text` is computed by `render_status_chip(code, detail)`,
   not written directly by individual call sites.

Until `Subscribe`/push variants from order 152 land, existing request/reply
messages can fold into the same state model:

- `VmStatusReply { phase, podman_ready }` -> `vm.*` plus `podman.ready` or
  `podman.starting`.
- `GithubLoginStatusReply` -> `auth.github.ready` or
  `auth.github.logged-out`.
- `CloudRefreshReply` -> `cloud.ready`; a failed fetch becomes
  `cloud.err.failed`.

Once push exists, add one status event topic instead of proliferating one-off
UI fields:

```text
SubscriptionTopic::RuntimeStatus
ControlMessage::RuntimeStatusPush { seq, event }
```

If a narrower wire delta is preferred, `VmStatusPush`, `LoginStatePush`, and
`CloudProjectsPush` can each carry a `RuntimeStatusEvent` alongside their
domain-specific data. The important invariant is one code vocabulary.

## Tray message map

All chip strings below are at or under the 37-character cap. Tooltips and logs
may include richer detail; the chip never renders raw stderr, stack traces, or
multi-line error bodies.

| Code | Chip text |
|---|---|
| `host.idle` | `Idle` |
| `host.starting` | `Starting Tillandsias` |
| `host.quitting` | `Quitting...` |
| `vm.provisioning` | `Preparing VM` |
| `vm.starting` | `Booting VM` |
| `vm.ready` | `VM ready` |
| `vm.draining` | `Stopping forges` |
| `vm.stopping` | `Stopping VM` |
| `vm.err.failed` | `VM failed` |
| `guest.starting` | `Starting guest` |
| `guest.control.ready` | `Guest ready` |
| `guest.err.bootstrap` | `Guest setup failed` |
| `guest.err.control-wire` | `Guest control failed` |
| `podman.starting` | `Starting Podman` |
| `podman.ready` | `Runtime ready` |
| `podman.degraded` | `Runtime degraded` |
| `podman.err.unavailable` | `Podman unavailable` |
| `podman.err.container` | `Container failed` |
| `auth.github.logged-out` | `GitHub login needed` |
| `auth.github.ready` | `GitHub ready` |
| `auth.github.err.failed` | `GitHub auth failed` |
| `cloud.refreshing` | `Loading cloud projects` |
| `cloud.ready` | `Cloud projects ready` |
| `cloud.err.failed` | `Cloud projects failed` |
| `forge.launching` | `Launching forge` |
| `forge.ready` | `Forge ready` |
| `forge.err.failed` | `Forge failed` |
| `transport.err.unreachable` | `VM connection failed` |
| `transport.err.secure-handshake` | `Secure channel failed` |

Rendering priority when multiple codes are active:

1. User-action failures (`forge.err.*`, `auth.*.err`, `cloud.err.*`).
2. Runtime failures (`vm.err.*`, `guest.err.*`, `podman.err.*`,
   `transport.err.*`).
3. Active user action (`forge.launching`, `cloud.refreshing`).
4. Readiness blockers in dependency order: VM, guest, Podman, auth.
5. `runtime.ready` equivalent: show `Runtime ready` when `vm.ready`,
   `guest.control.ready`, and `podman.ready` are all current.

## Error-code naming

Use dotted codes for machine stability and add a short support code only when a
message leaves the local machine (diagnose bundle, bug report, or support log).

Support-code format:

```text
TIL-<DOMAIN>-<REASON>
```

Examples:

- `transport.err.secure-handshake` -> `TIL-TRANSPORT-SECURE-HANDSHAKE`
- `podman.err.unavailable` -> `TIL-PODMAN-UNAVAILABLE`
- `guest.err.bootstrap` -> `TIL-GUEST-BOOTSTRAP`
- `auth.github.err.failed` -> `TIL-AUTH-GITHUB`

The dotted code remains the primary programmatic key. The support code is a
stable display alias for logs and screenshots.

## Follow-on implementation packet

The implementation packet should:

1. Add a shared `RuntimeStatusCode` + `RuntimeStatusEvent` module.
2. Add a `render_status_chip(code, detail)` helper that enforces the 37-char
   cap using `clamp_tray_status_chip`.
3. Map `VmPhase`, `LifecyclePhase`, `GithubLoginState`, `podman_ready`, and
   cloud refresh outcomes into codes.
4. Replace direct macOS tray `status_text` writes with code-derived rendering.
5. Add unit tests pinning every code to a chip string <= 37 chars and asserting
   raw multiline errors are never rendered as the chip.
6. When order 152 lands, carry `RuntimeStatusEvent` over the push stream instead
   of introducing new ad hoc UI fields.

## Exit criteria

- A finite state machine is proposed for host/vm/guest/podman.
- Stable error-code naming is proposed.
- The proposed codes map cleanly onto observable stream events.
- The proposal specifies how the tray converts codes into <=37-char messages.
- The proposal calls out any states that should remain internal-only.
- A follow-on implementation packet can consume the result without guessing.
