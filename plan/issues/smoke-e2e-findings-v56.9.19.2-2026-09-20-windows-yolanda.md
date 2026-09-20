# Smoke: curl-install e2e — v56.9.19.2 — windows / yolanda — 2026-09-20

- run_start: `2026-09-20T07:58:18Z`
- evidence_dir: `target/smoke-e2e` (prior evidence archived under `_archived-20260920T005818Z/`)
- channel: daily (prerelease), release base pinned to the tag via `TILLANDSIAS_VERSION`
- host: yolanda-windows, Windows 11 26200.9457, Ryzen 7, 16 GiB. Branch `windows-next`.
- operator consent: given in-session for the full documented reset, including the
  two Credential Manager entries (the runbook's §1/§2 consent line was put to the
  operator before §1 ran, naming the Vault bootstrap and the credential deletion).

## Verdicts

| § | verdict | evidence |
|---|---|---|
| §1 curl-install | **PASS** | `install_exit=0`; sha256 ok `3ac29ae269140504facd46ba772b76e892c9a87860e63161ebd5f393b4279d4d`; `tillandsias-tray 56.9.19.2 (77aa56588)` bounded-exact matched |
| §2 destructive reset | **PASS** | tray stopped (pid 9984), `terminate_exit=0`, `unregister_exit=0`, distro `tillandsias` gone from `wsl -l -v`; both guest-vault credentials absent; `tillandsias-vm-uuid` preserved |
| §3 pristine init | **PASS** | cold `provision_exit=0` in 91s, `RESULT: VM Ready — control wire up ✓`; rootfs postdates the destruction marker; one-block re-run: `phase=Ready podman_ready=True`, `diagnose_exit=0`, `version=56.9.19.2` = release tag |
| §3b shutdown | not run | out of scope for the Windows lane in this runbook |
| §4 forge lane | not applicable | the `--opencode` forge lane is Linux/Podman today |

PASS entry: v56.9.19.2 — Windows install clean, reset clean, init clean.
This is the third of the three platform reports the promotion requires.

## What this run does and does not establish

**ESTABLISHES**: the published v56.9.19.2 Windows artifact downloads, verifies by
sha256, installs, reports the exact release tag on two surfaces (`--version` and
`--diagnose --json`'s `version`), the runtime substrate destroys, and the enclave
re-provisions from a genuinely cold room — the rootfs at
`%LOCALAPPDATA%\tillandsias\wsl\ext4.vhdx` postdates the destruction marker
(01:01:09 vs 00:59:26), so it is a fresh provision and not a survivor.
This is the tray this fix-forward exists to ship: v56.9.19.1 shipped NO Windows
tray, and these are bytes no prior smoke executed.

**DOES NOT ESTABLISH**: §3b shutdown or §4 forge-lane behaviour, neither of which
this lane runs. Cold Ready durability is NOT established either — see finding 3.

## Findings

### 1. The §2 cache purge, taken literally, destroys the BUILD toolchain (capability: `smoke`, `windows`)

The runbook's Windows §2 says "cache purge" without naming a path. The obvious
reading — remove `%LOCALAPPDATA%\tillandsias` — is WRONG on any host that also
runs the builder distro: that directory contains `wsl-build\ext4.vhdx`, which on
this host is **142.9 GB and is the `tillandsias-build` distro's disk**, i.e. the
gate toolchain, not runtime state.

Measured: the removal was attempted and FAILED (`removed=False`) only because
`tillandsias-build` was Running and Windows held the file. On a host where the
builder is Stopped — its normal state between gates — the same command succeeds
and silently destroys the build environment. The smoke would then report a clean
reset while having deleted the host's ability to gate.

REMEDY: §2 must name the runtime paths explicitly and EXCLUDE `wsl-build`, or
assert the builder distro is untouched afterwards. esme's two-distro distinction
(`tillandsias-build` = gate, `tillandsias` = runtime, the smoke destroys only the
runtime) is correct and is exactly what the runbook's prose does not encode.

### 2. The §3 rootfs-freshness selector is ambiguous on a two-distro host (capability: `smoke`, `windows`)

The block selects the rootfs with
`Get-ChildItem $env:LOCALAPPDATA -Recurse -Filter ext4.vhdx | Where-Object { $_.FullName -match 'tillandsias' }`.
On this host that pattern matches TWO artifacts — the runtime's `wsl\ext4.vhdx`
AND the builder's `wsl-build\ext4.vhdx` — because `wsl-build` sits under a parent
named `tillandsias`. It resolved correctly here only because the runtime rootfs
happened to sort newest (01:01:09 vs the builder's 00:58:39).

Had a gate written the builder's disk after the marker — routine on this host,
where gates run for ~2 hours — `Select-Object -First 1` would have picked the
BUILDER's vhdx and the assertion would have passed while measuring the wrong
artifact, or failed spuriously. I added `-notmatch 'wsl-build'` to get a sound
measurement; the runbook should carry it.

### 3. Cold Ready durability is UNMEASURED here, and the reason is mine (capability: `smoke`)

My first `--status-once` poll after the cold provision read `status_exit=1`,
`reachable: false`, `WSA_ERROR(10060)`. That is NOT a provision failure and is
NOT filed as one. The runbook warns in terms: the §3 block is ONE script because
Ready is not durable after `--provision-once`, and "do not re-run `--status-once`
later and file its exit 1 as a provision failure". I had split §3 across three
PowerShell invocations, so my status reading was taken minutes after provision
exit — the documented trap, reproduced by my own step-splitting.

Re-run as the runbook prescribes (provision, poll, diagnose in one block) the
result is `provision_exit=0` warm in 7s, `phase=Ready`, `podman_ready=True` at
t+7s, `diagnose_exit=0`. So §3 PASSES on a valid measurement, and the state at
COLD provision exit remains unmeasured on this host. A cold one-block run is the
measurement that would close it.

Recorded so the next reader does not mistake the invalid reading for a defect,
and because it is the second time today that splitting a documented block
produced a false red.

### 4. §1 leaves a tray process running that §2 must kill — third instance

`install-windows.ps1` ends by LAUNCHING the tray ("Launching Tillandsias (WSL2
provisioning = --init will run automatically)"), leaving pid 9984 running and the
`tillandsias` distro Running before §2 began. macneo measured this on both the
v56.9.19.1 and v56.9.19.2 macOS smokes; this is the third instance and the first
on Windows. It also means §1 is NOT a non-destructive download check on Windows
either — it provisions — which is the 1133-kktm scope point.

Directly relevant to **1286-4437**: the installer defers provisioning to that
background launch instead of running `--provision-once` and exiting with its
status, which is the pre-fix result that packet names.

## Recorded, not findings

- Both `vault-shamir-share-v1` and `vault-root-token-v1` were ALREADY ABSENT
  before §2 (echo-count predicate, order 1004-vsh2 — the exit code does not
  discriminate). Nothing needed deleting, so the clean-room precondition held
  without the deletion the operator authorised. `tillandsias-vm-uuid` present
  and preserved, as designed.
- `%USERPROFILE%\.cache\tillandsias` (221.3 MB) was present and removed.
  `%APPDATA%\tillandsias` absent.
- Cold provision 91s on this host against esme's measured 117s cold / 18s warm on
  esmeraldinha; warm here 7s. Not comparable as durations (different hardware and
  cache state) — recorded for the two-Windows-host regime note.
- `diagnose --json` carries `version`, `guest_version` (both 56.9.19.2) and
  `build_commit` 77aa56588, so the release-tag assertion is MET on this build —
  unlike the macOS lane, where the field's absence made it unmet.
