# Gap: 7 Windows tray-parity cells require an ATTENDED interactive smoke — 2026-07-09

- class: verification-gap (order 258 residual; mirrors order 257 / the macOS
  gap packet `macos-tray-parity-attended-smoke-gap-2026-07-09.md`)
- owner: operator (Tlatoāni) at the Windows tray + Windows agent recording results
- status: RESOLVED 2026-07-12 — all 7 cells verified live on the operator-attended
  smoke (see order 258's completion event); step-10 (order 274 first-login
  probe) also discharged. Residual defects found DURING the pass are filed
  as their own packets/issues (orders 308-314, wire stale-render, PTY
  throughput, spinner burn).
- trace: openspec/tray-parity-matrix.yaml, plan/index.yaml order 258,
  litmus:tray-parity-matrix-complete
- filed_by: windows-bullo-fable5-20260709T2310Z

## Context

Order 258 requires every required-row Windows cell in
`openspec/tray-parity-matrix.yaml` to be verified on a LIVE tray (code reading
explicitly disallowed). This cycle verified what is honestly verifiable
unattended and set the rest to `todo`. Until the attended pass flips them to
`done`, `litmus:tray-parity-matrix-complete` (post-build) will FAIL on Windows
`--ci-full` — that is order 243's intended design, not a build break to "fix"
by editing the matrix without evidence.

All evidence below is from the freshly rebuilt + reinstalled tray at
`windows-next@92675e8e` (embedded SHA == HEAD, freshness gate green) against
this host's provisioned `tillandsias` WSL distro, 2026-07-09T23:18–23:25Z,
tray log `%LOCALAPPDATA%\tillandsias\logs\tray.log` (RUST_LOG=debug session).

## Verified unattended this cycle (cell set to `done`)

- **One-off status/probe**: `--status-once --json` live →
  `{"reachable":true,"wire_version":2,"phase":"Ready","podman_ready":true,
  "exit_code":0}`; `--diagnose --json` live → exit 0, full schema
  (distro_registered/running true, wire.phase Ready); the stopped-VM error
  path was also exercised live earlier in the session (reachable=false with
  actionable error text, embedded exit_code 1). One-off guest exec via the
  platform bridge: `wsl.exe -d tillandsias -- sh -c …` → `GUEST_OK`,
  Fedora 44, guest headless `v0.3.260707.2`, exit 0. Mechanism note: the
  Windows probes ride `VmStatusRequest` over hvsocket plus `wsl.exe`
  host-side checks rather than the control-wire `ExecOneShot` frame the row
  parenthetical names (macOS `--exec-guest`); the windows tray never calls
  `ExecOneShot` — `wsl.exe -d <distro> --` is its documented one-shot/PTY
  bridge (notify_icon.rs:2588-2622). If the operator wants strict
  ExecOneShot-frame parity instead of capability parity, flip this cell back
  and file an enhancement packet.

## Strong partial evidence gathered (cells left `todo` — attended run completes them)

- **Local (🏠 ~/src) project submenu**: host-side scan live
  (`Initial scan complete count=5`, filesystem watches on `C:\Users\bullo\src`,
  6 active watches) AND the VM-side wire round-trip live
  (`local projects refreshed (VM-side) count=5` every fast-poll round).
  Residual: submenu rendering needs eyes.
- **Cloud (☁️) submenu / --list-cloud-projects**: the full
  `CloudRefreshRequest` chain ran live against the guest and failed gracefully
  not-logged-in (`cloud projects refreshed count=0`, no error). Residual: a
  credentialed run must show a real repo listing + overflow behavior. Note the
  Windows tray has no `--list-cloud-projects` CLI flag (macOS-only probe) —
  the wire chain evidence is from the tray's own refresh path.
- **GitHub login state**: `github login state refreshed (VM-side)
  logged_in=false` live (graceful logged-out render path). Residual: menu
  action must open a POPUP Windows Terminal (`wt.exe` titled tab
  "Tillandsias — GitHub Login", never inline) and complete with a real PAT.
- **Enclave status indicator**: healthy path live — `vm status polled
  phase=Ready podman_ready=true` applied to the chip, then SC-07 suppression
  held (no further status polls; push subscription established ~0.7s after
  keepalive). Residual: degraded/failed indicator states need attended
  induction (e.g. `wsl --terminate tillandsias` while watching the icon).
- **Push/streams context** (affects login/cloud cells): the in-VM headless is
  `v0.3.260707.2`, which PREDATES 744f4749 (LoginStatePush/CloudProjectsPush
  sources), so those topics cannot push yet on this VM; the tray's designed
  fallback (startup fast-poll burst + poll-while-unconfirmed) covered the gap
  exactly as order 154 slice 2 intended. Refresh the in-VM headless before
  expecting push-driven login/cloud updates in the attended session.

## No unattended evidence possible (pure UI cells, `todo`)

- Per-project submenu: 6-leaf tool set
  (Claude/Codex/OpenCode/OpenCodeWeb/Observatorium/Maintenance)
- Cloud (☁️) project submenu + overflow (rendering half)
- Local (🏠 ~/src) project submenu (rendering half)
- Interactive agent attach — Windows opens the in-VM PTY via
  `wsl.exe -d <distro> --` inside Windows Terminal (`wt.exe` present per
  --diagnose), NOT control-wire InteractiveStream; the attended pass verifies
  the terminal window + live agent PTY.

## Attended checklist (one session closes all 7)

1. Refresh the in-VM headless past 744f4749 first (rebuild + reinstall guest
   binary, or re-provision) so push topics are live.
2. Launch installed tray; confirm notification-area icon + status chip.
3. Open menu: Local 🏠 submenu lists the 5 `~/src` projects; Cloud ☁️ submenu +
   overflow behavior.
4. Per-project submenu: 6 leaves (Claude/Codex/OpenCode/OpenCodeWeb/
   Observatorium/Maintenance).
5. GitHub Login menu item → POPUP `wt.exe` tab titled "Tillandsias — GitHub
   Login" (not inline) → complete with a real PAT (first attempt on a fresh VM
   may hit order 259's vault race — retry once).
6. After login: cloud submenu populates with real repos (flips the
   remote-listing cell).
7. Attach on a project → Windows Terminal window with live agent PTY via
   `wsl.exe`.
8. Observe status indicator healthy → induce degraded/failed
   (`wsl --terminate tillandsias`) → confirm indicator + recovery.
9. Record each result as a `done` flip + evidence in order 258's completion
   event; re-run `scripts/run-litmus-test.sh tray-app --phase post-build` to
   confirm the parity litmus goes green.

Single packet covers all 7 misses deliberately (shared root cause: attended
session required); each cell is enumerated above so no miss is untracked.

## Addendum 2026-07-10 (order 274 criterion 3)

10. **Fresh-distro first login — vault lock-namespace probe** (closes order
    274): on a freshly provisioned distro (or after `wsl --unregister` +
    re-provision), click **GitHub Login** for the FIRST time. Expected: the
    credential prompt appears; the guest journal shows NO `exit 125` /
    vault name-in-use error (`wsl -d tillandsias -u root -- journalctl -u
    tillandsias-headless | grep -i "name.*in use\|exit 125"` comes back
    empty). The order-259-class fix pins HOME/XDG_RUNTIME_DIR in both unit
    writers; this is its live discharge on Windows.
