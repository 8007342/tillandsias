# v56.10.19.1 daily e2e smoke — macos: PASS (install, three wipe cycles, soft reset; 1788 slices 10/11 UNTESTED) (2026-10-19)

- verdict: **PASS** for v56.10.19.1 on macOS. Install, full wipe and reprovision, three consecutive cold first forge launches, and the soft-reset retry all pass. 1788-qlwq slices 10, 11 and 12 are UNTESTED, not failed: an upstream `flutter create` hang meant their fixture project never existed (1804-fcx7).
- run_start: 2026-10-19T21:01Z
- evidence_dir: target/smoke-e2e on tlatoanis-macbook-air (previous run archived under _archived-20261019t210148z/; an invalid first cycle run is kept under run1-no-wipe/)
- forge_lane_outcome: cold 1, 2, 3 PASS (rc=0, agent answered READY); arms forge on a new project: slices 1-8 PASS, 10/11/12 UNTESTED
- signature_verification: cosign:verified:1/1

Release: v56.10.19.1 = `b2f2f4766` (prerelease, publishedAt 2026-10-19T20:36:05Z, 34 assets). Run on the coordinator's GO, under the operator's standing instruction (2026-10-12) to smoke every release with the full-reset curl install. The user was warned in-session before each wipe. Sibling heads at start: main b2f2f4766, linux-next 7f05d459c, windows-next b38f71052, osx-next 49731c152.

| | |
|---|---|
| host | tlatoanis-macbook-air, macOS 27.0 arm64 |
| install | `curl -fsSL …/v56.10.19.1/install-macos.sh` with TILLANDSIAS_RELEASE_BASE/TILLANDSIAS_VERSION: curl_exit=0 install_exit=0 (ended 21:01:52Z); /Applications, no fallback path |
| version | `tillandsias-tray 56.10.19.1 (git b2f2f4766, built 2026-10-19T20:56:51Z)` |
| final state | tray relaunched; `--diagnose --json` rc=0, version 56.10.19.1, provisioned true (2026-10-20 18:3xZ) |

    §1 install       PASS  exit 0, exact version, cosign verified 1/1 (verify.sh on the tar.gz bundle)
    cold 1 (wipe)    PASS  e2e-step2-macos.sh rc=0, rootfs.img gone; --provision 21:16:05 → 21:16:31Z exit 0, fresh rootfs;
                           --opencode ~/src/tillandsias → 21:21:49Z rc=0, READY
    cold 2 (wipe)    PASS  destroy rc=0; --provision 21:22:01 → 21:22:45Z exit 0, fresh rootfs; --opencode → 21:28:52Z rc=0, READY
    cold 3 (wipe)    PASS  destroy rc=0; --provision 21:29:04 → 21:29:44Z exit 0, fresh rootfs; --opencode → 21:34:08Z rc=0, READY
    guest check      PASS  every post-wipe boot (2 per cycle, journalctl --list-boots): invalid_class=0, libsemanage=0;
                           no image-ensure failure markers, no podman-broken captures
    1793 soft reset  PASS  planted a current-version forge-base marker over --exec-guest; installer SOFT reset; next boot:
                           MARKER_ABSENT
    1788 arms        1-8 PASS; 10/11/12 UNTESTED (below)

Invalid first attempt, recorded so it is not mistaken for evidence: the first cycle driver called `scripts/e2e-step2-macos.sh` without its required LOG_DIR argument, which exited 2 without destroying anything, and the driver continued. Those three "cold" launches were warm. The evidence is under run1-no-wipe/; the driver now aborts when the destroy fails or rootfs.img survives, or when --provision reports "Already provisioned". All three cycles above are the re-run on real wipes.

## 1792-48yg live arm and 1784-skfj criterion 3 (three consecutive cold first launches)

**PASS on v56.10.19.1: 3 of 3.** No "SELinux: Invalid class" and no libsemanage loader error in any boot after any wipe; forge-base and the other images were built from scratch each cycle and the agent ran. The VM powers off when `--opencode` exits, so the guest check counts every boot since the wipe, not only the current one.

## 1793-wggq live arm (soft reset clears a failed-build marker)

**Criterion 1 PASS.** The guest's reset line names "image-ensure-failures (failed-build markers)". The installer's own log does not name it. The negative control (a marker that must SURVIVE because its source_digest matches) was NOT EXERCISED: it needs the real forge-base digest planted, which this run did not do.

## 1788-qlwq live arms

Run in a fresh forge on a NEW local project (`~/src/kumbia-smoke`) with the image's own tillandsias-plan.

    slice 1  HOOKS-PATH            PASS  rc=0, local hooksPath set and named, global hooks dir unchanged
    slice 2  PLAN-ON-PATH          PASS  login and non-login shells; the pre-push stub found the plan binary
    slice 3  WORK-REF-DEFAULT      PASS  work_ref written, work/1234-abcd ok, template refused
    slice 4  DENIED-MESSAGE        PASS  the refusal printed the seed's own message
    slice 5  DERIVE-HOOKS-PATH     PASS  derive lists pre-push from core.hooksPath
    slice 6  WARN-PHASE-LOUD       PASS  the warned push was accepted and says so
    slice 7  NO-CWD-METRICS        PASS  no .cache/ in either scratch project
    slice 8  NO-TRAILING-SLASH     PASS  no 'game/' rendering in any output
    slice 9  NO-LANDING-PATH       NOT EXERCISED  outward (GitHub origin)
    slice 10 FLUTTER-ROUTE-ALLOWED UNTESTED  no app existed to route; the agent printed "ARM 10 FAIL" but its first
                                   result was "no Dev server routed line / kumbia never created"
    slice 11 PREVIEW-SUBDIRS       UNTESTED  publish_local refused invalid_app_dir (build/web never built)
    slice 12 FLUTTER-NO-CDN        UNTESTED  no verdict line printed
    slice 13 DART-MATCHES-FLUTTER  not in this prompt

Why UNTESTED rather than FAIL: the fixture script's `flutter create --platforms=web … kumbia` ran through the forge's flutter shim (`images/default/cli/flutter` → `tillandsias/exec`) and never returned. `out-flutter.txt` holds only its first line (`date=2026-10-19T21:43:37Z flutter=/usr/local/sbin/flutter`). Slices 10 and 11 were expected to still fail on this release (1794-rf3a/1795-rtfy fixes are not in it); this run cannot confirm or refute that. The opencode session then sat for about 21 hours until it was stopped by hand on 2026-10-20 (1805-oxb3).

The slice-10 negative control did run: `https://not-routed-smoke.kumbia-smoke.localhost:18443/` was refused with `URL_NOT_ALLOWED: port must be 8080 (got Some(18443))`. Note that the refusal names the PORT, not the unrouted host; with no routed app to compare against, it does not show that host routing is what refused it.

## Ledger claims

**NO LEDGER ROW for v56.10.19.1** in README.md at the tag (third release in a row: v56.10.17.1 and v56.10.18.1 were also missing). Filed as 1806-rlg8.

- EXERCISED: 1792-48yg (3/3 cold first launches clean), 1793-wggq (criterion 1), 1796-ukey (install path), 1788-qlwq slices 1-8.
- NOT EXERCISED: 1793 negative control; 1788 slices 9-13.
- NOT APPLICABLE: Linux/Windows-only items.

## Findings

- **1804-fcx7** (p1, filed): `flutter create` through the forge's toolchain shim (tillandsias/exec) never returns.
- **1805-oxb3** (p2, filed): an `opencode run` in the smoke forge has no exit or time bound; it hung about 21 h. Backstop: the idle reaper, 1800-465n.
- **1806-rlg8** (p2, filed): the README release ledger has no row for v56.10.19.1.

Scratch left on the host: `~/src/kumbia-smoke` (smoke project).
