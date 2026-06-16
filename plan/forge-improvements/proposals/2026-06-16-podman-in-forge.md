---
title: Install Podman inside forge container for self-hosted builds
gap: "missing_tools: podman — forge cannot run its own build.sh or local-ci.sh scripts"
category: runtime-tool
status: proposed
proposed_at: 2026-06-16T08:00:00Z
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
