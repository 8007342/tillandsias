# Smoke: curl-install e2e — v56.9.19.1 — macOS — macneo (Tlatoanis-MacBook-Neo)

- run_start: 2026-09-19T17:13:47Z
- evidence_dir: target/smoke-e2e   (no prior evidence existed; nothing archived)
- forge_lane_outcome: **NOT RUN — NOT APPLICABLE ON THIS LANE.** The `--opencode`
  forge lane is Linux/Podman only (skill Host Matrix). macOS has no §4 block.
  This is a stated gap, not a pass, and NOT a `cold-host guard stop`: the
  credential guard was never reached because the lane never ran.

Host: macOS 27.0 (26A428), arm64, Apple Silicon. Branch `osx-next` @ e2c5fbe71.
Channel: daily. Release under test: **v56.9.19.1** (GitHub `isPrerelease=true`).
Sibling heads at run start: main e2c5fbe71, linux-next e2c5fbe71,
osx-next e2c5fbe71, windows-next 3c4e3ffd7.

**Release scope: Linux + macOS only.** The Windows tray job failed at its build
step, so no Windows artifact shipped in this release; `windows-next` is
correspondingly behind the other three heads. Stated here because a reader
seeing three-of-four branches level would otherwise assume a three-platform cut.

## PASS summary

§1 curl-install PASS · §2 destructive reset PASS · §3 provision + diagnose PASS.
Init clean on a genuinely pristine substrate. The forge lane did not run (not
applicable on macOS), so this run makes NO claim about agent behaviour.

| step | assertion | result |
|---|---|---|
| §1 | `install_exit=0` | PASS |
| §1 | installed to `/Applications`, no `~/Applications` fallback | PASS |
| §1 | EXACT tag: `tillandsias-tray 56.9.19.1 (git e2c5fbe71, built 2026-09-19T17:09:36Z)` | PASS |
| §2 | `ok:e2e-step2-macos:destroyed`, `step2_exit=0` | PASS |
| §2 | `~/Library/Application Support/tillandsias` absent after reset | PASS |
| §2 | residue file header-only (`[macos-residue]`, nothing below) | PASS |
| §3 | `provision_exit=0`, `{"status":"provisioned"}` | PASS |
| §3 | `rootfs.img` NEWER than the destruction marker — fresh, not a survivor | PASS |
| §3 | `diagnose_exit=0`; `.provisioned==true`; `.rootfs_present==true` | PASS |
| §3 | `.version == "56.9.19.1"` — second surface for the tag | PASS |

1.7 GiB of pre-existing VM state and caches were destroyed before §3, so the
provision is from nothing: Fedora Cloud image re-downloaded (528 MB) and
converted during this run.

Recorded, deliberately NOT asserted (runbook says so): `release_tag=fedora-44`
is the guest image tag, not the release; `guest_version=null` and
`metrics_status=unsupported:no-live-wire-handle` because `--diagnose` without
`--with-metrics` does not boot the VM — asserting either would pass forever
without testing anything.

## Ledger claims

The release's README row is the source for this section. **There is none** — see
`smoke-finding/no-readme-ledger-row-v56-9-19-1` below. Claims were taken instead
from the PR #117 body, which the coordinator named as the substitute; that is a
weaker source, because a PR body is not the artifact's own durable description
and is not what a future reader of README will find.

Claims as stated in PR #117:

- **NOT APPLICABLE (not this lane):** gate on trunk 139e7027b — pre-build litmus
  369/0, launcher built+installed, post-build smoke 12/13, runtime residual 5/0,
  `scripts/release-preflight.sh ok`. All Linux-lane gate results; this lane
  neither reproduces nor contradicts them.
- **NOT APPLICABLE (not this lane):** the one shipped red,
  `litmus:opencode-prompt-e2e-shape` — the forge OpenCode agent failing on
  `Error from provider (Console): Rate limit exceeded`. The dispatch asked that
  this be recorded verbatim and not be allowed to fail install/provision
  verdicts. **It could not have:** the forge lane does not run on macOS, so this
  run never reached an agent at all. Recording it as NOT APPLICABLE rather than
  as "did not occur" — absence here is a property of the lane, not evidence
  about the rate limit.
- **EXERCISED:** that the published macOS artifact installs and identifies
  itself as this release — asserted twice, from `--version` and from
  `--diagnose --json .version`.
- **EXERCISED:** that a pristine macOS host provisions from nothing.
- **NOT CHECKED (this lane could have and did not):** guest-side behaviour under
  `--with-metrics`, which boots the VM — `guest_version` and the guest/tray skew
  check are therefore untested this run. The runbook permits skipping them; this
  run skipped them.
- **NOT CHECKED:** `smoke-init-pristine` timing record. The §3 provision ran in a
  detached block that emitted no timing record, so the longest step of this lane
  contributed no measurement. My omission, not a product defect.

## Stated gaps — NOT passes

- **§3b container shutdown: NOT ASSERTED.** On macOS the substrate is a
  Virtualization.framework VM, so the per-container stop/exit-code loop runs
  inside the guest or not at all. The runbook says to record this rather than
  report 3b clean. Order 1134-u934's defect class (a container burning its full
  grace and being SIGKILLed to a reported 0) is therefore UNTESTED on this lane.
- **§4 forge lane: NOT RUN**, Linux/Podman only. No claim about enclave
  bring-up, the credential guard, egress (§4b), or agent behaviour.
- **§4b order-298 egress assertion: NOT REACHED** — it depends on a running lane.

---

### Work Packet: smoke-finding/no-readme-ledger-row-v56-9-19-1

- id: `smoke-finding/no-readme-ledger-row-v56-9-19-1`
- owner_host: any
- capability_tags: [release, docs, testing]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v56.9.19.1`
- evidence:
  - `README.md` — `grep -c '^| v56.9.19' README.md` → `0`; no exact row and no
    DISTILLED span covering the tag.
  - Runbook §0.2b: "A MISSING ROW IS A FINDING, NOT A SKIP."
- repro:
  - `awk -v tag=v56.9.19.1 '...' README.md` per §0.2b → `NO LEDGER ROW for v56.9.19.1`
- next_action: >
    Append the v56.9.19.1 row to the README RELEASE/INTENDED FEATURES/BUGFIXES
    table, or determine why the release skill's append step did not run for this
    cut. Until it exists, every smoke of this tag must source its claims from PR
    #117, which is not durable: a future reader auditing what this release
    claimed to fix will find nothing in the artifact's own ledger. Note this cut
    was operator-directed fix-forward, so the append may have been bypassed with
    the manual path rather than failing.
- events:
  - type: discovered
    ts: `2026-09-19T17:13:47Z`
    agent_id: `macos-macneo-claude-20260919t171347z`
    host: macneo

### Work Packet: smoke-finding/install-macos-reports-stable-channel-for-a-prerelease

- id: `smoke-finding/install-macos-reports-stable-channel-for-a-prerelease`
- owner_host: macos
- capability_tags: [release, install, macos, observability]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v56.9.19.1`
- evidence:
  - `target/smoke-e2e/01-install-macos.log:1` — `  channel: stable`
  - `target/smoke-e2e/01-install-macos.log:2` — `  resolving latest release`
  - The release actually installed is v56.9.19.1, which GitHub reports as
    `isPrerelease=true`, fetched from the pinned `TILLANDSIAS_RELEASE_BASE`.
- repro:
  - `curl -fsSL "$BASE/install-macos.sh" | TILLANDSIAS_RELEASE_BASE="$BASE" bash`
    where `$BASE` points at a prerelease tag.
- next_action: >
    The install is CORRECT — the pinned base was honoured and the right asset
    downloaded (sha256 ok, exact-tag assertion passed). Only the log lines are
    wrong: they are emitted before the RELEASE_BASE override is considered, so
    they describe a resolution path that did not happen. Make the channel/
    resolution lines reflect the pin (e.g. `channel: pinned <tag>`), or suppress
    them when `TILLANDSIAS_RELEASE_BASE` is set. Low severity as a behaviour,
    higher as an instrument: an operator debugging a future bad install would
    read line 1 and wrongly conclude the stable channel served the artifact.
    Same family as the status-channel rows (1260-2qgi) — a message that reads
    like a report of what happened, produced by something that did not observe it.
- events:
  - type: discovered
    ts: `2026-09-19T17:14:00Z`
    agent_id: `macos-macneo-claude-20260919t171347z`
    host: macneo

### Work Packet: smoke-finding/install-macos-provisions-and-is-not-a-download-test

- id: `smoke-finding/install-macos-provisions-and-is-not-a-download-test`
- owner_host: macos
- capability_tags: [release, install, macos, docs, consent]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v56.9.19.1`
- evidence:
  - `target/smoke-e2e/01-install-macos.log:13` — `Launching Tillandsias (--init / VM provisioning runs automatically on first launch)...`
  - `target/smoke-e2e/01-install-macos.log:15` — `(Provisioning runs in the background on first launch — no extra step needed.)`
  - A `tillandsias-tray` process was running after §1 and had to be stopped by §2.
- repro:
  - Run §1's macOS block on a host with no prior install.
- next_action: >
    The runbook documents this hazard for LINUX only: "install.sh is not a
    download test — it runs the full init (1133-kktm) ... on an operator's
    workstation say what §1 actually does before running it; consent to a
    download check is not consent to a Vault bootstrap." install-macos.sh does
    the macOS equivalent — it launches the tray and begins VM provisioning — and
    no equivalent warning exists on the macOS path. Add one, and state it in the
    Host Matrix. This matters because most of the fleet's macOS hosts are
    WORKSTATIONS, not smoke hosts, and the runbook itself notes that distinction
    was missed once before (order 1004-vsh2). Harmless on macneo, which is a
    dedicated floor smoke host with operator pre-authorization.
- events:
  - type: discovered
    ts: `2026-09-19T17:14:00Z`
    agent_id: `macos-macneo-claude-20260919t171347z`
    host: macneo

### Work Packet: smoke-finding/timing-duration-zero-collides-with-the-stub-sentinel-on-macos

- id: `smoke-finding/timing-duration-zero-collides-with-the-stub-sentinel-on-macos`
- owner_host: any
- capability_tags: [tooling, metrics, macos, observability]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v56.9.19.1`
- evidence:
  - `.cache/metrics/tillandsias-timing.jsonl` — two records from this run:
    `{"step":"smoke-destructive-reset",...,"duration_ms":0,"exit":0}` and
    `{"step":"smoke-health-check",...,"duration_ms":0,"exit":0}`
  - `scripts/timing-log.sh` `timing_now_ms` — uses `date +%s%3N`, which is
    GNU-only; BSD date does not support `%3N`, so its own fallback arm degrades
    to `seconds*1000`. Confirmed live on this host: `timing_now_ms` returns
    `1789838494000` — whole seconds, zero ms digits.
  - `scripts/timing-log.sh` `timing_emit` — a record whose `_t0` is 0 is
    SKIPPED as "meaningless ... the path-skew fallback stub", i.e. 0 already
    carries the meaning "instrument was not available".
- repro:
  - On macOS: `. scripts/timing-log.sh; timing_now_ms` → value ending in `000`.
    Time any sub-second step and the emitted `duration_ms` is `0`.
- next_action: >
    On macOS the clock has 1-SECOND resolution, so every step faster than a
    second records `duration_ms: 0` — indistinguishable from the stub case the
    script itself treats as meaningless. Two different conditions produce the
    same value, and only one of them means "no measurement". Either use a
    millisecond source that exists on BSD (`python3 -c 'import time;...'`, or
    `perl -MTime::HiRes`), or emit an explicit resolution field / sentinel
    (`duration_ms: null` + `resolution: seconds`) so a sub-second real
    measurement is distinguishable from an absent one. This matters because
    1013-qv7c exists precisely so FLOOR hosts contribute timings, and macOS
    floor hosts are the ones now contributing zeroes.
- events:
  - type: discovered
    ts: `2026-09-19T17:22:00Z`
    agent_id: `macos-macneo-claude-20260919t171347z`
    host: macneo

---

## Observation — recorded, not filed as a defect

`--diagnose --json` reports `kernel_present: false`, `kernel_bytes: null`,
`initrd_present: false`, `initrd_bytes: null` on a host that provisioned
successfully and reports `provisioned: true` with a 250 GiB sparse
`rootfs.img`. The runbook asserts neither field, and this lane has no basis for
saying whether a direct-kernel boot path is expected to populate them on the
qcow2/Fedora-Cloud arrangement. Recorded so that someone who knows the design
can say it is normal — NOT filed as a finding, because "a field I do not
understand is false" is not evidence of a defect.
