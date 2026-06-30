# macOS Tray Parity Gaps — audit 2026-06-28

**Status:** `in_progress`
**Filed by:** osx terminal, 2026-06-28
**Kind:** enhancement (tray parity — order 128)
**Trace:** `plan/issues/tray-feature-parity-matrix-2026-06-28.md`, `spec:tray-minimal-ux`

## Summary

macOS column audit vs. the parity matrix filed by linux-next (order 128).
GitHub login flow verified E2E in this session. `--list-cloud-projects` added
as a tray CLI mode this session. Remaining gaps filed below.

## E2E Verified This Session

| Capability | macOS Status |
|---|---|
| GitHub login in terminal (expect-style, name/email/token prompts) | ✅ VERIFIED — `--github-login` worked E2E 2026-06-28 |
| `--list-cloud-projects` CLI mode | ✅ ADDED this session (osx-next `list_cloud_projects_main`) |
| VM phase health check (no raw timeout) | ✅ wait_phase_ready (eced3b6f) |
| Proxy CA cert + exited-container workaround | ✅ bash pre-flight in tray (8144c5db) |

## Bugs Fixed This Session

- `opencode_main` vault URL: `https://10.0.42.2:8200` → `https://vault:8200`
  (was using stale IP, would fail with TLS NotValidForName)
- `--list-cloud-projects` fell through to AppKit GUI / serial console
  (tray didn't recognize the flag; now dispatched to `list_cloud_projects_main`)

## Remaining Gaps (macOS)

### P1 — Per-project submenu (cloud projects not appearing in menu)

| Feature | Linux | macOS |
|---|---|---|
| Cloud (☁️) project submenu | ✅ | ❌ not yet implemented |
| Per-project 6-leaf tool set | ✅ | ❌ not yet implemented |

The menu currently shows a static "Tillandsias" chip + a Quit item. After
`--github-login`, the tray should fetch project list and render cloud project
submenus. This requires the tray's `status_item.rs` to poll
`--list-cloud-projects` output and build `MenuStructure` entries.

**Next action (osx):** wire `list_cloud_projects_main` result into
`status_item.rs` polling loop → build cloud project submenus.

### P2 — `--list-cloud-projects` blank-terminal issue

On first run after a fresh VM boot, the expect-based exec session that
drives `--github-login` produces blank output on the host terminal because
PTY echo is in raw mode. Tracked separately as
`macos-tray-github-login-blank-terminal` on linux-next.

The `list_cloud_projects_main` streaming approach (output written via
`exec_over_stream_with_input_streaming` callback) AVOIDS this because output is
written to stdout directly, not to /dev/tty via PTY bridge.

### P3 — Enclave status indicator

Not implemented on macOS (static chip only). Linux tray shows healthy/degraded/
failed status. **Next action:** implement VmPhase polling in status_item.rs
(VmStatusRequest over vsock from the status item's background worker).

### P4 — Local (~/src) project submenu

Not implemented on macOS. Linux tray shows ~/src projects. macOS tray has the
necessary vm-layer infra but the `status_item.rs` menu builder doesn't populate
local projects.

### P5 — Transport normalization (order 126)

Blocked on order 124 (linux spec). Once the `ExecOneShot` / `InteractiveStream`
facade is defined, macOS backend should conform. The current `exec_guest_main` /
`github_login_main` / `list_cloud_projects_main` pattern will be unified under
the facade.

## Work Packets Spawned

### Work Packet: macos-parity/list-cloud-projects-tray-mode
- id: `macos-parity/list-cloud-projects-tray-mode`
- owner_host: macos
- capability_tags: [rust, macos, tray]
- status: done
- evidence: osx-next, `list_cloud_projects_main` in `diagnose.rs`,
  `--list-cloud-projects` dispatch in `main.rs`

### Work Packet: macos-parity/opencode-vault-url-fix
- id: `macos-parity/opencode-vault-url-fix`
- owner_host: macos
- capability_tags: [rust, macos, tray, vault]
- status: done
- evidence: osx-next, `opencode_main` URL corrected to `https://vault:8200`

### Work Packet: macos-parity/cloud-project-submenu
- id: `macos-parity/cloud-project-submenu`
- owner_host: macos
- capability_tags: [rust, macos, tray, ux]
- status: ready
- next_action: >
    Wire `list_cloud_projects_main` or a background poll into `status_item.rs`
    menu builder. Populate `MenuStructure` cloud project nodes from the
    `--list-cloud-projects` output. Blocked until tray architecture supports
    refresh (requires ExecOneShot or a background task channel).

### Work Packet: macos-parity/enclave-status-indicator
- id: `macos-parity/enclave-status-indicator`
- owner_host: macos
- capability_tags: [rust, macos, tray, ux, vsock]
- status: ready
- next_action: >
    Add VmPhase polling to `status_item.rs` background worker. Expose
    `VmStatusRequest` via the vsock control wire and update the chip text.
    The `probe_vm_phase` fn in `vsock_exec.rs` is already available.

## Events

- type: audit
  ts: "2026-06-28T23:00:00Z"
  agent_id: "macos-advance-20260628T2300Z"
  host: macos
  note: >
    GitHub login E2E verified. list-cloud-projects added as tray CLI mode.
    opencode vault URL fixed. Parity gaps filed as P1-P5.
