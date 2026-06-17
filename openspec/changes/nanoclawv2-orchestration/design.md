# Design

## Context

The repo already has the right primitives for this shape:

- `repeat` already supervises recurring agent cycles.
- `meta-orchestration` already treats the host as the authority and insists on
  branch-aware commits and pushes.
- the tray already owns project-scoped launch actions.
- the image builder already has a baked-container workflow.
- MCP is already the repository's preferred narrow tool surface for agents.

NanoClawV2 should fit into that model, not replace it.

## Decisions

### 1. Control plane: host-mediated, not direct Podman

NanoClawV2 must not get the Podman socket, arbitrary shell launch, or direct
secret material. It gets a narrow host control surface that only exposes
approved orchestration actions. That surface may be MCP-first, HTTPS-first, or
both, but the policy engine stays on the host.

### 2. Container model: dedicated baked image

NanoClawV2 gets its own image in the baked-container list. That image may start
from the existing Tillandsias base, but it needs its own config overlay so we
can seed:

- the NanoClawV2 runtime configuration;
- the approved MCP servers;
- the allowed skills, including the work-loop skill(s);
- any project-scoped env vars needed for branch awareness.

### 3. Launch model: per-project leaf

The tray gets a new per-project leaf, `🦞 NanoClawV2`, positioned with the
existing harness/action list. Clicking it launches a NanoClawV2 container for
that project, not a shared global daemon.

### 4. Allowed actions

The first release should keep the action vocabulary small:

- request `/advance-work-from-plan` on a project-scoped work tree;
- request an approved build or build-and-test action;
- request an approved local service launch;
- delegate to an approved forge container for the same project;
- query status of the bounded workflow.

Anything outside the allowlist is rejected on the host.

### 5. Smoke and repeat

Every supported host kind needs a way to validate the launch path:

- Linux mutable: local-build smoke should prove the leaf launches and the host
  broker accepts at least one allowed action.
- Linux immutable: published-release smoke should prove the installed binary
  still launches NanoClawV2 correctly.
- macOS and Windows: the host-specific loop should verify the launcher surface
  and the broker contract without assuming Linux-specific Podman behavior.

`repeat` and `/meta-orchestration` should remain branch-aware and push every
meaningful result before exit.

## Risks

- Giving NanoClawV2 raw container-spawn authority would collapse the security
  model.
- A second control plane, if not tightly specified, will drift from the tray's
  existing launch and logging conventions.
- Smoke coverage can become misleading if it only checks that a container name
  exists and not that the allowed action path actually works.

