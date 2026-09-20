# Smoke: curl-install e2e — v56.9.19.2 STABLE — macOS — macneo (Tlatoanis-MacBook-Neo)

- run_start: 2026-09-20T09:17:48Z
- evidence_dir: target/smoke-e2e   (previous run archived under `_archived-20260920t091748z/`, 13 files MOVED not deleted)
- forge_lane_outcome: **NOT RUN — NOT APPLICABLE ON THIS LANE.** The `--opencode`
  forge lane is Linux/Podman only. Not a `cold-host guard stop`: the credential
  guard was never reached because the lane never ran. This run makes NO claim
  about agent behaviour.

Channel: **stable** — the one-shot post-promotion run the promote script
prescribes. Host: macOS 27.0 (26A428), arm64. Branch `osx-next` @ 17bc1854c.
Release under test: **v56.9.19.2**, confirmed `isPrerelease=false` at
`/releases/latest` before starting.

**NO NEW FINDINGS. PASS on §1/§2/§3.**

## What the STABLE arm tests that the daily arm cannot

This is the first macOS run of the DEFAULT OPERATOR PATH:

    curl -fsSL .../releases/latest/download/install-macos.sh | bash

with **no `TILLANDSIAS_RELEASE_BASE` and no pin**. Both earlier macneo smokes
(v56.9.19.1 and v56.9.19.2 daily) overrode that resolution, so until this run no
macOS smoke had ever proven that `/releases/latest` serves an installable macOS
artifact. The daily arm proves the newest prerelease installs; only this arm
proves the PROMOTED one does, by the route a real operator uses.

| step | assertion | result |
|---|---|---|
| §0.2b | README ledger row for the tag | present |
| §0.4 | prior evidence archived (13 files), no stale leak | PASS |
| §1 | `install_exit=0`, unpinned `/releases/latest` path | PASS |
| §1 | `/Applications`, no `~/Applications` fallback | PASS |
| §1 | EXACT tag `tillandsias-tray 56.9.19.2 (git 77aa56588, ...)` | PASS |
| §2 | `ok:e2e-step2-macos:destroyed`, 2.3 GiB destroyed, residue header-only | PASS |
| §3 | `provision_exit=0`, `{"status":"provisioned"}` | PASS |
| §3 | `rootfs.img` NEWER than the destruction marker — fresh, not a survivor | PASS |
| §3 | `diagnose_exit=0`; `.provisioned`; `.rootfs_present`; `.version == "56.9.19.2"` | PASS |

The clean room is verified, not assumed: 102 Fedora-image download progress
lines, i.e. the full 528 MB was re-fetched after the reset rather than reused.

## 1280-58kq verified in production on the branch a fixture could only simulate

That order's SECOND criterion — the regression guard — says the UNPINNED output
must be unchanged, so a real operator sees no difference. This run is the first
unpinned macOS install since the fix landed, and it holds:

    channel: stable
    resolving latest release

with **zero** occurrences of `channel: pinned`. Both lines are now TRUE
statements: the installer really is resolving `/releases/latest`. Before the fix
these same two lines appeared while a pinned PRERELEASE base was in force, which
is what made them a defect. The fixture asserts this arm with a stub; this is the
arm executing against a live install.

## Ledger claims

The v56.9.19.2 README row is present.

- **EXERCISED:** that the PROMOTED artifact installs from `/releases/latest` on
  macOS by the default path, self-identifies as 56.9.19.2 on two surfaces, and
  provisions from a wiped substrate.
- **EXERCISED:** the zero-code-delta claim, from this lane's angle only — macOS
  behaviour is unchanged from the daily arm of the same tag. This lane cannot
  verify the diff assertion itself.
- **NOT APPLICABLE:** everything the cut was actually for — the Windows tray job,
  the sidecar staging fix, the yolanda native validation, the MSIX constraint,
  the Linux Nix cache regime, and `litmus:opencode-prompt-e2e-shape` with its
  Console rate-limit red. The forge lane does not run here, so this run never
  reached an agent; absence is a property of the lane, NOT evidence about the red.
- **NOT CHECKED (this lane could have and did not):** `--with-metrics` guest
  checks, so `guest_version` and the guest/tray skew check remain untested —
  the same gap as both prior macneo runs, repeated deliberately rather than
  quietly dropped.
- **NOT CHECKED:** cosign signature verification. Bundles are published and the
  installer verified SHA256, but this lane ran neither `verify.sh` nor a cosign
  verify. See `1273-4mak`: no smoke on any platform has ever verified a
  signature, and this stable run — the one that gates promotion — did not either.

## Stated gaps — NOT passes

- **§3b container shutdown: NOT ASSERTED** on macOS (guest-side substrate), so
  1134-u934's class is untested on this lane.
- **§4 forge lane / §4b egress: NOT RUN**, Linux/Podman only.

## Findings status

No new findings. The four packets from the v56.9.19.1 macOS run:

1. `no-readme-ledger-row-v56-9-19-1` — REMEDIED; the row is present.
2. `install-macos-reports-stable-channel-for-a-prerelease` — **FIXED and
   verified here**, order 1280-58kq, landed ec1a8244a + e7235a57e. Both criteria
   hold on a live unpinned install.
3. `install-macos-provisions-and-is-not-a-download-test` — became order
   1281-pgit. Its swap half (534202d73) and documentation half (057212bc3) are
   on trunk; the DESIGN half stays explicitly unmet. §1 of this run still
   launched the tray and provisioned a VM, exactly as the runbook now documents.
4. `timing-duration-zero-collides-with-the-stub-sentinel-on-macos` — became
   macbookair's 1279-a7b6; not re-measured here.

## Observation — recorded, not filed (carried)

`kernel_present: false`, `initrd_present: false` on a provisioned host with
`provisioned: true`. `diagnose.rs` defines `provisioned` as `rootfs_present`
alone, so both false is by construction; whether the qcow2/Fedora-Cloud boot
path ever needs those files is a question for the macOS boot-path owner. Still
NOT filed as a defect.
