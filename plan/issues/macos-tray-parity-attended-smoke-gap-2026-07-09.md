# Gap: 7 macOS tray-parity cells require an ATTENDED interactive smoke — 2026-07-09

- class: verification-gap (order 257 residual)
- owner: operator (Tlatoāni) at the macOS tray + macOS agent recording results
- status: open
- trace: openspec/tray-parity-matrix.yaml, plan/index.yaml order 257,
  litmus:tray-parity-matrix-complete, plan/issues/macos-m8-interactive-smoke-failures-2026-06-16.md
- filed_by: macos-Tlatoanis-MacBook-Air-fable5-20260709T2132Z

## Context

Order 257 requires every required-row macOS cell in
`openspec/tray-parity-matrix.yaml` to be verified on a LIVE tray (code reading
explicitly disallowed). This cycle verified what is honestly verifiable
unattended and set the rest to `todo`. Until the attended pass flips them to
`done`, `litmus:tray-parity-matrix-complete` (post-build) will FAIL on macOS
`--ci-full` — that is order 243's intended design, not a build break to
"fix" by editing the matrix without evidence.

## Verified unattended this cycle (cells set to `done`)

- **ExecOneShot probe**: `tillandsias-tray --exec-guest '<shell>'` exercised
  live twice on the freshly provisioned VM (guest forensics + version probe),
  final line `{"status":"ok","exit_code":0}` — see
  `plan/issues/macos-build-install-smoke-e2e-findings-2026-07-09.md`.

## Strong partial evidence gathered (cells left `todo` — attended run completes them)

- **--list-cloud-projects**: live unattended run executed the full chain (VM
  boot → control wire → vault bootstrap COMPLETE with policies
  [GitMirror, Forge, Tray, Inference, GithubLogin] → containerized `gh`) and
  failed gracefully with the correct not-logged-in `404 secret/data/github/token`.
  Residual: a credentialed run must show an actual repo listing.
- **Interactive agent attach (InteractiveStream)**: the wire-level PTY
  primitive was proven live by the `--github-login` expect-flow (PtyOpen
  session, guest prompt matched, host response delivered). Residual: the tray
  MENU Attach flow (Terminal.app/iTerm2 window via osascript) needs eyes.
- **GitHub login popup terminal**: CLI login path reaches credential prompts
  live (see e2e findings). Residual: menu action must open a POPUP terminal
  (never inline) and complete with a real PAT.

## No unattended evidence possible (pure UI cells, `todo`)

- Per-project submenu: 6-leaf tool set
- Cloud (☁️) project submenu + overflow
- Local (🏠 ~/src) project submenu
- Enclave status indicator (healthy/degraded/failed) — note: healthy-path chip
  text update was observed in tray stderr (`vm-status: phase=Ready …`), but
  degraded/failed indicator states and the visual surface need attended checks.

## Attended checklist (one m8-style session closes all 7)

1. Launch installed tray; confirm menu bar icon + status chip.
2. Open menu: verify Local 🏠 submenu lists ~/src projects; Cloud ☁️ submenu +
   overflow behavior.
3. Per-project submenu: 6 leaves (Claude/Codex/OpenCode/OpenCodeWeb/
   Observatorium/Maintenance).
4. GitHub Login menu item → POPUP terminal (not inline) → complete with real
   PAT (note: first attempt on a fresh VM may hit order 259's vault race —
   retry once).
5. After login: --list-cloud-projects shows real repos; cloud submenu
   populates.
6. Attach Here on a project → terminal window with live agent PTY.
7. Observe status indicator through healthy → (induce) degraded/failed if
   feasible (e.g. stop the VM guest service).
8. Record each result as a `done` flip + evidence in order 257's completion
   event; re-run `scripts/run-litmus-test.sh tray-app --phase post-build` to
   confirm the parity litmus goes green.

Single packet covers all 7 misses deliberately (shared root cause: attended
session required); each cell is enumerated above so no miss is untracked.
