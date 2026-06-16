---
title: Install Podman inside forge container for self-hosted builds
gap: "missing_tools: podman — forge cannot run its own build.sh or local-ci.sh scripts"
category: runtime-tool
status: deferred
proposed_at: 2026-06-16T08:00:00Z
triaged_at: 2026-06-16T09:40:00Z
triage_decision: >
  DEFERRED with rootless-feasibility rationale. Rootless podman-in-podman is not
  feasible inside the forge's current hard isolation envelope (--cap-drop=ALL,
  --userns=keep-id, --security-opt=no-new-privileges) without weakening it.
  Stays in the forge backlog; not promoted to the active frontier. See triage
  note at end of file.
changes:
  - file: images/default/Containerfile
    description: |
      Install podman via microdnf so forge agents can run build.sh and
      scripts/local-ci.sh internally. Requires --privileged or rootful podman;
      investigate rootless podman as preferred approach within existing
      security envelope.
---

## Gap

Multiple diagnostic runs (`diagnostics_20260614T062505Z-summary.md`,
`diagnostics_20260614T160501Z-summary.md`,
`diagnostics_20260614T180458Z-summary.md`) report that podman is **not
available** inside the forge container.

The project's build scripts (`./build.sh`, `scripts/local-ci.sh`) use podman
extensively for building, testing, and CI workflows. Without podman inside the
forge, agents cannot perform self-hosted builds or CI verification.

## Evidence

- `diagnostics_20260614T062505Z-summary.md`: missing_tools includes podman
- `diagnostics_20260614T160501Z-summary.md`: proposed_enhancements flags podman
- `diagnostics_20260614T180458Z-summary.md`: missing_tools includes podman
- Build scripts `./build.sh` and `scripts/local-ci.sh` use `podman` extensively

## Privacy/Isolation Assessment

**Requires careful review.** Installing podman inside the container raises
isolation questions:

- **Rootless podman** is preferred and should work within the existing
  `--userns=keep-id` / `--cap-drop=ALL` envelope. Rootless podman uses
  `podman unshare` and user namespaces for container operations.
- **Rootful podman** would require `--privileged` or additional capabilities,
  which would weaken the isolation envelope. This is NOT recommended.
- The forge would need a nested container store, potentially on a dedicated
  tmpfs or the existing cache mount.

If rootless podman is feasible, the forge gains the ability to run Dockerfiles,
build container images, and execute CI workflows — all within the existing
sandbox. If not feasible, this proposal should be marked `blocked` and
documented as a known limitation.

## Triage decision — 2026-06-16 (linux, coord/critical-forge-proposal-triage-20260616)

**DEFERRED (known limitation). Rootless feasibility: negative within the
current envelope.**

The proposal's optimistic "rootless podman should work within
`--userns=keep-id` / `--cap-drop=ALL`" is not accurate for this forge:

- Rootless podman needs setuid `newuidmap`/`newgidmap` plus a populated
  `/etc/subuid`+`/etc/subgid` range to map a nested user namespace. Under
  `--userns=keep-id` the forge runs as a single mapped uid with **no** subordinate
  id range, so `podman` cannot create the nested userns it needs.
- It also typically requires `/dev/fuse` (fuse-overlayfs) and relaxed seccomp;
  `--cap-drop=ALL` + `--security-opt=no-new-privileges` block the
  setuid-helper path outright. Enabling them is exactly the envelope weakening
  the project forbids.
- Rootful/`--privileged` is explicitly out of scope per the project's container
  security flags (non-negotiable per the work-loop skill).

**Rationale for deferral rather than investment:** the forge's role is running
agents, not self-hosting the container build. `./build.sh` / `scripts/local-ci.sh`
already run on the host (and the destructive smoke loop exercises them there).
A nested builder would duplicate that with materially weaker isolation. If a
genuine in-forge build need emerges, the right design is a *separate* rootless
builder sidecar with its own scoped envelope and subid range — a much larger
piece of work that should get its own proposal, not a `microdnf install podman`
line in the shared default image.

Kept in the forge backlog as `deferred`; not promoted to `plan/issues/ACTIVE.md`.

