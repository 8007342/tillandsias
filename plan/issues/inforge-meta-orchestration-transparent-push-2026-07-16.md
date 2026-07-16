# GOAL: BigPickle/Hy3 runs /meta-orchestration inside the forge with a transparent push (Windows lane)

- Date: 2026-07-16
- Filed by: windows-bullo-fable5-20260716T0731Z (operator session goal)
- Operator directive: "We want a successful /meta-orchestration happening inside
  the forge, able to transparently push to remote." Linux builder is active
  ~2026-07-16T07:30Z→12:30Z (5 h) on 45-minute /meta-orchestration cycles and
  will pick up any linux-owned packet filed here.
- Related: order 350 (windows forge parity gate), order 382 (root-owned staged
  gitdir), order 318 DONE (mirror verified-ack relay), provisional
  windows-260715-4 (maintenance-session name collision), order 334
  (stable-milestone-v1), `git-mirror-push-false-success-not-relayed-2026-07-12.md`,
  `forge-credential-guard-push-channel-gap-2026-07-08.md`.

## Agent identities

- **BigPickle** — the opencode-harness in-forge agent (plan.yaml
  `big_pickle_template`; first full Windows in-forge cycle 2026-07-13).
- **Hy3** — in-forge agent identity observed in the operator's 2026-07-16
  curl-install session (orders 374/382 field evidence; correct MO-SMOKE
  grammar). Same lane class as BigPickle.

## Root cause chain, as measured on this host (Yolanda, Windows 11 + WSL2)

1. **Mirror false-success (P1)** — FIXED: order 318 landed synchronous
   pre-receive relay with verified acks (`aeebb939`, in v0.3.260715.6 guest
   images running here). A forge push now relays durably or fails loud.
2. **"Wire-lane insteadOf injection gap" — ROOT CAUSE FOUND (this cycle)**:
   `read_host_project_origin_url` (crates/tillandsias-headless/src/main.rs)
   shells out to `git`, but the WSL2/VZ guest OS ships NO git binary (git
   exists only inside forge containers). The launcher therefore got
   `None` and `write_forge_gitconfig` silently omitted the GitHub→mirror
   `url.insteadOf` rewrite on every wire lane. It was never a lane-launch
   injection wiring gap: the structural gitconfig injection engaged fine
   (order-350 crit-2a PASS on 2026-07-15); only the rewrite section was
   dropped, and the 2026-07-15 crit-2b FAIL was additionally masked by a
   no-origin parity fixture. FIX (windows-next, this cycle): fall back to
   parsing `.git/config` directly when the git binary is absent/fails
   (`parse_gitdir_origin_url`, 3 unit pins). PLEASE REVIEW: linux — shared
   code, also hardens git-less Linux/macOS hosts.
3. **Order 382 root-owned staged gitdir (P1)** — OPEN, linux pickup, ready.
   On this host the current `/home/forge/src/tillandsias` clone is
   forge-owned (Hy3's chown workaround was applied this morning), so the
   demonstration proceeds; unattended fresh installs still hit it.
4. **Maintenance-session name collision (windows-260715-4)** — OPEN, linux
   pickup, ready. Breaks lane RELAUNCH (125); a 45-minute recurring in-forge
   cadence hits it on every cycle after the first unless the stale
   maintenance container is removed. Workaround used here: `podman rm` the
   stale `tillandsias-<project>-forge-maintenance` between lanes.
5. **Stable-channel staleness (observation)** — the operator's 2026-07-16
   morning curl-install yielded tray `0.3.260712.1 (38d33cd8)` while
   v0.3.260716.1 exists; if the installer's default channel is the stable
   label, none of fixes 1-4 reach operators until a new stable is promoted
   (exactly order 334 stable-milestone-v1). Linux coordinator: confirm
   channel semantics and fold this goal's chain into the 334 burndown.

## Requests to the linux builder (5 h window)

- [ ] Review+merge the windows-next origin-url fallback commit (this cycle;
      shared headless code).
- [ ] Order 382: land the staged-gitdir ownership fix (P1, ready, shaped in
      packet; kills the manual chown).
- [ ] windows-260715-4: maintenance-session `--replace` fix (order-314 class;
      required for RECURRING in-forge cycles).
- [ ] Order 334: pull this chain into the stable-release burndown so the
      curl-install stable channel gains the working forge push path.

## Live evidence (2026-07-16, this cycle)

(appended as produced — see order-350 evidence doc for the probe protocol)
