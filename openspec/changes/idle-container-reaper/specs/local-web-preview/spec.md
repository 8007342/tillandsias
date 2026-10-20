## MODIFIED Requirements

### Requirement: Existing MCP lifecycle contract

Extend the existing host-services tool registry and dispatch path; do not add a
second MCP server or bypass session identity. Keep the existing result/error
envelope and legacy result fields. Inputs are:

| Tool | Arguments | Meaning |
|---|---|---|
| `publish_local` | `category: "WEB"`, optional `runtime: "auto"\|"static"\|"wrangler"` (default auto) | Start/publish or reconcile this lane's preview; a reaped preview is relaunched on the current source |
| `service_status` | none | Observe, no launch/restart side effects; `serving` says whether the route answers end to end, and after a failed reload `last_failure.previous_preview_serving` says whether the old preview is still served; a reaped preview reports `state: "reaped"` |
| `service_stop` | `category: "WEB"` | Stop container and remove only its route; already absent or reaped is success |
| `service_reload` | `category: "WEB"` | Restart the recorded profile on the same live source and URL; a preview that exited or was reaped is recreated the same way; absent with no record is `not_running` |
| `service_logs` | `category: "WEB"`, optional `lines` (1-500, default 100) | The preview's own output (stdout and stderr, tail kept, 64 KiB cap), its state and exit code; only for the lane that owns it; a reaped preview answers `state: "reaped"` with the retained tail |

Removing a preview container never waits a stop grace period (1723-2fiq):
the static server is PID 1 and ignores SIGTERM, so a graceful remove outlived
the per-call budget and every reload timed out.

Idle previews are terminated by the host (`container-idle-reaper`, class
`preview`, budget at least 3 hours). Serving local content is therefore an
idempotent service: a reaped preview is relaunched on demand by
`publish_local` or `service_reload` from the lane's reap record and serves
the source as it is now. A reaped preview MUST be a defined status, never an
error: `service_status` returns `state: "reaped"`, `reaped_at`,
`reason: "idle:<budget>"`, `relaunch: "publish_local"`, the `url` it will
have again, `serving: false` and `route_ready: false`. A relaunch that
needs a missing image inherits the image-ensure contract (`preparing` with
`retry_after_s`, never an agent-visible retry loop). The forge's
instructions MUST tell agents, in one sentence, that idle containers get
terminated and that `publish_local` relaunches the preview.

Initial-phase prerequisite: the host binary MUST be built with the `tray`
feature and its existing authenticated MCP listener must be available. Moving
the listener or lifecycle out of that feature is outside this phase. Listener
startup/connection failure MUST be reported as unavailable; it cannot be
reported as a successfully published or stopped service.

Implementation seam agreed by parent, Sol and Terra:
`crate::local_web_preview::{publish(project,instance,runtime,debug),
status(project,instance),stop(project,instance,debug),reload(project,instance,debug)}`.
Each function is async and returns `Result<serde_json::Value,String>`.
`project` and `instance` originate from the authenticated listener identity,
not caller-supplied tool arguments.

Reject invalid types and unsupported runtime/category values before side effects.
`publish_local`/`service_reload` succeed only after runtime readiness and effective
router configuration are verified. Repeated publication MUST leave one container
and one route. Preserve unrelated routes, including authenticated routes.
Serialize same-project mutations. If replacement fails, report failure and remove
any stale route to a dead backend; never return `running` for that result.

Results retain `state` (`running`, `stopped`, `starting`, `failed`, `reaped`,
or `unknown`) and `url` on successful publish. Add `runtime`, `watch` (boolean), and `tls`:
`{enabled: boolean, host_trust: "unknown"|"verified"|"untrusted", diagnostic: string}`.
Status additionally reports route readiness as `route_ready: boolean` and a
bounded diagnostic when unhealthy. `unknown` distinguishes inspection/transport
failure from confirmed absent/stopped. Error envelopes retain code `-32000` and
carry a stable reason in `message` (e.g. `live_worktree_unavailable`,
`lane_conflict`, `invalid_runtime`, `runtime_not_ready`, `router_not_ready`,
`not_running`, `remote_binding_forbidden`). Do not return secrets or raw env.

> Delta: on 2026-10-19 a removed preview answered `not_running: no preview
> container; publish_local first` and `not_running: no preview to reload`,
> which agents read as failures; nothing told an agent that idle previews are
> terminated.

#### Scenario: Status after a reap
- **WHEN** the reaper has removed the lane's idle preview and the lane calls `service_status`
- **THEN** the reply is `state: "reaped"` with `reaped_at`, `reason`, `relaunch` and `url`, and no error envelope

#### Scenario: Publish relaunches and serves new content
- **GIVEN** a reaped preview and an edit to `index.html` made after the reap
- **WHEN** the lane calls `publish_local` with no `runtime`
- **THEN** the preview runs again on the same URL with the recorded runtime
- **AND** the next uncached request returns the edited file

#### Scenario: Reload after a reap
- **WHEN** the lane calls `service_reload` on a reaped preview
- **THEN** it is recreated from the reap record, not refused with `not_running`

#### Scenario: Agents are told
- **WHEN** a forge starts
- **THEN** its instructions contain the sentence that idle containers are terminated and that `publish_local` relaunches the preview
