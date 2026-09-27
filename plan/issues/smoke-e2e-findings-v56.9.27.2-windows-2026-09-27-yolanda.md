# Smoke e2e — v56.9.27.2, Windows, yolanda, 2026-09-27

Verdict: **PASS** (install, signature, version, provision, launch). Operator
authorised the destructive run on this host. Two findings are recorded below;
neither blocks the release.

cosign:verified:4/4

Host: Windows 11 10.0.26200.9457, WSL 2.7.13.0, Windows PowerShell 5.1.26100
for the install (the default a user gets), cosign v3.0.5 windows/amd64
(sha256 matches sigstore's cosign_checksums.txt).

## Steps

| Step | Result | Evidence |
|---|---|---|
| 1369-sjbc: unstable URL, TILLANDSIAS_CHANNEL + VERSION unset (resolve-only) | PASS | `resolved-channel: unstable (default of this installer copy) base: https://github.com/8007342/tillandsias/releases/download/unstable`, exit 0 |
| 1 — exact-tag install (`install-windows.ps1` of v56.9.27.2, TILLANDSIAS_VERSION pinned, PS 5.1, child process) | PASS | `install_exit=0`; asset `tillandsias-tray-56.9.27.2-windows-x64.zip`, `sha256: ok (dab3290a...0f1)` |
| 1 — exact version | PASS | `tillandsias-tray 56.9.27.2 (52e3bc32e)`, bounded match on 56.9.27.2 |
| 1s — cosign, every Windows asset against its own bundle, identity `^https://github[.]com/8007342/tillandsias/[.]github/workflows/release[.]yml@refs/(tags\|heads)/` | PASS 4/4 | install-windows.ps1, SHA256SUMS-windows, tillandsias-tray-56.9.27.2-windows-x64.zip, tillandsias-windows-x64.zip |
| 2 — destructive reset | PASS | done BY THE INSTALLER (`--reset-state`): distro + disk, the two host vault credentials, the download cache destroyed; `tillandsias-vm-uuid` preserved |
| 3 — provision from pristine | PASS | installer log: `reset-state: provisioned and ready (exit 0)`; guest journal's only boot begins 09:16:06 PDT, after the reset |
| 3 — wire | PASS | `--status-once --json`: reachable, wire_version 4, phase Ready, podman_ready true |
| 3 — diagnose | PASS | `--diagnose --json` exit 0; version = guest_version = 56.9.27.2, build 52e3bc32e, distro registered + running |
| launch | PASS | installer: `Tray started`; tillandsias-tray.exe running (PID 3868) until the Quit below |

## Finding 1 — 1430-rnpd, Windows arm: a tray Quit ends in a forced power-off

Measured with the operator clicking **Quit** in the tray menu, VM running.
Guest clock (PDT):

- 09:44:20.6 Quit clicked (tray.log 16:44:20Z)
- 09:44:23.78 systemd begins stopping units under `poweroff.target` — the
  `systemctl poweroff` that `wsl --terminate` issues for a systemd distro
- 09:44:23.79 → 09:44:26.26 tillandsias-headless: `Received shutdown signal` →
  `Graceful shutdown completed`
- 09:44:26.3 → 09:44:33.8 nothing logged for 7.5 s; the poweroff does not complete
- 09:44:33.79 WSL: `InitTerminateInstanceInternal:2763: systemctl poweroff did
  not terminate the instance in 10000 ms, calling reboot(RB_POWER_OFF)`
- 09:44:33.83 tray.log: `VM drained on Quit (wsl --terminate)`
- 09:44:54 next start, journald: both `system.journal` files `corrupted or
  uncleanly shut down, renaming and replacing`

So the row's reading ("no clean shutdown at all") is half right. The guest does
get a shutdown attempt — WSL itself runs `systemctl poweroff` with a 10 s
budget, and the headless drains cleanly in 2.5 s — but the poweroff does not
finish inside that budget, WSL forces power-off, and the next start finds
unclean journals. What stalled for the last 7.5 s is not in the journal. Note
also that the guest's `journalctl --list-boots` shows ONE boot across the stop:
WSL2 distros share the utility VM's kernel, so `-b -1` is not how to read the
previous run on Windows; journald's unclean-journal message on the next start
is the signal.

## Finding 2 — the installer's provisioning output is mojibake on PowerShell 5.1

The installer relays the guest's phase lines, and their emoji arrive as
`[reset-state] phase: dY"� Starting Fedora Linux�?�` and
`RESULT: VM Ready �?" control wire up �o"`. Same class as 1420-ev7i (the
Windows provision console prints raw phase lines); recorded there.

## Incident during the run (mine, not the product's)

A read-only journal query I passed to `wsl.exe` as an argument lost its quoting
across the hop, and a `shutdown` fragment of a grep pattern ran as root in the
guest, scheduling a poweroff at 09:46:13. Cancelled with `shutdown -c` at
09:45:22 (no job or schedule file remained, distro Running). It happened after
every measured step above, so no result depends on it. All later guest queries
went through stdin.

## Host state left behind

Tray not running (the operator's Quit). The tillandsias distro is Running,
started by my post-Quit journal reads.
