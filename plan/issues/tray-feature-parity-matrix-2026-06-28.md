# Tray Feature & UX Parity Matrix (linux / macos / windows)

**Status:** `ready`
**Owner:** linux (authors the matrix) — each host verifies its column
**Date:** 2026-06-28
**Kind:** enhancement (verifiable parity)
**Trace:** `spec:tray-minimal-ux`, `spec:simplified-tray-ux`, `spec:tray-app`

## Intent

The operator requires **1:1 feature parity and user experience** across the
linux, macos, and windows trays. Today parity is asserted in prose and drifts
(e.g. the menu leaf set, github-login terminal behavior, cloud/local project
submenus, enclave status indicators). Make parity an **enumerated, verifiable
matrix** so a missing/divergent feature on any platform is a failing check, not a
surprise.

## Deliverable

`plan/issues/` matrix → promoted into a machine-checkable form:
`openspec/tray-parity-matrix.yaml` listing every tray-visible capability with a
per-platform status cell, plus a litmus that fails when a row marked `parity:
required` is not `done` on all three platforms.

### Seed rows (to be completed by the research scan)

| Capability | Linux | macOS | Windows | parity |
|---|---|---|---|---|
| Per-project submenu: 6-leaf tool set (Claude/Codex/OpenCode/OpenCodeWeb/Observatorium/Maintenance) | ✅ | ? | ? | required |
| GitHub login in popup terminal (never inline) | ✅ | ⚠️ blank-terminal bug | ? | required |
| Cloud (☁️) project submenu + overflow | ✅ | ? | ? | required |
| Local (🏠 ~/src) project submenu | ✅ | ? | ? | required |
| Enclave status indicator (healthy/degraded/failed) | ✅ | ? | ? | required |
| `--list-cloud-projects` / remote project listing | ✅ | ? | ? | required |
| Interactive agent attach (InteractiveStream) | ✅ | ? | ? | required |
| One-off status/probe (ExecOneShot) | ✅ | ? | ? | required |
| Quit / lifecycle (VmShutdownRequest on quit) | ✅ | ✅ | ✅ | required |
| Provision / diagnose flow | ✅ | ✅ | ✅ | required |
| Host-specific VM substrate (podman / VZ / WSL) | n/a | n/a | n/a | platform-specific |

(`?` = audit needed; the scan fills these from each tray crate.)

## Exit Criteria

- `openspec/tray-parity-matrix.yaml` enumerates every tray capability with a
  per-platform cell and a `parity: required|platform-specific` tag.
- `litmus:tray-parity-matrix-complete` fails if any `required` row is not `done`
  on all three platforms (drives the per-host work).
- Each host verifies its column and files gap packets for its `required` misses.

## Dependencies / Coordination

- The InteractiveStream / ExecOneShot rows are satisfied by the host-guest
  transport normalization packets; this matrix is the acceptance gate that proves
  the normalization actually delivered identical UX.
- Release held until macOS completes current work; the matrix should be all-green
  on `required` rows before that release.

## Related

- `host-guest-transport-normalization-research-2026-06-28.md`
- `plan/issues/tray-convergence-coordination.md`
