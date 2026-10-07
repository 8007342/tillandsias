# Local web preview

@trace spec:local-web-preview

## Status

status: draft
version: v1
id: enclave.web.local-preview@v1
verification: S0 (design; executable coverage and live evidence pending)
previous: none; additive runtime profile over enclave-service-catalog

## Purpose and authority

Operator direction, 2026-10-07, recorded in
`plan/issues/local-web-preview-design-2026-10-07.md`: agents publish the live
forge project to a sibling Wrangler local-development container and the host
browser reaches it through the local HTTPS router. No production deployment,
Chromium sibling, tray UI change, or host CA trust-store modification is approved.

## Requirements

### Requirement: Session-bound live source

All lifecycle calls MUST use the project and forge lane authenticated by the
existing MCP socket. Caller-supplied project labels, host paths, image names,
commands and port mappings MUST NOT select resources. Resolve the running
forge's actual worktree, not `host_project_root()/project`, a git mirror, a
second clone, a commit snapshot, or an exported copy. The sibling MUST see
uncommitted and untracked source changes through the same backing filesystem.
An absent forge or unresolvable live mount MUST fail explicitly before replacing
a working service. Support the actual tmpfs-in-forge layout: an ordinary bind of
the host's similarly named path does not satisfy this requirement. Preserve
credential quarantine; sharing the worktree MUST NOT share the forge root,
control socket, git credential broker, or host home.

#### Scenario: Uncommitted assets change

- **GIVEN** an authenticated lane with an assets-only Wrangler project
- **WHEN** its agent edits `var/html/index.html` without committing
- **THEN** the next uncached request observes the edit through the same preview URL
- **AND** a second lane/project cannot read or replace this lane's source

One WEB service per project remains the compatibility model. Record its owning
lane. A second lane of the same project MUST receive `lane_conflict` on a
mutation while the service is owned by another live lane; no implicit takeover.
Status MAY report that conflict without exposing private filesystem paths.

### Requirement: Shared source preserves the bounded HOT storage contract

`forge-hot-cold-split` remains authoritative. Sharing source MUST preserve its
four HOT roots: `/opt/cheatsheets` (8 MB, 0755), `/home/forge/src` (per-launch
`compute_hot_budget()` MB, 0777), `/tmp` (256 MB, 01777), and `/run/user/1000`
(64 MB, 0700). Their backing MUST remain kernel tmpfs with independently
enforced mount caps and ENOSPC on overflow; no disk-filesystem fallback or
application-managed source spill is allowed. Kernel swap under the approved
existing ForgeBudget below is permitted. Keep the existing per-launch budget computation and RAM
preflight. Host owner-only (0700) lane-parent permissions do not replace the
specified container-visible source-root permissions or its kernel size cap.

The proposed path
`$XDG_RUNTIME_DIR/tillandsias/lanes/<project>-<instance>/workspace` is only a
mount-location proposal. A subdirectory of the user's shared runtime tmpfs is
NOT a per-lane bounded filesystem. Merely checking tmpfs filesystem type, using
0700, polling usage, or setting a container memory ceiling MUST NOT be accepted
as equivalent to the source mount's `size=<budget>m` ENOSPC guarantee. Fail
explicitly before source launch/publication if the required bound cannot be
provided; never silently substitute the host checkout or a disk-backed volume.

A shared implementation MUST preserve the existing host-tier `ForgeBudget`
(`memory.max`, `memory.high`, `memory.low`, `memory.swap.max` and PIDs) unchanged
and prove accounting/enforcement against actual shared-source allocations,
not just argv presence. Governing provenance is the explicit operator ruling
on order 437 recorded in
`plan/issues/forge-memory-swap-architecture-design-2026-09-26.md` and the newer
approved delta at
`openspec/changes/forge-swap-backed-memory-ceiling/specs/forge-hot-cold-split/spec.md`.
Positive bounded swap is intentional; this feature MUST NOT restore the stale
canonical no-swap/sum-of-mounts formula or change host swap provisioning.
Preserve implemented cgroup budget encoding, rather than mechanically
substituting the delta's illustrative `--memory-swap` flag spelling.
Memory charging to the host/controller, another lane or a mount helper MUST NOT
bypass the owning lane's approved memory/swap budget. Creating a filesystem in a host namespace
does not establish which cgroup pays for its pages; measure actual allocation
and reclaim behavior. An OOM at the container limit is not evidence of the
filesystem-cap ENOSPC requirement. Sibling runtime private state remains
separate from source and must not become an additional forge HOT root.

The same newly initialized backing filesystem may be mounted read-write at
the forge's unchanged `/home/forge/src` for the normal mirror clone, then exposed
only through validated read-only selected config/assets/Worker paths to the
sibling. Preserve file-watch visibility including atomic-save/rename behavior;
single-file binds that pin obsolete inodes do not satisfy watch semantics.
Verify shared SELinux labels and UID mappings without broadening access to
other lanes, host paths or secrets. A label option such as `ro:z` alone is not
proof of either isolation or functional sharing.

Bounded accepted watch limitation: when a root configuration or root Worker
entrypoint must be mounted as an individual file, atomic replacement may keep
the sibling on the old inode until `service_reload` remounts it. The publish and
status diagnostics MUST explicitly disclose that reload requirement for those
file mounts; do not advertise complete automatic watch for them. Directory
mounts remain preferred and MUST observe atomic-save replacements and new
assets automatically. This exception does not permit silent stale assets or
relax local-only binding validation after live config edits.

Preview stop/reload MUST NOT destroy a live forge's source. Forge termination
MUST revoke/stop its preview and release the shared source mount and data,
including when the sibling otherwise keeps a mount reference alive. A new
launch generation MUST receive fresh source and budget even if project/instance
names are reused. Crash recovery must remove only verified stale lane-owned
resources, never another live generation. No persistent named-volume reuse may
silently recover old source or old size options.

#### Scenario: Bounded sharing, not a runtime-directory approximation

- **GIVEN** a disposable lane with computed source budget and a live sibling
- **WHEN** the forge writes beyond the source filesystem cap
- **THEN** writes fail with ENOSPC at the per-lane cap and the other lane remains usable
- **AND** mount/size, cgroup memory and swap evidence identify the real bounds
- **WHEN** the forge is torn down and relaunched with the same project name
- **THEN** no old sibling or old source bytes survive into the new generation

Architectural exception is PROPOSED, NOT ACTIVE: replacing the canonical
`--tmpfs=/home/forge/src:size=<budget>m,mode=0777` launch mechanism with a
shared, independently size-capped kernel tmpfs backing mounted at that same
root. The canonical spec currently requires the literal `--tmpfs` mechanism.
Equivalent behavior alone does not reconcile that wording: integration must
record the evidence and narrowly amend that mechanism requirement before
activation. No waiver of size/ENOSPC, four roots, memory/swap, preflight or
ephemerality is proposed. Until a rootless supported mechanism proves these
properties, shared-source provisioning remains an explicit unresolved obligation.

2026-10-07 review checkpoint: Sol reports a successful disposable rootless
named-tmpfs proof (4 MiB cap/ENOSPC, readonly volume-subpath sharing, writer
cgroup shmem and keep-id UID 1000). Full-launch lifecycle evidence remains
pending. Parent resolved memory-policy precedence for THIS feature: preserve
the newer approved positive-swap `ForgeBudget` policy cited above. Unsynced
canonical no-swap text remains a pre-existing spec-sync residual under
1552-e3wf, not an implementation requirement to reverse that policy. This
resolution does not sync/activate the entire swap change, authorize host swap
provisioning, or permit persistent/disk-backed project source. Kernel-managed
swap under the existing budget is distinct from a disk filesystem source
fallback. The small writer-cgroup proof is not complete launch-budget or
generation-cleanup acceptance.

### Requirement: Allowlisted local runtime profiles

Category remains `WEB`. The host MUST choose only managed profiles `static` and
`wrangler`; these are not arbitrary commands or images. `runtime=auto` selects
Wrangler when exactly one root `wrangler.jsonc`, `wrangler.json` or
`wrangler.toml` exists, otherwise static. Multiple configs MUST fail as ambiguous.
Explicit Wrangler without a config MUST fail. Invalid Wrangler configuration
MUST NOT silently fall back to static. Wrangler itself parses its configuration;
hand-parsing JSONC as JSON or requiring `main` is incorrect.

Wrangler MUST execute `wrangler dev --local --ip 0.0.0.0 --port 8080` from the
project root with an explicit selected config and private ephemeral writable
runtime state/cache outside the source mount. Source SHOULD be read-only to the
sibling; any necessary exception requires a narrow documented path. Watch local
file changes by default. Explicit reload restarts/reloads the preview runtime,
not the host browser and not merely Caddy. Browser auto-refresh is not required.
No `deploy`, login, production token, `--remote`, remote resource binding or
Cloudflare production operation may be introduced. Remote-enabled project
bindings MUST be refused or disabled with an explicit diagnostic before serving.
Use a pinned Wrangler/Node/workerd-compatible managed image; no launch-time
unpinned `npx` fetch. Package scripts are not executed as the preview entrypoint.

#### Scenario: Actual target shape

- **GIVEN** `wrangler.jsonc` with `assets.directory="./var/html"`, no `main`
- **WHEN** `publish_local` runs in auto mode
- **THEN** local Wrangler serves that directory using its asset semantics
- **AND** `/wrangler.jsonc` and files outside the configured asset directory are not served

The existing `images/web` busybox runtime and its `web-image` contract remain
the static compatibility profile. The new runtime belongs in
`images/web-wrangler`, not a silent enlargement of the less-than-10MB static image.

### Requirement: Existing MCP lifecycle contract

Extend the existing host-services tool registry and dispatch path; do not add a
second MCP server or bypass session identity. Keep the existing result/error
envelope and legacy result fields. Inputs are:

| Tool | Arguments | Meaning |
|---|---|---|
| `publish_local` | `category: "WEB"`, optional `runtime: "auto"\|"static"\|"wrangler"` (default auto) | Start/publish or reconcile this lane's preview |
| `service_status` | none | Observe, no launch/restart side effects |
| `service_stop` | `category: "WEB"` | Stop container and remove only its route; already absent is success |
| `service_reload` | `category: "WEB"` | Restart the recorded profile on the same live source and URL; absent is `not_running` |

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

Results retain `state` (`running`, `stopped`, `starting`, `failed`, or `unknown`)
and `url` on successful publish. Add `runtime`, `watch` (boolean), and `tls`:
`{enabled: boolean, host_trust: "unknown"|"verified"|"untrusted", diagnostic: string}`.
Status additionally reports route readiness as `route_ready: boolean` and a
bounded diagnostic when unhealthy. `unknown` distinguishes inspection/transport
failure from confirmed absent/stopped. Error envelopes retain code `-32000` and
carry a stable reason in `message` (e.g. `live_worktree_unavailable`,
`lane_conflict`, `invalid_runtime`, `runtime_not_ready`, `router_not_ready`,
`not_running`, `remote_binding_forbidden`). Do not return secrets or raw env.

### Requirement: HTTPS routing and honest trust

The successful preview URL MUST be
`https://www.<project>.localhost[:actual_tls_port]`, routed by the existing
`tillandsias-router` using the existing local CA machinery. A TLS listener may
be added on a loopback-only port; existing HTTP routes remain compatible. The
preview container MUST NOT publish a host port. Keep Caddy admin private and
use the existing in-container reload mechanism. TLS certificate SAN must cover
the actual returned multi-label hostname; `*.localhost` alone does not cover
`www.<project>.localhost`. Probe with the actual hostname/SNI and CA verification.

Narrow routing amendment proposed by this draft: the routing spec's
exactly-one-host-address rule continues to govern the existing HTTP ingress
`127.0.0.1:<http_host_port> -> :8080`. For this preview profile only, permit
one additional `127.0.0.1:<tls_host_port>` mapping to the router's TLS listener.
The two ingress mappings are the complete allowed set; no wildcard-address,
admin-port or per-service publication is permitted. Preserve the HTTP listener,
its port selection and existing routes. This is a draft exception pending
integrator reconciliation/verification, not activation of a changed routing spec.

Trust of the CA in a runtime container is NOT evidence of host-browser trust.
Default `host_trust=unknown` unless a host-side verification actually establishes
it. An explicitly CA-verified curl is transport evidence, not browser-trust
evidence. A browser trust failure must be reported as such without calling the
runtime stopped. MUST NOT run trust-store installation commands, disable TLS
verification, or silently return HTTP as a successful HTTPS preview.

#### Scenario: Host lacks CA trust

- **WHEN** the backend and CA-verified HTTPS route work but browser trust fails
- **THEN** status distinguishes healthy runtime/TLS from untrusted or unknown host trust
- **AND** diagnostics explain the separate approval needed to install trust
- **AND** no trust-store bytes are changed

## Sources of truth and limits

### Approved Wrangler parser adapter boundary

Operator approval recorded 2026-10-07 in
`plan/index.d/20261007t192318z-local-web-preview-adapter-approval-yoga.yaml`
permits the small Tillandsias-owned JavaScript adapter to the pinned npm
Wrangler parser. This is a local-web-preview-only exception to the default
runtime-helper language policy, not a general JavaScript execution surface.
The adapter runs only in the managed Wrangler image's no-network inspector,
with the selected configuration mounted read-only and private scratch state.
It calls the vendor parser, rejects remote-enabled bindings, and returns
selected source paths plus exact approved config bytes to the trusted Rust
controller. Those bytes are private effective-config material, never an MCP
response or diagnostic. No agent-supplied JavaScript, package scripts, new
adapter npm dependency, production credentials or deployment command is allowed.
Config generations are pinned until explicit reload; assets and Worker source
remain live. Keep the adapter confined to the preview module; a Lua-only
replacement can be evaluated separately without changing Wrangler semantics.

- `plan/steps/357-web-publish-local-mvp.md`; completed orders 363/364: reuse,
  not a claim that publication is missing.
- `openspec/specs/enclave-service-catalog/spec.md`, `mcp-tool-socket/spec.md`,
  `forge-environment-discoverability/spec.md`: identity, allowlist, transport.
- `openspec/specs/web-image/spec.md`: static profile remains unchanged.
- `openspec/specs/subdomain-routing-via-reverse-proxy/spec.md`: existing HTTP
  listener semantics; this draft proposes an additive TLS exception to its
  exactly-one-host-address clause, to reconcile before activation.
- `cheatsheets/runtime/caddy-reverse-proxy.md`: draft vendor pointer, not L1 proof.
- Target observed 2026-10-07: sibling `../tillandsias.org/wrangler.jsonc`.
  Verify pinned Wrangler CLI/runtime semantics against vendor docs during image work.

## Acceptance and litmus status

No new passing/executable litmus is claimed. Before activation, bind behavioral
tests in `openspec/litmus-bindings.yaml`: lifecycle/MCP validation and failure
classification; live-source identity including two lanes; assets-only config and
uncommitted watch; TLS SNI/SAN/loopback and trust non-mutation. Positive and
negative cases, deadlines and artifacts are specified in the design packet.
Existing `web-image-shape` and catalog/MCP tests remain regression controls.
