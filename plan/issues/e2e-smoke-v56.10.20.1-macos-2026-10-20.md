# v56.10.20.1 daily e2e smoke — macos: PASS (install, 4 consecutive clean cold launches after one unexplained stall, soft reset, rootful preview probe) (2026-10-20)

- verdict: **PASS** for v56.10.20.1 on macOS, with one finding. Install, full wipe and reprovision, the soft-reset retry and the guest's rootful preview probe pass. Of five cold first forge launches after a full wipe, the first stalled (rc=1, 300 s with no output); the next four passed consecutively. The stall is filed as 1810-sl5h.
- run_start: 2026-10-20T22:19:05Z
- evidence_dir: target/smoke-e2e on tlatoanis-macbook-air (previous run archived under _archived-20261020t221904z/)
- forge_lane_outcome: cold 1 FAIL (vsock_exec idle 300 s), cold 2, 3, 4, 5 PASS (rc=0, agent answered READY)
- signature_verification: cosign:verified:1/1

Release: v56.10.20.1 = `f0e61287e` (prerelease, publishedAt 2026-10-20T21:56:05Z, 34 assets; the macOS tray reports built 2026-10-20T22:13:35Z). Run on the coordinator's request, under the operator's standing instruction (2026-10-12) to smoke every release with the full-reset curl install. The user was warned in-session before the wipes.

| | |
|---|---|
| host | tlatoanis-macbook-air, macOS 27.0 arm64 |
| install | `curl -fsSL …/v56.10.20.1/install-macos.sh` with TILLANDSIAS_RELEASE_BASE/TILLANDSIAS_VERSION: curl_exit=0 install_exit=0 (ended 22:19:16Z); /Applications, no fallback path |
| version | `tillandsias-tray 56.10.20.1 (git f0e61287e, built 2026-10-20T22:13:35Z)` |
| final state | tray relaunched; `--diagnose --json` rc=0, version 56.10.20.1, provisioned true (22:58Z) |

    §1 install       PASS  exit 0, exact version, cosign verified 1/1 (verify.sh on the tar.gz bundle)
    cold 1 (wipe)    FAIL  destroy rc=0; --provision 22:19:30 → 22:19:41Z exit 0, fresh rootfs; --opencode → rc=1 at 22:27:07Z:
                           {"error":"opencode: vsock_exec: no data from guest for 300s — connection stale …"}
    cold 2 (wipe)    PASS  --provision 22:27:59 → 22:28:46Z, fresh rootfs; --opencode → 22:33:26Z rc=0, READY
    cold 3 (wipe)    PASS  --provision 22:33:59 → 22:35:11Z, fresh rootfs; --opencode → 22:41:45Z rc=0, READY
    cold 4 (wipe)    PASS  --provision 22:42:11 → 22:43:06Z, fresh rootfs; --opencode → 22:48:05Z rc=0, READY
    cold 5 (wipe)    PASS  --provision 22:48:18 → 22:49:01Z, fresh rootfs; --opencode → 22:54:46Z rc=0, READY
    guest check      PASS  every post-wipe boot of every cycle (2 per cycle): invalid_class=0, libsemanage=0; no
                           image-ensure failure markers; cycles 3-5: no OOM, hung-task or soft-lockup kernel lines
    1793 soft reset  PASS  planted a current-version forge-base marker over --exec-guest; installer SOFT reset; the
                           next boot logged "image-ensure-failures (failed-build markers)"; MARKER_ABSENT
    1794-rf3a probe  PASS  publish_local of a static site on a rootful guest: route_ready true, serving true

## Cold first launch 1: stalled with no output (1810-sl5h)

Cold 1 printed the first notice from each of the four detached image ensures (router, git, inference, forge), then nothing for 300 s, and the Mac side gave up with `vsock_exec: no data from guest for 300s — connection stale`. The parent loop in `crates/tillandsias-headless/src/main.rs` prints a heartbeat every 60 s while a helper runs. On v56.10.19.1 that heartbeat appeared and the launch finished in about 5 minutes. On this cycle no heartbeat appeared at all, which points at the guest process, or the whole guest, going quiet rather than at a slow build.

The evidence was lost. The cycle driver went straight into the next cycle's wipe, and the stop interrupted cycle 2's provision, so cycle 2 was rerun from a clean wipe. Cycles 2-5 were run with a driver that stops after each launch and captures the guest's image-build logs, failure markers, image list and the previous boot's kernel log. The stall did not recur in those four.

The only visible difference in cycle 1: it followed the installer's own tray launch (Application Support 2.4 G and Caches 698 M before the wipe), and it provisioned in 11 s against 43-72 s for the others. v56.10.19.1's cycle 1 started from the same 698 M cache and passed, so this is a clue, not a cause.

## 1792-48yg and 1784-skfj criterion 3 (three consecutive cold first launches)

**PASS on cycles 2-5 (4 consecutive), after one unexplained failure on cycle 1.** No "SELinux: Invalid class" and no libsemanage loader error in any boot after any wipe. Every image was built from scratch each cycle (the guest's image-build logs carry fresh build-progress lines for forge, inference, proxy, router, vault and git).

## 1794-rf3a live arm (a rootful guest probes the preview on the router's enclave address)

In a fresh forge on `~/src/kumbia-smoke`, a hand-made static site (`smoke-static/build/web/{index.html,sub/page.html,version.json}`; flutter create still hangs, 1804-fcx7) was published with `publish_local {"category":"WEB","runtime":"static"}`. Both `publish_local` and `service_status` reported `route_ready:true, serving:true, url https://www.kumbia-smoke.localhost:18443`. On a rootful guest that readiness comes from the probe this fix moved to the router's enclave address.

The arm's curl ran INSIDE the forge against that URL and got 000 for all three paths. That is the arm's fault, not the release's: inside the forge, `*.localhost:18443` is the forge container's own loopback, where nothing listens. Reaching the preview from the Mac's browser is 1794 (b), PR #594, not in this release. The run was bounded at 1500 s and finished in under 2 minutes.

## Ledger claims

**NO LEDGER ROW for v56.10.20.1** in README.md at the tag (fourth release in a row; 1806-rlg8).

- EXERCISED: 1792-48yg and 1784-skfj criterion 3 (as above), 1793-wggq criterion 1, 1794-rf3a (the guest's readiness probe), and on every forge launch the per-container credential files of 1118-fqfk slice 2a (the stack came up and the agent ran).
- NOT EXERCISED: 1795-rtfy (the window CDP relay), 1799-a6xi (Antigravity sign-in), 1798-nwpg (a Linux desktop tray companion), 1793's negative control, 1788 slices.
- NOT APPLICABLE: Linux- and Windows-only items.

## Findings

- **1810-sl5h** (p2, filed): one cold first launch in five after a full wipe went silent for 300 s and was killed by the vsock_exec idle timeout, with no heartbeat and no cause captured.
- **1806-rlg8** (open): no README ledger row, again.
- Arm design (not a release defect): a preview curl from inside the forge does not test host reachability. Future preview arms should check readiness in the guest, and run the browser-side curl from the Mac once #594 ships.

Scratch left on the host: `~/src/kumbia-smoke/smoke-static/`.
