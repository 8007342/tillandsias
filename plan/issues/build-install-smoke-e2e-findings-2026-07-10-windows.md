# build-install-and-smoke-test-e2e (Windows) — findings — 2026-07-10

- discovered_by: `/build-install-and-smoke-test-e2e` (windows)
- host: Windows 11 Home 10.0.26200 (native, WSL2 substrate)
- branch: `windows-next`
- commit tested: `c52a1e2e` (order 261 ruby-free parity gate + order 154 slice 2
  push-topic tray transport — first local-build e2e covering slice 2 ea03e08e)
- version: `0.3.260709.4`
- run_id: 20260710T0100Z-series (see `target/build-install-smoke-e2e/CURRENT_RUN`)
- evidence: `target/build-install-smoke-e2e/<run-id>/*`

## Result: PASS — all Windows gates green

Full destructive cycle: local release build → direct-copy install (freshness
gate: embedded SHA `c52a1e2e` == HEAD) → `wsl --unregister tillandsias` +
cache/VHDX wipe → cold `--provision-once` (rootfs re-downloaded, distro
re-imported, dnf transaction 135 pkgs, headless services enabled) ending in
`RESULT: VM Ready — control wire up ✓`, exit 0 → `--diagnose --json` exit 2
(degraded-as-expected: distro registered, VM idled after the provision process
exited). 21 schema keys present, `build_commit=c52a1e2e`.

Note (per skill guardrail): this PASS covers build + install + destroy +
re-provision + diagnose. It does NOT validate the interactive tray surface;
the attended tray smoke remains tracked by
`plan/issues/windows-tray-parity-attended-smoke-gap-2026-07-09.md` (order 258).

Curl-install e2e not run this cycle: release hold active (16 parity gaps per
loop_status), no release newer than the plan's latest tested.

## Gates

| Gate | Result |
|---|---|
| 0 preflight | PASS — clean tree, branch `windows-next`, HEAD `c52a1e2e`, e2e-preflight `eligible` |
| 1 build (`scripts/build-windows-tray.ps1`) | PASS — exit 0, 1m43s |
| 1 install (direct copy to `%LOCALAPPDATA%\Programs\Tillandsias`) | PASS — `--version` → `tillandsias-tray 0.3.260709.4 (c52a1e2e)`, embedded SHA == HEAD |
| 2 destroy (`wsl --unregister tillandsias` + cache/wsl dirs) | PASS — distro no longer listed, cache + wsl dirs removed |
| 3 cold re-provision (`--provision-once`) | PASS — exit 0, `RESULT: VM Ready — control wire up ✓` |
| 3 diagnose (`--diagnose --json`) | PASS — exit 2 (degraded-as-expected), 21 keys, `build_commit=c52a1e2e` |
| 4 forge lane | n/a (linux-only lane) |

### Work Packet: smoke-finding/windows-freshness-probe-ps51-stderr-quirk

- id: `smoke-finding/windows-freshness-probe-ps51-stderr-quirk`
- owner_host: any
- capability_tags: [windows, e2e, skills, tooling]
- status: ready
- kind: optimization
- discovered_by: `/build-install-and-smoke-test-e2e` on `windows-next@c52a1e2e`
- evidence: >
    Gate 1 freshness probe `$ver = & <tray.exe> --version` captured an EMPTY
    string under Windows PowerShell 5.1 (the tray prints --version to stderr,
    and PS 5.1 native-stderr capture is unreliable/wraps in ErrorRecords),
    producing a spurious `FRESHNESS-GATE: FAIL` and a diagnostic detour. The
    working capture is `cmd /c "<tray.exe> --version 2>&1"`. This is the
    second consecutive Windows e2e run to burn a step on PS 5.1 output
    plumbing (2026-07-09 run hit Tee/NativeCommandError noise on the build
    gate).
- impact: >
    Every unattended Windows e2e cycle risks a false-negative freshness gate —
    the one gate that guards against silently testing a stale artifact.
- repro: PowerShell 5.1: `$v = & tillandsias-tray.exe --version; $v.Length` → 0.
- next_action: >
    Canonicalize the Windows freshness probe in
    `skills/build-install-and-smoke-test-e2e/SKILL.md` §1·Windows as a concrete
    `cmd /c ... 2>&1` snippet (mirroring the §1·macOS sed recipe), or emit
    --version on stdout in the tray (check clap/main wiring — stdout is the
    conventional stream for --version). One-line skill edit either way;
    overlaps `smoke-finding/windows-local-install-path-mismatch` (2026-07-09,
    still ready) which canonicalizes the same section.
- events:
  - type: discovered
    ts: "2026-07-10T00:55:00Z"
    agent_id: "windows-bullo-fable5-20260710T0010Z"
    host: windows
