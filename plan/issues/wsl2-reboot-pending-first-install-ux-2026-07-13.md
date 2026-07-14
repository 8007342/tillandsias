# WSL2 first-install / reboot-pending states must fail classified, not crash — 2026-07-13

- filed_by: `windows-yolanda-fable5-20260713T2105Z` (meta-orchestration cycle,
  operator directive from The Tlatoāni, live session 2026-07-13)
- discovered_by: firsthand fresh-host provisioning of Windows 11 Home
  10.0.26200 ("yolanda", shiny new host, zero WSL state) during
  `/build-install-and-smoke-test-e2e` preparation
- evidence: session captures below; sibling context
  `plan/issues/build-install-smoke-e2e-findings-2026-07-11-windows.md`
  (attempt-1 handshake-timeout family), order 312 events (membership-classified
  hcsdiag failure — the classification pattern to mirror)
- packets: plan/index.yaml orders 323 (tray/vm-layer classification + UX) and
  324 (installer affordance)

## Operator directive (verbatim intent)

Windows end users running WSL2 for the first time will also require a reboot
after the first install. The Windows tray must support that state and
gracefully display a meaningful message along the lines of **"WSL2 requires a
restart"** instead of just crashing / failing to create the WSL2 VM.

## Environment states end users can be in (all captured live this session)

| State | Signature captured on yolanda 2026-07-13 |
|---|---|
| S1 `wsl-platform-absent` | `wsl --status` → `The Windows Subsystem for Linux is not installed. You can install by running 'wsl.exe --install'.` (exit 50 via cmd, exit 1 via --version). Fresh Win11 ships the wsl.exe stub only. |
| S2 `reboot-pending` | `dism /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart` → **exit 3010** ("operation completed successfully", restart required). Microsoft.WSL 2.7.10 installer notes verbatim: "If the virtual machine platform Windows optional feature was enabled, a restart is required for WSL to function properly." Corroborating system-wide signal: VS Build Tools bootstrapper refused with **error 5008** (reboot pending) in the same window. In this state every VM create/start fails generically (the 2026-07-11 attempt-1 "connect+handshake timed out" family is what a user would see). |
| S3 `virtualization-disabled` | Not hit here (`HypervisorPresent=True`, `VirtualizationFirmwareEnabled=True` via Win32 CIM), but the classifier must name it: firmware VT-x/SVM off → HCS errors on any VM start. |
| S4 healthy | Post-reboot: `wsl --status` → `Default Version: 2`, exit 0. |

## Product gap (where it crashes today)

`crates/tillandsias-vm-layer/src/wsl.rs` — `WslRuntime::start()` (lines
~509-560): preflight is `is_wsl_service_sane()` + `perform_wsl_shutdown_recovery()`,
then 5 retry "start pokes" with backoff. None of S1/S2/S3 is classified: on a
first-install machine the pokes burn ~50s of retries and surface a generic
failure (or downstream handshake timeout), which reads as a crash. The same
unclassified path is reachable from `--provision-once`, tray cold launch, and
`wsl --import` during provisioning. Order 312 already established the pattern
to follow (membership-classified hcsdiag failure with aka.ms/hcsadmin
remediation + `--diagnose --json` context field); this extends that
classification to the WSL-platform layer itself.

## Detection recipes (verifiable, no guessing)

- S1: `wsl.exe --status` exit != 0 AND stdout/stderr contains the
  not-installed marker (locale caveat: match exit code + `aka.ms/wslinstall`
  URL which is locale-stable, not the English prose).
- S2: WSL app present (`wsl --version` works OR appx installed) but
  VirtualMachinePlatform pending: `HKLM:\...\Component Based Servicing\RebootPending`
  key present, or DISM feature state reports restart-needed, or VM start fails
  with the HCS service-unavailable family while `HypervisorPresent=True`.
- S3: `Win32_ComputerSystem.HypervisorPresent=False` AND
  `Win32_Processor.VirtualizationFirmwareEnabled=False`.

## Exit shape

Classified preflight verdict (enum, unit-tested mapping) consumed by:
1. provisioning/start error path — fail FAST (no 5-poke retry storm on
   classified-fatal states) with the exact remediation string, e.g.
   "WSL2 requires a restart to finish installing — please reboot Windows and
   relaunch Tillandsias" (S2), "WSL is not installed — run `wsl --install
   --no-distribution`" (S1), "enable virtualization in BIOS/UEFI" (S3);
2. tray toast + menu status line (order 250 minimal-UX intent);
3. `--diagnose --json` field (e.g. `wsl_platform: ok|absent|reboot-pending|virtualization-disabled`)
   so e2e evidence carries the state;
4. `scripts/install-windows.ps1` — same classification at install time,
   instructing the restart *before* first tray launch instead of the current
   warn-and-continue (S1 warning exists; S2 not detected at all).
