# Why

NanoClawV2 is being treated as a first-class orchestration engine inside the
Tillandsias platform, not just another agent session. The target behavior is:

- a per-project launch point in the tray next to the existing harness/action
  list, labeled `🦞 NanoClawV2`;
- a dedicated baked container for NanoClawV2 with only approved tools,
  skills, and MCP registrations;
- a host-mediated control path so NanoClawV2 can request allowed work
  (builds, `/advance-work-from-plan`, project-scoped service launches,
  forge-agent delegation) without gaining raw Podman or credential access;
- smoke coverage that proves the NanoClawV2 launch path works on every
  supported host kind and remains branch-aware.

The user-facing goal is simple: run a NanoClawV2 instance inside a restricted
container, ask it to orchestrate approved project work, and keep the trust
boundary on the host side.

## What Changes

- Add a baked `nanoclawv2` container image to the Tillandsias image set.
- Add a per-project tray launcher leaf, `🦞 NanoClawV2`, beside the existing
  project harness actions.
- Add a narrow host orchestration surface that NanoClawV2 can reach through
  authenticated MCP calls and, where appropriate, enclave HTTPS endpoints.
- Bind NanoClawV2 requests to a specific project, branch, and host kind.
- Keep all container spawning allowlisted: only images and entrypoints owned by
  Tillandsias may be launched.
- Extend smoke coverage so launch, tool registration, and one approved action
  are exercised explicitly.

## Impact

- One new baked container and one new per-project launcher path.
- One new host-side orchestration control plane or broker path.
- Small but non-trivial changes to launch menus, smoke tests, and plan
  bookkeeping.
- No relaxation of credential isolation. NanoClawV2 remains a restricted
  client of host-approved services, not a general-purpose runtime.

