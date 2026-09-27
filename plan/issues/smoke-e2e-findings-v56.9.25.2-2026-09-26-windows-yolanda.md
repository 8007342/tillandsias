# Smoke e2e findings — v56.9.25.2 — 2026-09-26 — windows — yolanda

- run_start: 2026-09-26T02:02:53Z
- evidence_dir: target/smoke-e2e   (previous runs archived under _archived-20260926t020253z/)
- forge_lane_outcome: not applicable — §4 is the Linux/Podman `tillandsias --opencode` lane; Windows has no `tillandsias` CLI (stated gap, not a pass)
- signature_verification: cosign:could-not-run:cosign-absent (winget install sigstore.cosign)

**Verdict: PASS (signatures unverified: cosign-absent).**

Operator authorized this destructive run on this workstation for this run (2026-09-26); coordinator GO from macuahuitl-fedora.
Channel set explicitly: TILLANDSIAS_CHANNEL=unstable plus TILLANDSIAS_VERSION=v56.9.25.2 (the exact-tag pin decides the base). 1369-sjbc is NOT in this build, so the installer prints no resolved-channel line.

## Sibling heads at run start

- main ce2da1f57
- linux-next 182033fd7
- windows-next 28ad32365
- osx-next 1bf1aad09

## Ledger row

The row for v56.9.25.2 is present on origin/linux-next (182033fd7).
- **Exercised on this lane:** the published install path, the installer-driven `--reset-state` reprovision, and a clean-room `--provision-once` from pristine.
- **Not applicable here:** the row's headline fix, 1371-a7w2 (Linux `--reset-state` keychain NoEntry). The nix http2/fallback change (1272-95ng) is a release-workflow fix and was proved by the release publishing.
- **Not looked at:** the embedded-Lua archiver apply path and 1366-d5v2 (developer tooling, not the installed product).

## Results

| Step | Result |
|---|---|
| §1 install (pinned v56.9.25.2) | install_exit=0 in 108 s; installer `--reset-state` → "VM Ready — control wire up", exit 0 |
| §1 version | `tillandsias-tray 56.9.25.2 (ce2da1f57)`, exact-bounded match to the tag |
| §1s signature | cosign:could-not-run:cosign-absent |
| §2 reset | tray stopped; `wsl --terminate` + `--unregister tillandsias` only (tillandsias-build, AlmaLinux-10 and Ubuntu untouched); vault-shamir-share-v1 and vault-root-token-v1 present→cleared; tillandsias-vm-uuid kept |
| §3 provision-once | provision_exit=0 in 64 s; fresh ext4.vhdx postdates the destruction marker |
| §3 status | status_exit=0, phase=Ready, podman_ready=True |
| §3 diagnose (last) | diagnose_exit=0, version=56.9.25.2 |
| §3b guest shutdown | not asserted on Windows (stated gap per the runbook) |
| §4 forge lane | not applicable (see above) |

**Memory:** the harness reaped NOTHING during this run. This host's WSL guest ran with the new 1339-r9xv swap keys (swap=8GB; SwapTotal 8388608 kB measured at 01:31Z). Before that, two background jobs here were reaped for host memory earlier the same day, with the 2 GB default swap.

**Run history, stated so the §2/§3 numbers are not misread:** the first §3 attempt ran under Windows PowerShell 5.1, and the harness block aborted on the tray's first stderr line (finding 2). That left a half-provisioned distro, so §2 was re-run (02-reset-rerun.txt, 02:06:39Z) before the clean §3 above. The §3 figures are from the second, clean pass.

### Work Packet: smoke-runbook-ledger-row-awk-fails-under-gawk

- **status:** ready
- **capability_tags:** [smoke, runbook]
- **finding:** §0.2b's awk (`$0 ~ "^\| " tag "( |\()"`) is fatal under gawk 5 on MSYS: `invalid regexp: unbalanced (`, preceded by "escape sequence \| treated as plain |". The ledger-row step then prints nothing, which reads like NO LEDGER ROW. This run used `grep -F "| $tag"` instead.
- **next_action:** escape for a dynamic regex (`"^[|] " tag "( |[(])"`), or match with index() on a fixed string; add a fixture that runs the block under gawk.

### Work Packet: smoke-windows-block-aborts-on-native-stderr-under-powershell-5

- **status:** ready
- **capability_tags:** [smoke, windows, runbook]
- **finding:** §3's Windows block sets `$ErrorActionPreference = 'Stop'` and then runs `& $tray --provision-once *>&1 | Tee-Object`. Under Windows PowerShell 5.1, a native command's stderr becomes a terminating NativeCommandError, so the tray's harmless `Failed to set locale, defaulting to "C.UTF-8"` killed the block mid-provision and left a half-built distro. It passes under pwsh 7.6 (`$PSNativeCommandUseErrorActionPreference = False`).
- **next_action:** state "run under pwsh 7" in the block and assert `$PSVersionTable.PSVersion.Major -ge 7`, or scope Continue around the native calls. Separately, the tray's locale warning on stderr is noise worth silencing.
