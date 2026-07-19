# Smoke e2e findings — v0.3.260719.1 curl-install from scratch (Windows)

- Release under test: `v0.3.260719.1` (daily, run 29668750741)
- Host: windows (windows-next), operator-ordered full wipe + from-scratch
  curl-install e2e (the same flow the 2026-07-18 field user ran)
- Agent: windows-bullo-fable5-20260719T0043Z
- Logs: `target/smoke-e2e/{01-install,01-install-retry,02-purge}.log` (local)

## Verified working (live, on the published artifact)

- `install-windows.ps1 -Purge` removed tray install, Start Menu shortcut,
  `tillandsias` WSL distro, and `%LOCALAPPDATA%\tillandsias\{cache,logs}`.
- NEW: elevated install registered Event Log source 'Tillandsias'
  (this cycle's spec reactivation) — first live exercise, worked.
- Pinned install (`TILLANDSIAS_VERSION=0.3.260719.1`): SHA-verified zip,
  version check `tillandsias-tray 0.3.260719.1 (7914f2ea)`, auto-launch.
- From-scratch provisioning started; NEW `provisioning phase` INFO tracing
  live in tray.log AND relayed to the Windows Application Event Log with
  clean rendering ("Setting up Fedora Linux…", "Downloading Fedora
  rootfs…") — windows-event-logging spec verified end-to-end on a real
  from-scratch install.

### Work Packet: smoke-finding/windows-installer-version-verify-transient-failure

- id: `smoke-finding/windows-installer-version-verify-transient-failure`
- owner_host: windows
- capability_tags: [windows, installer, powershell, release]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.3.260719.1`
- evidence:
  - `target/smoke-e2e/01-install.log:12` — `ERROR: tillandsias-tray --version failed (exit 1); binary is broken.`
  - Immediate manual rerun of the identical verification (same exe path,
    same cmd.exe redirect shape) exits 0 and prints the version; the full
    installer retry succeeded end-to-end minutes later.
- repro:
  - Not deterministic. Occurred on the FIRST execution of the
    freshly-extracted exe immediately after a `-Purge` in the same elevated
    session (plausible first-exec scan latency / handle contention);
    Defender shows no detection record.
- next_action: >
    Make the installer's --version verification retry (e.g. 2 attempts,
    2s apart) before declaring "binary is broken", and print the captured
    stderr instead of discarding it (2>nul) so a real failure is
    attributable. Consider also logging the verification failure to the
    Event Log source registered moments earlier.
- events:
  - type: discovered
    ts: "2026-07-19T02:00:00Z"
    agent_id: windows-bullo-fable5-20260719T0043Z
    host: windows

### Work Packet: smoke-finding/windows-purge-leaves-bak-dir

- id: `smoke-finding/windows-purge-leaves-bak-dir`
- owner_host: windows
- capability_tags: [windows, installer, powershell]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.3.260719.1`
- evidence:
  - After `-Purge` reported "Purged.", `%LOCALAPPDATA%\Programs\Tillandsias.bak`
    remained with a stale 2026-07-15 45 MB binary (created by a prior
    install's backup step).
- repro:
  - install twice (creates .bak), then `install-windows.ps1 -Purge`,
    then `Test-Path "$env:LOCALAPPDATA\Programs\Tillandsias.bak"` → True
- next_action: >
    -Purge (and -Uninstall) should also remove `$InstallDir.bak`; a purge
    that leaves a stale binary contradicts "full cleanup" and wastes 45 MB.
- events:
  - type: discovered
    ts: "2026-07-19T02:05:00Z"
    agent_id: windows-bullo-fable5-20260719T0043Z
    host: windows

## Minor observations (not packets)

- Tee-Object capture of the child `powershell -File` run drops some
  Write-Host lines (Asset/Downloading/sha256 rows absent from the teed log
  while the steps demonstrably ran) — logging artifact only.
- Singleton test-lock residue (`tillandsias-singleton-*.lock`) accumulates
  in `%LOCALAPPDATA%\tillandsias\` from cargo test runs; cosmetic.

## Provisioning observation log

- 02:01Z install retry OK, tray launched, phases: Setting up → Downloading
  Fedora rootfs (Event Log relay confirmed live — clean rendering, source
  registered by the installer's elevated path).
- 02:16:58Z Installing Tillandsias… (download took ~16 min)
- 02:18:11Z Starting Fedora Linux… → 02:18:14Z Connecting…
- 02:18:23Z **VM ready — control wire established** (from-scratch total
  ~17.5 min). `--status-once --json`: reachable, wire_version 2, phase
  Ready, podman_ready true, last_event "Securing Vault".
- `.import-complete` marker present with content `0.3.260719.1`
  (order 418 marker written at end of full provision — verified).
- RELAUNCH TEST (order 418 fast path): Stop-Process + relaunch at
  02:18:53Z → exec probe green → fast path (NO re-download) → 02:19:05Z
  VM ready. 12 seconds relaunch-to-Ready.
- No crash loop, no terminal windows observed flashing during either run,
  bounded keepalive holding the wire (order 417 supervision active).

## VERDICT: PASS

Release v0.3.260719.1 curl-install e2e on Windows from a fully wiped
substrate: install (after one transient verify flake, filed above),
from-scratch provision to wire-Ready, Event Log relay live, import marker +
fast-path relaunch verified. The crash-loop-class fixes (417/418) rode the
exact flow the 2026-07-18 field failure took and behaved as specified.

## Post-PASS operator finding (2026-07-19T03:00Z live session)

### Work Packet: smoke-finding/cloud-attach-unauthenticated-raw-vault-404

- id: `smoke-finding/cloud-attach-unauthenticated-raw-vault-404`
- owner_host: any
- capability_tags: [ux, auth, vault, headless, tray, fail-loud]
- status: ready
- discovered_by: operator (The Tlatoāni) on release `v0.3.260719.1`, fresh
  post-wipe guest, minutes after the PASS verdict
- evidence:
  - Cloud attach terminal: `Error: containerized gh repo clone exited with
    status exit status: 2: vault-cli: HTTP error reading
    secret/data/github/token: curl: (22) The requested URL returned error: 404`
    then `[processus terminé avec le code 1]` — a dead terminal, no guidance.
  - Guest journal: git containers (`tillandsias-git:v0.3.260712.1`) churn on
    the same 404 every list/attach poll (spawn → 404 → die → secret remove).
  - Tray log: GitHub Login PTY opened 02:51:52Z (`--github-login`), cloud
    attach clicked 02:59:07Z; login flow starts with an interactive
    `Git author name [...]:` prompt and only writes the token AFTER the
    device flow completes — the 02:51 login was evidently not completed, so
    no token existed. Write/read paths agree (`secret/github/token`); this
    is NOT version skew.
- repro:
  - Fresh guest, skip/abandon GitHub Login, click a cloud project attach.
- next_action: >
    Fail-loud-but-actionable at the auth boundary: (1) headless cloud
    attach/clone should classify the missing-token 404 into "Not signed in
    to GitHub — run GitHub Login first" (and exit once, not a bare curl
    error); (2) the tray should gate cloud-project attach entries on login
    state (disabled + "Sign in first" hint, or auto-open the login flow);
    (3) the remote-projects list poll should back off / stop respawning git
    containers while unauthenticated (container churn every poll cycle);
    (4) the login PTY should make clear the flow is incomplete if closed
    early. Also relay this classified error at ERROR so it reaches the
    Windows Event Log.
- events:
  - type: discovered
    ts: "2026-07-19T03:00:00Z"
    agent_id: windows-bullo-fable5-20260719T0043Z
    host: windows
