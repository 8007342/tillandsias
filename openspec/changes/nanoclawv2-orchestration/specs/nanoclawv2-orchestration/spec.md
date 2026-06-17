# nanoclawv2-orchestration delta — nanoclawv2-orchestration

## ADDED Requirements

### Requirement: NanoClawV2 is a baked, project-scoped orchestration container

The Tillandsias launcher SHALL expose a per-project action labeled
`🦞 NanoClawV2`. Activating that action SHALL start a dedicated NanoClawV2
container for the selected project. The container SHALL be built from a baked
image that is owned by Tillandsias and SHALL NOT be an arbitrary user-supplied
image.

The NanoClawV2 container SHALL inherit the selected project identity, the
current branch context, and only the approved environment needed for local
orchestration. It SHALL NOT inherit raw Podman access, host credentials, or any
broader host shell.

@trace spec:nanoclawv2-orchestration, spec:tray-app, spec:podman-orchestration

#### Scenario: NanoClawV2 leaf launches a dedicated container

- **WHEN** the user activates `🦞 NanoClawV2` for a project
- **THEN** Tillandsias launches a NanoClawV2 container bound to that project
- **AND** the launched container is an allowlisted baked Tillandsias image
- **AND** the launch is logged with project, branch, and host kind metadata

### Requirement: NanoClawV2 may request only approved orchestration actions

NanoClawV2 SHALL communicate with Tillandsias through a host-mediated control
surface. The control surface MAY be MCP-first, HTTPS-first, or a combination of
the two, but the host SHALL remain the policy authority.

The approved v1 action set SHALL be narrow and explicitly allowlisted. At a
minimum, NanoClawV2 MAY request:

- a project-scoped `/advance-work-from-plan` cycle;
- an approved build or build-and-test action;
- an approved local service launch for the selected project;
- delegation to an approved forge container for the same project;
- bounded status queries for the current work item.

Any request outside the allowlist SHALL be rejected by the host before any
container spawn, build, or external request occurs.

@trace spec:nanoclawv2-orchestration, spec:mcp-on-demand, spec:podman-orchestration

#### Scenario: Host rejects an unapproved action

- **WHEN** NanoClawV2 requests an action that is not in the allowlist
- **THEN** the host returns a structured denial
- **AND** no container is spawned
- **AND** no secret or external endpoint is touched

### Requirement: NanoClawV2 tool configuration is seeded, not free-form

The NanoClawV2 container SHALL receive only the skills and MCP servers required
to perform the approved orchestration actions. The seeded tool surface SHALL be
declared in the Tillandsias image/config overlay, not assembled ad hoc by the
container at runtime.

The seeded tools SHALL be project-scoped and branch-aware. If a tool would
operate on a different project, different branch, or unapproved image, the host
policy layer SHALL deny it.

@trace spec:nanoclawv2-orchestration, spec:podman-orchestration, spec:mcp-on-demand

#### Scenario: Tool surface is project-scoped

- **WHEN** NanoClawV2 starts for project `alpha`
- **THEN** the seeded tools can act only on `alpha`
- **AND** a request to target `beta` is denied
- **AND** the denial is logged

### Requirement: Smoke coverage proves NanoClawV2 launch and one approved action

The build/install smoke and the published-release smoke SHALL each include a
NanoClawV2 launch check. The check SHALL verify that the `🦞 NanoClawV2` launch
path exists, starts the container successfully, and can execute at least one
approved orchestration action.

The smoke SHALL file a dated plan issue packet for any failure in launch,
policy enforcement, tool seeding, or branch-aware behavior.

@trace spec:nanoclawv2-orchestration, spec:release-smoke, spec:tray-app

#### Scenario: Smoke validates launch and action path

- **WHEN** a smoke test activates the NanoClawV2 launcher for a project
- **THEN** the container starts successfully
- **AND** the smoke can observe the approved tool surface
- **AND** at least one approved action completes end to end
- **AND** any failure becomes a plan issue packet
