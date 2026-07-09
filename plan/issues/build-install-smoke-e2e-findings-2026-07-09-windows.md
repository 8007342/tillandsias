# build-install-and-smoke-test-e2e (Windows) — findings — 2026-07-09

- discovered_by: `/build-install-and-smoke-test-e2e` (windows)
- host: Windows 11 Home 10.0.26200 (native, WSL2 substrate)
- branch: `windows-next`
- commit tested: `a68c9825` (post-merge of `origin/linux-next`)
- version: `0.3.260709.4`
- run_id: `20260709T201326Z`
- evidence: `target/build-install-smoke-e2e/20260709T201326Z/*`

## Result: PASS — all Windows gates green

Full destructive cycle on commit `a68c9825`: local release build → direct-copy
install (freshness gate: embedded SHA == HEAD) → `wsl --unregister tillandsias`
+ cache/VHDX wipe → cold `--provision-once` (rootfs re-downloaded, distro
re-imported, dnf transaction 135 pkgs, headless services enabled) ending in
`RESULT: VM Ready — control wire up ✓`, exit 0 → `--diagnose --json` exit 2
(degraded-as-expected: distro registered, VM idled after the provision process
exited; wire probe WSA 10060 until a tray holds the keepalive). 17 schema keys
present. Per the runbook, exit 0/2 pass; only exit 1 fails.

Note (per skill guardrail): this PASS covers build + install + destroy +
re-provision + diagnose. It does NOT validate the interactive tray surface;
an attended tray smoke follows this run.

## Gates

| Gate | Result |
|---|---|
| 0 preflight | PASS — clean tree, branch `windows-next`, HEAD `a68c9825` |
| 1 build (`scripts/build-windows-tray.ps1`) | PASS — exit 0, 2m53s, `tillandsias-tray.exe` 7,176,192 bytes |
| 1 install (direct copy to `%LOCALAPPDATA%\Programs\Tillandsias`) | PASS — `--version` → `tillandsias-tray 0.3.260709.4 (a68c9825)`, embedded SHA == HEAD (freshness gate) |
| 2 destroy (`wsl --unregister tillandsias` + cache/wsl dirs) | PASS — distro no longer listed, `%LOCALAPPDATA%\tillandsias\{cache,wsl}` removed |
| 3 cold re-provision (`--provision-once`) | PASS — exit 0, `RESULT: VM Ready — control wire up ✓` |
| 3 diagnose (`--diagnose --json`) | PASS — exit 2 (degraded-as-expected post-provision idle), 17 keys, `build_commit=a68c9825` |
| 4 forge lane | n/a (linux-only lane) |

### Work Packet: smoke-finding/e2e-preflight-not-windows-aware

- id: `smoke-finding/e2e-preflight-not-windows-aware`
- owner_host: any
- capability_tags: [testing, e2e, windows, tooling]
- status: done
- discovered_by: `/build-install-and-smoke-test-e2e` on `windows-next@a68c9825`
- evidence:
  - `scripts/e2e-preflight.sh:42-45` — the eligibility verdict emits
    `skip:no-podman-binary` whenever `podman` is not on PATH, which is the
    normal state on Windows: the Windows lane's podman lives *inside* the WSL2
    distro, not on the host. Verdict observed on this host:
    `target/build-install-smoke-e2e/20260709T201326Z/00-e2e-eligibility.txt`.
- impact: >
    The meta-orchestration E2E Gates table declares Windows eligible for
    local-build e2e, but the structured verdict the loop is instructed to obey
    unconditionally skips it on every Windows host. An obedient unattended
    cycle would never run the Windows e2e gate.
- repro:
  - `bash scripts/e2e-preflight.sh eligibility` on any Windows host → `skip:no-podman-binary`
- next_action: >
    Make `e2e_eligibility_verdict` host-aware: on MINGW/MSYS/Windows probe
    `wsl.exe` availability (and optionally WSL2 kernel presence) instead of a
    host podman binary; keep the podman probes for Linux. Pin with a litmus
    update to `litmus:e2e-eligibility-probe-shape`.
- resolution: >
    Fixed on windows-next: `e2e_eligibility_verdict` now has a MINGW*/MSYS*/
    CYGWIN* branch (mirroring the Darwin branch a linux/macos worker landed at
    f347053e in the interim) that keeps the deterministic XDG_RUNTIME_DIR
    no-session + smoke-lock branches and probes `wsl.exe` instead of host
    podman, emitting `skip:no-wsl` or `eligible`. Verified on this host:
    verdict flipped skip:no-podman-binary -> eligible; XDG override still
    yields skip:no-podman-user-session; grammar check emits exactly one
    well-formed line. Litmus grammar `^(eligible|skip:[a-z0-9-]+)$` unchanged
    (additive reason, same pattern the Darwin branch's skip:no-macos-hypervisor
    followed).
- events:
  - type: discovered
    ts: "2026-07-09T20:13:26Z"
    agent_id: "windows-bullo-claude-fable-20260709T2013Z"
    host: windows
  - type: completed
    ts: "2026-07-09T21:55:00Z"
    agent_id: "windows-bullo-claude-fable-20260709T2107Z"
    host: windows
    summary: "Windows branch added to scripts/e2e-preflight.sh (skip:no-wsl reason); verified eligible on this host."

### Work Packet: smoke-finding/windows-local-install-path-mismatch

- id: `smoke-finding/windows-local-install-path-mismatch`
- owner_host: any
- capability_tags: [install, windows, skills, documentation]
- status: ready
- discovered_by: `/build-install-and-smoke-test-e2e` on `windows-next@a68c9825`
- evidence:
  - `skills/build-install-and-smoke-test-e2e/SKILL.md` §1·Windows — says
    "Install the freshly built tray per the repo's Windows install convention
    (scripts/install-windows.ps1 against the local dist artifact)".
  - `skills/build-windows-tray/SKILL.md` §4 — says `install-windows.ps1`
    "rebuilds via the (now-safe) build subscript, copies to %LOCALAPPDATA%…".
  - `scripts/install-windows.ps1:1-230` — the actual script is the *curl
    installer*: it downloads `SHA256SUMS-windows` and the release zip from
    GitHub releases and has no local-artifact mode at all.
- impact: >
    Following either skill verbatim installs the *published release* binary
    instead of the local build, silently violating the e2e guardrail "Never
    substitute a published-release binary for the local build". This run used
    the direct-copy fallback instead (stop tray → copy
    `target/release/tillandsias-tray.exe` → `--version` freshness gate).
- repro:
  - Read `scripts/install-windows.ps1` — no parameter accepts a local zip/exe.
- next_action: >
    Either add a `-LocalArtifact <path>` mode to `install-windows.ps1` (skips
    download/SHA fetch, still does shortcut + two-layer verify), or update both
    skills to canonicalize the direct-copy local install path with the
    freshness gate. Update the stale §4 claim in `build-windows-tray` either way.
- events:
  - type: discovered
    ts: "2026-07-09T20:13:26Z"
    agent_id: "windows-bullo-claude-fable-20260709T2013Z"
    host: windows

### Work Packet: smoke-finding/tray-output-log-committed

- id: `smoke-finding/tray-output-log-committed`
- owner_host: linux
- capability_tags: [hygiene, git]
- status: ready
- discovered_by: `/build-install-and-smoke-test-e2e` on `windows-next@a68c9825`
- evidence:
  - `tray_output.log` (13 lines) is tracked at the repo root; it arrived in the
    `origin/linux-next` history merged on 2026-07-09 (visible in the merge
    diffstat). It is a generated runtime artifact, not source.
- next_action: >
    `git rm tray_output.log` on `linux-next` and add it to `.gitignore`
    (fits the existing generated-artifact ignore section).
- events:
  - type: discovered
    ts: "2026-07-09T20:13:26Z"
    agent_id: "windows-bullo-claude-fable-20260709T2013Z"
    host: windows
