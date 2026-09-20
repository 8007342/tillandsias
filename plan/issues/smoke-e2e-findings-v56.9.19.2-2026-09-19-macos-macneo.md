# Smoke: curl-install e2e — v56.9.19.2 — macOS — macneo (Tlatoanis-MacBook-Neo)

- run_start: 2026-09-19T18:55:10Z
- evidence_dir: target/smoke-e2e   (previous run archived under `_archived-20260919t185510z/`, 13 files MOVED not deleted)
- forge_lane_outcome: **NOT RUN — NOT APPLICABLE ON THIS LANE.** The `--opencode`
  forge lane is Linux/Podman only (skill Host Matrix); macOS has no §4 block.
  Not a `cold-host guard stop`: the credential guard was never reached because
  the lane never ran. This run makes NO claim about agent behaviour.

Host: macOS 27.0 (26A428), arm64. Branch `osx-next` @ ca33ccb7b.
Channel: daily. Release under test: **v56.9.19.2** (`isPrerelease=true`),
the stable-promotion candidate. Tray under test:
`tillandsias-tray 56.9.19.2 (git 77aa56588, built 2026-09-19T18:34:59Z)`.

**NO NEW FINDINGS.** All four packets from the v56.9.19.1 macOS run reproduce or
are resolved, one candidate was investigated and dismissed, and the run is a
clean PASS on §1/§2/§3.

## PASS summary

| step | assertion | result |
|---|---|---|
| §0.2b | README ledger row for the tag | **FOUND** — the .1 finding is REMEDIED |
| §0.4 | prior evidence archived, no stale leak | PASS |
| §1 | `install_exit=0`, sha256 `af6c2e5e…` ok | PASS |
| §1 | `/Applications`, no `~/Applications` fallback | PASS |
| §1 | EXACT tag `tillandsias-tray 56.9.19.2 ` | PASS |
| §2 | `ok:e2e-step2-macos:destroyed`, `step2_exit=0`, 1.2 GiB destroyed | PASS |
| §2 | app-support dir absent; residue header-only | PASS |
| §3 | `provision_exit=0`, `{"status":"provisioned"}` | PASS |
| §3 | `rootfs.img` NEWER than the destruction marker — fresh, not a survivor | PASS |
| §3 | `diagnose_exit=0`; `.provisioned`; `.rootfs_present`; `.version == "56.9.19.2"` | PASS |

**The clean room was verified, not assumed.** This provision completed in 42 s
against ~7 min on the .1 run, which looked like a cached image and would have
undercut the from-nothing claim. It was checked: `grep -c "Downloading Fedora"`
returns **102 progress lines in both runs**, the full 528 MB was re-downloaded
here, and `~/Library/Caches/tillandsias` does not exist post-reset. The
difference is download speed, not a warm cache. Recorded because the fast number
is the one a later reader would be suspicious of.

## Ledger claims

The v56.9.19.2 README row was present this run (`grep -c '^| v56.9.19.2 '` → 1).

- **EXERCISED:** the ZERO-CODE-DELTA claim, from this lane's angle only — the
  macOS artifact of .2 installs, self-identifies as 56.9.19.2 on two surfaces,
  and provisions identically to .1. This lane cannot verify the diff assertion
  itself (`.github/workflows/release.yml`, README, plan/ records); it observes
  that the macOS behaviour is unchanged, which is consistent with it.
- **EXERCISED:** that the macOS asset set of release run 35459238928 installs
  from a clean host (dmg + tar.gz + SHA256SUMS-macos, cosign bundles present).
- **NOT APPLICABLE (not this lane):** the entire reason for the cut — the
  Windows tray job shipping, the sidecar staging fix (1171-ccf2 / 723-wd8i), the
  yolanda native validation, the MSIX version-field constraint. macOS evidence
  says nothing about any of it.
- **NOT APPLICABLE:** the Linux job's Nix cache-miss regime, the Linux smoke on
  pirria, §3b's 1134-u934 confirmation (Linux-only on that lane).
- **NOT APPLICABLE:** `litmus:opencode-prompt-e2e-shape` and the Console API
  rate-limit red — the forge lane does not run here, so this run never reached
  an agent. Absence is a property of the lane, NOT evidence the red is gone.
- **NOT CHECKED (this lane could have and did not):** `--with-metrics` guest
  checks, so `guest_version` and the guest/tray skew check remain untested —
  same gap as the .1 run, deliberately repeated rather than quietly dropped.
- **NOT CHECKED:** cosign signature VERIFICATION of the macOS assets. The
  bundles are published and the SHA256 was checked by the installer, but this
  lane never ran `verify.sh` or a cosign verify. Naming it because "cosign
  bundles present" reads like a signature check and is not one.

## Stated gaps — NOT passes

- **§3b container shutdown: NOT ASSERTED** on macOS (guest-side substrate), so
  1134-u934's class is untested on this lane. pirria confirmed it fixed on
  Linux; that does not transfer here.
- **§4 forge lane / §4b egress: NOT RUN.**

## Findings status — all four .1 packets, tracked

1. `smoke-finding/no-readme-ledger-row-v56-9-19-1` — **REMEDIED.** The v56.9.19.2
   row is on origin and §0.2b found it. The coordinator identified the true
   cause as better than my filing: the row was composed and its land REFUSED by
   the ledger-distillation advisory (914-nkc4) at 11 rows against a policy of
   10, not "the append step did not run". The row and the distillation landed as
   one commit, which is the remedy the policy names. The sequencing lesson — a
   smoke go must wait for the row's land, or the row is part of the cut — is
   recorded in the .2 row itself.
2. `smoke-finding/install-macos-reports-stable-channel-for-a-prerelease` —
   **REPRODUCES.** `01-install-macos.log` still opens `channel: stable` /
   `resolving latest release` while installing v56.9.19.2, which GitHub reports
   `isPrerelease=true`, from a pinned `TILLANDSIAS_RELEASE_BASE`. Unchanged; no
   new packet, this is a recurrence event on the existing one.
3. `smoke-finding/install-macos-provisions-and-is-not-a-download-test` —
   **REPRODUCES.** `01-install-macos.log:14` — `Launching Tillandsias (--init /
   VM provisioning runs automatically on first launch)...`. Recurrence event.
4. `smoke-finding/timing-duration-zero-collides-with-the-stub-sentinel-on-macos`
   — **REPRODUCES, and this run supplies the CONTRAST CASE the packet was
   missing.** One run now contains both states:
   `{"step":"smoke-init-pristine","duration_ms":42000,"exit":0}` (a multi-second
   step, measured correctly) and
   `{"step":"smoke-health-check","duration_ms":0,"exit":0}` (a sub-second step,
   recording 0 — indistinguishable from `timing_emit`'s "instrument absent"
   sentinel). The clock works; only its 1-second resolution is the problem, so
   the remedy is resolution or an explicit sentinel, NOT a broken-clock fix.
   Append this as evidence to the existing packet.

Also closed from the .1 run's NOT-CHECKED list: `smoke-init-pristine` **was**
emitted this run (42 s). That was my omission last time, not a product defect,
and it is now fixed.

## Investigated and NOT filed

`install-macos.sh` moves an existing bundle to `/Applications/Tillandsias.app.bak`
(31 MiB, holding the previous `tillandsias-tray 56.9.19.1`). This looked like
unbounded backup accumulation on a host that smokes daily, and §2's destruction
does not touch `/Applications`. It is NOT a defect: `scripts/uninstall.sh`
removes the `.bak` sibling explicitly and its own comment states the design
("install-macos.sh moves any existing app aside ... nothing ever reads it"). A
single fixed-name `.bak` is overwritten by each install rather than accumulating.
Recorded so the next runner does not re-investigate it.

## Observation — recorded, not filed (carried from the .1 run)

`kernel_present: false`, `initrd_present: false` on a provisioned host, with
`provisioned: true` and a 250 GiB sparse `rootfs.img`. The coordinator traced
part of it: `diagnose.rs` `diagnose_snapshot` stats `vmlinuz` and `initramfs.img`
beside `rootfs.img` and defines `provisioned` as `rootfs_present` alone, so both
false on a provisioned host is by construction rather than a contradiction.
Whether the boot path ever needs those two files on the qcow2/Fedora-Cloud route
is decided in the VM launch code and was not traced by either of us. Stays an
open question for the macOS boot-path owner; still NOT filed as a defect.
