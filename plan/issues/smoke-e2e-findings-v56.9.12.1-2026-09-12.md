# /smoke-curl-install-and-test-e2e — v56.9.12.1 on ESMERALDINHA (N100/16GB, Windows 11 + WSL2) — VERDICT: FAIL at §3

**Tag:** v56.9.12.1 (`7ed1327ec`) · **Regime:** ESMERALDINHA, Intel N100 / 16 GB, Windows 11 26200.9445, WSL 2.7.13.0, floor tier
**Run:** 2026-09-12 04:01Z–04:12Z · **Channel:** daily, pinned by `TILLANDSIAS_VERSION` to the exact tag
**Operator authorization:** obtained for this run specifically (the host is a workstation, not a dedicated smoke host — DESTRUCTIVE §2 per order 1004-vsh2)

## Verdict

**FAIL.** The release installs and verifies correctly, but a cold provision
from a pristine state never reaches Ready: the control-wire Noise handshake
fails deterministically. Reproduced twice, 280 s and 162 s, identical error.
`ready_history: "never-observed-ready"`.

This is a release finding on the Windows lane, not a host flake and not a
runbook artefact — see "Why this is not the runbook's fault" below.

| step | result |
|---|---|
| §1 curl-install | **PASS** — all three 1004-fue3 assertions |
| §2 destructive reset | **PASS** — clean room by 804-ckst |
| §3 fresh init | **FAIL** — control-wire handshake, exit 1, twice |
| §4 forge run | **NOT RUN** — gated on a clean §3, correctly |

## §1 — install (PASS)

- `install_exit=0`, pinned to the exact tag rather than `/releases/latest`
- installer verified SHA-256 `ad02f0562e5cdca36ad33039b26c84ca53a5be8f4e18500e5dcad85819d3d005` on `tillandsias-tray-56.9.12.1-windows-x64.zip`
- tray resolved at `%LOCALAPPDATA%\Programs\Tillandsias\tillandsias-tray.exe` — still NOT on PATH, so 1004-vsh2's fallback remains load-bearing
- `--version` exact-matches the tag: `tillandsias-tray 56.9.12.1 (7ed1327ec)`

## §2 — destructive reset (PASS, valid clean room)

- tray stopped; `wsl --terminate tillandsias` then `--unregister`, exit 0
- `tillandsias-build` SURVIVED (802-bajv's terminate-not-shutdown discipline did its job at this point in the run — but see finding 2)
- Credential Manager: `vault-shamir-share-v1` and `vault-root-token-v1` were both **present** and were cleared; `tillandsias-vm-uuid` preserved
- So this run satisfies 804-ckst, unlike 2026-08-17 whose stale share invalidated its "cold" claim

## §3 — fresh init (FAIL)

Provision reaches the end of install and dies at Connecting:

```
[provision] phase: 🔵 Starting Fedora Linux…
[provision] phase: 🔵 Connecting…
[provision] RESULT: FAILED — control-wire handshake did not succeed within budget:
            hvsocket open: secure handshake failed: noise: input error
```

Two runs, both from a genuinely pristine base (the distro was re-unregistered
between them):

| run | seconds | exit | error |
|---|---|---|---|
| cold | 280 | 1 | `noise: input error` |
| retry | 162 | 1 | `noise: input error` |

Nine backoff attempts (1→30 s) all fail identically. From `--diagnose --json`:

- `distro_registered: true`, `distro_running: true` — the VM starts; it is the
  secure handshake on vsock 42420 that fails, not the boot
- `ready_history: "never-observed-ready"`
- `wire.reachable: false`, `guest_version: null`
- `wsl_platform: "ok"`, `elevated: true`
- `guest_wiring: { tray_version 56.9.12.1, guest_version_before 56.9.12.1, outcome "skipped-version-match" }`

`status_exit=1`, `diagnose_exit=2` (diagnose exit is NOT asserted, per the
measured wire-lapse note in the runbook).

**Open question worth a second pair of eyes:** `guest_wiring` reports
`guest_version_before: 56.9.12.1` and skipped the wiring on a version match —
on a guest provisioned seconds earlier from a wiped disk. Whatever the guest is
reporting, the wire never completes a handshake with it. Given 1122-xi2f /
1126-w8rq territory (an embedded guest that is a 0-byte placeholder makes guest
injection a SILENT no-op), it is worth confirming the x86_64 guest embedded in
THIS zip is a real binary. I did not confirm it; stating it as a lead, not a
cause.

## Why this is not the runbook's fault

The first §3 attempt aborted for an unrelated PowerShell reason (finding 3
below). I re-unregistered the half-provisioned distro and re-ran from a true
pristine base before recording either data point above. Both recorded runs are
clean-room runs, and the second was a further retry on top. The failure is
reproducible and independent of the abort.

## Findings filed from this run

1. `windows-provision-control-wire-noise-handshake-v56.9.12.1-2026-09-12.md` — the release blocker above (capability: `release`, `windows`, `control-wire`)
2. `tray-recovery-runs-global-wsl-shutdown-2026-09-12.md` — the tray's own recovery path runs `wsl --shutdown`, violating 802-bajv from inside the product
3. `smoke-windows-block-defects-2026-09-12.md` — two defects in the runbook's §3 Windows block (stderr trap; stale evidence directory)

## Regime notes

- This lane is cold BY CONSTRUCTION (806-a4tu): `--unregister` takes
  `/root/.cache/tillandsias/models` with the vhdx. Warm-vs-cold is not a
  variable here; it has one value.
- Model re-pull was never reached — the run died before the guest was usable —
  so the 280 s and 162 s figures are NOT comparable to a full cold provision
  that reaches Ready. Do not use them as a provisioning benchmark.
