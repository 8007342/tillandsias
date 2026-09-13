# Fleet restart 2026-09-12 — recovery drill, assignments, and the stable promotion plan

Coordinator: `macuahuitl-fedora` (message it by that name). The operator's
instruction to every host on 2026-09-12: macuahuitl leads; hosts report for
work and take assignments from it. This file is the durable copy of what the
coordinator says in messages, so a host that fetches origin can read it
without waiting for a reply. Filed by the coordinator; supersedes nothing in
`methodology/`.

> **Writing convention (from 2026-09-13T03Z):** this file has one writer, the
> coordinator. Every other host records its drill findings in its own file,
> `plan/issues/fleet-restart-2026-09-12-<host>.md` — a FLAT top-level name
> (created on first use, dated bullets, same shape as below), and the
> coordinator folds those files into this one on each coordination pass. Six
> hosts appending to one file produced two merge conflicts in a single cycle;
> per-host files compose the way ledger fragments do, and the fold is the
> fold. Flat, not a `.d/` directory: the pre-push plan-only lane accepts a
> plan/issues capture only at the top level or under one of its four class
> directories, and a nested path would force a full gate on every drill
> write on every host (lenovinha read the lane's case statement before the
> first host paid it, then measured both shapes against the hook through the
> issue-capture fixture's harness). The lane's table, so the next person
> inventing a directory finds out before paying: a flat `plan/issues/*.md`
> or a file under exactly one of `research/`, `exploration/`,
> `enhancement/`, `optimization/` takes the plan-only lane; any other
> subdirectory, or anything nested deeper, takes the FULL gate. A naming
> decision is a performance decision, and only the case statement says so;
> lenovinha pins both shapes in test-pre-push-issue-capture-lane.sh.

## Why every host starts with a recovery drill

Every host was rate-limited a few days ago in the same way macuahuitl was
(a cycle cut off between finalization and push). macuahuitl's checkout had
14 unpushed merges and two finished fragments sitting untracked for five
days. Assume yours looks the same. Its seven expired claims were released to
`ready` on 2026-09-11 by the coordinator with a what-is-left `next_action`
each: 1083-gzqj, 1084-x8ya, 1098-q7bk, 1109-t8kw, 1115-yvrq (released),
1074-96z9 and 1105-h8vr (closed). Your old claim is gone; re-claim what you
pick up, after reading the row's events.

The drill, in order, on your platform branch (`linux-next`, `osx-next`,
`windows-next`):

1. `git status --porcelain --untracked-files=all` — read it before anything.
2. `scripts/salvage-dirty-worktree.sh restart-<yyyymmdd>` — ALWAYS, before you
   decide anything about the dirt (order 872-c9nd). Report the `ok:salvaged:`
   ref and sha to the coordinator; that is the copy that survives a re-clone.
3. `git fetch origin --prune`, then merge `origin/linux-next` into your branch
   (the pre-push gate requires it anyway). Do not rebase merge commits.
4. Review your own dirt against the packets it belongs to. Land what
   implements a packet as its own commit citing the order; leave the rest in
   the salvage ref and say so. `scripts/check-resumable-claim-dirt.sh` is the
   detector; `resumable:` is a licence to review and land, never to auto-commit.
5. `scripts/cycle-preflight.sh` (rebuild the plan binary), then the guards:
   credential channel, committable branch, MCP health, capability row
   (`scripts/check-capability-row.sh`; on `due:`/`stale:` regenerate it).
6. Land with `scripts/land-on-platform-branch.sh <branch>` — never a
   hand-rolled fetch/rebase/push. Then take your assignment below.
7. Report to the coordinator in one message: the salvage ref, what you
   landed (as a CONDITION testable on origin, e.g. "203d56218 is an ancestor
   of origin/windows-next"), and what you are starting.

Run the three ledger-shape checkers before any land that files packets,
appends events, or compacts: `scripts/check-scorable-obligation-added.sh`,
`scripts/check-long-running-view.sh`, `./target/release/tillandsias-plan check`.
A new packet needs `verifiable_closure:` or `unscoreable:` in its OWN fragment
bytes; `set-field` cannot satisfy that gate. Events on archived packets are
refused; file a new packet citing the old packet_id.

## The release plan you are part of

- v56.9.11.1 was cut 2026-09-11: Linux and macOS artefacts published, the
  Windows tray job FAILED (1122-xi2f: the 1059-ry6t placeholder check demanded
  both guest arches while order-282 staging resets the non-host arch to zero
  bytes). The one-line fix landed on linux-next at 203d56218, applied blind
  from Linux.
- Next: a Windows host confirms the fix builds, the coordinator cuts the next
  daily (the version rolls forward; the operator ruled the label is a
  monotonic counter, "CRDT style"), every platform runs the curl-install
  smoke on it, and on green evidence from all three platforms the coordinator
  promotes it to `stable` (`gh release edit --prerelease=false --latest` plus
  the `stable` tag). The current stable, v56.9.2.1, is broken per the operator.
- Smoke evidence is a `plan/issues/` report or a ledger event per host, PASS
  or the findings, with the release tag and the host's regime in the first
  line. A smoke that finds nothing writes a PASS report; silence is not a pass.

## Assignments (first pass; the coordinator adjusts on your report)

| host | branch | after the drill |
|---|---|---|
| yolanda-windows | windows-next | (1) confirm 1122-xi2f: `/build-windows-tray` on a checkout where `git merge-base --is-ancestor 203d56218 origin/linux-next` holds and origin/linux-next is merged in; paste the packaging verdict into a 1122-xi2f event. (2) when the next daily publishes: `/smoke-curl-install-and-test-e2e` (Windows), file findings. |
| esme-windows | windows-next | (1) `/probe-macos-tray-on-windows` daily probe. (2) when the next daily publishes: `/smoke-curl-install-and-test-e2e` on this floor-tier host — a release smoke compiles nothing and is exactly the tier's work. Do not take general-queue drain. |
| yoga-silverblue | linux-next | (1) `/smoke-curl-install-and-test-e2e` on v56.9.11.1 NOW (immutable Linux lane: published releases, never local builds), then again on the next daily. (2) 1115-yvrq, your own packet, released to ready: its next_action step 6 needs a real `select-work-batch.sh` run on an immutable host — that is you. |
| lenovinha-silverblue | linux-next | (1) your two work branches are unmerged on origin: `work/1069-c9w6` (the 1063-nraf fixture fix) and `work/1087-h2z9` (a new gate step + `test-gate-divergence-is-declared.sh`, whose declaration file is now live on trunk and refused a coordinator land once) — decide, then land or say why not. (2) curl-install smoke on the next daily. |
| macbookair-macos | osx-next | (1) `/smoke-curl-install-and-test-e2e` on v56.9.11.1 (Tillandsias.dmg + tar.gz are published), findings to plan/. (2) nothing else for now — macneo is back and owns 1084-x8ya. |
| pirria-cachyos | linux-next | (1) salvage FIRST: 1098-q7bk's next_action records a local draft on pirria (an arm plus a PID-1 mutant control) that never pushed. (2) 1098-q7bk is ready and yours by history; 1096-p3tn (timing log written to two paths) is also yours. Floor-tier: no general-queue drain. |
| macneo-macos | osx-next | reported 01:40Z. (1) 1084-x8ya is macneo's again (macbookair told to drop it). (2) `/build-macos-tray` on the merged tree; findings to plan/issues/macos-build-findings-<DATE>.md. |

Do not run `./build.sh --check` per packet; one land per pass. Do not arm a
cron or reopen a cycle on the coordinator's behalf. Ask before touching a
surface another host's claim names (`tillandsias-plan expire-claims
--list-live` after the merge, not before).

## Hazards found during the drill (2026-09-12, first hour)

- **A killed land TASK can leave a live land PROCESS** (yolanda): the harness
  reported "killed — low on memory" with an empty log, the re-run started a
  second `land-on-platform-branch.sh`, and both ran `build.sh --check` against
  the SAME CARGO_TARGET_DIR — a self-inflicted starvation loop that looks like
  flaky infrastructure. Rule: before re-running a land, `ps -ef | grep
  '[l]and-on-platform-branch'` and kill survivors; never conclude a land's
  outcome from its task status; verify only with `git merge-base --is-ancestor
  <sha> origin/<branch>` after a fresh fetch. A kill inside `build.sh --check`
  cannot leave a half-push — the script pushes only after the gate.
- **The smoke item is a request, not consent** (macbookair, yoga): on an
  operator workstation `/smoke-curl-install-and-test-e2e` destroys the VM or
  podman substrate, and the skill says a peer's instruction is not that
  authorisation. Both hosts asked their operator and proceeded on the
  operator's word. That is the correct reading of the assignment table.
- **Compaction skips the status join** (yoga, 1123-k3mq): the runtime fold is
  a monotone join over the status ladder, not last-write-wins; compaction
  wrote a newer `ready` over an older `completed` into the base. Every row the
  coordinator moved on 2026-09-11 is exposed to a returning host's older
  higher-ladder fragment; check `status <order>` on the fold, never the base
  row; move a row DOWN only with `--reopen-evidence` (650-dq6u).
- **Two work branches declined as superseded** (lenovinha): work/1069-c9w6
  and work/1087-h2z9 both had same-subject twins on trunk plus trunk-only
  follow-ups; landing either would have regressed trunk. Dispositions are
  ledger notes. An unmerged ref on origin is otherwise indistinguishable from
  forgotten work.
- **Enclave services dead for ~5d9h on two hosts** (lenovinha, macuahuitl),
  self-healed by cycle-preflight; dates the outage to about 2026-09-06T16Z.
- **Two probe defects filed by the probes' own subjects**: check-host-tools
  resolves cargo through its PATH repair but not rustup, so installed musl
  targets read MISSING (macneo); host-capability-probe labels every Windows
  row `host: linux_mutable` (yolanda).
- **Restage the guest before `/build-windows-tray`** (yolanda): a returning
  Windows host's `target-guest/` is weeks old (54.0.0 on yolanda, from
  2026-08-30); the 689-gipe version check resets a stale staged guest to the
  zero-byte placeholder, and the 1059-ry6t check then throws "guest asset is
  a placeholder" — a true verdict about the host and a false one about
  1122-xi2f. Build or download the source-matched guest first (the skill's
  step 2 cargo path when Nix is absent). Never fake a non-empty asset.
- **A landing freeze lasted about an hour** (02:00Z–02:15Z): yoga's honest
  reopen of 1115-yvrq left a `completed` event beside an `in_progress` fold,
  `check-fragment-status-loss.sh` refused it, and the mandated pre-push merge
  of trunk spread the refusal to every platform branch. Fixed on trunk by
  teaching the guard that a later `falsified` event supersedes the closure
  (ac0ea1089); the lane that let it through is 1124-7f3u.
- **A guard that scans binaries** (yolanda): `check-proxy-permissive-port-routing.sh`
  puts `--include='*.rs'` AFTER `--`, so grep applies no filter and a staged
  guest binary under crates/ "references 3129". Fires only on a Windows host
  between staging and packaging. One-token fix; yolanda's packet.
- **A packaging report is only a verdict if it ends in `Built:` or a throw**
  (yolanda): a killed Start-Process left a log ending mid-build with neither;
  the assets looked correct and it read as a pass. Check the exe's
  LastWriteTime, not the log's last line.
- **A gate that overwrites live guest state** (macneo, 1127-xm3m): one unit
  test in the macos-tray crate writes the user's real crashloop.state with
  `ever_ready 1`, so every `./build.sh --check` on a Mac destroys the evidence
  a guest packet measures. macbookair's 980-ja2m instance rests on that file.
- **Two lanes, one report filename** (macbookair, macneo): the smoke runbook
  templated the report path without a host field; two platforms smoking one
  release on one UTC day collide add/add at land time, and "take one side"
  deletes a platform's result. Keep both; the template now carries
  `<host_kind>-<host_id>` (1004-fue3 event).
- **The cap must cross into WSL** (esme): `CARGO_BUILD_JOBS` exported in the
  Windows shell does not reach `build.sh --check` inside the distro; export
  `WSLENV=CARGO_BUILD_JOBS/u` too, or a 16 GB host compiles the whole
  workspace unbounded and the harness kills the land.
- **Compaction charges the hosts that have not pulled it** (pirria,
  1126-vswr): a behind tree diffed against a current base sees every fragment
  compacted since as ADDED — 650 plan invocations at 2.9s in the debug
  binary, ~30 min of one floor gate. The wrong first explanation is kept
  beside the correction in the packet, on purpose.
- **Cut freeze versus gate freeze**: from the release gate's start to stage
  2's back-merge push, a code landing on linux-next moves the head past the
  gated one and restarts the gate; plan/, docs and skills/ are exempt, and
  platform-branch syncs of green trunk never touch the cut.
- **Split /bin on macOS** (macneo, fourth regime gap of the night): a fixture
  that derived its scratch PATH from the directories holding `bash` and `git`
  (e6a834746) had no `dirname` on a Mac — /bin and Homebrew carry no coreutils —
  so every Mac gate went red on a script that died before its own skip. Fixed
  by donating `dirname`'s directory (7c746366c). Same lesson as the other three:
  "measured green" is a property of the regime that measured it, and wiring or
  authoring a gate step should say which hosts newly run it and on what.
- **The control wire's root cause** (macbookair, confirmed on trunk and on
  Windows): release builds derive the handshake key from each binary's OWN
  self-hash, so a tray and a musl guest never share a key; it surfaced only
  once the wire was secure by default (post-v56.9.5.1) and only where a guest
  VM exists. Rulings, fix routing and the closure tests are on 1084-x8ya.
- **A gate step with no path operand hangs on a piped stdin** (macbookair
  found it, lenovinha named the mechanism, fixed on trunk at d15aaf3d4):
  `scripts/check-cheatsheet-refs.sh` handed ripgrep globs, a pattern and
  `--replace` but no path, so rg read stdin; under an inherited pipe that
  never closes it blocks forever, and the trailing `|| true` never runs
  because rg never returns. It presents as a land with no verdict, not a red
  (43 min on macbookair). `< /dev/null` does NOT reproduce it (EOF); a FIFO
  control does: pre-fix rc 124 under `< <(sleep 60)`, post-fix the script
  returns. It was green everywhere it had ever run because every prior stdin
  delivered EOF. lenovinha's rule, learned by breaking three regimes in one land and
  adopted with that provenance: **promoting a check from `--ci-full` to
  `--check` is a change of blast radius, not of frequency** —
  it changes which hosts, which userlands and which stdin shapes run the step,
  and 1087-h2z9's triage of 22 checks into `--check` produced four regime gaps
  (root, no rg, BSD grep, split /bin) and this fifth one (stdin shape) in one
  night. esme flipped sides mid-night by installing rg: from "refuses for lack
  of rg" to "can hang" without ever having run the step; it takes the first
  post-fix run as the positive control.
- **A push quiet is an instrument, and one was enough**: a two-fix code land
  from macuahuitl was refused three times as `attempts-exhausted` while origin
  moved every ~2.5 min under an ~8 min gate; every loser pays a full gate to
  re-enter a race it may lose again (yoga: two attempts at ~4 min each on a
  Silverblue host). Under a ten-minute fleet-wide quiet the same land passed on
  attempt 1. macbookair's corollary: a slow host is not a quiet host — it
  pushes late, decoupled from any state it last observed, and is the worse
  neighbour in a race. Landing order after the quiet was assigned per branch
  (one host at a time per platform branch, each messaging its SHA to the next)
  rather than a free-for-all.
- **The agent harness kills its own background waiters under memory
  pressure during a gate** (macuahuitl, twice in one land): two
  `run_in_background` polling loops were stopped with "the system is running
  low on memory" while `./build.sh --check` ran, though `free` showed 53 GiB
  available. The `setsid nohup` land itself survived both kills, and a
  Monitor task polling the same log did not get killed. Detach the long job,
  and watch it with Monitor rather than a background shell.
- **A correct guard landed alone breaks the fleet when the suite manufactures
  the state it refuses** (pirria, 1096-p3tn): the packet blamed the metrics
  split (`/tmp/tillandsias-timing.jsonl` beside the checkout's log) on a
  best-effort sourcing stub. An `ls -l` before and after one gate caught the
  real writer: litmus fixtures that build a scratch root without a `.git`,
  symlink `scripts/` into it and EXECUTE from there without naming a log
  (resolution follows the executed script's location, not the cwd — three
  fixtures, not the eleven first claimed; the other eight patches are
  defence-in-depth, and every step name in the nine preserved records maps to
  those three), so `metrics_default_log`
  takes its documented no-checkout `/tmp` fallback — deterministically, on
  every host, every gate, exactly matching the packet's own 2026-09-06
  evidence. The reader guard pirria wrote is right and would have refused
  metrics on every host after every gate, because the gate recreates the
  split it refuses — so the guard's FIRST firing is guaranteed and
  fleet-wide, at the moment it lands, not probabilistically later. Ruling: guard and cause land together (each fixture names
  its own scratch log), the packet's stated cause is recorded as falsified,
  and the guard must not trip once per host on the stale `/tmp` file every
  host already carries from tonight's gates.
- **Watch a gate for a stall, not only for a verdict** (macbookair, after
  reporting a dead land as "slow" twice): a hung gate never produces the
  verdict a waiter is polling for, so "still gating" is indistinguishable from
  "dead" to a watcher that only greps for `ok:`/`refused:`. macbookair's land
  of e1100c919 ran under a watcher that polls the gate log's mtime and reports
  STALL when it goes five minutes without advancing. One command; adopt it for
  every detached gate. Also confirmed there: the host-qualified smoke report
  filename holds — origin/osx-next carries three v56.9.12.1 reports side by
  side (linux_immutable-lenovinha, linux_mutable-macuahuitl, macos-macbookair)
  where two lanes collided on one name five hours earlier.
- **A fixture green through both of its own defects** (lenovinha, 1127-waxf,
  during the quiet window): the packet's fixture stayed 5/5 while the full
  gate refused twice — once because `verifiable_closure:` was prose describing
  a fixture instead of naming one (977-448j's refusal, fixed by naming
  `scripts/test-gate-stamp-does-not-memoize-guard-owned-paths.sh` and its
  pre-fix measurement, not by reaching for `unscoreable:`), and once because a
  symmetric "refuse when the checker is absent" guard broke
  `test-gate-stamp-scope.sh` case 7. The distinction behind the second: the
  plan binary is a BUILD ARTIFACT, commonly absent, so its absence is a live
  hole; the checker is TRACKED, so its absence is not a state a real checkout
  reaches and `build.sh` would fail the full gate anyway. A guard on an
  unreachable state is pure cost — it obliges every fixture driving the lane
  to provision the file. Reverted with the reasoning left in the file. The
  contrast case, same night: `issue-capture-lane`'s CONTROL arm also objected,
  and there the change was KEPT and the arm taught a third verdict — its intent
  is qualification (a fragment is not turned away as outside the allowlist),
  and a fail-closed refusal is not a qualification failure; folding it into
  `bad` would have pinned the pre-1124 behaviour as the contract. Both looked
  identical from outside ("my change broke someone's fixture"); only one was
  overreach, and the test that separates them is "is this a state a real
  checkout reaches", which differs for artifacts and tracked files even when
  the code shape is identical. Neither
  defect was visible from the fixture that owns the packet; only the run that
  contained the other checks saw them, which is the claim 1127-waxf makes.
- **The first Windows host back paid nine land attempts and six real gate
  refusals, none of them noise** (yolanda, landed at 42551c649): the
  proxy-permissive-port guard scanned a 14 MB binary because `--include`
  after `--` is inert (1127-apa8, fixed); publishing a capability row wedged
  every push with plan-ledger-incomplete (1128-4ffr); ripgrep was absent from
  a WSL toolbox nothing provisions (1129-xm5z); `chmod 000` does not constrain
  root so no Windows gate could pass the spec-index arm (1129-3yv7, fixed);
  a fragment closed itself with no evidence (fixed); and the guard auditor
  read five orphans through Windows symlink materialisation (trunk fix
  7b9b58e55). Each refusal was a defect the fleet did not know it had. What
  esme inherits for free from that land is the list above; what no commit
  can do for a host is install rg in its build distro.
- **Fleet rule until 1127-waxf lands: a plan-only land proves nothing about
  the ledger guards** (yoga, applied by lenovinha and macuahuitl): a commit
  touching only `plan/index.d/*.yaml` cannot stale the gate stamp, so
  `./build.sh --check` memoizes out and the fragment-schema and status-loss
  guards never execute — the exact path 1115-yvrq's reopen took when it froze
  the fleet. Before every plan-only land, run by hand and report the COUNTS,
  not a bare verdict (violation:0 cannot distinguish clean from never-ran):
  `scripts/check-fragment-status-loss.sh` (`ok:no-fragment-status-loss:<n>
  checked`) and `tillandsias-plan check --strict-fragments` (`ok: <n>
  packets`).
- **Refusing a caller that had not asked the question** (pirria, three times
  in one night, named as a standing shape): an empty-variable check that would
  have refused a correctly anchored CLAUDE_PID path (caught by yoga's negative
  control); a source-time refusal of a caller that had already named its logs
  (caught by `test-memo-hit-observability` arm 3); and, shipped in 68d404947,
  a metrics split guard placed BEFORE `cycle-metrics.sh`'s subcommand branches,
  so a TIMING-log split refused an unrelated FLOW append and
  `test-cycle-flow-emit-idempotency.sh` failed 12 scenarios on a host
  carrying the night's fixture debris — clean on pirria only because the
  control that proved the writer fix had cleared /tmp first. CORRECTED within
  the hour by lenovinha: that fixture runs in NEITHER `--check` nor the land
  path — its only caller is a litmus test (748-tkjx keeps litmus out of
  `--check`), so the blast radius is litmus runs and `--ci-full`, not lands;
  lenovinha's gate was green with 99 lines of debris present and the fixture
  absent from a 4759-line log. The coordinator broadcast the land-blocker
  reading to six hosts before checking which gate runs the fixture — the
  n=1-without-its-regime shape, again. The divergence file answered "which
  gate runs this" in one grep; it doubles as orphan detection for
  `test-*.sh`, which the guard auditor cannot see. Fix: the guard is
  scoped to the reporting path (`--emit-*` never reaches it), arm 9c pins both
  halves; landed ahead of the queue, with a one-line workaround broadcast
  (remove `/tmp/tillandsias-timing.jsonl` when its litmus-record count equals
  its line count). That condition earned its keep within the hour: on yolanda the file
  was a THIRTY-TWO DAY timing ledger (4756 lines, 921 litmus), real
  build-check records from 2026-08-11 on, because that host's real records
  land in the /tmp fallback. Moved aside with a dated suffix, never deleted.
  (Corrected twice by yolanda: checkout detection WORKS from the build
  distro; and splitting /tmp by TIMESTAMP rather than record type shows every
  non-litmus record predates .cache's first line — last real /tmp record
  2026-08-26T04:07Z, first .cache record 04:49Z the same day, zero real
  records since. /tmp is an ARCHIVE of pre-changeover history plus fixture
  debris; .cache is the live log. pirria's falsification holds on Windows
  too. The coordinator relayed the first inference to pirria as a reopening
  within minutes and had to un-tell it: a large count reads as current and
  is not, and only the timestamp split can tell.) Each instance was caught by someone else's control or an
  instruction, none by the author's own review: treat it as a standing hazard
  for guards written under time pressure — a guard fires where a NUMBER IS
  PUBLISHED, not where a record is appended. Third writer category found by
  the enumeration: `scripts/litmus-run-one.sh` symlinks `.git` into its
  scratch root, so `metrics_default_log` resolves to that temp dir's own
  `.cache/metrics` and the records are silently discarded on exit — neither
  shared nor misleading, and exactly why it never polluted /tmp while the
  eleven fixtures (scratch roots without `.git`) did.
- **Three population gaps in one night, all the same shape** (lenovinha):
  a guard's verdict covers the files it enumerates, and three guards each
  omit a class the night needed. `audit-guard-activation.sh` enumerates
  `check-*.sh` only, so an orphaned `test-*.sh` is invisible to it and the
  divergence file (`scripts/gate-divergence-declared.txt`) is what actually
  answers "does this fixture run in either gate" — one grep.
  `check-plan-binary-probe-usage.sh` walks `scripts/` and the litmus corpus
  and not `build.sh`, so lenovinha's first 1127-waxf arm — a hardcoded
  `target/release/tillandsias-plan` exec-bit test (721-nyev: an exec bit is a
  claim, not evidence) with a `|| exit 0` skip-that-reads-as-pass — sat in
  the gate's own entry point while the guard built to refuse that construct
  reported `ok:21 eligible of 990`. Its header already records one earlier
  silent scoping; the defect was narrowed, not closed. Filed as its own row
  rather than widened inside 1127-waxf. The arm is now unconditional through
  `resolve_plan_binary` with a violation line; the skip was a second opinion
  on a question `check-fragment-status-loss.sh` already settles one line above.
- **The ripgrep fix is verified on Windows** (esme, the positive control):
  on a host that had rg installed that night and had never executed the
  step, under an inherited pipe with no stdin redirection, the gate printed
  `OK: 577 cheatsheet references resolved.` and returned. No per-phase timing
  line: `TILLANDSIAS_GATE_PROFILE=1` prints its table at the END of a gate and
  this gate aborted later, so the flag only pays out on a gate that finishes.
- **Sixth regime gap: the 1124-7f3u lane fixture's premise depends on
  CARGO_TARGET_DIR** (esme found it, lenovinha diagnosed it against the
  coordinator's wrong guess): "arm1: the lane admitted a fragment-bearing
  push it could not fold (rc=0)" on the Windows lane. The coordinator expected
  the root-versus-chmod shape of 1129-3yv7; no arm in that fixture uses a
  permission bit. `resolve_plan_binary` reads three inputs and checks
  CARGO_TARGET_DIR FIRST (783-jdeh); the fixture unset only
  TILLANDSIAS_PLAN_BIN, and every forge and `with-wsl2-builder.sh` export
  CARGO_TARGET_DIR to an absolute directory holding a real binary, so arm 1's
  premise ("no runnable binary") was false before the arm began and the lane
  correctly accepted. Reproduced on Linux rootless with the variable exported
  — esme's line verbatim — which rules the root diagnosis out rather than
  doubting it. Fix (c8d1d2686): `env -u TILLANDSIAS_PLAN_BIN -u
  CARGO_TARGET_DIR`, root-proof because it removes an input instead of
  relying on a permission root ignores; 5/5 with the hostile variable
  exported and 5/5 clean, no skip. The tell that separates the two shapes:
  ask whether the arm's premise uses a PERMISSION or an ENVIRONMENT — an
  unset is only as complete as the list of what to unset (889-twhe's "the
  environment quietly does not reproduce the condition", one variable over).
- **The timing-ledger predicate was wrong on both Windows hosts** (yolanda,
  esme): yolanda 4756 lines / 921 litmus over 32 days; esme 1289 / 279 over
  27 days including the 40 build-check records its own CARGO_BUILD_JOBS
  packet cites. Two hosts checked, two real ledgers. (yolanda later refuted the "checkout detection fails" reading with
  one-command tests, then the "concurrent writer" reading with a timestamp
  split: /tmp is pre-2026-08-26 history plus fixture debris, nothing real
  since; the two files are an archive and a live log, and a reader of either
  sees a fraction nobody announces.) Nobody deletes; the only remedy is mv-aside, and only when the
  guard actually blocks a run. A remedy whose safety is a conditional relayed
  between hosts at 06:00 is one paste from being run unconditionally (esme).
- **The debug pair reaches Ready where the release pair cannot** (yolanda,
  1084-x8ya): same host, distro, v56.9.12.1 source and VM substrate; debug
  tray + debug guest (shared `DEV_ROOT_SEED`) → "VM Ready — control wire up"
  in 521 s; release pair → "noise: input error" in 210 s. The only variable is
  the build profile, which is the only thing that changes where the root
  secret comes from: keying is the mechanism, transport and framing are
  exonerated, macbookair's root cause is confirmed from the other direction.
  Validity controls: the injected guest is the feature-enabled debug build
  (size and digest checked) and its vsock listener bound. Two traps recorded
  as the same shape as the night's others: a guest built with a bare
  `cargo build` lacks `listen-vsock` and refuses to start (exit 78) — without
  that guard it would have bound nothing and failed indistinguishably from a
  keying failure; and injection is version-gated (`SkippedVersionMatch`), so a
  debug guest reporting the same version would have been skipped and the arm
  would have paired a debug tray with a release guest. Forced re-injection by
  removing the guest binary; the `wsl --unregister` requested of the operator
  was withdrawn as unnecessary after reading `GuestWiringOutcome`. The new
  refusal log line discriminated on first use: `early eof` (a probe closing)
  followed by Ready, not a key disagreement.
- **The non-reproducing host did the work** (lenovinha, on the sixth regime
  gap): both the coordinator and the fixture's author started from the root
  diagnosis, and what settled it was yolanda being UNABLE to reproduce esme's
  red on a clean Windows host — that eliminated platform and build lane as
  the variable and turned "it fails on Windows" into "a runnable ELF exists
  at that path for any historical reason". Ask the host that cannot reproduce
  what it sees, not only the one that can.
- **The keying fix's completeness criterion was wrong and its site count was
  wrong in both lanes** (yolanda, macbookair): corrected on 1084-x8ya — no
  bare `channel_psk(` call remains is the criterion (the version stays in the
  HKDF info), and each lane has ONE production call site with the rest inside
  test functions.
- **A gate check gives different verdicts on an unchanged tree** (yoga, found
  while widening `check-plan-binary-probe-usage.sh` for 1128-j9fc): ten runs of
  the ORIGINAL guard on one tree report `scripts=7/568` seven times and
  `scripts=8/568` three times; the patched guard flakes the same way. Exactly
  one file flips eligibility — `test-fragment-status-loss.sh`, seen 2/8 — so a
  violation there is found by coin flip. Refuted by measurement: ugrep (GNU
  grep forced, still flakes), SIGPIPE under pipefail (the pipeline extracted
  verbatim is 20/20 and 30/30 in a while-read loop), the file's bytes.
  Reproducible in situ, not in isolation, mechanism open. Ruling: the
  widening lands honestly scoped (a population fix that names its
  population, not a trustworthy refusal), the flake is its own row with the
  numbers, yoga takes it next; closure is twenty consecutive runs giving one
  verdict and a planted violation found 20/20.
- **Every host's next `--check` after merging 8e3afa99f is a full gate,
  once, by design** (lenovinha, 1127-waxf): a pre-1127 stamp carries no plan
  digest and reads `stale:no-plan-digest-recorded`, fail-closed into one
  re-gate per host. esme's ~20-minute full gate was the first observed
  re-stamp. Do not debug a 300-second gate that is doing what it was told.
  The by-hand ledger-guard rule retires on TWO conditions — the fix on trunk
  AND each host re-stamped once — so hosts report their first post-1127 full
  gate and the rule retires on observation, not on the SHA.
- **The keying fix reached trunk at f51e96382** (relay of osx-next
  b77559aa7 by macuahuitl; macbookair's proof: a release tray keyed to guests
  built moments earlier, cold-provisioned on a zeroed substrate, host had
  guest metrics at 22 s where v56.9.12.1 timed out at 300 s). The first relay
  gate refused on `scripts/test-archiver-ruby-could-not-run.sh` ("positive
  control did not pass on a host with ruby (rc=1)", "the refusal path left
  scratch state in the worktree", 3/5); the same fixture passed 5/5
  standalone on the same tree and passed in the relaunched gate — the second
  in-situ-only flake of the night, named as a sibling on yoga's flake row.
  Windows conversion (yolanda) and the two-binary provision remain before the
  next cut; stable remains v56.9.2.1.
- **Windows lane back in full** (esme, windows-next 9a765da19, sixteen
  commits, attempt 1): arm 0 of the 1124-7f3u fixture green as the
  verification host ("the premise holds — no plan binary resolves under the
  scrubbed environment"), which retired esme's own residue hypothesis — the
  resolving route was the WSL2 redirect's fresh copy inherited into the
  fixture, not the stale Sep 4 ELF; a plausible story fitted to one
  measurement, retracted in the report. The stale ELF still matters for
  1129-4su6 because at PUSH time the redirect is unset and the lane falls
  back to the checkout. The cheatsheet step costs 4.2 s on a host with rg
  (gate total 2049 s, reported separately). Found on the same gate: the
  "touched and left OPEN with no next_action" advisory evaluates the
  declaring fragment in isolation and never consults the status channel later
  fragments carry — 73 firings on one tree, at least two on packets the fold
  reports verified/completed (1124-7f3u, 1115-yvrq). Filed by esme, unclaimed.
- **A push with no timeout emits nothing** (macneo, two land stalls, 3000 s
  each): "land: attempt 1 — push" was the last line, the push log was ZERO
  bytes, and a stack sample showed git-credential-osxkeychain blocked in
  `CSSM_DecryptDataFinal` — the login keychain waiting for a GUI unlock a
  non-GUI session can never give. Isolated standalone: `printf
  'protocol=https\nhost=github.com\n\n' | timeout 20 git credential-osxkeychain
  get >/dev/null; echo rc=$?` → rc 124 (ALWAYS redirect stdout: on success the
  helper prints the live token, and the first form put the operator's PAT
  into a transcript — macneo flagged rotation);| timeout 20 git credential-osxkeychain
  get` → rc 124, no output; fetches worked all night because anonymous reads
  never consult the helper. macneo correctly refused `gh auth login`
  (1025-a896), credential rewiring and token injection. **Operator ask (corrected by macneo — the keychain is NOT locked):** on
  tlatoanis-macbook-neo, from a GUI session (Terminal.app opened normally,
  not over ssh, not from an agent), run `git push` in ~/claudia/tillandsias
  — or `security find-internet-password -g -s github.com` — and when macOS
  asks whether to allow access to the github.com credential choose ALWAYS
  ALLOW. Four probes: `show-keychain-info` and `list-keychains` succeed, the
  item's metadata reads (srvr=github.com), only the `-g` DECRYPT hangs — the
  stored credential's ACL wants a confirmation dialog no non-GUI session can
  show, and it blocks instead of failing. Unlocking will not help. Nothing
  else on that host is blocked, its four
  commits are green locally and off the cut's critical path. Hardening
  routed to pirria: bound the push with a timeout and make an empty push log
  its own named refusal.
- **Same helper, same repo, opposite outcome — the variable is the session**
  (macbookair): its `credential.helper` is exactly `osxkeychain` and it
  pushed six times tonight, because its agent runs inside the operator's
  logged-in GUI session with the login keychain unlocked. So macneo's hang is
  neither a helper misconfiguration nor a credential fault — a genuine
  credential fault REFUSES with output; a locked keychain HANGS with none.
  Discriminator that needs no operator: `git config --get-all
  credential.helper` plus a push probe on a throwaway ref. Fourth instance of
  the night's shape — a thing that hangs rather than fails, on a host where
  the same code works by hand (rg with no path, the dead 43-minute land, the
  auditor's grep, the keychain). The durable lesson: when something is slow,
  check whether it is ALIVE before reporting it slow — `stat` the log twice
  a minute apart, and look for a process with 0:00.00 CPU time.
- **Seventh regime gap, second GNU-versus-BSD: `sed -i SCRIPT FILE`**
  (macbookair, on lenovinha's 1127-waxf fixture): BSD sed takes the argument
  after `-i` as a backup SUFFIX, so the strip that synthesises a pre-1127
  stamp is a no-op on macOS, plan_digest stays, and arm4 fails itself while
  the code under test is right. `-i ''` is the trap in the other direction
  (GNU consumes the empty string as the script), which is how the `grep -R`
  fix travelled wrong earlier. Portable form: write through a temp file and
  `mv`, no `-i` at all. Landed on osx-next by macbookair with both measured
  arms; relayed to trunk in the coordinator's next slot (Linux unaffected).
  macbookair's count for the night — grep -R on symlinks, rg with no path,
  the keychain ACL prompt, ugrep-as-grep, sed -i — is five environment-
  dependent defects that each passed where written and reached trunk green;
  a counted, non-blocking portability advisory over `scripts/` for the known
  GNU-only idioms would have named three of them before they froze a lane.
  Filed by macbookair, theirs after the smoke.
- **The same class, swept before it was found one at a time** (lenovinha):
  the unlanded 1129-4su6 refusal in `scripts/hooks/pre-push-local-gate.sh`
  used `find -printf '%T@ %p'` (GNU-only); on BSD find — macOS pushes
  osx-next through THIS hook — it fails, `$_newer` goes silently empty and
  the refusal drops the "newer:" line esme asked for. A fix for a defect that
  degrades silently on one platform would itself have degraded silently on
  one platform, in the file the packet is about. Rewritten with POSIX
  `ls -t`; three `touch -d` in `test-plan-binary-freshness.sh` became
  `touch -t`. For the portability advisory's tally: a fixture's gap fails
  LOUDLY on the host that runs it, a hook's DEGRADES SILENTLY on the host
  that pushes — separate them by severity. Hazard from the same sweep, third
  time tonight: an assertion written at the same moment as the fix inherits
  the author's picture of it, so its first red is as likely to be the
  assertion as the code (an arm pinned main.rs as "newest" when Cargo.lock
  legitimately wins in that fixture; now it asserts a real source, not which).
  Run the new arm and read its failure; do not trust it because it is green.
- **A packet whose deliverable is a new test can satisfy neither ledger
  gate** (macbookair, measured twice while filing 1130-i6xj): 977-448j
  refuses a packet with no scorable obligation; naming the future litmus to
  satisfy it trips `check-declared-closures-added.sh` with
  `declared-closure-unresolvable`, which build.sh exits on. Ruling: the bind
  is intended (a declared pin must resolve), and the sanctioned form is
  `unscoreable: unpinnable-until-the-guard-exists` naming the exact future
  litmus filename and instructing the claimer to write it in the same commit
  as the guard and move the closure text across. Declaring the pin anyway and
  letting it dangle is 1068-cxmf's defect under a new number. The two
  refusals must name each other; small row, macbookair, after the smoke.
  macOS lands unblocked at osx-next 73d951a6e (sed fix, 804-deux findings,
  1130-i6xj); trunk gets the sed fix on the coordinator's relay.
- **Windows conversion landed** (yolanda, windows-next b2fa4a21c): one
  production call site and two test sites converted, build.rs exports the
  embedded guest digest (None on a placeholder, never an empty file's hash),
  no bare `channel_psk(` remains, and the mismatch arm was shown to go RED
  when the two digests are made equal — a green arm never shown red would
  have been this packet's own defect under a newer name. Two hazards from
  the same land: (1) test functions inserted after the previous STATEMENT
  rather than after the enclosing test's closing brace nest inside it; Rust
  accepts it, `#[tokio::test]` on a nested fn never registers, brace balance
  passes, the suite goes green with neither arm running — only indentation
  caught it, and plain `cargo check` compiles no `#[cfg(test)]` code at all
  (`--all-targets` does). (2) `git commit --amend` right after a merge amends
  the MERGE — check the parent count first (2 = merge, do not amend); the
  coordinator made the same mistake tonight and recovered the same way, by
  reflog. **Operator ask:** consent for `wsl --unregister tillandsias` on
  yolanda for the cold two-binary provision (the distro holds only debug-pair
  artifacts and has never reached Ready; tillandsias-build is untouched);
  yolanda runs the weaker in-distro re-injection arm meanwhile, labelled.
- **The archiver ruby fixture flakes in situ on two hosts with opposite ruby
  layouts** (macuahuitl rc=1 with ruby on the host AND in the tillandsias-builder toolbox, measured; yoga rc=3 with ruby
  absent on the host and present in the toolbox): the same gate run passes
  the 4/4 could-not-run verdict fixture at ~:4045 and fails
  `test-archiver-ruby-could-not-run.sh`'s positive control at ~:4679;
  standalone the failing fixture passes 5/5 on both hosts, repeatedly. Two
  full gates lost to it tonight. yoga's hypothesis, recorded as a hypothesis
  with its prediction: the positive control's outcome depends on WHICH
  execution context the gate hands that step (host vs toolbox dispatch, or
  a PATH that differs between the two invocations), so the two call sites
  should disagree about `command -v ruby`. Different mechanism from the
  SIGPIPE flake in 1130-qk7d (fixed, 15/15). yoga takes it after 1128-j9fc
  lands; first move is printing `command -v ruby`, the host kind and the
  dispatch path at both call sites inside the gate, before changing anything.
  Sharpened by yoga from the fixture's own logic: arm 4 skips only on the
  CONJUNCTION rc=3 AND "no usable ruby", and yoga's gate hit rc=3 without
  that string — so inside the gate the ARCHIVER itself returns could-not-run
  with a different reason (standalone on the same tree it is rc=0, 305/305),
  and the fixture merely notices. First move on both hosts is therefore to
  print `$out2`, which the fixture already captures at :67 and discards at
  :74. Separate cause under the same fixture's name: arm 5 fails if plan_tmp,
  plan_tmp_bak, scripts/archive-plan-packets-check.rb or toolbox exist in the
  worktree — exactly what an interrupted land leaves behind — so "the refusal
  path left scratch state" (macuahuitl) may be a second mechanism, not the
  ruby one.
  Sharpened by yoga from the fixture's own logic: arm 4 skips only on the
  CONJUNCTION rc=3 AND "no usable ruby", and yoga's gate hit rc=3 without
  that string — so inside the gate the ARCHIVER itself returns could-not-run
  with a different reason (standalone on the same tree it is rc=0,
  305/305), and the fixture merely notices. First move on both hosts is
  therefore to print ``, which the fixture already captures at :67 and
  discards at :74. Separate cause under the same fixture's name: arm 5 fails
  if plan_tmp, plan_tmp_bak, scripts/archive-plan-packets-check.rb or
  toolbox exist in the worktree — exactly what an interrupted land leaves
  behind — so "the refusal path left scratch state" (macuahuitl) may be a
  second mechanism, not the ruby one.
- **A keyed release pair reaches Ready on Windows** (yolanda, 1084-x8ya):
  "VM Ready — control wire up" in 77 s with a release tray whose
  EMBEDDED_GUEST_SHA256 (read from the generated embedded_guest_digest.rs,
  not inferred from the staged asset) equals the digest of the guest injected
  into the distro (4434eb13…, 14,910,776 bytes); the same host's unkeyed
  release run earlier died at Connecting in 210 s with two necessarily
  different self-hashes. Both binaries release profile, guest built with
  build-guest-binaries.sh's exact flags, re-injection proven (the pre-removal
  digest was the debug one). Labelled the WEAKER arm by its author: prior
  state in the distro and a locally built tray. The mechanism is closed on
  both VM platforms; the promotable closure is the smoke of the CI-built tag
  on each, which needs the operator's per-run destruction consent.
- **Two hosts' changes to one mechanism, verified against each other BEFORE
  the second landed** (lenovinha, on yoga's 1128-j9fc widening): merged
  baf53e287 and re-ran the guard on the merged base rather than trusting the
  pre-merge green — `ok:plan-binary-probe-usage:22 eligible of 1043 scanned
  [scripts=9/570 litmus=13/422 entry=0/51]` — so yoga's new entry-point
  population is clean and lenovinha's hook, which now names candidate paths
  in its stale-validator search, is eligible and compliant because it
  resolves through the probe. First time tonight the composition was checked
  ahead of the land instead of discovered after it. 1129-4su6 lands with its
  row OPEN on esme's end-to-end arm, which is structurally unreachable until
  the refusal is on trunk.
- **A fallback is "never wrong" only if you have checked it on the host that
  will reach it** (lenovinha, corrected by esme, on 1129-4su6): the
  declaration coupling that derives the fresher build's path was first
  described as degrading to the rebuild remedy "worse, never wrong"; on the
  one host that needs the derived remedy that fallback is not degraded, it is
  useless — it loops the operator through a rebuild that never touches the
  stale copy, and they stop trusting the next thing the tool prints. The
  coupling now breaks loudly (a marker on both lines, a fixture asserting the
  declaration parses). 1129-4su6 is landed at c44c55d26 and deliberately NOT
  closed: "the mechanism is on trunk" and "the mechanism works where it
  matters" are different claims, and esme's verbatim refusal is the second.
- **An exemption describes what is allowed, not what is free** (lenovinha,
  after a plan-only closure push moved trunk under the coordinator's relay
  gate and cost it a re-integrate and a second 8-minute gate): "plan-only is
  exempt" was true and still forced a full re-integration on whoever was
  mid-gate. The question before any push during a freeze is not "am I
  exempt" but "is anyone mid-gate", and the second has to be asked even when
  the first answers yes. The coordinator then asked for a total hold, plan-
  only included, for the relay's last minutes.
- **The cut's first release gate refused on a litmus pinning the pre-fix
  API shape** (macuahuitl, 1084-x8ya): `litmus:psk-input-parity-shape`
  grepped for `channel_psk(` and could not see `channel_psk_for_guest(`, so
  the converted hvsocket.rs matched only doc comments — "does not use
  workspace VERSION for PSK" on a file that does. A fixture that encodes the
  symptom's spelling as the contract. Fixed at 46bc11426 with both spellings
  and a -A3 window; controls: pre-fix step FAILS on the post-fix tree (the
  gate log), post-fix passes 3/3, post-fix FAILS on a copy with the version
  literal replaced. The guest responder legitimately keeps a bare
  `channel_psk(` — it has no digest to key to, it IS the digest's subject —
  so the next tightening must not chase it. Cost: one 22-minute gate and a
  30-minute later tag.
- **Asking "unreachable by construction?" found the self-hash surviving on
  one path** (macbookair, after the relay): `build.rs` refused only an EMPTY
  digest while the runtime required exactly 64 hex, so a non-empty malformed
  digest passed the build, returned None at runtime, and the `None =>` arm
  derived from the host's own hash silently — 1084-x8ya reinstated with no
  signal. Unreachable via `build-macos-tray.sh` only because the producer
  happens to emit 64 hex. Closed at both ends on osx-next (ede57fcc0):
  build.rs validates the runtime's shape and names the lengths; the None arm
  is cfg-split and returns a named error on release. Rides the NEXT daily;
  v56.9.12.2's row names it as a known defect shipping. A formatting delta
  ended up inside the land's integrate merge (`--amend` after the integrate
  had already created it) — named rather than rewritten mid-land.
- **After `podman system reset`, the first metrics read on a host carrying
  pre-2026-08-26 archive records in /tmp will refuse** (pirria): the reset
  does not clear /tmp, so `violation:metrics-log-split` fires once with the
  mv-aside remedy; correct behaviour, not a regression from the release —
  told to every smoking host so nobody files it as one.
- **The floor-tier treadmill, measured** (esme): a windows-next land merged
  trunk at 09:13, gated green for 39 minutes, and was refused at 09:52 on
  containment because trunk had moved to 8a45bd522 under it — the stamp was
  valid, the merge premise beneath it was not. A green gate on that tier is
  21-25 minutes at best, so against a trunk moving every few minutes the
  platform branch can land only in the gaps. Ruling: esme switches to the
  relay-ref shape for the rest of the cycle (push the gated tree to
  `work/<order>`, yolanda merges it into windows-next on their next land),
  converting a 39-minute exposure into a seconds-long merge on a fast host;
  the one exception is the plan-only push that is lenovinha's 1129-4su6 arm,
  which must leave esme's own push path.
- **§1 of the smoke is not a non-destructive binary install** (pirria, on
  cachyos, v56.9.12.2): `install.sh` runs the full init — 131 lines of
  podman/vault output, a Vault bootstrap provisioning twelve policies and
  AppRole roles, and a `tillandsias-vault` container left running on 8201.
  Reversible, not nothing, and not what "curl-install and assert the tag"
  describes; the coordinator had named it the safe half. The §1/§2 consent
  line still holds (§2 destroys, §1 provisions), but the runbook must say
  what §1 does so an operator agrees to the real thing. Also: on a fish
  shell `${PIPESTATUS[0]}` expands to nothing and install_exit goes blank —
  the runbook's §0 bash guard exists for exactly this and must sit at the top
  of the §1 recipe, not only in §0. cachyos §1: 175 s, "Tillandsias
  v56.9.12.2" verbatim, from v56.9.5.1; macuahuitl §1: 78 s, exact tag.
- **v56.9.12.2 on Windows, CI-built tray: Ready in 38 s** (yolanda, weaker
  arm, stated on the report's second line): §1 install_exit=0, tray reports
  56.9.12.2 (8a45bd522); no `wsl --unregister` (consent not granted, asked
  twice, not inferred from silence), re-injection forced and demonstrated
  (local 4434eb13… before, published 85495603… after); provision Ready with
  the control wire up in 38 s; diagnose LAST: phase=Ready, wire reachable,
  ready_history=observed-ready where v56.9.12.1 read never-observed-ready on
  the same host. Pairing evidenced two ways rather than asserted (the
  injected guest is byte-identical to the asset CI staged; the NNpsk0
  handshake succeeded). Answers "does CI-built keying work on Windows" —
  yes; does not answer "does a pristine host reach Ready" — that is one
  consent away. Report: smoke-e2e-findings-v56.9.12.2-2026-09-12-windows-yolanda.md.
- **v56.9.12.2 §1 on the Windows floor host** (esme, N100/16 GB): install
  exit 0 in 22 s, "tillandsias-tray 56.9.12.2 (8a45bd522)" verbatim, SHA-256
  of the zip verified by the installer, evidence in a per-tag directory
  cleared at start. The tray is still not on PATH after the install — a third
  consecutive tag on which 1004-vsh2's fallback is load-bearing. On the
  1129-4su6 arm esme caught their own false negative before sending it: a
  plan-only push of `plan/issues/*.md` is validated without the plan binary
  (`needs_yaml` is set only for `plan/index.d/`), so no staleness refusal
  there is correct; the real arm is a push carrying one index.d fragment,
  with the hook resolving a 2026-09-11 .exe that `plan_binary_is_stale`
  reports STALE against Cargo.lock.
- **v56.9.12.2 is STABLE** (macuahuitl, 10:52Z): macOS cold smoke with the
  CI-built tray PASSED on macbookair — substrate zeroed, provisioned from
  nothing, host had guest metrics at 38 s; three releases on that host by the
  same procedure read v56.9.11.1 TIMED OUT, v56.9.12.1 TIMED OUT,
  v56.9.12.2 ok. With yolanda's CI-tray Ready on Windows (in-distro arm) and
  the Linux/Windows §1 installs, the daily was promoted: prerelease off,
  releases/latest = v56.9.12.2, `stable` moved 341ab0010 → 8a45bd522.
  Recorded gaps: the pristine-host Windows provision and the Linux reset path
  await per-run consent. Found by the smoke's land: `touch -t 202609120600`
  in `test-plan-binary-freshness.sh` (the control arm's stub `touch`; this morning's `-d`→`-t`
  conversion) froze "current" to a literal that expired at 06:00Z — the stub
  is now older than sources the fixture writes at run time, the control arm
  inverts, and EVERY code land on EVERY host refuses (plan-only lands pass
  only because the partial memo runs the ledger guards alone). A hardcoded
  timestamp is a fixture with an expiry; sixth shape for 1130-i6xj, silent-
  degrade class because it reads as a real staleness refusal. Fix: plain
  `touch` (mtime = now), macbookair, relayed to trunk next.
- **Linux full smoke on the floor host, and a p1 one step past §3** (pirria,
  cachyos, operator-consented): §1 175 s, §2 reset to 0 containers / 0
  volumes / 0 images, §3 init 398 s from a pristine store, 15 images rebuilt,
  vault healthy, zero hits for every failure class the runbook enumerates.
  Then, at shutdown after "Graceful shutdown completed": `tillandsias-vault`
  Exited (137) — SIGKILL after the full 30 s grace, every host, every stop.
  Read from the RUNNING container, not the script: PID 1 is bash
  (`images/vault/entrypoint.sh`), vault is PID 10, tee PID 11, no trap, so
  SIGTERM hits the shell and vault is never told to stop. Second defect in
  the same two lines: the server is a backgrounded PIPELINE, so `$!` holds
  TEE's pid and the obvious one-line trap would signal tee and look correct.
  1134-u934 (p1): fix plus a runbook §3b (stop the substrate, assert every
  container exits 0 within its grace), pirria. Also 1133-kktm: §1's prose
  promises a download test and the installer runs the full init — a CONSENT
  defect; and the bash guard the coordinator asked pirria to "add" to §1 was
  already there (SKILL.md, the `BASH_VERSION` line) — the recipe relayed in
  a chat message had dropped it: an instruction quoted out of its runbook
  loses the guards the runbook wrapped it in, and the coordinator prescribed
  a fix without reading the file (the check-for-the-capability shape).
- **The promotion proven on the default Windows path** (esme): with
  `TILLANDSIAS_VERSION` unset, install-windows.ps1 reported "Channel: stable",
  resolved /releases/latest itself, fetched
  tillandsias-tray-56.9.12.2-windows-x64.zip with the same sha256 as the
  pinned §1 run (949e1997…), and the tray reports "tillandsias-tray 56.9.12.2
  (8a45bd522)" — stable channel and exact-tag pin serve the identical
  artifact, 16 s. esme's assertion used a bounded regex; the runbook's
  substring form would accept 56.9.12.20 (amendment to 1133-kktm). On the
  same host both loci of 1129-4su6 are verified: in-distro the refusal named
  the fresher redirected build and the orphaned checkout copy, Windows-side
  the generic rebuild remedy cleared the staleness in 2m16s — one tree, two
  loci, two opposite correct answers; the orphaned Sep 4 ELF is removed on
  the refusal's own reasoning and the row is closed verified.
- **The portability advisory landed with a baseline, not a zero** (macbookair,
  1130-i6xj, osx-next 91b04268d): the first run found 35 genuine pre-existing
  GNU-only idioms unrelated to the night (stat -c ×14, sed -i ×13, date -d ×5,
  readlink -f ×2; sampled bare `sed -i` in bump-version.sh, delegate-outcome.sh
  and ensure-nvidia-cdi.sh), so "zero on the fixed tree" would have made the
  closure un-passable and therefore deleted; the closure is per-instance and
  the 23 silent-degrade / 12 loud-fail split prints on every gate as a
  baseline that must not climb. The guard's own four false positives (a
  correct BSD-first `stat -f || stat -c` chain, the repo's GNU/BSD absorption
  layer, help text, `grep -r` over the canonical skills/ tree) and one in the
  fixture (a negative control matching its own advice string) are pinned as
  negative controls; 102 s → 6 s by a glob pre-filter. Three structural facts
  for the next litmus author: a new litmus must be bound in
  openspec/litmus-bindings.yaml or nothing runs it (660-ryhn class); steps go
  under `critical_path:`; each `command:` is a single-line double-quoted
  scalar, which is why the convention is a thin litmus over a test-*.sh
  fixture. Two pre-existing macOS reds found by stash-and-rerun: BSD `wc -l`
  pads its count so a string compare against "1" fails on every Mac (eighth
  idiom: string-comparing a wc count; macbookair fixes it), and
  litmus:tool-dispatch-lib (diagnosis pending). The Linux gate then printed
  loud-fail=14 against macbookair's 12; macbookair suspected a platform
  difference in their own guard, the coordinator suspected a moved tree, and
  the byte-identical 14-entry lists on both platforms at the same commit
  settled it: the 12 was measured before `test-portability-idioms.sh`
  existed, and that fixture's :61/:63 carry the idioms as test SUBJECTS, so
  the guard flags its own proof — deliberately, with a comment saying so
  rather than a by-name exemption. One baseline, 23/14 at e5d5ac0af, both
  platforms. A measurement whose tree state is not stated, in the packet
  about measurements whose regime is not stated (macbookair's own words).
- **ci-release 37/37 on macOS; neither standing red was in the code under
  test** (macbookair, osx-next 8f004a77d): BSD `wc -l` pads its count in
  every form, so a string compare against "1" failed on every Mac — the
  sigpipe litmus fixed to `-eq`, an eighth idiom added with a `tr -d`
  negative control, and the new arm immediately found a live red nobody had
  reported (`test-capability-manifest-guard.sh` string-comparing a padded
  count, "drifted token count differs" while the code was fine). And
  litmus:tool-dispatch-lib: arm 4f asserted `= "RESOLVER-ABSENT"` where three
  outcomes exist — `.` is a POSIX special builtin, so on bash 3.2 (every
  macOS /bin/bash) a failed source under `set -e` terminates the shell
  despite `|| true`; the old caller printed nothing, empty fell to the else
  branch, and the arm reported the opposite of what happened. Changed to
  `!= "RESOLVER-PRESENT"`, what it always meant. The property worth naming:
  an assertion that enumerates fewer outcomes than exist does not merely
  miss — it reports a specific falsehood, and both of today's did so in the
  direction that accused the subject. Filed: 1135-z8gn (the 35-item GNU-ism
  backlog with the 23/14 baseline, both hosts named, the ninth idiom `. FILE
  || true` under set -e, unscoreable with its scorable slice named) and
  1136-n8sh (the two ledger guards must name each other; the unresolvable
  half is Rust in tillandsias-plan, the 977-448j half is a shell string).
- **Both proposed template slices had zero live defects, and both times the
  guard's knowledge was the cause** (macbookair, osx-next 8b401ecae):
  readlink -f — one instance runs inside a `podman run … -c` string
  (Linux context, needed TRANSITIVE tracking across a 35-line assignment
  chain to exempt, pinned in both directions), the other is on a Darwin that
  carries `-f`; `date -d` — four correct GNU-first chains falling back to
  BSD `date -j`, which the counterpart list did not know, and one fixture
  subject. An incomplete counterpart list does not under-report, it accuses
  working code. Honest baseline 20 silent / 13 loud at 8b401ecae, seven
  first-run entries never defects; the real classes are `stat -c` (14) and
  `sed -i` (13), sampled real (claim-ledger-node.sh falls back to EMPTY
  rather than BSD and yields a blank mtime on macOS). Fixed on the way:
  plan-binary-probe.sh's same-artefact compare answered "same" having
  compared two empty substitutions where readlink -f is absent — now refuses
  on an empty side, dormant on today's fleet. The land was refused by
  check-bash-dialect because the fixture's ok() message carried a literal GNU
  idiom: a test about tests that contain their subject, caught containing
  its subject, both guards correct; fixed by splitting the literal, the
  offered allowlist entry declined. Third time today the cheap path was the
  wrong one — dangle a litmus pin, delete a detector to zero a class, add an
  allowlist entry: each one line, each passes the gate, each spends someone
  else's future.
- **The sed -i silent-degrade half closed; the false alarm was the finding**
  (macbookair, osx-next bc2875709, baseline 20/13 → 15/13): four production
  conversions to the temp-file form, with the consequence measured on BSD —
  `delegate-outcome.sh` marks a record filed so a later cycle does not
  double-file it; the old form failed with "invalid command code f" and left
  filed=no, so the next cycle filed it again. `bump-version.sh` was the
  false alarm: its `sed -i` already sits inside a GNU/BSD dialect branch
  whose author solved more than `-i` — BSD sed rejects the `0,/re/` address
  as a SILENT no-op (exit 0, file unchanged) — so a naive conversion would
  have removed the warning and left the real defect on the script that bumps
  the release version. Reading the lines first was the only thing between
  the template and that outcome. Third false-positive class: an idiom inside
  a dialect branch, exempted by a bounded six-line window, never file-level.
  Also measured: BSD sed supports `/re/,+2d`; not every GNU-looking address
  is GNU-only. Loud-fail half (13 fixture entries, ≥3 deliberate subjects,
  ~8-9 real conversions) left on 1135-z8gn as a followable next_action; the
  class is stopped here to spend the budget elsewhere.

## Autonomous drains (operator directive, 2026-09-12 evening)

The operator restarted the fleet with fresh contexts and asked the coordinator
to schedule `advance-work-from-plan` on trusted hosts and let them drain
planned work autonomously. Cadence armed: macuahuitl runs a coordination pass
every 2 h at :41 and a meta-orchestration cycle every 4 h at :09; macbookair
drains macOS every 4 h at :20; yolanda drains Windows every 4 h at :50 and
merges esme's `work/<order>` refs; esme runs the macOS-tray-on-Windows probe
daily at 09:15 and a measurement-only drain every 8 h at :25; pirria finishes
1134-u934 then a measurement-only drain every 8 h at :55 and is the Linux
smoke host for future dailies. All crons are session-only and expire in 7
days. Every host: claim before work, 6-10 packets per story, one gate per
story, the sub-agent budget, report only on blockers, hazards and completed
stories.

- **The cycle checkout lock cannot see a native Windows PID** (yolanda, on
  windows-next ae69e23a4): `cycle-checkout-lock.sh` classifies the anchor and
  tests the recorded holder with `kill -0`, and under MSYS bash a native
  Windows PID is not an MSYS PID, so a live claude.exe harness is stamped
  `explicit-DEAD`, every recorded holder stale-reaps on the next read, and a
  second lane reads `ok:checkout-lock:free` while the first holds it. The
  verdict's FIX line tells the operator to put the variable on the command
  line, which cannot help. FIXED as 1137-da83, landed 3cfea048a on
  windows-next (commits 80de8e0a1 and 971c70f07). Found independently within one hour by both Windows hosts,
  from opposite anchors — yolanda via an explicit TILLANDSIAS_CYCLE_HOLDER_PID,
  esme via CLAUDE_PID. The shipped probe is esme's `ps -W` WINPID predicate,
  NOT the tasklist/OpenProcess this entry first prescribed: `kill -0` still
  answers first, so the change is a no-op off Windows by construction. Two
  things the fix needed that the diagnosis did not predict — `mark-attested`
  had to accept anchor equality before walking ancestry (the walk climbs MSYS
  pids and the lock records a native one, so a correct liveness probe alone
  would have made it refuse `held-by-other` about the cycle's own lock), and
  the fixture's independent oracle needed a third outcome, "could not ask",
  distinct from "dead". The one-lane-at-a-time rule for Windows hosts can be
  retired once esme's verification lines are in. FIRST LIVE PROOF, unprompted:
  the coordinator's 4h cron fired on yolanda while that very land was mid-gate
  and was refused `skip:overlap-lock-held:lane=prompt pid=12388`. An hour
  earlier the same call answered `ok:checkout-lock:free` on both Windows hosts
  no matter what was running — so the guard's first real contention on this
  host was refused correctly by the fix that was landing at the time.
- **macneo can push again; the probe leaked the token** (macneo, osx-next
  369c67add, four commits landed attempt 1, the secure_stream.rs union merged
  clean): the operator approved the keychain ACL and the 20-second probe
  returned rc 0 — and printed the PAT to stdout, because the coordinator's
  probe line had no redirect. The rc is the signal; stdout is the secret.
  Every probe of a credential helper redirects stdout: `… get >/dev/null;
  echo rc=$?`. macneo flagged rotation to the operator; the drill's earlier
  probe text is corrected above. Crons on every host are session-only and
  expire 2026-09-19; the cadence must be re-armed on session start.
- **What the pipe-verdict fixture found — extends the coordinator's rule entry
  below, which named this fixture as its follow-up.** Read that one first for
  the rule; this one is what writing the arm turned up, including a correction
  to the remedy both entries originally gave. (yolanda and esme, 2026-09-12.)
  THREE FALSE CLAIMS IN ONE HOUR, two
  hosts, three different commands: esme read `tasklist ... | head -2; echo
  rc=$?` as tasklist's 0 (it exits 1) and caught it before reporting; yolanda
  made the identical mistake on the same primitive and published it to a peer
  as a measured two-host difference that did not exist; yolanda then read
  `land-on-platform-branch.sh | tail -25` as exit 0 and told two parties the
  land tool reports success over a refused gate. It had exited 3 and named its
  gate log — and that tool's header exists BECAUSE someone once shipped exactly
  that bug, so it was accused of the defect it was written to prevent, by a
  reading that had the defect. esme was about to file a row against it.
  Capture into a variable (`out="$(cmd 2>&1)"; rc=$?`) or `set -o pipefail`.
  SAY "SNAPSHOT THE ARRAY AS THE VERY NEXT COMMAND" — `ps=("${PIPESTATUS[@]}")`,
  then index it — and NOT "use ${PIPESTATUS[0]}". PIPESTATUS[0] is not wrong; it
  is FRAGILE, and the distinction decides whether this entry survives contact
  with a reader. Read as the first command after the pipeline it is correct, so
  anyone who tests it in isolation finds it works and concludes the warning was
  overblown. But ANY intervening command resets the array, and the intervening
  command everyone writes is `a=$?` — precisely what you reach for alongside it.
  `a=$?; b="${PIPESTATUS[0]}"` yields 0 and 0 even on one line, because `;`
  separates two commands; a `$( )` or `( )` around the pipeline loses it too.
  The mechanism is fine; the idiom it travels with destroys it (esme's framing).
  THE NEAR-MISS IS PART OF THE RULE: an isolated test of PIPESTATUS[0] passes. Pinned executably by
  litmus:land-verdict-through-a-pipe (scripts/test-land-verdict-through-a-pipe.sh),
  which plants a refusing gate in a scratch repo and reads it six ways. Same family as the macneo probe entry above — there the
  rc was the signal and stdout the secret; here the rc is the thing the pipe
  silently replaces. The trap is that `head`/`tail` are what you reach for to
  make output READABLE, so the habit that makes a measurement legible is the
  habit that corrupts it. NOTHING STRUCTURAL CAUGHT ANY OF THE THREE: one was
  caught by re-reading one's own command, one by a peer flagging a disagreement
  they declined to explain away, one by checking a claim before filing a row on
  it. So the second half of the rule is social — flag a disagreement you cannot
  explain rather than smoothing it, because agreement between two sources is
  not evidence when both share a method.

  AND THE THIRD HALF IS THAT CAREFUL THOUGHT DID NOT REACH THE BOTTOM OF THIS;
  AN ARM THAT COULD GO RED DID. The `${PIPESTATUS[0]}` fragility above was found
  only when a fixture refused to go green against a tool that had just been
  proven correct — neither host got there by reasoning, and both had already
  published the weaker advice. The same file taught it twice: that fixture
  opened with `set -uo pipefail`, one of the three sanctioned remedies, and
  four trap arms went green while measuring the remedy instead of the defect.
  When the subject is how a measurement lies, write the arm.
- **A fixture reaches the gate by one of two routes, and neither is automatic**
  (yolanda and esme, 2026-09-12). `scripts/test-*.sh` is NOT globbed by
  build.sh. Route 1: an explicit `_run bash "$SCRIPT_DIR/scripts/test-X.sh"`
  line in build.sh (~100 of them, e.g. test-cycle-lock-attested-release.sh).
  Route 2: a litmus binding — and route 2 is TWO FILES.
  `openspec/litmus-tests/litmus-<name>.yaml` defines the test;
  `openspec/litmus-bindings.yaml` registers it against a spec_id, and
  `get_litmus_tests_for_spec` reads that registry to decide what
  `run-litmus-test.sh <spec>` runs. Definition only: the file exists and no
  spec run picks it up. Registry only: a pin naming a test nothing defines,
  which is 1068-cxmf's standing defect. A fixture wired by NEITHER route is a
  file, not a gate — that is the vacuous-green shape, and the corpus has 253+
  test scripts against 125 distinct names in the litmus yamls, so the gap is
  not hypothetical. Wire it in the same commit that writes it and say which
  route. Both hosts got a piece of this wrong before checking the runner
  source: one claimed the litmus binding was the only route, the other that the
  registry file was not involved.

  RELATEDLY, a `| tail -1` inside a litmus step is CORRECT and should not be
  filed as an instance of the pipe rule above. `run-litmus-test.sh` honours the
  exit code only when a step declares NEITHER `success_pattern` NOR
  `expected_behavior` (the order-256/267 strict-exit arm); with
  `expected_behavior` the verdict is content-based, so `tail -1` extracts the
  signal rather than discarding it. STATED AS A RULE RATHER THAN AS A FACT ABOUT
  ONE FILE (esme's phrasing): a content-asserted step is only as good as the
  guarantee that its verdict line CANNOT PRINT EARLY. Guard the terminal `ok:`
  behind the failure counter — `[ "$fail" -eq 0 ]` — or the step passes on a
  fixture that died halfway. esme chased this to the bottom while primed to find
  the bug, and reported it as a negative.

  A RELATED SCARE, NARROWED RATHER THAN FILED. run-litmus-test.sh's own header
  comment on its yaml-reader tiering warns
  that without yq the runner falls back to grep approximations that decide WHICH
  TESTS RUN, so a host would silently select a different test set and nothing
  would report the difference. Measured on yolanda, which has NO yq: the comment
  overstates the residual, because order 746-htj9 added a FIRST tier —
  `tillandsias-plan yaml-json | jq` — and it resolves here. Piping the registry
  through `jq -r '.specs[] | select(.spec_id=="ci-release") | .litmus_tests[]'`
  returned the correct list including a binding added minutes earlier, so
  selection was NOT degraded on a yq-less host. The real residual is narrower:
  a host with neither yq NOR a resolvable tillandsias-plan+jq falls to grep, and
  steps whose own COMMANDS call yq still fail or return empty — which is what
  `warn:litmus-degraded-no-yq` already reports. Not filed as a row on that
  basis: the in-place comment predates its own mitigation. (Cited by symbol:
  the tiering comment sits above `_yaml_jq` / `get_litmus_tests_for_spec` in
  scripts/run-litmus-test.sh — 881-29me, and a line range would have drifted
  the moment anyone edited that header, which is precisely what this drill
  entry asks the next reader to do.)
- **First autonomous-drain stories** (evening, 2026-09-12): yoga 1132-r4mt
  (two hypotheses refuted, the re-exec asymmetry named, two clean in-situ
  samples with the print armed, refusal still uncaught) and 890-27mv (the
  release-tier freshness reporter; ruling: macuahuitl is the nominated
  ci-full host — every cut's gate plus one scheduled run per day when no cut
  ran — no rotating sample, since 888-vgs8 puts convergence history where the
  tier runs); lenovinha packet B → 1137-dzzu (STEP_SKIP_EXIT) and 1136-n8sh's
  Rust half, then 1138-bb5r found on the way (a present-but-unusable rg
  passes the cheatsheet check over zero references — every resolve_tool
  consumer inherits it); macbookair 803-r8u4/803-rbqf (is_battery_present
  was a bare bool that every non-Linux host serialised as a confident
  `false` — macneo's own 09-04 row proved it — now Option<bool>;
  inference-policy-router throttles on battery, so an unprobed laptop was
  never throttled; scripts/windows-host-capability-probe.sh hardcodes true,
  for yolanda/esme to check); macneo's four commits and cron. Three rules
  from those stories: (1) after touching accel_probe.rs, build --release
  before publishing a capability row — a debug-only cycle printed the OLD
  nulls under a FRESH timestamp, and two hardware fingerprints from one host
  in one cycle is the stale-artifact signature; (2) `cargo test -p X "a|b"`
  takes a substring, not a regex, so a falsification pass can select ZERO
  tests and print `test result: ok` — every falsification states "N
  selected, M filtered out"; (3) choose a gate-steps.d prefix AFTER the land
  script's integrate step, which pulls sibling steps in (205 collided with an
  incoming 205-1137-dzzu and cost a gate). Line citations rotted within a
  day on two packets (check-logs.jsonl append, run-litmus-test.sh call):
  cite by symbol.
- **A silenced stderr turned a missing path into 930 lines of "divergence"**
  (yoga, retracted within the hour): `git show HEAD:images/default/skills/…`
  with stderr to /dev/null exited 128 (the path is untracked by design —
  .gitignore ignores the derived tree, build.rs excludes it from asset
  collection) and produced a zero-byte file, which diffed against the
  941-line canonical copy read as a fleet hazard. `diff -rq skills/
  images/default/skills/` reports zero differences. Kept from the chase: the
  forge image's build context is images/default/, so the Containerfile's
  `COPY skills/` ships the DERIVED tree, and the sync is load-bearing for
  what every in-forge agent reads — a guard there would assert "derived
  matches authored at image build time". Verifying a hazard hard enough to
  file it is what dissolved it.
- **Never read a land or gate verdict through a pipe** (yolanda, esme: three
  instances on two Windows hosts in one hour, none caught structurally):
  `scripts/land-on-platform-branch.sh … | tail` reports tail's status, so a
  refused gate (exit 3, log named) read as exit 0 and esme nearly filed a row
  against the tool on that word. Rule on 1137-da83 and here; a fixture that
  plants a refusing gate behind `| tail` and asserts the wrapper reports the
  refusal is the follow-up. Also settled before hwfp-v2's schema: a Vulkan
  vendorID is a u32 namespace (llvmpipe 0x10005) while DrmRenderNode's u16
  is right for its only production source (sysfs PCI ids) — parse_pci_id
  REFUSES the overflow and drops the whole node, so reusing it for Vulkan
  ids would silently drop the software-rasterizer row 793-zumy criterion 2
  exists to reject; a dropped row and a never-enumerated device look the
  same. esme is authorised for one release build of the probe in
  tillandsias-build to record the real-iGPU-beside-software-GPU enumeration.
- **A gate arm that reads the fleet's live claim state refuses overlapping
  lands** (lenovinha, 1034-whsp's `test-selector-drops-cross-branch-claims.sh`):
  the two count-equality arms run the selector twice and assert an identical
  batch count, so any claim or land by another host between the two reads
  fails them — "a clean check altered the batch (2 vs 3)" with the fleet
  moving, 6/6 three times with it quiet, nothing in the diff touching the
  selector; the drop/name arms held throughout, so the contract is intact
  and only the snapshot assertion is broken. Non-reproducible by the host it
  hits, which is the worst shape for a gate, and now structural with four
  hosts draining. Fix (lenovinha): assert the selector's response to the
  stub, never the equality of two live reads. Second structural race: the
  gate-steps.d prefix is read-then-written, so two hosts landing in one
  window collide (205, then 215/225 tonight); the fix shape is a
  collision-free mint like next-order. And the 349 scratch-ref pattern gains
  a step from 776-jcf3's linux half: before deleting the probe ref, check its
  commit is an ancestor of the branch — had it not been, deleting would have
  destroyed the only remote copy.
- **Coordination pass 2026-09-13T00:4xZ** (macuahuitl, 2h cron): relayed
  osx-next 6d5f14de9 (macbookair's 803-r8u4/803-rbqf story: is_battery_present
  → Option<bool>, host-fact corrections) and windows-next 5a7b5fe45 onto
  linux-next in one land. Recorded from the hosts: esme's 1139-xe5m — the
  `--capabilities` command serves ~/.cache/tillandsias/capabilities.json when
  present and nothing in the envelope says so (decisive test: cache aside →
  wall-clock timestamp; cache present → the same .356539631 nanoseconds
  replayed 20 h later), so a stale provisioning state can propagate through
  the capability matrix as a current measurement; the closure must
  distinguish cached from measured by reading the ENVELOPE ALONE. esme's
  finding on 793-zumy: `wsl2_paravirtual_gpu_reason` returns
  "engine-missing:no-vulkan-icd" unconditionally on a host where the ICD is
  installed and enumerates an INTEGRATED_GPU — the reason is false even if
  the cpu-only verdict is right; the debug build was the correct instrument
  on the floor tier (149 s clone+deps, 64 s sidecar, 27 s headless, cold, at
  CARGO_BUILD_JOBS=2 on ext4). yoga: hwfp-v2 records PCI ids only, with a
  boundary test pinning that a Vulkan vendorID (0x10005) must not parse as a
  PCI id, and a correction event on 793-zumy for a fabricated example whose
  conclusion survives. Candidate, not a row: a doc comment that says a
  ledger event is wrong should not be able to land without a correction
  event — the correction sat in code for three weeks while the ledger, the
  surface a cold reader starts from, kept the error. The 4h meta cycle on
  this host landed 1119-w2rj criteria 1-3 (one sonnet sub-agent, 233,797
  tokens) and attested; 803-49re is parked in the ledger; the daily 09:09
  ci-full is armed.
- **A prover authored on the Windows lane landed without its executable bit**
  (relay of windows-next 5a7b5fe45): `scripts/check-ripgrep-available.sh`
  arrived as mode 100644, and `test-host-tools.sh` requires `-x` on a prover,
  so the relay's gate refused "prover for rg exists" on Linux while every
  Windows gate had passed (MSYS does not enforce the bit). Fixed by
  `git update-index --chmod=+x` on trunk. Rule for the Windows hosts: after
  creating any scripts/*.sh, set the mode in the index explicitly before
  committing — a Windows gate cannot see that it is missing.
- **The vault shutdown p1 is fixed on pirria and cannot land from there**
  (1134-u934): SIGTERM forwarded to VAULT's pid, measured 30 s / exit 137 →
  1 s / exit 0 against real containers, tee-pid trap ruled out by the process
  tree in the log; a THIRD defect found on the way — under `set -e` a trapped
  signal interrupts a bare `wait`, which returns 143 and exits the shell
  before vault seals, so a correct trap plus a bare wait still stops
  uncleanly; all waits guarded, the handler reaps vault, the subsequent-boot
  early return shares one path. Fixture is live-container by design (a
  `grep trap` fixture passes the wrong fix) and exits 3 without an enclave;
  runbook §3b added; 1135-8t3a (inference has the same shape, READ not
  measured) and 1136-u6nq filed. The floor host lost four 15-minute gates to
  a trunk that moved inside every window: floor-tier code now lands by the
  relay shape — push the gated tree to `work/<order>`, macuahuitl merges. Two
  routed facts: the installed tray embeds the image sources
  (EMBEDDED_RUNTIME_ASSETS), so NO host gets this fix until a daily is cut
  from a trunk carrying it — cut-worthy; and a Cargo.lock newer than
  target/debug/tillandsias-plan makes the set-field fixture refuse
  `stale-plan-binary` on any host that pulls without cycle-preflight.
- **The checkout lock is real on Windows** (yolanda, 1137-da83, windows-next
  3cfea048a): first live proof unprompted — the coordinator's 4h cron fired
  mid-land on yolanda and got `skip:overlap-lock-held`, refused by the very
  fix that was landing, where an hour earlier the same call read free on
  both Windows hosts whatever was running. esme's exec-bit sweep: 108 of 678
  tracked *.sh are not 100755 and only the `[ -x ]` prover population can
  break (three declared, clean after the fix); the rest is a latent hazard
  resting on an invocation convention. The coordinator told both Windows
  hosts the +x was "on trunk" while the relay carrying it was still gating —
  two hosts idled on that premise until esme checked by ref (the
  hand-peers-a-condition-not-a-local-SHA shape, under the coordinator's
  name).
- **A salvage branch named "integrated and deletable" held the only copy of
  three fragments** (macneo, 1080-4deb, osx-next 7fe19c312): the row's own
  next_action said to delete salvage/unknown/20260910-1080-4deb-arm1; its
  tip 94f12eeb7 is an ancestor of NONE of the four branches (positive control
  on a known-trunk commit), and it carried ARM 1's claim, progress and
  release fragments that never reached trunk — the code landed, the
  provenance did not, so "did this work land" answered yes off the gate step
  while the record was missing. 1080-4deb's own subject one level up. The
  three fragments are restored unmodified (fold verified undisturbed) and
  relayed to linux-next by this pass; ONLY after that is the branch
  deletable, and the corrected next_action says to re-run the four-branch
  ancestor check rather than trust a sentence. Rule: a salvage ref is the one
  ref whose deletion is unrecoverable by construction — "integrated" earns
  the ancestor check every time, never the code check. Evidence:
  plan/issues/salvage-branch-named-deletable-holds-the-only-copy-2026-09-13.md.
- **Killing a gate does not kill the gate** (pirria, measured; p1 row filed):
  `./build.sh --check` re-execs inside the tillandsias-builder toolbox via
  podman exec, so killing the host-side wrapper reaps only the wrapper — the
  container-side build.sh, parented by conmon, kept running the gate 12
  minutes after it was "stopped", concurrently with the gate started after
  it; SIGTERM did nothing, SIGKILL to the pid and its child ended it. This is
  the leading mechanism for 1132-r4mt: two gates in one checkout, one
  writing the scratch the other's arm 5 forbids and racing the archiver its
  arm 4 measures — macuahuitl's own refusal followed a killed pre-gate by
  seconds and passed on relaunch once the stray had finished. Also explains
  the orphaned cheatsheets/zzz-skip-exit-probe debris (1141-5pgh's remedy
  corrected). On the floor tier this is systematic: the hosts that interrupt
  15-minute gates are the ones that cannot afford a second one. Fix shape:
  the wrapper propagates its termination into the container, and the gate
  refuses to start while another build.sh is alive in the same checkout.
- **The vault fixture's fourth case** (yoga, 1140-i6ct, found by running it
  instead of trusting the prediction): on a host with a live but STALE
  enclave the fixture takes the measurement path and reports the pre-fix
  signature (30 s / 137) as the source's defect while the fix sits in the
  tree — could-not-run covers no-podman / no-container / would-not-start /
  never-healthy and not "built before the fix", which is the common case on
  every host until it rebuilds. p2 while wired into no gate; p1 the moment
  someone wires it. lenovinha measured 1119-w2rj's named residual from a
  real --cloud launch (rc 128 → the forge launches without a mirror redirect;
  a stray ./<name> repo in the cwd → configured from an unrelated repository,
  rc 0) and takes the packet to close it, with criterion 4 in the forge they
  already have; 776-jcf3's observability strings do not exist on a working
  launch and its expectation is being amended with that run.
- **Ratified: the deletion gate for a salvage ref is per-line accounting**
  (macneo, 1080-4deb): ancestry cannot authorise deleting a ref whose content
  was restored by relay (the tip's commit is on no branch) and byte-identity
  is unpassable once trunk evolves a file, so the gate is: every line the tip
  carries over its merge base that trunk lacks is accounted for as superseded
  by a NAMED successor or present under a rename, the accounting written on
  the row BEFORE the deletion, re-verified against a fresh fetch immediately
  before the irreversible act. This ref cleared it (seven denominator-guard
  lines kept and widened, two signature comments under a rename, one loose
  grep replaced by the anchored match at 112ea637c) and is deleted, confirmed
  absent with a positive control on ls-remote. A control that has since
  merged is a control that cannot fail.
- **The narrow override is the question the hook is asking** (macneo): the
  pre-push refusal under 874-w2gc offered `TILLANDSIAS_SALVAGE_DELETE_OK=1`
  and, two lines later, mentioned `git push --no-verify` under "this hook is
  the trunk's only gate". Not equivalent, and the text did not say so: the
  narrow one keeps every other check running (no-stale-base-revert,
  main-branch-affordance, linux-next-merged still printed on the delete); the
  broad one pushes the same bytes and discards all three, and on a day with a
  stale base lands a real defect. Refusals must name the narrow override and
  say `--no-verify` is not it.
- **The surviving gate reproduced on a third host, with the protocol
  sharpened** (yoga): kill the wrapper → host side reaped, container-side
  build.sh alive under conmon with a live child; SIGTERM inert, SIGKILL
  reaps. Refinements: a relaunched gate may be a stamped no-op
  (`ok:gate-fresh`) so a clean `ps` then proves nothing — force it; the
  discriminator is the PPID (conmon versus the launching podman exec), true
  before any kill; where the toolbox shares the host PID namespace one `ps`
  suffices. Arm 5 of 1132-r4mt stays a proposed cause, not a demonstrated
  one; the earlier "relaunch passed" samples may have been stamped no-ops.
  yoga takes pirria's wrapper-propagation row plus a gate-level lock; pirria
  verifies on the floor tier.
- **The surviving-gate fix landed** (yoga, 1141-vf9w parts 1 and 3,
  23c3dfce3): the wrapper no longer execs, so a signal has something to
  arrive at, and termination propagates into the container-side tree by an
  environment MARKER rather than an argv match — a stray and a healthy
  concurrent gate run identical argv, and killing a legitimate gate is worse
  than the orphan; bounded SIGTERM then SIGKILL; the reap lives in
  scripts/lib-dispatch-reap.sh because with-wsl2-builder.sh dispatches the
  same way (891-5shq: a second boundary must not reimplement the first's
  fix). Three defects yoga put into their own fix, all caught by measurement
  or a gate: a /proc scan at 819 ms per pid polled 20 times (16 s inside a
  handler that runs while the caller is dying), ~300 permission errors
  sprayed to the caller's stderr, and `mapfile -d ''` (bash 4.4+) refused by
  check-bash-dialect naming darwin's 3.2. A mutation test silently did not
  apply and reported a pass for the second time in a night (a sed pattern
  missed after an indentation change): the rule now is print the mutation
  diff and refuse if it is empty before believing any mutation result. An
  invented order (1141-p2wq) was written into three files before the minted
  1141-vf9w replaced it — the mint-never-pick rule doing its job late. Part
  2, the gate-level lock, stays in_progress: pirria saw a legitimate NESTED
  build.sh mid-gate, so the discriminator is conmon versus the launching
  podman exec, never "another build.sh exists"; its third criterion is to
  trace gate-stamp.sh as shared state and answer whether a surviving gate can
  write a false PASS or only cause a false fail. pirria's relay re-gated on
  yoga (6071c346d); the [low-end] linux queue is empty, so pirria's cadence
  runs the due de-slop sweep (306 orders since the last) as its standing
  tier work, and 1004-4xie's role corrected to windows.
- **No Windows host could pass the gate: a stale .exe outranked the fresh
  ELF in a run-don't-stat probe** (esme, 1140-d6ni; 67.5 minutes to a FALSE
  refusal): `resolve_target_binary` tries `$name.exe` before `$name`; inside
  tillandsias-build both artefacts sit side by side, WSL interop is now
  enabled so the Sep-4 PE32+ RUNS and is accepted, and the Windows binary
  joins `/mnt/c/...` with a backslash — check-cheatsheet-tiers refuses
  "cheatsheets/ directory not found" on a tree with 244 tracked entries.
  1030-i2p8 fixed exactly this for resolve_plan_binary ("locus-native
  artefact first") and its comment predicted the masking would lift; the
  sibling never got the reorder. yoga lands the one-line reorder with a
  stub-.exe arm; the row also names yolanda's silent cargo-absent SKIP that
  reports `ok:` while the check never ran — the worse half, since the reorder
  alone removes the loud signal and leaves the silent gap. esme deleted the
  stale untracked artefact (ephemeral build output, not consent-class).
- **The floor-tier plan-only window** (esme, measured): a plan-only push
  takes the plan-only lane only on a tree origin/windows-next already
  contains; merging trunk to satisfy containment turns it into a union
  needing the stamp (the 68-minute gate), and a first push of a `work/`
  ref has no remote base to diff so the hook must demand the full gate (the
  hook is right; the advice was unreachable). A floor Windows host can push
  plan-only only in the window right after a capable host's land brings
  windows-next up to trunk and before trunk moves on. Standing rule:
  yolanda's lands carry esme's plan-only work as a matter of course; esme
  pushes directly only when the window is open, never a union gate for a
  plan-only change. Five harness waiters were reaped for memory during the
  4050 s gate; it survived because it ran under setsid inside the distro.
- **CORRECTION to the two bullets above, measured by yolanda and esme
  against the hook's predicate** — discard the "floor-tier plan-only window"
  framing and the "silent second route" claim. (1) `_lane_can_scope` in
  scripts/hooks/pre-push-local-gate.sh walks every merge in the outgoing
  range and requires each merge's SECOND parent to be an ancestor of
  origin/linux-next; esme's refused head had 17 merges with one disqualifying
  (its second parent was yolanda's checkout-lock land 3cfea048a, not yet
  relayed to trunk) and the accepted head had 28 merges and none. So a floor
  host can push plan-only without a stamp at any time provided it does not
  MERGE a branch carrying un-relayed commits: basing on origin/windows-next
  (first parent) is free, merging it makes that content a second parent —
  same branch, same content, different parent position, opposite verdict —
  and the reason is not tidiness (a non-trunk second parent can carry
  unreviewed code invisible to a first-parent walk). The cause was fleet
  timing — the lag between a platform land and its relay — and the relay is
  the coordinator's to keep short; this land carries 3cfea048a. What stands:
  the linux-next-merged guard runs before the lane; a first push of a
  `work/` ref has no remote base and needs the full gate; 4050 s is the cost
  of a floor-tier UNION push, not of routine plan work. (2) The "silent
  cargo-absent skip reporting ok" on yolanda was a FIXTURE's assertion text
  (test-cycle-preflight-cargo-resolution.sh quoting the value it asserted on)
  read as the host's verdict; the real tier step 190 lines down had passed.
  1140-d6ni is "the tier check is broken on esme by the stale-.exe
  resolution", no second route; the reorder (yoga, 1142-wn2k superseded into
  it) is the whole fix; open question, not a claim: yolanda's host carries
  the same artefact shape with interop on and did not break. Fourth instance
  of one error class in a night, named: a search that returns something has
  not answered the question — ask what the matched line IS before reading
  what it says. Also: esme held the checkout lock 87 minutes after a gate,
  visible only because 1137-da83 made the lock real; long gates on any host
  launch DETACHED from the harness (nohup/setsid to a log; yolanda verified
  the gate alive in a later call), since the harness reaps its own tasks.
- **SECOND CORRECTION: the 4050 s gate and the false ERROR had one cause,
  and it was not the tier** (esme): launching `./build.sh --check` from
  INSIDE the WSL distro (to survive the harness's memory reaps) made
  scripts/with-wsl2-builder.sh see an already-Linux shell, skip its re-exec,
  and never export CARGO_TARGET_DIR to the distro-local ext4 target dir — so
  the gate compiled against ./target on drvfs (6.75x) and
  resolve_target_binary found the stale tillandsias-policy.exe that the
  sanctioned target dir never holds (62 occurrences of target/debug in
  esme's log, zero of tillandsias-wsl2-target; yolanda's log the reverse).
  The reorder is right but reachable only when CARGO_TARGET_DIR points at a
  mixed-artefact directory, which the sanctioned path avoids by construction
  (1140-d6ni's third amendment). Deleting the .exe did not persist — cargo
  re-created the hardlink from target/debug/deps. Rules for both Windows
  hosts: never launch a gate by hand inside the distro; detach from Git Bash
  (nohup … & disown, verified alive in a later call) so the re-exec still
  happens. "esmeraldinha is not slow, its filesystem is" — and this time the
  filesystem was chosen by a bypass.
- **A host landing CODE is starved by plan-only churn** (lenovinha, measured):
  1119-w2rj finished, green (536 tests, criterion 4 executed against the
  real image with a 0755-refuses/0777-succeeds control), exhausted four land
  attempts — an 8-minute full gate racing a 5-10 minute trunk cadence, six of
  the twelve preceding commits being the coordinator's own plan-only drill
  records landed one per message. The cheap lane sets the cadence and the
  expensive lane pays it. Policy: the coordinator batches plan-only records
  into ONE land per coordination pass (this bullet waits for the next one);
  every host batches plan-only pushes into its cycle's land; and the land
  tool must make a re-integrate that brought only plan/ paths cost the
  partial memo rather than a full gate — lenovinha files and fixes it, and
  takes 1083-gzqj next (1140-5bre does not close its ARM 2: the baseline on
  the live ledger was kept one layer down).
- **CORRECTIONS to the two entries above, all three errors mine** (esme, after
  yolanda re-read the evidence and yoga questioned it):
  - **Route B does not exist.** The "silent cargo-absent SKIP that reports
    `ok:`" was never yolanda's gate verdict — those lines are assertions from
    `scripts/test-cycle-preflight-cargo-resolution.sh`, whose arm reads
    `skip:cheatsheet-tiers:cargo-absent*) ok "absent cargo reads as a SKIP,
    not an ERROR ($got)"`, i.e. a fixture quoting the value it asserted on.
    Their production step validated 228 cheatsheets and passed. The argument
    that the reorder alone would be a worse end state FALLS with it: the
    reorder is simply the fix. My error was folding an unverified second-hand
    observation into a row as measured fact — one clause ("reported by
    yolanda, not verified from here") would have kept the row true, and it
    would also have given the source a second look at their own claim.
  - **The reorder is defence in depth, not a live break.** The ordering defect
    is real, but it is reachable only when `CARGO_TARGET_DIR` points at a
    directory holding both a native and a non-native artefact. `build.sh`
    sources `with-wsl2-builder.sh`, which re-execs the whole script into the
    distro AND exports `CARGO_TARGET_DIR=/root/.cache/tillandsias-wsl2-target/<repo>`
    — ext4, Linux artefacts only, zero `.exe` (measured on yolanda). No host
    on the sanctioned path can reach the bug. I reached it because I launched
    the gate by hand inside the distro to survive harness reaps, so no re-exec
    happened and the build used `./target` on drvfs, which holds both.
  - **4050 s is the cost of bypassing the wrapper, not of the floor tier.**
    The 6.75x against yolanda's ~600 s compares a drvfs target dir with an
    ext4 one, not two host tiers, and must not be cited as a tier ratio.
  - **The plan-only "window" does not exist either.** `_lane_can_scope` walks
    `git log --merges` over the outgoing range and requires every merge's
    `^2` to be an ancestor of `origin/linux-next`. Merge COUNT is irrelevant —
    a 28-merge head passed where a 17-merge head failed. What disqualified the
    failing head was ONE merge whose second parent was a peer's land that the
    coordinator had not yet relayed to trunk. **Basing on `origin/windows-next`
    is free; MERGING it is what exposes you.** So a floor host can push
    plan-only at any time: branch from `origin/windows-next`, merge
    `origin/linux-next` once, cherry-pick the plan commits, push. No window,
    no stamp, no relay dependency.
  - **Deleting the stale artefact does not persist.** It returns with its
    original mtime and link count 2 — cargo re-creates the hardlink from
    `deps/`. The mixed-artefact directory is not a state you can clean up out
    of; it is a property of building both ways into one tree.

- **A query that returns cleanly is not a query that answered your question**
  (esme + yolanda, five instances in one night, by two hosts who spent that
  night discussing this failure mode). Four were wrong-SUBJECT errors: a
  registry grepped for a script filename that correctly never appears there;
  a gate log grepped for lines ABOUT the check instead of the check; a
  hypothesis about whether a probe's candidate ran, when the probe was never
  reached; a window-watcher that fired on its own host's push and could not
  distinguish it from the peer's land. Each query was well formed, ran
  cleanly, and returned a confident null or a confident match about the wrong
  thing. **A confident null is not a negative result.**
  The fifth is a different axis and worth naming separately: a **wrong-TIME**
  error. A push ran in the background; the remote was checked BEFORE it
  finished, read as `NOT contained`, declared failed, and a duplicate push
  launched. The first had succeeded; the second was rejected with
  `cannot lock ref ... is at b48b05a5d but expected 7c07cbbcf` — a failure
  message whose content was proof of success, since the ref it could not lock
  was at the pusher's own commit. The habit "verify by content, not by exit
  code" gave no protection, because that habit governs WHAT you measure and
  says nothing about WHEN. A correct method applied before the world has
  finished answering returns a clean, honest answer to nothing.
  **Ask what the matched thing IS, and ask whether the thing you are measuring
  has finished happening.**

- **A written rule competes with the problem in front of you and loses**
  (yolanda's formulation, both hosts' evidence). Both hosts violated a rule
  they had in their own durable notes, within the hour they spent discussing
  that exact failure. esme's notes carry a section headed "THE GATE IS THE
  EXCEPTION TO THE setsid-IN-THE-DISTRO RULE", stating that an in-distro
  launch skips the `CARGO_TARGET_DIR` redirect, and supplying the check:
  `grep -c 'Re-execing inside' <gatelog>` — 1 means the real path, 0 means a
  different configuration. Run on the 4050 s gate log, after the fact: **0**.
  yolanda had the setsid rule written down, read it, launched Windows-side
  anyway, and lost three lands. Neither violation was carelessness; both
  happened while solving a real and urgent problem the note also addressed.
  The moment you most need the rule is the moment something urgent argues
  against it, which is why the check has to be mechanical rather than
  remembered.
- **Coordination pass 2026-09-13T02:1xZ** (macuahuitl): landed the pass's
  records with the plan-only deltas of osx-next (macneo's 1080-4deb close)
  and windows-next (esme's drill corrections and 1140-d6ni's third
  amendment) as one land after a merge conflict in this file (both sides
  kept) — a land the coordinator had launched over the unresolved merge was
  refused by the tool's own dirty-tree check, which is the tool working;
  four attempts, the first three lost to code landing from yoga and
  lenovinha. Second land: pirria's de-slop sweep from work/1141-deslop-sweep
  (examined 141, confirmed 2, retracted 1 — 1063-htns obsoleted as a strict
  subset of 834-7ut9, the survivor re-measured at 56 sites; 964-zgga's
  closure corrected from a phantom fixture name — filed 1: 1141-f5nk, the
  sweep's own record outside the plan-only lane). pirria's session ended
  after the sweep (unreachable; its 8-hourly cadence was session-only and
  must be re-armed on relaunch); the coordinator deleted the relayed work
  ref after the ancestor check. Seven full gates for zero direct lands is
  the floor tier's number: plan-only lane or work/ refs only. yoga's
  resolve_target_binary reorder is on trunk (c91650cec) and esme runs the
  confirming gate through the sanctioned wrapper; lenovinha closed
  1083-gzqj (all three arms) with the 1141-f5nk lane fix and takes the six
  remaining snapshot-class fixtures; 1142-85zx (the stamp's plan-only
  re-integrate memo) stays filed pending the 1036-e5w9 reading.
- **Five of five snapshot-class leads refuted, and that is the honest
  result** (lenovinha, 1083-gzqj item 5, dbd2df4fa): the nine counted by two
  sweeps were CANDIDATES, not instances — three were real and are fixed, five
  are legitimate arms (contract pins with no numeric comparison, a
  correctness check with its own tally, the DOCUMENTED could-not-run code 3
  of 965-sxec, a declared vacuity floor kept with its message fixed) that a
  claimer reading only the prohibition would have stripped. Method that
  changed the answer: the cited line numbers were not where the numbers
  were — three of six carried no comparison at that line — so each file was
  swept and every hit classified by the four kinds (live-state snapshot,
  contract pin, correctness check, declared floor). Item 6 stays open as its
  own row: both sweeps read only --check, and --test, --ci-full, the litmus
  corpus and the hooks are unexamined. 1141-f5nk closed with its evidence
  event: the deslop-sweeps.d record enters the plan-only lane as A-or-M with
  an append-only guard, because the ledger is one file per host and an
  A-only shape would have qualified a host's first sweep and taxed every one
  after.
- **The drill is a contended file** (yolanda: two pure-append conflicts in
  one cycle on this file, one producing a near-duplicate of the coordinator's
  own rule entry): with six hosts appending findings to one document, a
  conflict per land is the expected cost. Convention from 2026-09-13T03Z:
  each host appends to plan/issues/fleet-restart-2026-09-12-<host>.md (a flat
  top-level name — a `.d/` directory would fall outside the plan-only lane
  and cost a full gate per write); the coordinator folds those into this
  file on the coordination pass and is the only writer of it. Also from yolanda: the 4050 s / 600 s ratio is not a
  tier comparison (two launch configurations on two hosts) and is retired
  from routing until esme's sanctioned-path gate produces the floor-tier
  number; 1137-da83 fully closed at 496d17370 (fixture, litmus, binding, the
  `| tail` fixture wired by both routes); one Windows cycle cost ~820k tokens
  through four correct refusals and three harness kills — the price of that
  lane's gate churn, for the operator to weigh against its 4-hour cadence.
- **The floor-tier gate cost, measured on the sanctioned path** (esme,
  ff1204a5e): `./build.sh --check` launched from Git Bash with the re-exec
  verified in the log (`Re-execing inside` = 1, versus 0 on the 4050 s run)
  reached CHECK_RC=0 in 2598 s, tier step 228 validated — yolanda's count.
  The ratio factors exactly: 4050/2598 = 1.56x for bypassing the wrapper
  (drvfs target dir), 2598/~600 = 4.33x for the host itself against
  yolanda's sanctioned path; 1.56 × 4.33 = 6.75, the observed ratio. The
  second correction over-corrected: there IS a real ~4x tier signal, good to
  one significant figure until yolanda's side is measured rather than
  approximated. Cite 2598 s as the floor-tier gate. The sanctioned path
  cannot reach 1140-d6ni's defect (one runnable candidate only), so the
  confirmation was the mixed drvfs directory: resolve_target_binary now
  returns the ELF where it returned the .exe, and the identical tier
  invocation reports 228 validated where it said "cheatsheets/ not found";
  yoga's hermetic guard is the load-bearing artefact. esme checked trunk
  containment BEFORE merging origin/windows-next for the first time tonight
  and rebuilt the known-good shape (base, one trunk merge, commits on top;
  9 merges, 0 disqualifying). The main drill conflicted twice more during
  that push; the per-host convention is earning itself immediately.
- **A row sat ready for a week after its defect was fixed under another
  order** (lenovinha, 1085-g52w, ab30dac7c): b026372ff (filed as 1124-7f3u,
  2026-09-12) closed the reopen-is-not-status-loss behaviour six days after
  1085-g52w was filed and cited nothing; all three exit criteria passed at
  HEAD. lenovinha implemented the row's prescribed fix (timestamps threaded
  through the fold's join), found it redundant AND one axis laxer than the
  falsified-event rule already covering the reachable set, and reverted it —
  a second, laxer rule beside a working one is how a guard acquires a hole
  nobody chose. It surfaced only because arm 1 was scored against the
  pre-fix guard and PASSED there; a green suite plus a plausible diff would
  have shipped redundant complexity under a confident closure. Landed: the
  fixture only (gate step 245; arm 1 reproduces the filed text verbatim
  pre-fix, arms 2-3 are preservation arms, not proofs). Coordinator row to
  file on the next pass: a reconciliation check surfacing ready rows whose
  owned_files a landed fix touched since filing — surfaced, never
  auto-closed.
- **Trunk red on every macOS host at c6d191d39** (macbookair, reproduced in a
  pristine worktree): 1141-vf9w's `tillandsias_marked_pids()` enumerates
  /proc, which darwin lacks, so the reaper reports success having killed
  nothing — fails OPEN in production (with-tillandsias-builder.sh is a live
  caller) — and test-dispatch-reap.sh spawns with `setsid`, absent on darwin,
  so the arm reds for a second, unrelated reason. The file's header was
  careful about bash 3.2; the dialect guard checks the shell and cannot see a
  filesystem the target lacks. Ninth idiom class for 1135-z8gn: absent-on-
  darwin primitives, which no flag-shaped advisory finds. Unblock (macbookair,
  osx-next, relayed next pass): the fixture skips on darwin with a named
  reason, the reaper returns a named `unsupported:dispatch-reap:no-proc` to
  its caller (loud, never open), and the real darwin design — a token file or
  process group, since darwin cannot read another process's environ — is a
  child packet of 1141-vf9w for yoga. macbookair's 1137-rgfm claim was
  invisible to the fleet while the red held its push.
- **Corrections from the author and a second Mac** (yoga, macneo): the
  fail-open was not an unseen axis — lib-dispatch-reap.sh's header STATED the
  requirement ("a no-op that says so rather than a silent success; a caller
  must tell 'nothing to reap' from 'cannot see anything to reap'") and the
  code four lines below returned 0 on an empty list, the same
  comment-asserts-what-code-lacks class the author had corrected in
  check-cheatsheet-tiers.sh two hours earlier. A named return alone moves the
  silent success up a layer: the caller's trap discards it and exits 143
  clean, so the caller must say loudly that termination was not propagated.
  Scope: on darwin with-tillandsias-builder.sh returns early before the lib
  is sourced, so the dispatch path is unreachable there today — the fixture
  red is the live breakage, a darwin skip is not coverage, and the reaper's
  darwin arm is for the future Linux caller. The child packet must keep
  three states (live / idle conmon-only / stray). macneo: this and the
  keychain orphan (`_ccc_timeout` kills gh, its `security` child survives at
  PPID 1) are one family — termination does not propagate across a process
  tree on darwin — and the fix shape is likely shared (process groups,
  `kill -- -PGID`; `pgrep -P` as the portable enumeration). Keychain root
  cause REVISED: not an ACL and not a backlog — the operator's clicks did
  nothing because the dialog's password field was empty (item mdat unchanged
  since 2026-09-06); a wedged SecurityAgent (21 h, ignored SIGTERM, respawned
  on SIGKILL) plus PPID-1 orphans; the restart cleared it and a bare decrypt
  now returns rc 0. Remedy on recurrence: restart, or enter the login
  keychain password before Always Allow — not an ACL edit, not gh auth login.
  macneo's claim/release of 1080-4deb item 2 never reached origin (refused
  before landing), so the fleet never saw it taken; the mandated trunk merge
  dragged a .step file into a plan-only push, which is the claim-alone-and-
  fast shape failing under a mandatory pre-push merge.
- **CORRECTION to the two bullets above, measured by yolanda and esme
  against the hook's predicate** — discard the "floor-tier plan-only window"
  framing and the "silent second route" claim. (1) `_lane_can_scope` in
  scripts/hooks/pre-push-local-gate.sh walks every merge in the outgoing
  range and requires each merge's SECOND parent to be an ancestor of
  origin/linux-next; esme's refused head had 17 merges with one disqualifying
  (its second parent was yolanda's checkout-lock land 3cfea048a, not yet
  relayed to trunk) and the accepted head had 28 merges and none. So a floor
  host can push plan-only without a stamp at any time provided it does not
  MERGE a branch carrying un-relayed commits: basing on origin/windows-next
  (first parent) is free, merging it makes that content a second parent —
  same branch, same content, different parent position, opposite verdict —
  and the reason is not tidiness (a non-trunk second parent can carry
  unreviewed code invisible to a first-parent walk). The cause was fleet
  timing — the lag between a platform land and its relay — and the relay is
  the coordinator's to keep short; this land carries 3cfea048a. What stands:
  the linux-next-merged guard runs before the lane; a first push of a
  `work/` ref has no remote base and needs the full gate; 4050 s is the cost
  of a floor-tier UNION push, not of routine plan work. (2) The "silent
  cargo-absent skip reporting ok" on yolanda was a FIXTURE's assertion text
  (test-cycle-preflight-cargo-resolution.sh quoting the value it asserted on)
  read as the host's verdict; the real tier step 190 lines down had passed.
  1140-d6ni is "the tier check is broken on esme by the stale-.exe
  resolution", no second route; the reorder (yoga, 1142-wn2k superseded into
  it) is the whole fix; open question, not a claim: yolanda's host carries
  the same artefact shape with interop on and did not break. Fourth instance
  of one error class in a night, named: a search that returns something has
  not answered the question — ask what the matched line IS before reading
  what it says. Also: esme held the checkout lock 87 minutes after a gate,
  visible only because 1137-da83 made the lock real; long gates on any host
  launch DETACHED from the harness (nohup/setsid to a log; yolanda verified
  the gate alive in a later call), since the harness reaps its own tasks.
- **The "open question" in the bullet above is CLOSED, by the bullet above
  it.** Sequencing artefact of two hosts appending concurrently: the
  coordinator's correction records yolanda's identical artefact shape and
  clean pass as unexplained, and esme's entry — written later, landed first —
  answers it. An in-distro launch skips `with-wsl2-builder.sh`'s re-exec, so
  `CARGO_TARGET_DIR` is never redirected and the gate builds into the repo's
  own `./target` on drvfs, which is the only directory holding a `.exe`. One
  cause, both symptoms: the 4050 s and the stale-`.exe` false ERROR. Nothing
  about yolanda's host differed; its gate never looked at the mixed-artefact
  directory. Read the two together and take the later one.

## Folded from per-host files (coordination pass 2026-09-13T04:1xZ)

- **yoga** — `plan/issues/fleet-restart-2026-09-12-yoga.md` (the first
  per-host file; its bullets stay authoritative there and are folded here by
  reference rather than copied, since a copy would re-create the conflict
  surface the convention removes): the checkout-lock-and-boundary discipline
  adopted for its cron cycles, the 1141-vf9w gate-lock discriminator (group
  live pids by the dispatch token, then live / idle conmon-only / stray, with
  only a live build.sh counting as contention — one live, seven idle, one
  false stray measured), the 1142-wn2k supersede into 1140-d6ni, and the
  duplicate-filing gap between minting and claiming (minting does not check
  whether another host already filed the subject). Relayed this pass:
  windows-next ff1204a5e (yolanda's 1137-da83 pipe-verdict fixture made
  executable and its citations by symbol; esme's 1140-d6ni confirmation with
  the 2598 s decomposition).
- **Two security fixes landed by the drain, both live, both cut-worthy**
  (lenovinha): 1118-bscs (f19df57ca) — the enclave's git credential helper
  drained stdin and answered unconditionally, handing a live GitHub token to
  anything that asked; now parses host= and protocol=, whole-string host
  match (`*github.com` would accept evil-github.com, `github.com*` would
  accept github.com.attacker.net, both pinned), https-only, fail-closed —
  and squid's `http_port 3129` with no bind address and no source ACL was
  allowlist-free egress reachable from every enclave container by container
  address, whatever the header's accurate "provisioned but not routed"
  measurement said about ROUTING (a truthful statement about intent read as
  evidence about exposure); now 127.0.0.1:3129. 1118-d3b6 (36409ca58) — the
  inference container fetched `releases/latest/download/…` at container
  start and executed it with no checksum, so two containers from one image
  an hour apart could run different code with nothing recording which; now
  pinned to v0.34.0 with a per-arch SHA-256 verified before extraction,
  fail-closed on three paths, digests from the release API so the bump
  recipe costs no download; the enclave does NOT get install.sh's
  "sha256sum not found; skipping" usability trade, and the code says why.
  Criterion 2 (NPU telemetry) deferred and declared: `grep -i npu` found
  nothing where the spec specifies rows — silence reading as satisfaction.
  The gate-steps prefix race hit a third time (255, then 260) — every
  collision tonight was between hosts in the same gate window, so the mint
  needs unpredictability, not global coordination (1140-i2b6, unclaimed). A
  `grep -q`-under-pipefail hazard was reported and RETRACTED by lenovinha
  within the hour before filing: the class is owned by 1076-kft9
  (lib-sigpipe-verdict.sh, a diff-scoped guard that is gate step 070 today,
  whose header records that a whole-repo sweep was run and rejected for
  crying wolf), its analysis is deeper (EPIPE iff the producer still has
  bytes to write when the consumer exits — producer latency alone is
  incomplete — with a measured filesystem dependence: drvfs 10/10 versus
  ext4 and btrfs 0/10), and the claimed mechanism did not reproduce (0/12
  synthetic). What was observed: one false verdict, then 11/1, then 12/0
  repeatedly after switching to `grep -c`; the fix is sound, the cause is
  not isolated. esme then measured the printf arm on both loci, 20 runs
  per point: 0/20 at 19 kB, 3/20 at 39 kB, 16/20 at 49 kB, 20/20 from
  55 kB, non-monotonic through 55-61 kB, identical on drvfs and ext4 (no
  file is read, so the filesystem cannot matter), with a positive control
  that both loci SIGPIPE readily — a race between printf finishing its
  writes and grep exiting on the first match, not a threshold. No row:
  lib-sigpipe-verdict.sh does not skip printf, it REFUSES printf a verdict
  ("unmeasured: producer-size-is-a-runtime-property"), which esme's data
  confirms to the mechanism — there is no size at which a static verdict
  would be right. Counts appended to 1076-kft9. macbookair's rule after the pipeline-status trap for the third time
  in a night: capture the status of the thing you are measuring, unpiped,
  and quote the count of what actually ran; an absent result and a negative
  result render identically. Also from macbookair: with-tillandsias-builder.sh
  short-circuits on darwin via `[[ ! -f /etc/os-release ]]`, not a platform
  test — a porter searching for uname will not find it.
- **A detector that reported every gate as its own competitor** (yoga,
  1141-vf9w criterion 3, 936d22364 → 3a7d2013d): build.sh re-execs into the
  toolbox before its fast refusals, so the detector ran inside the container
  where the host-side wrapper is visible (shared PID namespace) but its
  environ is unreadable — `[ -r /proc/<pid>/environ ]` answers TRUE across
  that boundary and the read is then denied; access(2) lies. The `[ -r ]`
  guard passed, `2>/dev/null || continue` swallowed the denial, every wrapper
  vanished, every group looked headless. yoga had written that exact caution
  in lib-dispatch-reap.sh ("a process that changed credentials can pass
  access(2) and still deny the read") and guarded the classifier with the
  test they had documented as unreliable — the second time in two cycles a
  caution was violated a few lines below it; their words: "I treat my own
  comments as done rather than as requirements." Found only by forcing a
  gate to WATCH the advisory's output after the binding was already verified.
  Advisory staging turned an every-Linux-gate-refuses-itself outage into a
  log line. The lesson above the others: 8/8 hermetic passed over a detector
  wrong in production, because a fixture of plain files is always readable —
  a hermetic fixture pins the LOGIC and is silent about the SUBSTRATE, and
  their "hermetic" fixture then inherited TOOLBOX_PATH from the gate's
  container, claiming a regime it did not have (now 11/11 in both loci).
  Fixed three ways, each with a mutation-verified arm: refuse to answer
  inside a container, count a denied read and suspend the accusation, ask on
  the HOST before dispatch. Promotion to refusing needs clean in-situ runs on
  a non-Silverblue Linux host (macuahuitl reads the advisory line on its next
  gate) and a WSL host, because the fixture cannot see substrate.
- **Folded by reference, coordination pass 2026-09-13T06:1xZ**: esme's
  `plan/issues/fleet-restart-2026-09-12-esme.md` (the exec-bit sweep by
  population, the sanctioned floor gate at 2598 s, the printf SIGPIPE
  measurement) and macbookair's `…-macbookair.md` (is_battery_present as a
  bare bool on every non-Linux host, the stale-artifact trap in the
  capability probe, check-capability-row.sh blind to host facts, the gh
  dialog being a fixture's control run, the read_github_token invitation now
  filed as 1139-imd4, the darwin reaper fail-open). Relayed this pass:
  osx-next e7318c7dd (the darwin unblock — named skip, loud trap, 1145-iigx
  filed; macbookair's claim of 1137-rgfm now visible) and windows-next
  5cf0eb866 (esme's 1076-kft9 measurement; yolanda's claim of 823-u5zf).
  The relay conflicted in scripts/with-tillandsias-builder.sh: yoga's caller
  half (`_tb_on_signal`, on trunk first) and macbookair's `_tb_reap_and_report`
  (the same fix written on osx-next before the relay) — trunk's function kept
  for both hunks, no dangling reference, dispatch-reap fixture 9/9 on the
  merged tree. Two hosts fixing the same caller within an hour is the
  duplicate-filing gap one layer down: a heads-up on a shared script beats a
  merge-time choice.
- **The competing-gate detector's second substrate** (macuahuitl, from its
  own landing gate at 4d0b99dba, mutable Fedora, toolbox dispatch): line 1
  `ok:no-competing-gate` from the host-side call before dispatch, line 13
  the honest `could-not-run:competing-gate:inside-container`; no false
  accusation, same shape as Silverblue. The WSL datapoint is the Windows
  hosts' to produce (a false accusation there is the interesting result).
  yoga verified the relay's wrapper resolution rather than trusting it —
  both halves pair on trunk (reaper returns 2 unsupported where it cannot
  see; `_tb_on_signal` reports loudly; absent-token path rc 0) — and nearly
  reported the reaper broken from one command: they had exported the wrapper
  token into the shell running the reaper, so it found itself; a matcher
  over a set containing itself reports itself. Seam for 1145-iigx: the
  supported-guard's `/proc` root is hardcoded, so the unsupported arm is
  unreachable on every Linux host; an overridable root lets every host prove
  the refusal fires.
- **The competing-gate detector's guard enumerates jails, so an unrecognised
  jail accuses** (yoga, self-found while briefing yolanda; ancestry and bytes
  verified on macuahuitl from origin): the inside-container guard tests
  `TOOLBOX_PATH` and `container=oci|podman`; a WSL distro sets neither, and a
  distro cannot see the native Windows wrapper pid (1137-da83), so the
  detector there finds no wrapper for its own token and accuses by a second
  mechanism the fix for the first did not cover. Design yoga is taking in
  their :05 cycle: INVERT — answer only when the caller positively asserts it
  is host-side (the wrapper's pre-dispatch call passes a flag; build.sh's
  fast-refusal call does not; everything unflagged refuses), so a new dispatch
  shape is silent by default instead of wrong by default. Hold on yolanda:
  origin/windows-next carries 936d22364 (the detector with zero
  `inside-container` and no wrapper call — the version that accused every
  Silverblue gate); 3a7d2013d is on linux-next only and arrives with their
  pre-push merge; ba0fb4fd5 is already on linux-next, so the osx-next relay
  they asked for buys nothing and was not done. Two trunk-byte facts folded
  into the design: `with-wsl2-builder.sh` makes no detector call at all, so
  under the inversion the WSL datapoint becomes "does the unflagged in-distro
  call refuse" and promotion needs a flagged MSYS-side call that does not yet
  exist; and MSYS procfs exposes no `/proc/<pid>/environ`, so that flagged
  call would take the detector's unreadable-environ branch for every pid — to
  be answered as a named `unsupported:`, never as "none found" (the darwin
  fail-open shape). Condition for yolanda, not a claim: `ls /proc/$$/environ`
  under Git Bash.
- **The detector's blind scan answers ok** (yoga, CONFIRMED by control, not
  by argument; ordering read on trunk by macuahuitl): a procfs tree with every
  environ chmod 000, including a tokened build.sh with no wrapper, answers
  `ok:no-competing-gate` rc 0 — a clean bill of health from a scan that saw
  nothing, the darwin fail-open one substrate over. The `opaque` counter built
  to prevent exactly this sits AFTER the empty-accusation early return, so it
  is consulted only when there is already an accusation to suspend and never
  when the scan produced nothing because it could see nothing. yoga names it
  as their pattern, three cycles running: the mechanism built and then placed
  where it cannot fire. The obvious fix (opaque check first) is wrong — a
  healthy Linux /proc is full of root-owned unreadable environs, so every host
  would answer could-not-run. The distinction that works: count READABLE
  environs too and refuse (`unsupported:`) only when that count is zero; a
  healthy scan reads hundreds and keeps today's behaviour, a blind one (MSYS,
  darwin) stops being indistinguishable from a clean one. Offered refinement:
  require the caller's own tokened environ to appear in the scan (the
  self-match excluded in the test is the production positive control).
  Consequence stated rather than discovered: under the inversion the in-distro
  call refuses and a flagged MSYS-side call answers unsupported, so Windows may
  never be a substrate where the detector sees, and the criterion rewrite
  should say so. Queued in yoga's :05 cycle with the inversion: inversion,
  readable-count fix, criterion on dispatch shape, WSL wiring filed with the
  flag contract for yolanda.
  Settled design (yoga, same exchange): the host-side flag carries the
  caller's pid, so the fixture supplies a pid that exists in its fake procfs
  tree and no second seam appears; the detector verifies that pid's environ
  CONTAINS the caller's token (readable-but-tokenless is a contract violation
  and refuses loudly). Four fixture arms: pid absent, readable and tokened,
  readable and tokenless, present and unreadable. Fallback if the seam gets
  ugly: readable-count alone. The dispatch-shape criterion states MSYS/Cygwin
  as a substrate where the detector cannot see, closing the WSL row as a
  stated limit. Which of the two landed is to be recorded from yoga's report,
  not from this note.
  Exit-code contract agreed (yoga proposed, macuahuitl accepted): 0/1 proceed
  as today; 3 `could-not-run:competing-gate:blind` for pid absent or
  unreadable (this host cannot answer, stop asking); 2
  `refused:competing-gate:caller-contract` for readable-but-tokenless (a
  caller bug, fix the call site) — opposite remedies never share a code, and
  2 is the tree's usage/infra idiom (check-opsx-generated-dirt.sh). Trunk
  fact: both callers discard the rc today (`|| true` at
  the wrapper's pre-dispatch call in `with-tillandsias-builder.sh` and the fast-refusal call in `build.sh`), so the distinction
  lives in the fixture and the verdict line until promotion. Already true on
  trunk (yoga, read): the fixture's `check()` pins exit code AND verdict line
  together for all eleven arms, so a shared code reds the arm expecting the
  other; the new arms keep that helper rather than a weaker one beside it.
  Still owed: the criterion states that the four-code design binds the FUTURE
  consumer (nothing on trunk reads the number), the promoting consumer must
  enumerate 2 apart from 3 with no default that proceeds, and consumer wiring
  lands as its own change with its own evidence BEFORE promotion — the first
  reader of the codes must not also be the first thing that can stop a build.
- **A deny-list of placeholders cannot catch the next placeholder**
  (macbookair, 1137-rgfm, landed osx-next 2ccd051f1, attested 8326272e2;
  relay to trunk in the 07:41Z pass): `hardware_fingerprint` refused the
  placeholders already found ("Host CPU", "unknown", from 805-r98w), so
  "Apple Silicon CPU" passed a check whose purpose is catching placeholders,
  and every Apple-silicon Mac with the same core count hashed to one
  fingerprint (hw2-d1ec0bba772d4bda) — which is what let
  `capability-matrix --by-hardware` merge machines it never measured. Fix: a
  `name_source` on DeviceRecord asks the probe where the name came from; the
  deny-list survives only for `None`, because reading pre-field silence as
  "placeholder" would make every stored document unidentifiable on landing
  day. macOS reads `machdep.cpu.brand_string`; the GPU stays a declared
  `placeholder` (needs a framework call, not a sysctl) so that component is
  KNOWN to discriminate nothing. Both guards falsified (reverting the macOS
  arm reds one; ignoring provenance reds the cross-platform one — the one
  that proves the deny-list cannot do the job). Sits `implemented`: closure is
  a second Mac's fingerprint differing, which no single host can produce;
  routed to macneo as a measurement (no build). Corrected by macbookair
  before macneo spent it: the coordinator had predicted "macneo's current
  hash equals macbookair's old one if the core counts match", which is
  under-specified — the hash covers fieldset, cpu vendor/name/cores, gpu,
  npu AND a RAM power-of-two class, so 8 GiB versus 16 GiB differs on
  identical silicon; and a binary predating 803-r8u4 omits the RAM component
  entirely (measured on one machine, same minute: stale release
  hw2-5ce200f625e69d05, fresh hw2-d1ec0bba772d4bda). A cross-machine hash
  comparison is confounded until one release carries 2ccd051f1 on both. The
  unconfounded test is the raw inputs: if macneo's brand_string differs
  from "Apple M5" while cores match 10/10, the old code produced the
  identical `cpu:apple/Apple Silicon CPU/10c10t` on two chips — the
  collision shown from inputs, no hash involved. If cores differ the claim
  narrows to "the name discriminates nothing within a core-count class",
  said plainly rather than rounded up. Rule: a predicted equality of a
  derived value must list every input of the derivation first.
- **A 1-in-15 red unrelated to the diff teaches every host to disbelieve the
  gate** (macbookair, 1146-z8ux, unclaimed): two tests mutate one
  process-global env var in parallel threads; the pristine suite reproduced
  it at 1/15 over 15 runs after a stash, so it is pre-existing and
  timing-sensitive, and 1-of-3 versus 1-of-15 is not distinguishable at
  those counts. Host-independent: macuahuitl's next meta cycle or lenovinha.
- **"check not run" hid two arms that ran** (macbookair, self-corrected): the
  1141-vf9w step's skip description said the check did not run while the two
  substrate-refusal arms DO run before the darwin skip; a reader would have
  concluded macOS pins nothing — the conclusion 1145-iigx warns its claimer
  against. Now "2 substrate-refusal arms RAN and passed; 9 reaper arms could
  not run". A skip description enumerates what ran, not only what did not.
- **Two timing logs on macbookair** (operator item): `cycle-metrics.sh`
  refused (rc 2) between `/tmp/tillandsias-timing.jsonl` (13 lines, last
  2026-09-11T23:22:58Z) and `.cache/metrics/tillandsias-timing.jsonl` (28,471
  lines, live); the guard says move the stray aside, never delete, and
  concatenation is an operator decision. macbookair used the named-log escape
  and changed nothing on disk. Ask: retire the /tmp copy on macbookair.
- **The Windows lane is red on the competing-gate fixture, and it is the
  root regime, not the marker** (yolanda, measured on the sanctioned path;
  mechanism read on trunk by macuahuitl): arm "an unreadable process suspends
  the accusation" wanted rc 3 `unreadable-processes` and got the accusation.
  yolanda attributed it to WSL lacking a container marker; the arm is
  `chmod 000 "$r/103/environ"` in a fake procfs tree
  (the `opaque` scenario of `test-no-competing-gate.sh`, `newroot opaque`) with no root guard, the detector counts
  `[ ! -r environ ]` as opaque, and the WSL gate runs as root — root reads a
  000 file, opaque stays 0, the tokened build.sh has no wrapper, and the code
  accuses because it can read everything. Same shape as the 2026-09-12
  chmod-000 arm. TWO mechanisms, two fixes: (1) the fixture arm needs a named
  root skip or a root-proof construction (dangling symlink pins a different
  semantics) — the inversion alone leaves Windows red; (2) yolanda's
  production line `advisory:competing-gate:1 (not blocking)` is the measured
  WSL datapoint: in-distro call, no marker, wrapper invisible, fixed by the
  inversion. Ruling: both Windows hosts HOLD on the lane; no scoped skip, no
  advisory override, no second gate spent; yoga's :05 cycle carries both
  fixes; esme warned before their merge. yolanda read the block the right
  way round: the detector is advisory and did not block, the fixture blocked
  by correctly reporting the detector wrong here — silencing it would quiet a
  true report on someone else's row. 823-u5zf is done and green at 1d7b29bcc
  (the argv work had landed; what was open was its closure's observable
  being inert on the only headless path that could read it), blocked only by
  the above; to be kept off local-only (work ref or salvage). Not promoting
  1141-vf9w: measured false accusation on WSL today. yolanda's own
  correction: build.sh calls the detector directly on their host (the
  wrapper never does), inferred earlier from where the caller was expected
  rather than looked for. Condition sent, not a claim: `id -u` from a gate
  shell.
  MEASURED on esme before their merge: gate uid 0; a mode-000 file under
  /root reads successfully; verdict "a chmod-000 file IS readable as uid 0
  here" — the root attribution is closed by measurement on WSL, and esme will
  red on the same arm the moment they merge trunk (they hold, per the
  ruling). Instruction corrected for both Windows hosts: keep finished
  commits safe with `scripts/salvage-dirty-worktree.sh <order>`, NOT a
  work/<order> ref — a first push of a new work ref has no base to diff
  against and needs a full gate, which is red on those hosts by definition.
  esme's near-miss, named: their first probe passed mktemp through nested
  wsl.exe layers, the variable came back empty, chmod reported "cannot
  access ''", cat failed against an empty path, and the script concluded
  NOT exposed — a broken instrument producing a clean false negative; caught
  only because the chmod error line was in the output and did not belong
  there. An error line that does not belong is the instrument reporting it
  broke; filtering it for tidiness would have reported esme safe.
- **The salvage script covers the dirty tree, not the unpushed commit**
  (yolanda, measured): on a clean worktree with an unpushed commit and a red
  gate, `scripts/salvage-dirty-worktree.sh` answers `ok:salvage-not-needed`
  rc 0 having preserved nothing, and a first push of a new work/<order> ref
  needs the full gate that is red — so neither half of the coordinator's
  instruction reached the state the salvage rationale was written for
  (finished work sitting where nothing protects it). Fleet recipe, read from
  the hook before relying on it: `pre-push-local-gate.sh` exempts a push in
  which EVERY ref is `refs/heads/salvage/*`, so
  `git push origin HEAD:refs/heads/salvage/<host>/<yyyymmdd>-<order>` lands
  the commit without a gate; verify by `merge-base --is-ancestor` and by
  content on the remote ref, not by the push's exit code. 1d7b29bcc is at
  salvage/yolanda/20260913-823-u5zf. Second property, from yolanda's own
  litter: a dangling symlink in the worktree makes the salvage script FAIL
  (`fail:salvage:add:error: open("dangling"): Function not implemented`)
  rather than skip the path, on the drvfs filesystem where salvage matters
  most. Both filed as one packet by macuahuitl. yolanda's uid-0 reading is
  the second WSL instance (root under both `-u root` and the bare
  `wsl.exe -d tillandsias-build` the gate uses). Their named near-miss:
  `d=$(mktemp -d); cd "$d"` under `bash -lc` returned empty, the cd failed,
  probe files landed in the REPO ROOT, and the cleanup was confirmed by
  listing /root — the wrong subject; the salvage run exposed it.
  LANDED (yoga, b75fd00cf, attempt 1): the arm constructs unreadability with
  a dangling symlink rather than chmod 000, chosen over the fleet's usual
  root skip on yolanda's argument — a skip costs the arm its teeth on every
  root host, which on this fleet is every WSL host, permanently
  (test-spec-index-durable-tier-demotion.sh under 1129-3yv7 asserts nothing
  there for that reason). 11/11 as uid 1000, under `podman unshare` as uid 0,
  and by yolanda inside tillandsias-build. Accepted knowingly and stated on
  the row: the arm pins "missing environ counts as opaque", so on a live
  /proc an unrelated process exiting between list and read can suspend a
  genuine accusation — weakens detection, cannot manufacture a false
  accusation, and is a stated PRECONDITION for promotion (a detector
  silenceable by ordinary churn is not one to hang a build on). Two
  narrowings: yolanda's `advisory:competing-gate:1` IS the measured WSL
  datapoint for the marker-absence mechanism; what remains untaken is a
  flagged host-side caller meeting unreadable processes. And THREE mechanisms
  defeat a chmod negative control (yolanda's framing): NTFS under Git Bash
  ignores the mode, root overrides it, and Silverblue passed only because the
  fixture happens to run as uid 1000 — the next person hits the NTFS instance
  and concludes the root fix does not apply. The tree already knew:
  1129-3yv7 recorded "chmod 000 does not constrain euid 0" on 2026-09-12,
  measured on yolanda, the day before the arm was written; `grep -rn 'chmod
  000' scripts/test-*.sh` would have found it in one command, and the cost of
  not asking whether the construct had a precedent was another host's lane.
  Hold lifted for both Windows hosts. Two directions reached the same
  diagnosis independently (reading the arm here; chmod under podman unshare
  on yoga), which is worth more than either.
  MEASURED on esme, both sides of the pair as uid 0: a mode-000 file reads
  (the defect); `ln -s /root/definitely-not-here /root/dangle; cat` fails
  (the fix). The first probe alone only showed the old arm broken, not that
  the new one works. esme's line on why the construction is the right shape
  and not merely a different one: mode bits are an ACCESS CHECK and uid 0 is
  defined as the identity that bypasses access checks, so no permission-based
  construction can ever produce unreadability for root — the old arm was
  unfixable in its own terms; a dangling symlink fails at RESOLUTION, before
  any permission question is asked, so it is uid-independent by construction
  and a future privileged context cannot defeat it again.
- **A contract three reviewers agreed on was unsatisfiable; the positive
  control found it on first execution** (yoga, inversion landed f0764598a):
  the agreed check "the passed pid's environ CONTAINS the caller's token"
  cannot hold — `/proc/<pid>/environ` is the environment a process was
  EXEC'D with, and the wrapper token is minted and exported at runtime by
  the asserting shell, so it is never in that shell's own environ (measured:
  exporting shell 0 matches, child exec'd after the export 1 match). The
  first wiring refused its real call site with
  `refused:competing-gate:caller-contract`, correctly, against a contract
  nothing could satisfy; the coordinator proposed it, yoga accepted and
  argued its exit code, yolanda did not dispute it. Replacement, stronger:
  the detector reads ITS OWN environ (`$PROC_ROOT/self`, so a fake tree can
  construct it) — this process is the child exec'd after the export, so the
  token is present exactly when the caller really exported it, and no
  convenient pid can be substituted. Four codes intact and mutation-verified
  distinct (11/12 on each of three mutations; 12/12 at uid 1000 and uid 0);
  in the landing gate: `ok:no-competing-gate` from the wrapper's flagged
  call, `could-not-run:competing-gate:no-host-side-assertion` from build.sh's
  unflagged one. The caller-contract code is the one of the four with
  production evidence. Left for yoga's next cycle: the dispatch-shape
  criterion (MSYS as a substrate that cannot see; churn-suspension clause
  naming a slow host) and the WSL wiring with the `--host-side <pid>` +
  exported-token contract for yolanda.
- **1137-rgfm did not compile on Linux** (macuahuitl, this cycle's gate, on
  the osx-next relay): `name_source` was added to DeviceRecord and set only
  in the macOS arm; six Linux initializers (nvidia, the three lspci-named
  GPU arms, the WSL2 dxg arm, the accel NPU arm) and two Windows arms
  (Win32_VideoController GPU, PnP NPU) lacked the field — darwin's cfg hid
  every one of them from the author's build, the green-on-one-regime shape
  on the cfg axis. Fixed in the same land with the provenance each site has
  (measured where nvidia-smi, lspci or PnP answered; placeholder for the
  fixed strings and the driver-derived NPU name); the Windows arms are
  patched blind and yolanda's next merge compiles them. Had the relay landed
  before a Linux gate ran, every Linux host's gate would have been red.
  MEASURED on macneo (raw sysctl, no build): brand_string "Apple A18 Pro",
  6 physical / 6 logical (2P+4E), 8 GiB, hw.model Mac17,5, macOS 26.6.2.
  Different core-count class from macbookair's M5 10c10t, so the old strings
  (`cpu:apple/Apple Silicon CPU/6c6t` vs `/10c10t`) never collided and this
  pair cannot demonstrate the collision; the claim narrows, as macbookair
  called in advance, to "the placeholder discriminated nothing within a
  core-count class". macneo's stored capability row (20260912t014039z)
  carries "Apple Silicon CPU" and hw2-15343879d48b5915 — the placeholder on
  a second machine, from the ledger. The fleet has no same-class pair; the
  suggested closure is the narrowed statement plus the cross-platform
  provenance guard. macneo flagged, not interpreted, an A-series brand
  string on a Mac model identifier; consistent with the low-cost A18 Pro
  MacBook and the operator's "low-end host", not investigated further.
  Routing consequence recorded (coordinator): macneo is a different macOS
  hardware class by measurement (A18 Pro, Mac17,5, 2P+4E, 8 GiB), so the
  fleet has two macOS classes and no comparable pair; work that assumed a
  second comparable Mac treats macneo as its own class. Their stored row's
  `system_ram_gb: null` dates their installed binary before 803-r8u4 (the
  vintage confound evidenced from the ledger, not from one machine's
  accident) — a floor-tier smoke item after the next release. macbookair
  closes 1137-rgfm on the narrowed statement with the cross-platform
  provenance guard as evidence and macneo's inputs plus stored row as the
  second-machine confirmation; owns the cfg-hidden compile break without
  qualification and is testing whether `cargo zigbuild` (the lane's own
  cross path) can compile the Linux arms on darwin, since a plain
  `--target x86_64-unknown-linux-musl` check dies in ring's build script
  before reaching the crate.
- **Partly stale, and the live half was quieter than the original defect**
  (lenovinha, 1123-k3mq closed at c93139300; third kind of stale row for
  1144-jfr5's evidence): criterion 1 was already met by 7c83653ec
  (686-7qcm, compaction applies the closure ladder), verified by the
  recorded pre-fix failure not reproducing; criterion 2 WAS live — once
  compaction refused a rung-lowering write it dropped the write AND deleted
  the fragment carrying it, in silence (`ok: compacted 1 fragment(s)`, zero
  words about the discarded value), so a coordinator releasing an expired
  claim got ok from set-field, ok from compact, a ledger still `completed`,
  and no record anywhere. The original defect at least left the wrong value
  visible in the base. Now compact reports the packet, the refused value,
  the winner, the host and the exact `set-field … --reopen-evidence` command
  — the remaining half of 1115-yvrq. Deliberately not done: last-write-wins
  status (would let a stale high-water fragment silently reopen finished
  work; 650-dq6u). 23/23, mutation-scored, one of three tests is the
  evidence. Fleet rule from lenovinha's repeated mistake (twice in one
  night, two crates): INSERT RUST TESTS ANCHORED ON THE `#[test]` LINE,
  never the `fn` line — anchoring on fn double-registers the new test and
  strips the attribute from the neighbour, silently disabling it while the
  suite reads green; verify by ENUMERATION, never the pass count.
- **The zigbuild cross-check works and catches the actual defect**
  (macbookair, measured): `cargo zigbuild -p tillandsias-headless --target
  x86_64-unknown-linux-musl` → rc 101, six E0063 at exactly the six Linux
  arms; the lane already requires zig + cargo-zigbuild
  (scripts/build-macos-tray.sh). Rule: zigbuild the guest target before
  landing a change to a cfg-split file. Boundary: 6 of 8 arms — no Windows
  target is installed on macOS, so the two Windows arms need yolanda or
  esme; plain `cargo check --target x86_64-unknown-linux-musl` dies in
  ring's build script for want of a cross C toolchain and never reaches the
  crate. Nearly sent `E0063 count = 0` while the build was still compiling —
  fifth absent-result-read-as-negative instance, caught. Decision recorded:
  macuahuitl lands the fix (it was committed here before the question);
  macbookair does not touch the file and re-runs zigbuild after merging
  trunk for the 0-errors arm. Two hosts, one file, heads-up before writing.
- **The unstageable-symlink axis is the git, not the filesystem** (yolanda,
  full matrix on one drvfs path): Git Bash cannot CREATE a dangling symlink
  (MSYS emulation copies the target); WSL creates it; WSL git stages it
  (rc 0, `A dangling`); Git for Windows cannot index it (rc 128,
  `open("dangling"): Function not implemented`). The salvage skip is a
  Git-for-Windows property reachable only when a non-MSYS tool created the
  path; written as drvfs the row would have sent a reproducer to WSL to
  conclude the skip is dead code. Wording corrected in the landing; the
  test-only seam is the only portable construction. Three fixtures in one
  night wrong about their own setup and green on the host that wrote them —
  yolanda's argument for cross-substrate gating. Coordinator cadence gap,
  named: `sweep-salvage-refs.sh` in report mode found 11 refs, 10 UNSEEN by
  the ledger (two from `salvage/unknown/`, one of yoga's from 2026-08-26) —
  the consumer 874-w2gc added has not been run on a cadence; `--apply` and
  the deletion of yolanda's now-redundant
  `salvage/yolanda/20260913-823-u5zf` (ancestry confirmed by them) are
  coordinator writes for the next pass. 823-u5zf landed windows-next
  4061856c8: the argv work was already landed and the next_action stale;
  what was open was the closure's own observable being inert (`--forge`
  exits before `init_tracing()` on the only headless path); pinned with a
  mutation control repaired twice (matched its own source; then passed by
  reading its own doc comment).
- **This cycle's land** (macuahuitl, ok:land:67009ea3b, second launch): the
  first launch was refused by the bash-dialect guard (761-g36m) — the new
  salvage loop's `"${paths_to_stage[@]}"` under `set -u` dies on bash 3.2
  when nothing is staged; the 3.2-clean `${arr[@]+"${arr[@]}"}` idiom fixed
  it, dialect check and fixture green, relaunched, attempt 1 ok. The gate
  caught on this host what would otherwise have been macOS's to find: the
  sub-agent wrote bash-4 idiom, the coordinator's own fixture run did not
  see it, the guard did. Landed together: the osx-next relay with its Linux
  compile fixed forward, 1146-z8ux and 1146-8j7i completed, 1147-6xqs filed,
  the loop-status fragment, and the held coordination records.
- **Coordination pass 08:11Z** (macuahuitl): relayed osx-next (1137-rgfm
  closed on the narrowed claim; the both-arms zigbuild rule) and
  windows-next (823-u5zf: the headless launch path never initialised
  tracing, so the closure's own observable was inert; 793-zumy evidence),
  no conflicts; the Windows tray crate changed, so a full gate. macbookair's
  0-errors arm: pre-fix osx-next 2ccd051f1 rc 101 with six E0063; post-fix
  trunk 95d98bde7 merged rc 0 — same host, same command, two trees; the
  rule is usable, not suggestive, and its boundary stands (6 of 8 arms; no
  Windows target on macOS; plain `cargo check --target …-musl` dies in
  ring). The salvage sweep's `--apply` cannot write: it appends to 874-s8vf,
  ARCHIVED, and the ledger refuses events on archived packets — filed as
  1148-3439 (standing salvage ledger under plan/salvage-refs.d/). The ten
  unseen refs disposed by hand (ancestry on four branches, then per-file
  content against trunk): pirria's three 2026-09-02/03 refs merged
  everywhere; macuahuitl/20260826-metrics-dashboard-carried identical on
  trunk → DELETED; macuahuitl/20260911-recover-sep6-fragments carried the
  two 2026-09-06 fragments whose content is already compacted into the base
  (1118-pifa and the floor-timing events) → DELETED; yolanda/20260913-823-u5zf
  on windows-next → delete after this relay lands; yoga/20260912-restart
  one file identical on trunk → yoga's confirmation asked; yoga/20260826-
  iteration-3 carries a scripts/local-ci.sh that DIFFERS (kept, yoga's);
  pirria/20260904-1013-qv7c carries a smoke-skill edit that DIFFERS (kept,
  pirria down); salvage/unknown/20260902-opsx-* two refs, 22 identical
  .claude/commands/opsx files each (kept until the lane is named). Operator
  item, from macbookair: every host's cadence is a session-scoped cron that
  dies with its session and expires 2026-09-19; the durable per-host timer
  is 890-27mv's open follow-up.
  Salvage disposition closed for yoga's two refs: yoga verified rather than
  agreed (diff against the PARENT, then byte-compare — the 1377-file diff
  against trunk is only the stale base and says nothing about what a ref
  carries): 20260912-restart one file identical (sha bb637c96fce1 both
  sides); 20260826-iteration-3 a real local-ci.sh PIPESTATUS fix that
  survived under 831-ezea. Both DELETED by the coordinator; seven salvage
  refs remain. yoga's implication for 1148-3439: the broken window is the
  interval since 874-s8vf was archived, during which salvage records were
  LOST rather than delayed, and every deletion has rested on a manual
  parent-diff — fine at eleven, not at a hundred, and silent.
- **pirria is back** (relaunched by the operator, reported 08:2xZ; destructive
  reset approved on that host by its user): briefed as floor tier — first
  the parent-diff of salvage/pirria/20260904-1013-qv7c (+91/-4 on the smoke
  skill; likely landed by another route) reported, not deleted; standing job
  the daily-channel curl-install smoke §0-§5 on the newest release with the
  timing helpers sourced (the only floor host that writes smoke-* records);
  per-host drill file flat; plan-only pushes gate-free; scripts/skills diffs
  handed to the coordinator rather than landed; cadence arming is the
  operator's.
- **A set-field on a long-form field silently drops other hosts' warnings**
  (esme, 793-zumy, landed windows-next 4456bdc53): correcting next_action
  replaced it wholesale and dropped three load-bearing lines — the
  VERIFICATION DEBT note, "DO NOT MOVE legacy_tier WITHOUT TELLING YOGA"
  (dev-inference-ensure.sh greps it with `grep -m1` on raw --capabilities
  output; a key ahead of it silently downgrades a host to cpu), and the
  hwfp-v2 field list — restored verbatim under a PRESERVED heading. Noticed
  ONLY because the tool echoed the old value's tail; check-fragment-status-
  loss guards status, not prose, so nothing in the gate chain catches it.
  Ledger-integrity hazard; packet in the next pass on esme's evidence. Also
  from esme: 1146-xs6s filed (the stale-plan-binary refusal recommends a
  candidate newer than the RESOLVED binary rather than the SOURCE, honours
  TILLANDSIAS_PLAN_BIN on existence alone, and named an ELF to a Git-Bash
  hook — two failure modes, no success mode on Windows; rebuilt at
  CARGO_BUILD_JOBS=1 in 1m38s, which made the guard's premise true); two
  self-corrections — jobs=1 SURVIVES the memory reaper where jobs=2 is
  reaped (true for survival, still worse for throughput), and Windows-side
  long work has no setsid equivalent, so only the in-distro side is
  protectable; and the capture lesson: filtering a diagnosis at capture time
  (grep on a variable, tail -20) discarded the verdict line twice — write
  the raw output to a file and query it afterwards; a filter has to
  anticipate the failure, and the point of a failure is that you did not.
  pirria's parent-diff verdict: salvage/pirria/20260904-1013-qv7c is
  REDUNDANT — the tip's skill blob is byte-identical to trunk commit
  5e6c6a4cc ("salvage(pirria): dirty worktree preserved before a cycle
  refusal"), landed by a second route (same subject, different sha, so
  `--is-ancestor` says no while the content is fully present), and trunk has
  since moved past it (1026-ps4n, 900-z3kv, 1004-vsh2 all edit the same
  sections; restoring the ref would regress them). Verified on macuahuitl
  (ancestor + blob compare) and DELETED. Six salvage refs remain: pirria's
  three merged everywhere, yolanda's (delete after the relay lands), and
  the two salvage/unknown/ opsx refs.
- **CORRECTION, withdrawn before it reached the operator** (macbookair): the
  "durable per-host timer" item recorded in the 08:11Z pass entry is NOT an
  operator ask. The operator told macbookair directly that non-durable,
  session-scoped crons are INTENDED: cadence is set per milestone by the
  orchestrator, and a durable scheduler would hand cadence control to
  something nobody re-points when the milestone changes. macbookair names
  the error class: inferring a defect from a property without asking whether
  the property was chosen — the same shape as the night's fixture packets,
  pointed at a design decision. 890-27mv's follow-up stands or falls on its
  own reasons; nothing measured this session is evidence for it.
  Pass 08:11Z landed ok:land:79fc27018 attempt 1 (both relays, 1148-3439,
  the pass record). yolanda's salvage/yolanda/20260913-823-u5zf deleted
  after 1d7b29bcc reached trunk by the relay; five salvage refs remain
  (pirria's three merged everywhere, the two salvage/unknown/ opsx refs).
- **1141-vf9w's reaper fixture flakes under gate load** (lenovinha,
  measured; relayed to yoga with a testable shape): land refused at attempt
  1 on `FAIL: a marked process is found by its token` (10/11); the same
  tree and commit standalone 11/11 three times running; the diff touched
  nothing near dispatch. "Passes alone, fails in the gate" refuses innocent
  diffs and is invisible to a hand re-run. Candidate, not a claim: the arm
  scans before the spawned child has exec'd, so its environ does not yet
  carry the token; under load the window opens. Fix shape if so: a bounded
  poll until the token is visible before the assert. The load was
  lenovinha's own gate (the coordinator's land ran on macuahuitl).
- **1119-6wn6's counter half** (lenovinha, re-landing): --emit-tokens
  appends one JSONL record per cycle beside the flow log with the flow
  log's properties (coercion over a poisoned row, cycle-id minting,
  replace-on-retry keyed host+cycle, always exit 0); views `tokens:` and
  `token_recur:` (top-3 REPEATED labels — a one-off is a cost, not a
  recurrence). Coordinator review: keep the more-than-once rule and add
  `token_max:` (largest single record, label, cycle id) so the incident
  that produced the packet — a one-off 4.5M — is visible without polluting
  the recurrence view; the fixture pins the baseline appears there and not
  in token_recur. Semantics to check: the first emitted row carries
  main_ctx≈900k, which was reported earlier as the SESSION cumulative; a
  per-cycle contract with the row re-emitted, or a field named
  main_ctx_cumulative. Stated limit: the instrument pins the ledger and the
  views, never the honesty of the number — only the agent observes its own
  spend. Two of lenovinha's own arms were vacuous by absence ("abc is not in
  the log" is true with no log) and pre-fix scoring caught it: 3 → 1 pre-fix
  passes, the survivor named (exit-0, undemonstrable pre-fix).
- **macneo :40 cycle** (osx-next ae9d9e42d, record b44ff8df3, relay next
  pass): 1127-apa8 closed as a READY-BUT-LANDED row — the fix was already
  on trunk as e357f3f87 (`--include='*.rs'` moved from after the `--` to
  before it in check-proxy-permissive-port-routing.sh; after the double
  dash grep took it as a path operand, so the filter never applied and the
  scan walked staged binaries — both halves of the title one reordering);
  verified on the host with a positive control on the 3129 literal so the
  empty .rs result is a true negative. Offered to 1080-4deb as a worked
  confirmation: the landing subject opens with fix(1127-apa8), so the
  anchored reader would have rung this row — one real closure out of the
  46-hit list, checked by hand. KEYCHAIN ASK CORRECTED AND RESOLVED (macneo,
  corroborated from the item, not the report): the standing operator ask
  said "run the command and choose Always Allow"; the operator did,
  repeatedly, and it did nothing — the dialog carries a PASSWORD field and
  Always Allow authenticates nothing unless the LOGIN KEYCHAIN PASSWORD is
  typed first (gh:github.com acct cdat == mdat == 2026-09-06T04:22:01Z
  before, during and after; no grant written). Root cause settled: a WEDGED
  SecurityAgent (21h45m, ignored SIGTERM, respawned on SIGKILL) plus
  accumulating PPID-1 `security` orphans, because _ccc_timeout kills gh and
  its security child survives holding a dialog no later timeout reaps — NOT
  a deny-by-default ACL (macneo's earlier guess) and NOT a prompt backlog
  (macbookair's). A restart cleared it; bare decrypt rc 0; three gates since
  reached the keychain without prompting. Same family as 1145-iigx. The ask
  comes off the operator list. Structural refusal worth a packet: the
  plan-only lane refused a one-line claim push because the mandated
  origin/linux-next merge pulled a non-plan path (already gated on trunk)
  into the outgoing diff — any cycle where trunk has added a non-plan file
  since the host's last merge pays a full gate for a claim; the lane should
  treat outgoing non-plan paths byte-identical to origin/linux-next as not
  the pusher's to gate. macneo's per-host file
  (fleet-restart-2026-09-12-macneo.md) written on the convention; folded
  by reference. Self-inflicted and reported: three line-number citations
  (881-29me) re-cited by symbol, guard re-proven with a planted fake file-and-line citation.
  yoga's follow-up on the reaper flake (ok:land:4423f6ea9): the exec-window
  shape is UNREPRODUCED, not confirmed — `sleep 0.3` removed entirely, 18
  runs (8 idle, 10 under six CPU hogs), zero failures on yoga — and fixed
  anyway on construction: a fixed sleep between spawning and asserting is a
  race by construction; `await_marked` now polls until the token is visible
  for that pid and FAILS LOUDLY on timeout (teeth: with the export removed
  it reds by name). The hypothesis found a second defect of opposite sign:
  arm 3, the negative control, was satisfied whenever the child had not
  exec'd YET ("absent from A's set" is implied by "absent from every set"),
  so under exactly the load that flakes arm 2, arm 3 passed for free. One
  missing synchronisation, two defects, only one visible. yoga's cycle is
  LANDED-BUT-UNATTESTED at 7c5c5e330, cause theirs end to end and recorded
  as the sanctioned exit: `pkill -f 'while :; do :; done'` matched the
  killer's own command line and killed the session mid-command twice; the
  second kill aborted a restore, the boundary snapshot was then taken over
  the dirty tree and recorded the deliberate test mutation as STARTUP DIRT,
  and restoring the file read as startup dirt vanishing — the guard was
  right. Nothing lost: the boundary's worktree.diff holds the discarded
  hunk. Three rules, yoga's, by name: kill by PID with a `$$` exclusion,
  never by a pattern that matches the killer; check the tree is clean
  before taking a boundary; SALVAGE BEFORE RESTORE — establish whose dirt it
  is before discarding it, whoever it turns out to be.
  CORRECTION (lenovinha, 47271ced5): the coordinator's relayed hypothesis
  for the reaper flake (spawn-then-scan before exec) was WRONG — `$!`
  equals the token holder in both environments, so a poll could not have
  settled it; not CPU load (8 spinners, 11/11), not /proc access, not
  setsid. The cause is the SIGPIPE CLASS, measured decisively inside
  tillandsias-builder varying only the pipe: `tillandsias_marked_pids |
  grep -qxF` under pipefail 5/5 FAILURE on a SUCCESSFUL match (grep -q
  exits at the first hit and SIGPIPEs the producer still walking /proc);
  the same question captured then matched 0/5. 1076-kft9's condition with
  its environment dependence (they measured drvfs vs ext4; this is host vs
  container) — why it refused innocent lands and every by-hand re-run was
  green. Both fixes were needed: yoga's alone 10/13 (await_marked polled
  by piping into grep -q and could only time out), lenovinha's alone
  11/11, combined 11/11 in-container and on host; lenovinha took yoga's
  file as the base (their arms, awaits, pb/pc vacuity fix) and applied
  capture-before-matching to the helper and the one raw pipeline where a
  SIGPIPE failure would have made the negative control pass for the wrong
  reason; arm accounting by enumeration (11 check calls in both files).
  Row stays yoga's. lenovinha's own earlier instance stays unproven and
  retracted; this is a different, reproducible instance in another file.
  1119-6wn6 review corrections landed: token_max pinned as a PAIR with
  token_recur (same record in one view and not the other); the mislabelled
  row fixed as main_ctx_cumulative (the average was NOT poisoned —
  avg_subagent_tokens aggregates subagent_tokens only — so the fix stands
  on the misuse, not the coordinator's predicted consequence); 13/13.
  yoga's closure (ok:land:9dc5853be, attested 391a5b471, boundary taken
  over a tree checked clean first), in their terms: 1132-r4mt's filing
  event dismissed SIGPIPE-in-a-grep-q-pipeline BY NAME as unable to explain
  the archiver's ruby positive control — correct about the SUBJECT — and the
  fixture built to study that packet then failed by exactly the dismissed
  mechanism and refused innocent lands for it. Ruling a mechanism out for
  the subject says nothing about the INSTRUMENT built to study it, and the
  instrument is the thing nobody reviews. Their own fix alone (await_marked
  polling by piping into grep -q) would have turned an intermittent false
  failure into a DETERMINISTIC one on every host whose gate runs in a
  container; it read as an improvement because it was green on the
  authoring host — fourth instance tonight. And the method error, in their
  words: failing to reproduce in 18 runs was the measurement saying the
  hypothesis was wrong, not licence to fix on construction and stop
  looking; "a fixed sleep is a race by construction" was true and
  irrelevant. Verified on merge: zero raw `marked_pids | grep` pipelines
  remain. Left on 1141-vf9w: the dispatch-shape criterion and the WSL
  wiring with the flag contract.
- **1118-dwgx landed windows-next dbc1c4d73** (yolanda, first-attempt land,
  one gate, no refusals, no memory kills — "a packet sized to a cycle and
  every check run before the gate rather than through it"): the browser
  enclave's podman argv is a wall of confinements (cap-drop=ALL,
  no-new-privileges, read-only, userns=keep-id, tmpfs for /tmp and both
  caches) and `--network=${TILLANDSIAS_BROWSER_NETWORK:-host}` was the one
  line that undid them BY DEFAULT with no proxy filtering, asserted by
  nothing; now falls back through TILLANDSIAS_ENCLAVE_NET
  (check-enclave-network-internal.sh's spelling) and is pinned in
  litmus:browser-isolation-core-shape beside cap-drop and user-data-dir;
  `labels.len() < 3` in allowlist.rs. Relay next pass. THE PIN REPRODUCED
  THE DEFECT IT WAS WRITTEN TO PREVENT: its first draft matched the
  rationale COMMENT above the flag, which quotes `--network=host` while
  explaining why it is wrong, so the step would have read its author's own
  prose as the code and reported the fix present — the same shape as
  823-u5zf's closure one packet earlier, in the pin written after learning
  it. Both steps strip comment lines now and the mutation control leaves
  the comment in place so the blindness is exercised. Caught only by
  running the step's command and reading what it matched; that also
  settled the stray hit (exactly one code occurrence of `--network=host`).
- **pirria's stable smoke of v56.9.12.2: PASS §0-§5** (report and two
  packets on linux-next 58835a8be, plan-only lane): install/version PASS;
  reset PASS (0 containers, 0 volumes, 0 images); init PASS 442.7 s, 15
  images; forge lane 66m39s, supervisor SURVIVED at 15 GiB; sealed and
  proxy asserts PASS; five smoke-* timing records written (field is `exit`,
  not `exit_code`) — the first floor-host timing records the metrics have
  had. 1134-u934 CONFIRMED on the published artifact at §3b (vault exit 137,
  elapsed 11 s ≥ grace 10 s, oom=false, tree `1 bash / 10 vault / 11 tee`;
  the fix 0b606fde7 landed after the tag's base 8a45bd522) — a confirmation
  event, not a new packet. THE FINDING THAT MATTERS (p1,
  smoke-finding/credential-cold-probe-reads-keychain-only): the
  credential-cold probe asks the host keychain only, while vault reads the
  keychain OR ~/.cache/tillandsias/fallback_*; fallback_vault-shamir-share-v1
  (mode 600) has sat on pirria since 2026-09-01 untouched by every reset, so
  the "cold" verdict was WRONG and the resync path was NOT exercised — the
  900-z3kv condition exactly, while 900-z3kv's own criterion-2 instrument
  certified the opposite; the vault log says "in keychain" when the share
  came from the fallback, which keeps the substitution unreadable. A wrong
  COLD on the host cited for cheap clean-room results is spent, where a
  wrong warm is discounted. pirria did NOT delete the fallback files:
  criterion 1's (a)/(b) is the operator's and now covers the fallback file
  as well as the keychain. p3: `tillandsias-plan blocked-on` errors "the
  ARTIFACT is stale — rebuild" while the binary has only blocked-by and the
  MCP layer advertises plan_blocked_on (second instance of the surface-skew
  class after `unknown query constraint: --capability-tags`). NOT CHECKED,
  stated: the release's headline 1084-x8ya keying — a lane that launches
  cannot tell a correctly keyed wire from an unkeyed one that works; the
  mismatch arm was never provoked. §4a: 15 GiB is a BOUNDARY, not a
  threshold — survived this run, lost the supervisor 2026-09-04 at the same
  size; setsid made it observable, not adequate. The in-forge agent pushed
  its own work (f156b1fb5, 1c181f233) and filed
  low-end-tier-structural-drain-gap-2026-09-13.md for its refused:no-tier-work.
  Not yet ledger rows: pirria's two findings are "### Work Packet" sections
  in the findings report, with no plan/index.d fragment (zero matching
  packet_ids); asked to file them as fragments through the plan-only lane
  with verifiable_closure/owned_files and the pre-fix result, else the
  coordinator files them from the report at the next pass. The forge agent
  on pirria compacted 320 fragments into the base (f156b1fb5; 9 fragments
  remain, 900 packets, all recent rows intact) — a base write from a floor
  host's forge that took the full gate inside the lane.
  Filed by pirria as ledger rows at d4c12ed05 (plan-only lane): 1149-vgn2
  (the credential-cold probe certifies cold while a fallback share keeps
  every reset warm; owned scripts/probe-credential-cold-state.sh and its
  fixture; unscoreable form naming the future litmus, the measured pre-fix
  FAILS verbatim, and two negative controls — no item and no fallback still
  answers cold; a keychain item present still answers warm) and 1149-e8my
  (the plan CLI blames a stale artifact for a subcommand name that never
  existed; owned crates/tillandsias-plan/src/main.rs). Both claimable
  (`ready` lists them worked:1@linux). check-declared-closures-added.sh
  refused the verifiable_closure form for both because each deliverable IS
  its guard (885-92iu) — the unscoreable form is the right one there, as
  1144-jfr5 and 1147-6xqs found. LANE POLICY, third structural refusal of
  the plan-only lane in one night, for the coordinator to file: the lane
  refused pirria's first attempt with "the resolved plan binary is STALE
  (full gate required)" because their trunk pull brought a newer
  crates/tillandsias-plan/src/main.rs than their binary — so the gate-free
  lane, built so floor hosts and forges can file without cargo, requires a
  cargo build on exactly those hosts (54.8 s warm on pirria; a cold target/
  or no toolchain has no move short of --no-verify, which is forbidden).
  1129-4su6's reasoning stands (a stale binary can accept a shape current
  rules refuse); the fix is to scope staleness to the fragment-validation
  surface rather than all of main.rs, or let the lane validate with a
  fetched binary. Siblings: macneo's (the mandated trunk merge pulls
  trunk-gated non-plan paths into the outgoing diff) and esme's 1146-xs6s
  (the staleness remedy names a wrong artifact).
- **1141-vf9w story complete** (yoga, ok:land:b48fef19f, attested
  549566ea2): criterion rewritten on dispatch SHAPE — the old "a
  non-Silverblue linux host and a WSL host" was satisfied by mutable Fedora
  in wording, not meaning (Silverblue and mutable Fedora are both toolbox
  dispatch: one shape measured twice wearing two distro names); now
  toolbox (satisfied; a third toolbox host adds nothing), wsl.exe, none;
  plus churn-suspension measured on a SLOW host; plus a consumer that reads
  the codes landed first. MSYS closes as a stated limit (no
  /proc/<pid>/environ on the Windows host side; the detector cannot see
  there by construction). 1149-3v3n filed for the Windows lane with the
  flag contract written out (`--host-side "$$"` before dispatch, token
  exported first, exit grammar 0/1/2/3, closure a QUOTED GATE LOG since the
  substrate is the subject) — not wired by yoga (with-wsl2-builder.sh is
  Windows-lane scope; unexercised code in someone else's file). Coordinator
  ruling: 1141-vf9w released to READY with the criterion as next_action and
  each remaining condition routed by host — wsl.exe datapoint → yolanda via
  1149-3v3n; churn-suspension on a slow host → pirria as a floor-tier
  measurement (recipe sent: a tokened sleep as the candidate, 30 detector
  runs under a churn loop and 30 without, four raw counts and scan
  durations); consumer wiring → its own packet, yoga to file.
  Done (yoga, ok:land:00bd88f9f, attested 7d518bf36): 1141-vf9w is READY
  with the three conditions routed by host on the row itself (wsl.exe via
  1149-3v3n on yolanda; churn-suspension on pirria; the consumer at
  1150-q462) — written for a distrustful stranger, the property a
  message-only park lacked earlier tonight. 1150-q462 filed (yoga's, p2):
  both call sites discard the status with `|| true`, so the four-code
  grammar binds nobody and a caller-contract bug is indistinguishable from
  an unsupported substrate; its criteria pin the BRANCHING (a stub returning
  2 must produce a different caller response than a stub returning 3 — the
  arm most likely to be deleted as redundant is the negative control), and
  the row states why it must not be bundled with promotion: the first
  reader of the codes must not also be the first thing that can stop a
  build, or a consumer bug and a detector bug arrive together and cannot be
  told apart in the field. Code 2 is the one with production evidence.
  Promotion closes on evidence, not work: a flag flip already pinned.
- **One row closed twice in one hour, on two branches** (1127-apa8):
  macneo closed it on verification at osx-next ae9d9e42d (~08:40Z); lenovinha
  closed it on verification at linux-next 358e3f4f3 (~09:50Z), having
  picked it from plan_next, which could not see macneo's claim or closure
  because both live on osx-next until the coordinator relays. Nothing to
  drop (both are verification-only closures; the relay will carry two
  completion records for one row), but the cost is a cycle of a fat host,
  and the cause is structural: CLAIMS AND CLOSURES ON A PLATFORM BRANCH ARE
  INVISIBLE TO plan_next ON EVERY OTHER HOST until the next pass. The claim
  event exists to prevent exactly this and it cannot, because the
  methodology sends platform hosts' plan edits to their platform branch.
  Candidate fix for a packet (methodology-level, operator-visible): let
  claim and closure fragments be pushed to linux-next from any host through
  the plan-only lane (the ledger's canonical home), or have the coordinator
  relay platform-branch plan fragments on a shorter clock than code. Also
  from lenovinha: a DISTINCT stale shape for 1144-jfr5, the cheaper one —
  the fixing commit NAMES the order (e357f3f87 "fix(1125-wi4d, 1126-w8rq,
  1127-apa8)") and the row was simply never moved off ready; the query "a
  landed commit whose subject cites <order> while <order> still folds
  ready" has no owned_files heuristic and no false positives, and belongs as
  a first pass ahead of the fuzzier one (still a candidate: the commit
  fixed three orders and might have completed only two, so verification by
  execution stays mandatory). lenovinha's near-miss, on the row: they cited
  this guard's green while closing 1118-bscs before knowing whether its
  --include defect was live — citing a guard's verdict without knowing what
  it searches is the near-miss, whatever the outcome. lenovinha next:
  1128-4ffr (a capability row wedges every push from a host absent from the
  compacted base).
- **The competing-gate detector has a PERMISSION FLOOR and can never accuse
  on an unprivileged Linux host** (pirria, measured; event on 1141-vf9w at
  81c936ea3; the churn hypothesis REFUTED): 30 runs per arm with a genuine
  stray alive (build.sh in cmdline + token, no toolbox sharing it): control
  accused=0 suspended=30; churn accused=0 suspended=30; opaque 164..171;
  37 vs 47 ms per scan (timing is not where the problem lives). Of 255
  processes 162 have an unreadable environ, 150 root-owned —
  /proc/<pid>/environ is owner-readable only, so opaque is permanently
  non-zero on every multi-user Linux host and ONE unreadable process is the
  threshold. The classifier is fine (all three states fire through the
  TILLANDSIAS_PROC_ROOT seam). Consequence: "promote once it has run clean
  across hosts" is satisfied forever on every unprivileged host because the
  detector cannot reach its own accusation there; the only regimes where it
  CAN accuse are the two that produced false positives (in-container same
  uid; WSL as root). Coordinator's brief was wrong twice (recorded): the
  detector does not test cwd (candidate = `*build.sh*` in cmdline plus the
  token; bare sleeps hit the debris arm on purpose) and the caller must pass
  --host-side with the token exported into the detector process. Candidate
  fix sent to yoga: count an unreadable environ as opaque only when the
  process could be the candidate's wrapper (same uid as the scanner, or a
  wrapper-shaped cmdline, which is world-readable). 1150-q462 (no consumer
  reads the codes) and this (the producer cannot emit the code) cite each
  other. pirria's plan-only push recorded its head as an un-gated union
  past a merge of origin/linux-next; the coordinator's next land gates it.
- **1128-4ffr closed** (lenovinha, cd7d62172): a joining host's capability
  row no longer wedges every push — preflight allows rc 3 only when every
  dropped entry carries the PENDING reason ("the compacted base carries no
  row for that host and locus") and zero fragments are malformed ("carries
  no host.host_id"); the allowance keys on the REASON, never the shared
  `dropped-entry:` prefix. The correct fix came from lenovinha's own invalid
  reproduction: their probe put host_id at entry level and hit the
  MALFORMED drop, which returns the same blocked:plan-ledger-incomplete —
  same verdict, different cause — so "falsified both ways" in the claim was
  false and was corrected on the row; arm 4 makes that mistake permanent
  (no host_id must STILL refuse; a prefix-keyed allowance would wave it
  through with arms 1-3 green). Second defect introduced and caught: the
  first cut allowed the case but left rc 3, which the next branch relabelled
  blocked:plan-ledger-invalid — a worse label — caught only by running all
  four cases separately. 5 of 6 arms are preservation arms; only arm 1
  demonstrates the fix, said so. NOT DONE, named: the fold still declines
  the row, so a joining host stops being WEDGED but APPEARS in the matrix
  only after a compaction; the matrix half is a different file
  (crates/tillandsias-plan) and its own row. On the 1127-apa8 duplicate:
  two hosts reaching one verdict by different routes is evidence the
  verification method is sound, though the cycle was wasted; the
  cites-the-order query would not have helped, since the row genuinely
  was ready on each branch.
- **CORRECTION: a joining host appears in the matrix immediately**
  (lenovinha, measured before implementing; the row 1151-pemc they had
  staged for the "matrix half" was removed before landing): with a
  well-formed capabilities row for a host+locus the base lacks,
  capability-matrix shows 11 rows with the fragment present and 10 without,
  and the probe's line carries `from:<the fragment>` — the matrix reads
  fragments directly. The decline 1128-4ffr measured is in the
  COMPACTION-CANDIDATE check, not the runtime fold; the only residue is that
  such a fragment never compacts until the base carries the host, a
  housekeeping wart. The claim "publishing stops the wedge but the host
  appears only after a compaction" was an untested inference that went into
  1128-4ffr's closure event, a handoff, the coordinator's reply and memory,
  and a filed row — three restatements, no measurement, until the one that
  mattered; lenovinha appends the correction to 1128-4ffr. Fourth plausible
  mechanism refuted under measurement tonight, the first that was the
  measurer's own and had propagated. No p2 filed for a working path.
- **The plan-only lane refuses a platform branch that is strictly behind
  trunk — which is every platform branch right after a relay** (esme,
  read out of the hook, not inferred; 1154-6big landed aaafbda66 once
  fixed): a plain `git merge origin/linux-next` FAST-FORWARDS when the
  branch has no commits trunk lacks, so no merge commit exists, the
  first-parent line is trunk's own, and `_lane_scoped_diff` (which walks
  `git log --first-parent --no-merges`) counts every trunk commit's files
  as the pusher's — "'scripts/gate-steps.d/270-1119-6wn6.step' is outside
  plan/index.d/". `_lane_can_scope` still passes (19 merges, 0
  disqualifying — trunk's own internal merges), so the predicate is
  necessary, not sufficient, and diagnosing from the merge list concludes
  the lane should have worked. THE PREDICTOR: `git log --first-parent
  --no-merges --oneline origin/<platform>..HEAD` must list only the
  pusher's own commits. RECIPE: fetch, `git checkout -B <wip>
  origin/<platform>`, `git merge --no-ff --no-edit origin/linux-next`,
  cherry-pick the plan commits, run the predictor, push. Why it is new:
  it fires only when the platform branch has nothing trunk lacks; every
  earlier push happened with the branch ahead, so a merge commit appeared
  by accident. Broadcast to yolanda, macbookair and macneo (osx-next and
  windows-next were both in the triggering state after the 10:11Z relay);
  fourth mechanism for 1152-y3bv (note event to append). esme got it wrong
  three times before reading the function ("too many merges", "the
  predicate is the test", "origin moved under me"). 1154-6big: resolve_probe
  in host-capability-probe.sh never tries ./target/debug/tillandsias (249 MB
  here, runs) while its siblings do; paired with lenovinha's half (check()
  skips the expiry check when the live fold is unavailable, fail-open
  reproduced at 7000 days), theirs lands first or alongside because fixing
  the probe first would hide it; esme's mixed locus pair (in-guest carries
  schedulable sets, windows-host none) is the only fleet data that can
  exercise its arm 13 against real folded sets.
  Correction to the broadcast (yolanda, measured): windows-next was NOT in
  the triggering state when the coordinator said so — esme's 1154-6big
  (aaafbda66) and a wip merge commit ("Merge … into replay5") had landed
  after the relay, so the branch was divergent (2 ahead, 2 behind), not
  contained; the coordinator inferred the state from the relay rather than
  measuring it. The hazard stands; the window reopens whenever a relay
  leaves a platform branch fully contained and nobody has pushed since,
  which on tonight's cadence is most of the time between lands. yolanda
  confirmed the mechanism from the hook source and named their own earlier
  conflation (checked _lane_can_scope against their head, reported "would
  qualify on that axis" without the axis it does not cover). "Necessary,
  not sufficient" is the sentence for 1152-y3bv: _lane_can_scope answers a
  question about MERGES (every second parent already in trunk) and says
  nothing about what the first-parent walk will sweep up; two independent
  conditions. Predictor adopted over trusting the merge shape.
  macneo measured osx-next IN the triggering state (0 commits trunk lacks;
  osx-next an ancestor of linux-next), so a plain merge there fast-forwards
  now; they re-armed their own :40 job (de51113a, the old one cancelled)
  with the --no-ff recipe and the predictor, plus three lane lessons so the
  next unattended cycle does not re-pay them: cite by symbol never by line
  (881-29me refused a full land over three citations); an ancestry
  negative control must be a commit the test can actually refuse (an
  origin/windows-next that had since merged could not fail — the deleted
  salvage tip 94f12eeb7 is their standard); finalize-cycle.sh can emit MORE
  THAN ONE `MO-FULL:` line in one run — take the LAST (they verified the
  first on a prior cycle, right by luck). On 1152-y3bv: both symptoms are
  one root — the lane attributing trunk's already-gated commits to the
  pusher (the fast-forward makes the whole first-parent line trunk's; the
  claim-push case pulled one already-on-trunk path); "paths byte-identical
  to origin/linux-next are not the pusher's to gate" answers both, and the
  predicate passing while the lane refuses is what makes it expensive.
  Both halves measured (macbookair, in a scratch worktree on osx-next, same
  trunk f2061603b, same plan-only commit, one flag apart): plain merge →
  fast-forward to trunk's own commit, predictor lists 22 commits (theirs
  plus 21 of trunk's, every one touching paths outside plan/index.d) — the
  refusal; `--no-ff` → HEAD 28b514e7c distinct from trunk, predictor
  count 1, only theirs. Why --no-ff is the right shape and not a trick: the
  lane asks "which commits are YOURS" by walking first-parent from the
  remote branch; a fast-forward destroys the only structure that can
  answer (the branch pointer IS trunk's commit, no first-parent line of
  your own remains); --no-ff keeps the merge commit whose first parent is
  your branch — the flag keeps the fact the lane reads. Caveat: the
  predictor is a PRE-push check whose answer changes the moment trunk
  moves; it belongs immediately before the push, like the gate stamp, not
  at the top of the cycle.
- **`$?` does not survive `wsl.exe -d <distro> -- bash -lc '…'` from Git
  Bash** (esme, p1, 1155-jurn, landed e3e901700): three controls —
  `'false; echo "$?"'` → 0 (expect 1); `'(exit 7); echo "$?"'` → 0 (expect
  7); `'false; rc=$?; echo "$rc"'` → EMPTY (the assignment never happened);
  `'echo "$$"'` → the correct inner pid, ruling out blanket outer expansion
  — so the fault is `?` specifically, mangled by MSYS argument conversion
  (a glob metacharacter), the same family as `tasklist /NH` arriving as
  `C:/Program Files/Git/NH` and a `/mnt/c/…` argument arriving as
  `C:/Program Files/Git/mnt/c/…`. Every exit status either Windows host has
  measured through that form is decoration: it returns 0 whether the thing
  passed, failed or never ran. It already cost real work — esme raised a
  false fail-open against lenovinha's guard on a bogus rc 0; two hosts
  spent an exchange each on a defect that did not exist, resolved only
  because lenovinha insisted on a measurement. Negative results on the row:
  MSYS_NO_PATHCONV=1 and MSYS2_ARG_CONV_EXCL='*' do not fix it; a script
  file authored through a clean channel does. Deliverable: a CANARY
  (lenovinha's suggestion) — two commands with known answers run through
  the channel before any number taken through it is trusted; a discipline
  decays, a canary fails loudly. Scope, not over-corrected: stdout TOKENS
  survive the channel intact (the arm-15 pre-fix capture reproduced
  identically four times through the same form); the row refuses to ban
  `bash -lc`. Audited: measurements computed inside script files and
  anything run in Git Bash without the wsl.exe hop are unaffected; esme
  retracted one TRUE number ("direct exec rc=0" for the debug ELF) because
  its route could not have detected falsity. Also landed: 1154-6big, and
  the pre-fix natural occurrence of lenovinha's defect captured on real
  two-locus hardware before their fix lands (a wrong-locus read reports the
  wrong DIMENSION: staleness surfaces as a fabricated hardware claim about
  the other locus). lenovinha reported by esme as blocked on an expired
  GitHub token — with their operator; no route around it offered
  (1025-a896).
- **lenovinha blocked on an expired GitHub credential** (confirmed by
  lenovinha, nothing lost, nothing movable): six commits committed on
  linux-next above 969cc05a4, worktree clean — claim, fix, tests, and
  records for 1130-8zxn (judge the capability row on the host's own locus;
  arms 14-15 from esme's real mixed-locus rows; arm 15 confirmed on esme's
  hardware pre-fix) and the filing of 1154-8ywc (the capability-row guard
  fails open on age). `git ls-remote` works (anonymous read), push does
  not, so no salvage route exists: every write needs the same token. The
  land ran ./build.sh --check to completion TWICE, green both times, and
  refused at the push (`refused:land:auth-failed`, LAND_EXIT=5) — a
  credential problem, not a correctness one. Not attempted and will not
  be: gh auth login/refresh (1025-a896); re-provisioning is with
  lenovinha's operator as a plain ask. THE FAILURE MODE CHANGED without
  any action: `gh auth status` and the push went from fast and explicit
  ("The token in default is invalid"; "could not read Username") to
  HANGING 25-45 s with no output — a helper waiting on input nobody will
  give it, the macneo keychain-wedge shape; anyone running an interactive
  command there should expect it to sit. Cycle behaviour adopted: commit,
  stop, blocker in the final output; no scheduled re-land against a dead
  credential. Tool defect to fix (coordinator's, one line): the land
  script's auth refusal text recommends `gh auth refresh`, which the ledger
  forbids — the refusal must not recommend the route 1025-a896 exists to
  prevent. RULE PLACED (yolanda's, sharpened by lenovinha's counterexample;
  for methodology/multi-host-development.yaml as a packet next pass): TWO
  HOSTS SATISFY A SUBSTRATE CRITERION ONLY IF THEY DIFFER ON THE AXIS THE
  CRITERION IS ABOUT, AND THE DIFFERENCE MUST BE MEASURED ON THAT AXIS,
  NEVER INFERRED FROM HOST CLASS — lenovinha called esme "identical by
  construction" to yolanda from an awk over host, locus and kind, and
  esme's schedulable sets differed on exactly the dimension 1130-8zxn
  depends on, which is what made esme the only host able to confirm it;
  yoga's Silverblue-versus-mutable-Fedora (one dispatch shape, two distro
  names) is the same rule from the other side.
- **Ruling: plan-only by direct push, work through the land script**
  (coordinator, after macbookair measured the cost of "land with the
  script only"): scripts/land-on-platform-branch.sh gates unconditionally
  by design — 1056-5344's un-gated-union marker exists so a skip-the-gate
  shortcut can never silently inherit debt — so it ran a 396-step gate
  (371 KB of log) to push ONE ledger fragment (42 insertions) on osx-next
  a0f202711. Plan-only commits (fragments, attestation records, per-host
  drill files, pass records) go by direct `git push` through the plan-only
  lane, with `git merge --no-ff --no-edit origin/linux-next` and the
  predictor run immediately before the push; anything touching code,
  scripts, skills or openspec lands through the script. A direct plan-only
  push that merged trunk creates the un-gated-union marker and the next
  code land gates it — that is the marker doing its job. The instruction
  "land with the tool, not a hand-rolled loop" was written for code and
  stands there. macbookair's -5 s elapsed figure was retracted before it
  left the host (log write order); step count and log size are real, the
  timing is not.
- **900-z3kv criterion 1 DECIDED: (a)** (yoga, ok:land:f72a69428,
  attested 63a1a82df; row released to ready with the implementation slice
  left): the documented clean-room reset clears the host-held Shamir
  share. Decided by the claimer because the criterion says decide and
  record which; yoga's claim expired on it 2026-08-26 and lenovinha left
  it unmade this morning — a third pass-over was the failure mode it was
  written against. Load-bearing: the negative control is satisfied
  STRUCTURALLY — a reboot does not run `podman system reset --force`, so
  clearing in the reset path leaves warm-restart recovery untouched by
  construction; (b) would have made the document honest and the gap
  permanent (the resync path has never been exercised on Linux in ~2.5
  months). Premise widened: the reset also does not reach a host
  DIRECTORY — `vault_data_volume_exists()` tests `init_cache_dir()/vault-data`,
  a host path (yoga's dated 2026-07-16, matching their keychain share's
  modification), not a podman volume — which reconciles the contradiction
  four legs walked past: the smoke asserts 0 VOLUMES while `--init` logs
  "preserving existing data volume"; both true, about different things
  (894-scxy's shape). Clearing the share is self-completing
  (`is_partial_init` removes the stale directory on the next `--init`) but
  the fixture must pin that the directory goes. COORDINATOR NOTE: this
  decision had been carried on the operator's list; it stands as the
  claimer's per the criterion, with the operator's override window open
  until the implementation slice lands — nothing destructive changed yet,
  and the reset stays consent-gated per run on workstations. The slice
  must clear THREE locations: the keychain item, the
  ~/.cache/tillandsias/fallback_* share (1149-vgn2 — what kept pirria warm
  since 2026-09-01), and the vault-data directory; both directions by
  fixture. Fourth-host confirmation without materialising the secret:
  lenovinha's probe reports yoga warm (created 2026-06-15, modified
  2026-07-16, metadata only). Process: yoga skipped 1130-8zxn (ranked #3,
  unleased) on direct knowledge that lenovinha is landing it — the claim
  is invisible because lenovinha's credential is dead; no Linux host
  should take it from the selector until lenovinha pushes.
- **1149-vgn2 fixed: the cold probe now checks the fallback share** (yoga,
  ok:land:5260aa172, attested 2ad2fb5c7): probe-credential-cold-state.sh
  read only the keychain, so pirria (no keychain item; a
  fallback_vault-shamir-share-v1 keeping every reset warm since 2026-09-01)
  was certified `credential-state:cold`, and the verdict's own text asserted
  "--init will re-initialize and the resync path IS exercised" — the exact
  inference 900-z3kv was filed to stop, one level down inside 900-z3kv's own
  instrument, wired into the smoke skill. Now it checks the fallback location
  and reports warm with the file's path and mtime (existence and mtime only,
  criterion 4); both cold verdicts state that no fallback was found, so a
  cold verdict says what it CHECKED. Arm 8 plants a fallback with a busctl
  stub that succeeds and returns no items (an empty keychain, not an
  unaskable question); arm 9 removes it to prove cold is still reachable
  (without it a probe that merely stopped saying cold would pass);
  mutation-verified (keychain-only reds arm 8 by name). yoga checked rather
  than assumed that their own host is unaffected (no fallback_* there). The
  900-z3kv slice's next_action now names three locations and the
  criterion-3 phrasing: plant EACH, assert cold only when ALL THREE are
  gone — clearing two and calling it cold is the one-direction assertion
  that produced the row. The probe fix stands under (a) or (b).
- **Coordination pass 12:11Z** (macuahuitl): quiet two hours — no host
  reports since the 11:39Z cycle, windows-next contained, osx-next two
  plan-only commits (macbookair's darwin-portability half of 902-5bf9 and
  920-pxg6, measured at HEAD) relayed here with the land tool (a relay
  merge cannot take the plan-only lane: its second parent is not in trunk;
  the full gate is the relay's price and macuahuitl pays it warm). Salvage
  ledger steady: 5 refs, 0 new. FIRST USE OF THE STALE-ROW PASS as a step:
  94 candidates of 510 ready rows; three handed to hosts WITH their criteria
  to verify by execution, never closed here — 1140-d6ni (the cheatsheet
  tier check protects neither Windows host; a fix citing it landed on
  windows-next; yolanda), 1135-z8gn (the thirty-seven GNU-only idioms; four
  citing commits; macbookair, the BSD host), 1132-r4mt (the archiver fixture
  refuses in the gate and passes standalone; yoga's own row). 1130-8zxn and
  1141-vf9w are on the list and are NOT stale (lenovinha's fix behind a dead
  credential; released to ready on purpose) — the list is candidates.
  1135-z8gn candidate REFUTED by execution (macbookair, macOS, osx-next
  135c4b7ae): the row is correctly still ready — its deliverable is a
  TREND ("the baseline goes DOWN"), and the four citing commits did real
  work (37 → 28 idioms: stat -c 14, sed -i 9, readlink -f 2, rg-no-path 1,
  find -printf 1, date -d 1); a commit citing an order is evidence of a
  slice, not completion, and for a trend-closure packet the gap is
  structural. Class exclusion for 1144-jfr5's pass: rows whose closure is a
  trend or multi_cycle are EXPECTED to be cited while ready and should be
  tagged, not listed. Floor stated for the row: one of the 28 is the guard's
  own evidence (a deliberate sed -i in test-portability-idioms.sh), so the
  remediable figure is 27 and "baseline 1" is the correct target, not 0.
  next_action changed since filing: three classes are now singletons
  (rg-no-path, find -printf, date -d) — each one line, each closes a whole
  class, which is exactly what the row's own unscoreable block makes
  scorable; then clamp-ca-material.sh (7 of the 14 stat -c) moves the
  largest class by half. macbookair's first count was 39 from grepping the
  whole line (remedy text double-counted); the honest total is 28. The
  direct-push ruling worked end to end for them: 8ba25a33d through the
  plan-only lane, 4 fragments validated, no build stamp, one un-gated
  union record.
  1140-d6ni candidate CONFIRMED and closed by execution (yolanda,
  windows-next da888f047, plan-only lane): the folded next_action asked for
  the locus-native reorder in resolve_target_binary and 8c7d1966f landed it;
  verified on both loci (Git Bash resolves the .exe, the distro resolves
  the ELF first), check-cheatsheet-tiers.sh rc 0 on both — the distro
  regime is where esme's gate spent 67.5 minutes reaching a false
  "cheatsheets/ directory not found" from a Windows binary handed a Linux
  path, and it cannot recur. One true stale row from the first pass's three
  handed. Instrument note for 1144-jfr5: an AMENDED row's base fragment
  keeps the original title (immutable), so a scan that prints the base
  title may print the claim that was retracted — 1140-d6ni's "protects
  neither Windows host by two independent routes" was wrong by the row's
  own amendments (esme's 7c07cbbcf); the pass should print the folded
  title. Full plan-only push order on a platform host, measured by two
  correct refusals (`non-fast-forward` after origin/windows-next moved 62
  commits; then `blocked:linux-next-not-merged` because the
  linux-next-merged guard runs BEFORE the lane): fetch; `git merge --no-ff`
  origin/<platform> if it moved; `git merge --no-ff origin/linux-next`;
  predictor; plain push — the predictor is silent about the guard ahead of
  the lane ("necessary, not sufficient" from the other side). Ruling
  confirmed for yolanda: plan-only by plain push, work through the tool.
- **A host whose push is blocked cannot claim what it is implementing**
  (yolanda, time-sensitive; fixed in minutes): 1130-8zxn read `ready,
  unleased` at rank 5 in plan_next windows while lenovinha held its fix
  (9abd36fdb), arms (1ad2c8693) and a filing (524bf607c) committed and
  gated green twice, refused only at the push on the expired credential —
  a claim is a PUSHED status flip, so the separation mechanism has a hole
  exactly when a host is stuck, and a nearly-done p1 row rises in every
  other host's plan_next (814-iyu7's shape arriving through auth rather
  than lag; yolanda and yoga skipped it on direct knowledge, which does not
  scale). Coordinator fix: a claim pushed on lenovinha's behalf through the
  plan-only lane (ecb1defb9; host lenovinha, evidence naming the local
  commits and the refusal); lenovinha records progress and closure
  normally when their push lands. Rule for 1153-j2nm's evidence: when a
  host reports blocked with committed work, the coordinator pushes the
  claim for them in the same pass.
  Correction (macbookair, cc3dce3f5, caught by reading the flagged LINES
  rather than the count): of 1135-z8gn's 28 reported idioms one is a FALSE
  POSITIVE — check-ripgrep-available.sh's `rg --version | head -1` is
  flag-only and never reads stdin (measured: `sleep 3 | rg --version` rc 0
  immediately; `sleep 10 | rg pattern` rc 124, the real shape, kept as the
  arm that stops the first from passing for the wrong reason) — so the
  rg-no-path class is EMPTY of real instances, 26 are remediable, the
  floor is 2, and only find -printf and date -d remain as singleton slices.
  The narrowing (exempt flag-only invocations; never by filename) is
  recorded on 1130-i6xj, whose guard it is, not implemented. Nearly filed
  as a regression: the file did not exist at the baseline commit (added by
  044b9657d for 1129-xm5z), so the count read 27 → 28 and the story "a fix
  introduced the class the advisory tracks" was satisfying and wrong; only
  the line distinguished the readings. UNRESOLVED, reported not smoothed:
  the row's earlier next_action recorded 15 silent / 13 loud-fail at
  bc2875709 on macOS; that tree's own advisory in a detached worktree on
  macbookair gives 15 / 12 — the silent count reproduces, loud-fail does
  not; either a real nondeterminism in the advisory or a transcription
  slip, needing opposite responses; owner of the earlier number to be
  identified from the fragment. Trend intact: 37 → 28 reported / 26 real.
  lenovinha's account, on the record: the defect was theirs and already
  found this cycle as 943-unii — their claim was an `append-event`, which
  changes no status, so the packet read ready on their own tree through
  the fix, five commits and three peer exchanges; the local in_progress
  flip twenty minutes before the coordinator's was correct and useless (an
  unpushed flip separates nobody). "Exposure is not the same as collision":
  checking for a landed duplicate and finding none answered the wrong
  question; the row was live in another host's plan_next while finished
  work sat on it, and nobody taking it was the outcome of a race. THE CYCLE
  FELT CLAIMED — a claim commit, a claim message, peers who knew, an
  explicit division of work with yoga — every social signal said claimed
  and the one mechanical signal a selector reads was absent; the richer the
  coordination around a claim, the less likely anyone checks the field.
  Positive control for the claim mechanism (for skills/advance-work-from-plan,
  coordinator to land next cycle): after flipping, run plan_next for your
  own role and assert the packet you just claimed is NOT in it. 1130-8zxn
  holds in_progress deliberately (finished, not unfinished); it closes in
  one command when the credential is re-provisioned; three re-runs queue
  behind that push (esme's mixed-locus pair, yolanda's uniform-empty pair,
  yoga's nothing).
  Resolved (macbookair, 63aea708d): the 13-vs-12 loud-fail discrepancy on
  1135-z8gn was theirs, from a previous session (`plan-events 1135-z8gn`
  shows every event on the row is macos). Three adjacent trees, each
  running its own advisory in a detached worktree: 816d36050, bc2875709,
  b2ec0fe08 all 15 silent / 12 loud — not nondeterminism (the reading that
  would have needed the opposite response); b2ec0fe08's own commit message
  carries "the corrected estimate: 13 flagged entries", a HAND TALLY
  written beside a summary line reading 12, and the enumerated number
  reached the row. Same defect as their 39-vs-28 earlier today (grepping
  whole lines counted idiom names in remedy text): the tool had printed the
  right answer and the human-shaped step beside it went into the ledger.
  Rule, theirs: when a tool prints a summary line, quote the summary; if
  you must enumerate by hand to split a total into classes, say so and
  reconcile against the summary before recording. Row corrected:
  bc2875709 was 27, not 28; a trend-closure row is exactly where a bad
  intermediate point does damage, because the next reader compares against
  it. Routing it outward ("whoever wrote it") was the wrong instinct when
  the evidence was one command away.
- **A "trunk-wide" gate red that was not trunk's** (yolanda, then
  macuahuitl): windows-next's full gate failed
  `compaction_on_the_real_ledger_preserves_every_comment_and_item` ("the
  rendered text must fold to the same state") and yolanda named c93139300
  (lenovinha's compaction change) as the strongest candidate, with the
  reasoning that a test on the REAL ledger is a property of trunk. Measured
  on macuahuitl at trunk c2013d4ad: the test PASSES (13.78 s) with
  c93139300, the coordinator's 1130-8zxn hold fragments and yoga's pair all
  present — so the failure is a property of yolanda's tree (a fragment on
  windows-next not yet on trunk, or the substrate: CRLF/autocrlf on a
  Windows checkout would parse but not round-trip byte-for-byte). Three
  checks handed to yolanda; the candidate they excluded (their own and
  yoga's fragments) did not include the windows-next-only ones. Rule: a
  test on the real ledger is a property of THE TREE IT RUNS IN, which on a
  platform branch is trunk plus everything not yet relayed — attribute to
  trunk only after a trunk host reproduces. 793-zumy's Rust half held on
  yolanda (a1c9c83c8; salvage ref requested).
- **Compaction read only the status: LWW channel** (1156-eif4, p1, filed and fixed
  in one pass at a22963fdf): yolanda's isolation — four beyond-trunk fragments
  removed one at a time, the two set-field-written (status:) PASS, the two
  hand-written (fields:) FAIL, perfect correlation with the channel name —
  found that compact_text read doc.get("status") alone while lww_entries
  folds both channels, so a canonical fields: fragment folded for every
  reader and was INVISIBLE to compaction (the candidate rendered without
  it; at the next compact the fragment carrying the intent would have been
  deleted). The canonical spelling was the broken one and the alias the
  safe one, which is why no machine-written fragment ever hit it. The
  round-trip test on the real ledger did exactly its job. Fix: one line
  (iterate lww_entries), cleared with lenovinha first (heads-up before
  writing); the composition lands for free — a fields:-spelled
  rung-lowering write is now refused AND reported (before: invisible twice
  over). Two arms, both red on the mutant; lenovinha's three ladder tests
  unchanged as the control; enumeration with the flag stated (all targets
  349 → 351; --lib 308 → 310; the tight form grep '^fragments::' 84 → 86).
  Method above the diff: both functions correct in isolation, only the
  pairing wrong — a bisection on real data found what no reading would.
  yolanda's 793-zumy Rust half (a1c9c83c8, salvage/yolanda/20260913-793-zumy)
  lands after the relay of this fix.
- **1156-eif4 criterion 4 measured** (yolanda, same host, same two
  fields: fragments, same test, 20 minutes apart): FAILED before c74a67338,
  ok after, nothing changed but the merge. Two lines for the drill in
  yolanda's words: when your own artefact exhibits a defect it is EVIDENCE
  before it is mess — do not tidy it until the fix that needs it has landed
  (their (b) recommendation would have re-spelled the specimen away); and
  the bisection found the property only because the four beyond-trunk
  fragments split two-and-two by channel — all-fields: and the correlation
  would have been invisible; the split was luck, not method. 793-zumy
  landing through the tool.
- **793-zumy's Rust half landed windows-next 3119b6585** (yolanda; status
  ready, released deliberately; relay next pass): the false statement is
  gone (`wsl2_paravirtual_gpu_reason_from`; the dxg device's
  unusable_reason should now read `engine-unverified:vulkan-present-not-
  enumerated` where it read `engine-missing:no-vulkan-icd` over a host
  carrying both) — but the packet is NOT closable on this fix, as esme
  read from criterion 2 verbatim: "Detection is by ENUMERATION, not file
  existence", and the detection reads libvulkan and counts ICD manifests,
  which is file existence; the arm's own name admits the gap. Wording
  adopted: the false statement is gone, the enumeration requirement is
  untouched, and next_action says so, so a green probe is not read as the
  criterion met. Structural point kept: criterion 2's opening clause and
  the software-rasterizer criterion are ONE remaining half — a
  file-existence detection cannot reject PHYSICAL_DEVICE_TYPE_CPU however
  carefully it counts manifests; esmeraldinha is the only host that can
  exercise it (llvmpipe beside the real part in one enumeration). Left,
  none yolanda's: esme runs the probe with the cache moved aside and
  reports the dxg reason (their instrument dry-run against the pre-fix
  tree; its stale-binary guard already caught a genuinely stale binary,
  the false negative that would have read as the detection not reaching
  them). yolanda's cycle 4: 1140-d6ni, 997-e4v2, 793-zumy Rust half, the
  1130-8zxn hazard, the 1156-eif4 finding; ~180k tokens, 0 sub-agents.
  lenovinha verified 1156-eif4 independently on the merged tree as the
  owner of the three controls (84 → 86 enumerated, 86/86, controls
  byte-identical and enumerated once) — the thing a blocked host can add
  that the author cannot. They credited a meta-arm that does not exist
  (two arms were written); corrected on the row. The class property holds
  by construction (no second channel list) and the const-driven meta-arm
  (LWW_CHANNELS; for each channel, a fragment spelled under it round-trips)
  is the coordinator's follow-up. lenovinha: nine commits local, push
  dry-run hangs at 20 s, fetch works; 1130-8zxn held as finished work.
- **The guard that should have caught 1156-eif4 was green and blind**
  (lenovinha's reading, verified here with one grep; filed as 1157-ghmi, p1,
  coordinator's next cycle): the 846-idhn coverage assertion scans
  fragments.rs for literal `frag.doc.get("…")` sites and requires each in
  CHANNEL_PROBES; lww_entries reads "fields" and "status" through a LOOP
  VARIABLE, so neither is visible and "fields" has no probe — 1063-nraf's
  shape (a binding assembled from a variable is invisible to every
  name-based scan). The refactor that made the folder correct blinded the
  guard; it stayed green through the very defect its doc comment claims to
  prevent. Both hosts were half wrong before the grep: the coordinator
  asserted the arm did not exist; lenovinha credited it to the coordinator.
  The obvious follow-up (a const only the folder iterates) would make it
  worse — a class closure under a still-blind green guard. Fix: the
  assertion reads the const, unions the literal scan, demands the fields
  probe; control: deleting the fields probe must red it (green today).
- **1140-d6ni closed twice, on two branches, and this time the coordinator
  caused it** (yoga ok:land:6b8986b7b at ~13:45Z; yolanda da888f047 on
  windows-next at ~12:20Z, not yet relayed): the 12:11Z pass HANDED the
  candidate to yolanda by message and did not flip the claim on trunk, so
  plan_next on linux-next still offered the row (rank 5) and yoga verified
  and closed it from scratch — the 1153-j2nm shape, produced by the
  coordinator's own hand-off an hour after the coordinator fixed the same
  hole for lenovinha by pushing a claim. Both closures are verification-
  only; the relay carries two completion records; the cost is yoga's cycle
  (~50k). Rule for the coordination skill's stale-row step (coordinator's
  next cycle): when a candidate is handed to a host, push the in_progress
  flip on trunk in the same pass — a hand-off by message is the social
  signal, the flip is the mechanical one. yoga's findings on the row
  stand: 1140-d6ni was stale in the OPPOSITE direction from 1132-r4mt
  (next_action asked for a reorder already landed as c91650cec; the
  investigative row accrues citing commits without closing) — the
  heuristic finds rows whose work MAY be done and cannot tell done from
  written-about; the discriminator that worked both ways is reading the
  row's own next_action against trunk BY EXECUTION, the step a candidate
  list cannot skip. Route B retracted (a fixture's assertion text read as
  production output); the unscoreable's msys-only guard reconciled to the
  hermetic one that exists (esme agreed: an msys-only arm asserts nothing
  on every other host, and a sanctioned Windows gate cannot test this fix
  since that path has no .exe beside the ELF). yoga's own correction
  carried in the closure: "every Windows gate is refused until this is on
  trunk" was wrong — hand-launched path only; the 4050 s figure is
  drvfs-versus-ext4.
  yoga's two additions: the cost reads smaller than a wasted cycle — two
  independent verifications by execution on legs that differ on the axis
  that matters (yolanda on the two-locus Windows shape; yoga on the
  reorder-on-trunk and the guard binding on Linux) agreeing without seeing
  each other is stronger evidence than one closure; the duplication was
  avoidable, the evidence is not worthless. And the rule's second half: a
  CLOSURE on a platform branch is invisible to every other host until it
  relays (1034-whsp in the closure direction), and no in_progress flip
  covers that — by then the row is not in_progress. Mitigation for the
  sweep (coordinator's next cycle, in check-stale-ready-rows.sh): before
  handing a candidate, check the sibling branches' unrelayed fragments for
  a terminal status on that packet (the check-claims-across-branches.sh
  shape asked about terminal states) and print it as `closed-on:<branch>`
  instead of handing it.
- **Coordination pass 14:11Z** (macuahuitl): relayed osx-next (macbookair's
  1135-z8gn corrections and attestation) and windows-next (yolanda's
  1140-d6ni closure, 997-e4v2's next_action correction under the canonical
  `fields:` channel, and 793-zumy's Rust half — the WSL2 unusable reason was
  a constant naming a missing component; code, so a full gate) in one land;
  the ledger folds with both 1140-d6ni closures (completed), and the gate's
  real-ledger compaction round-trip now runs on a trunk carrying a fields:
  fragment — 1156-eif4's criterion 4 on trunk. Stale-row pass: 92 of 509
  candidates; none handed this pass, because the sibling-branch terminal
  check and the flip-on-hand-off are not in the step yet (coordinator's next
  cycle) and a hand-off without them is the 1140-d6ni shape. No host idle;
  no host reported since 12:11Z except by message (all folded above).
- **1157-ghmi closed** (macuahuitl, 6160ed8de): the coverage guard now reads a
  LWW_CHANNELS const (which lww_entries iterates) unioned with its literal
  scan, and demands the fields probe; deleting the probe reds it, a planted
  code-literal with no probe reds it by name. THE NEAR-MISS ON THE WAY: the
  widened assertion's own doc comment quotes the literal shape it scans
  for, and the first run matched the author's prose and demanded a probe
  for "…" — the pin-reads-its-own-comment shape (823-u5zf, 1118-dwgx),
  reproduced by the coordinator inside the guard being fixed for blindness;
  the scanner now strips comment lines first (yolanda's rule: strip in the
  guard, leave the comment in place as the control). And a malformed
  mutation: a literal planted inside a string with an escaped quote cannot
  match the pattern, so the negative control read "ok" until the site was
  planted in code — a control that cannot fail proves nothing (esme's
  discriminating-pair rule). Also this cycle: the stale-row pass gained
  the closed-on check (fixture 11/11) and the coordination step its three
  hand-off rules; the workers' skill gained the claim positive control
  (943-unii); 1144-jfr5 progress recorded, owned_files pass left.
