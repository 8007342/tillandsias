# macuahuitl session handoff — ready to pick up (2026-09-02, ~19:30Z)

The operator is restarting the whole fleet with fresh sessions ("they've all
been going astray and off-topic; we need context reset"). This is the state
the next clean session on macuahuitl inherits. Read this, the `## Direction`
in `plan/loop_status.md`, and the last two `## Cycle` entries; nothing else is
needed to start.

## What is true right now

- **Stable release v56.9.2.1 is live** (`/releases/latest`, 32 assets, all
  three platform jobs green). Cut 2026-09-02 16:19–17:36Z from linux-next
  f9f383256 via PRs #103/#104; README ledger row and work-queue line
  recorded. The Linux asset was blessed here (SHA256SUMS + `--version`).
- **linux-next is clean and level**; windows-next and osx-next are fully
  integrated (drift 0 at 19:00Z). main = d6d3e3ed9 (VERSION 56.9.2.1).
- **This host**: installed binary `~/.local/bin/tillandsias` is **v56.9.1.2**
  (the pre-release local build; carries the lane-socket fix and pids 4096);
  images are at v56.9.1.2 (all ten, baked today); tree VERSION is 56.9.2.1.
  The tray is NOT running. `./launch.sh --which` prints exactly this; a lane
  launch will rebake images at the binary's version. To move this host to
  the stable binary: `./build.sh --install` (keep the autoincrement) or the
  curl installer from the release.
- The dev-inference container runs with `pids.max=4096` (live `podman
  update`, 811-28eh); the durable 1024 is in the code and applies on
  recreation.
- Daily maintenance is stamped for 2026-09-02. Disk 82%. nix cache up.

## What landed today (macuahuitl), for orientation only

811-28eh closed (inference exit(2) = 128 pids ceiling; 10,080-request
falsification run); 956-llei four rungs (cgroup cpu.pressure adjudicator,
retired-phase skip, censored timeouts, the runner's stdin defect that hid 36
tests); 867-vd4z closed (yaml+markdown ghost gate); 890-nkdz closed
(measurement practice + build_check_mix); 911-m7js closed (archiver check
memoised on the ledger); 658-kcd5 closed (ghost traces re-pointed; baseline
18→1); 930-i6x4 closed (plan fast lane no longer stales the gate stamp);
scripts/litmus-run-one.sh (run one litmus file through the real runner);
./launch.sh. Two coordinator instrument errors were caught and filed
(pgrep is ERE; `tail --pid=$!` watches the setsid parent), and the release
runbook was corrected in three places.

## Next actions, in order (the story is the unit)

1. **Re-arm the loops** (session crons die with the session; the cadence
   table in `methodology/multi-host-development.yaml` is LOCAL time):
   `/coordinate-multihost-work` at `23 0-22/2 * * *`; full
   `/meta-orchestration` at `38 2-22/4 * * *`.
2. **Start of cycle exactly as the skill says** — `scripts/cycle-preflight.sh`
   first. `select-work-batch.sh linux` will offer the convergence-velocity
   epic again; the open p1s there are 829-dkuc (deslop sweep protocol) and
   941-trcf (the gate as a plan, not a flat list). 956-llei has two rungs
   left (host-browser lane skip — needs the esmeraldinha per-step log; low-end
   budgets — needs scout measurements). The `ephemeral-guarantee` spec is
   owed (three litmus tests bind to it; see the ghost baseline).
3. **Operator-gated on this host**: launch the tray (`./launch.sh`); the
   first lane launch from it is the 959-fpc5 fresh-4096 sample AND the
   tillandsias.org website lane's first-socket-connection measurement (the
   lane-socket fix is in the installed binary; write the measurement into the
   website repo's plan/host-notes.md and push to the mirror).
4. **Fleet**: lenovinha drains reliably (one packet per cycle); yolanda holds
   803-49re; yoga's twin-pair assignment is RETIRED (805-r98w proved the
   hosts differ) — give yoga 793-zumy and the next linux-role packet.
   Pirria/esmeraldinha: the 959 sample when relaunched.

## Traps the next session must not re-learn

- Census the LIVE fold (`tillandsias-plan query --status ...`), never the
  checked-in plan/index.yaml.
- A test that "died" may be an instrument error: `pgrep -f 'a\|b'` matches
  nothing; `tail --pid=$!` on a nice/ionice/setsid chain watches the parent.
- After an image rebake, warm podman's keep-id layer copy once before the
  full litmus (four forge fixtures otherwise time out NOT contended).
- Stale `target-guest/` from a bumped `--install` reads as an integrity
  mismatch; clear it.
- Install builds keep the autoincrement (never `TILLANDSIAS_SKIP_VERSION_BUMP=1`
  with `--install`); only `--check` may skip it.
- The session can stall for hours with a correct clock (07.5h today between a
  green gate and the cut); trust `date -u`, and record what the clock says.
