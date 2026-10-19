# v56.10.18.1 daily e2e smoke — macos: FAIL (install PASS; 2 of 3 cold first forge launches FAIL) (2026-10-19)

- verdict: **FAIL** for v56.10.18.1 on macOS. The install and the full reprovision pass. The first forge launch after a full wipe fails, and the soft reset cannot recover it.
- run_start: 2026-10-19T08:41:02Z
- evidence_dir: target/smoke-e2e on tlatoanis-macbook-air (previous run archived under _archived-20261019t084102z/)
- forge_lane_outcome: cold 1 FAILED (guest SELinux broke podman, forge-base failed 3x); cold 2 FAILED (failure marker survived the soft reset); cold 3 PASS (rc=0) after the marker was removed by hand; arms5 on a new project rc=0
- signature_verification: cosign:verified:1/1

Release: v56.10.18.1 = `07dde8b07` (prerelease, publishedAt 2026-10-19T08:16:55Z, 34 assets). It contains the 1788-qlwq lands #551 to #559. Run on the coordinator's GO, under the operator's standing instruction (2026-10-12) to smoke every release with the full-reset curl install. The user was warned in-session before the wipe. Sibling heads at start: main 07dde8b07, linux-next f101e083e, windows-next b38f71052, osx-next 49731c152.

| | |
|---|---|
| host | tlatoanis-macbook-air, macOS 27.0 arm64, 10 cores / 16 GiB; guest 8 vCPU / 8 GiB, kernel 6.19.10-300.fc44.aarch64 |
| install | `curl -fsSL …/v56.10.18.1/install-macos.sh \| TILLANDSIAS_RELEASE_BASE=… TILLANDSIAS_VERSION=v56.10.18.1 bash`: exit 0 (08:41:0x → 08:41:32Z); sha256 ok 75823f529ca4…; pin 55c60a3b80d3; /Applications, no fallback |
| version | `tillandsias-tray 56.10.18.1 (git 07dde8b07, built 2026-10-19T08:37:17Z)`; `--diagnose --json` .version = 56.10.18.1 |
| full reset | `scripts/e2e-step2-macos.sh`: removed 7.0G VM state and 698M cache; residue empty; then `--provision` exit 0 (08:41:58 → 08:44:22Z), fresh rootfs.img newer than the destruction marker |

    §1 install       PASS  exit 0, exact version, signature verified (verify.sh on the tar.gz bundle)
    §2 destroy       PASS  VM dir and cache gone, residue empty
    §3 provision     PASS  exit 0; provisioned/rootfs_present true; .version 56.10.18.1
    cold 1 (wipe)    FAIL  --opencode ~/src/tillandsias 08:46:32 → 08:53:01Z rc=1. At 08:50:15 the guest kernel logged
                           "SELinux: Invalid class 0" (+ slow_avc_audit WARNING on podman). After that every podman exec failed:
                           "libsemanage.so.2: cannot open shared object file: Invalid argument" (health checks exit 127).
                           forge-base failed 3x and was marked failed. A reboot cleared it.        → filed 1792-48yg
    cold 2 (soft)    FAIL  install-macos.sh (SOFT reset), then --opencode 08:56:57 → 08:58:39Z rc=1:
                           refused:image-ensure:forge-base:build-failed-previously. The marker survived the reset; macOS has no
                           retry short of --reset-guest; the refusal names a log that does not exist.  → filed 1793-wggq
    (intervention)         removed /root/.cache/tillandsias/image-ensure-failures/forge-base.json over --exec-guest
    cold 3 (soft)    PASS  install-macos.sh, then --opencode 08:59:11 → 09:04:37Z rc=0, including the forge-base build;
                           the agent ran. No router wedge in any cycle (1784's conmon hang did not reproduce).
    end state        tray relaunched; final --diagnose --json rc=0, provisioned, version 56.10.18.1 (09:51Z)

## 1784-skfj criterion 3 (three consecutive cold first launches reach the forge)

**FAIL on v56.10.18.1: 1 of 3.** The router/conmon wedge did not recur. Both failures had new causes, 1792-48yg and 1793-wggq.

## 1788-qlwq live arms

Run in a fresh forge on a NEW local project (`~/src/kumbia-smoke`, one commit, no remote), with the image's own `/usr/local/sbin/tillandsias-plan`. Each arm is a scripted check that prints its own verdict line (forge log: 05-forge-arms5.log).

    slice 1  HOOKS-PATH            PASS  install-hooks rc 0, local hooksPath set and named, global hooks dir unchanged
    slice 2  PLAN-ON-PATH          PASS  login and non-login shells resolve it; the pre-push stub found the plan binary
    slice 3  WORK-REF-DEFAULT      PASS  work_ref written, work/1234-abcd ok, work/<id> refused as a template
    slice 4  DENIED-MESSAGE        PASS  the refusal printed the seed's own default_branch_denied text
    slice 5  DERIVE-HOOKS-PATH     PASS  derive lists pre-push from core.hooksPath
    slice 6  WARN-PHASE-LOUD       PASS  the warned push was accepted and says "THIS PUSH WILL BE ACCEPTED"
    slice 7  NO-CWD-METRICS        PASS  no .cache/ in either scratch project
    slice 8  NO-TRAILING-SLASH     PASS  no "game/" rendering in any output
    slice 9  NO-LANDING-PATH       NOT EXERCISED  a live level-2 promotion through the mirror relays to a GitHub origin (outward)
    slice 10 FLUTTER-ROUTE-ALLOWED PASS (allowlist)  the routed flutter.kumbia-smoke.localhost:18443 was admitted; the unrouted host
                                         was refused with URL_NOT_ALLOWED (negative control)
    slice 11 PREVIEW-SUBDIRS       FAIL (BLOCKED)  publish_local refused: router_not_ready, "exact-hostname CA-verified HTTPS probe failed"
    slice 12 FLUTTER-NO-CDN        PASS  `flutter build web`: useLocalCanvasKit:true, canvaskit/ bundled
    slice 13 DART-MATCHES-FLUTTER  PASS  standalone dart 3.13.5 = the Flutter-bundled Dart named in the packet
                                         (flutter --version printed no Dart line to cross-check)

Failing 1788 arms on the release:
- **1788-qlwq slice 11 FAIL (blocked)**: the preview never started; publish_local returned router_not_ready in two separate forges. Filed 1794-rf3a.
- **1788-qlwq slice 10, the window half (not the slice's criterion)**: browser_open of the admitted URL failed with BROWSER_LAUNCH_FAILED, the CDP socket never appeared. Filed 1795-rtfy.

Caveat: in a forge on the tillandsias project itself, the discipline arms failed. That forge put `~/.local/bin/tillandsias-plan` on PATH, built from the mounted checkout, and the local `~/src/tillandsias` is an old 0.4 checkout without `discipline`. It shadows the image binary. That is a stale-checkout effect, not a new-project defect. A new project gets the image binary (measured above).

## Ledger claims

**NO LEDGER ROW for v56.10.18.1** (nor for v56.10.17.1) in README.md at the tag; the newest row is v56.10.16.2. This is a finding for the release skill's append step. The claims below come from the release notes.

- EXERCISED: 1788-qlwq (above); the install, sha and signature path; the on-demand image ensure (1776-ondm/ch4m): images were built in detached helpers on first use, and its failure marker is 1793-wggq.
- NOT CHECKED: 1761-bvyn, the localhost-only preview CA. Its preview never published (1794-rf3a), which may be related; the cause is not named.
- NOT APPLICABLE: Linux/Windows-only items.

## Findings

- **1792-48yg** (p1, filed): on the first launch after a full wipe, guest SELinux "Invalid class 0" broke every podman exec (libsemanage EINVAL), and forge-base failed 3x.
- **1793-wggq** (p1, filed): the image-ensure failure marker survives the installer's soft reset, and macOS has no retry, so one transient fault refuses the forge until the next release.
- **1794-rf3a** (p1, filed): publish_local on macOS refuses with router_not_ready, a CA-verified HTTPS probe failure.
- **1795-rtfy** (p2, filed): browser_open on macOS fails with BROWSER_LAUNCH_FAILED, the CDP socket is never created.
- **No README ledger row** for v56.10.17.1 and v56.10.18.1 (reported to the coordinator; not a product packet).

Scratch left on the host: `~/src/kumbia-smoke` (smoke project) and `~/src/tillandsias/smoke-1788/` (arm scripts, untracked). Each forge's own copies are gone with its container.
