# Order 455 Windows smoke — v0.3.260724.1 — 2026-07-24 — PASS

Operator-attended (The Tlatoāni at the terminal), windows host "Yolanda",
observer: windows-host Claude session (live log monitor + Event Log).

## Procedure

1. Full purge via the saved installer script: `& $env:TEMP\ti.ps1 -Purge`
   (v0.3.260724.1 script; saved-file execution — itself a live regression
   test of the 07-22 smart-quote P1: the script parsed and ran correctly).
   Purge removed: Start Menu shortcut + empty distro dirs, install dir,
   Installed-Software entry, NotifyIconSettings entry, WSL distro
   `tillandsias` (unregistered), cache/logs/wsl dirs, Event Log source.
   Clean — no residue found.
2. Pinned fresh install: `$env:TILLANDSIAS_VERSION='0.3.260724.1'` +
   `irm .../v0.3.260724.1/install-windows.ps1 | iex`. SHA-256 verified
   (fe5946b8...), `tillandsias-tray 0.3.260724.1 (51e5f0aa)` VERSIONINFO,
   single Installed-Software entry, tray auto-launched, `--init` implicit.

## Timings (tray log, UTC)

| Phase | Time | Delta |
|---|---|---|
| Setting up Fedora Linux | 07:20:29.58 | 0s |
| Downloading Fedora rootfs | 07:20:29.63 | — |
| Installing Tillandsias (download done) | 07:20:32.99 | download 3.4s |
| Starting Fedora Linux (import done) | 07:21:34.18 | import ~61s |
| Connecting | 07:21:35.67 | — |
| VM handshake success (attempt=1, wire_version=2) | 07:21:43.72 | — |
| **VM ready — control wire established** | **07:21:43.72** | **wipe→ready 74s** |

## Verification

- NO version-skew warning: pinned guest fetch delivered the matching
  build; `wsl -d tillandsias tillandsias-headless --help` →
  `Tillandsias v0.3.260724.1` (host VERSIONINFO identical). The skew
  guard is known-working (it fired correctly at 07:12Z against the
  pre-purge 260721 guest), so its silence here is positive evidence.
- Handshake on attempt 1; no crash-loop, no reprovision, no ERROR lines
  in the watched log window.
- Download throughput fix holds on the release binary (3.4s for the
  rootfs that took 25+ min pre-fix).

## Findings (non-blocking)

1. **Docs gap — execution policy**: published instructions only cover
   `irm | iex`; the uninstall/purge path requires running the SAVED
   script, which default client ExecutionPolicy (Restricted) blocks.
   The uninstall docs should ship the per-process bypass verbatim:
   `powershell -NoProfile -ExecutionPolicy Bypass -File ti.ps1 -Purge`.
2. Post-login menu refresh gap reproduced pre-purge (tray 260724.1 +
   old guest): recorded cross-platform in
   `macos-tray-github-login-stuck-no-prompt-refresh-2026-07-23.md`.
   The fresh same-version pairing is expected to push login state; the
   operator's next login is the live check.
3. Purge is destructive to vault by design (lives in the distro):
   github token + git identity need one re-login after a purge. Expected,
   but the installer could say so ("this removes your saved logins").

## Verdict

**PASS** — the v0.4 cross-platform smoke evidence gate's Windows column
is complete against v0.3.260724.1 (first daily carrying the full
07-23/24 stability wave).
