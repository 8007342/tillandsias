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
- **lenovinha is pushing again** (ok:land:beff45e60 — the ten-commit
  backlog — and ok:land:83c84b56e, the closure): 1130-8zxn completed,
  ahead 0, clean; yolanda's post-fix line `ok:capability-row-current:yolanda`
  rc 0 matched the prediction lenovinha wrote before the run, none of the
  three failure signatures; esme's mixed-pair leg is the only one
  outstanding. The credential item comes off the operator's list.
- **1157-ghmi's class is wider than its guard** (lenovinha, from yolanda's
  question "do other consumers hardcode one channel?", measured): four
  consumers iterate lww_entries (all fragments.rs, correct after the fix);
  THREE hardcode `doc.get("status").and_then(as_sequence)` in main.rs —
  carry_forward_gaps, and both scans in closure-evidence-check (the LWW
  closure scan and the verifiable_closure reassignment scan) — so a
  fields:-spelled write is invisible to each, and two of the three are
  guards that FAIL OPEN (an unscanned write is never an offender; nothing is
  indistinguishable from clean — every instance of this class found tonight
  fails open, and that is the polarity of a scanner that misses an input).
  The first site names the hazard and cites plan/index.d/README.md on the
  line above the bug. Live exposure: yolanda's two fields: fragments
  (997-e4v2, 793-zumy) are invisible to carry_forward_gaps now. Judged as
  its own row (different mechanism: the canonical list exists and is not
  canonical): the three sites use lww_entries, plus a scan-side guard —
  no `.get("status")`/`.get("fields")` in the fragment-channel shape outside
  lww_entries, matched on the declaration with a runtime-assembled needle
  (980-ja2m) so it cannot trip on its own quoted history — after which a
  fourth consumer cannot be written without the list or a red build.
  Ruling on yolanda's question (they asked rather than acted): (c) — leave
  both fields: fragments; the defect is in the readers and the row for
  them is the coordinator's; re-spelling treats the symptom on the one host
  that noticed. KNOWN AND TEMPORARY until that row lands:
  carry_forward_gaps will fire a false advisory on 997-e4v2 ("touched with
  no next_action") because the correction is spelled under fields:, which
  it cannot see — a reader who investigates will find a good next_action in
  the fragment; the ADVISORY is not broken, the reader is. yolanda's
  polarity observation for the row: an invisible input fails OPEN in a
  consumer scanning for offenders (closure-evidence-check, 1157-ghmi,
  1154-8ywc) and LOUD in one scanning for omissions (carry_forward_gaps);
  the loud one is more dangerous per instance, because it trains people to
  ignore the guard rather than fix the reader.
- **A release-path guard silently dead on every BSD host** (macbookair,
  1135-z8gn slice, heads-up given before writing, cleared): release-
  preflight.sh's workflow-inventory guard uses `find … -printf '%f\n'
  2>/dev/null | sort`; BSD find has no -printf, the error goes to
  /dev/null, the set comes back empty, and the guard passes having
  inventoried nothing. Two corrections from reading lines rather than
  counts: date -d is NOT a slice — test-check-bash-dialect.sh writes it
  into a fixture as the subject the guard must catch (like the deliberate
  sed -i) — so 28 reported, three non-defects, 25 remediable, floor 3; the
  count was revised 27 → 26 → 25, every revision downward and from reading
  a line previously only counted: a count of pattern hits is not a count
  of defects, and the gap closes only by reading. And the portability
  advisory has a FALSE NEGATIVE on the documented-incident form: its
  needle is the literal `"date -d "`, so `date -u -d "@123"` — the exact
  shape that shipped test-ledger-ts-guard.sh broken on BSD — is not
  flagged while the bash-dialect guard catches it; recorded on 1130-i6xj.
- **900-z3kv (a) implemented, inert** (yoga, ok:land:b721b880e, attested
  6a882f84e; row ready): scripts/clear-vault-host-credentials.sh, the Linux
  sibling of the Windows clearer absent since 803-49re — one place,
  best-effort, failures reported not fatal (a purge that aborts halfway
  leaves more stale state than one that finishes noisily). FOUR ITEMS, THREE
  LOCATIONS: the keychain holds vault-root-token-v1 as well as the share,
  and vault_bootstrap.rs writes both as fallback files — the narrower
  framing had travelled from the row into yoga's probe fix and their
  summary of the relay. Safety half: installation-uuid-v1 (the Linux
  counterpart of tillandsias-vm-uuid) is PRESERVED, said aloud, pinned by
  its own arm — clearing it makes the next vault underivable, not
  re-initialised; /etc/machine-id never touched. Criterion 3 both
  directions 6/6, the reverse arm (a wipe path that does not clear leaves
  the room detectably warm) being the half four legs lacked;
  mutation-verified (over-clearing the anchor, skipping the data dir,
  bypassing the consent gate — each 5/6); executed in a real gate (attempt
  2's log, "PASS: clear-vault-host-credentials 6/6"). The gate step binds
  the fixture, never the clearer. NOT WIRED into the documented reset, by
  design: that step changes what a destructive run does and the operator's
  override window on (a) is open. Ruling: it stays inert until the operator
  confirms (a) — yoga wires it next cycle then — or says (b), in which case
  the clearer is documented as deliberately not called.
- **The cfg-split class a third time, in the other direction** (macbookair,
  macOS gate red after the 14:11Z relay of 793-zumy): `wsl2_paravirtual_
  gpu_reason` is `#[cfg(any(target_os = "linux", test))]`, its only
  production caller is linux-gated, and 793-zumy retargeted the wsl2 test
  onto the `_from` seam — so on macOS under cfg(test) the arm compiles a
  function nothing calls and `-D dead-code` refuses; on Linux it is alive,
  which is why the coordinator's relay gate was green. macbookair's
  framing, recorded: a field missing from arms the compiler cannot see
  (name_source) and a function present on an arm it can see with its
  caller compiled out — one lesson, two directions, "the cfg you build
  under decides what the compiler can judge". Assigned to macbookair
  (cleared: nobody else in accel_probe.rs): drop `, test` from the cfg (the
  arm existed for a test that no longer calls it), pristine-worktree
  reproduction first, zigbuild the Linux target to confirm the production
  caller keeps it alive, land through the tool; the coordinator's next
  relay gates it on Linux. yolanda told for awareness; a production-entry
  test, if wanted, is a later addition under 793-zumy, not a cfg to keep.
  Their find -printf slice (2746ce14d) lands behind it; plan-only pushes
  keep moving.
  yolanda's account (theirs, confirmed structurally on their tree without a
  macOS compile: one production call inside the linux-gated block, zero test
  callers — the grep hit in the test region was a DOC COMMENT naming the
  function, checked rather than counted): 935-6fzk put `, test` on that cfg
  so the test could call the function on every host and said so in its
  comment; the 793-zumy retarget moved the test onto the `_from` seam for a
  good reason (the production entry reads the live filesystem, so asserting
  it would pass on every loader-less host and go RED on esmeraldinha, the
  only host that can verify the packet) and removed the only call the arm
  existed to permit. What they did wrong, precisely: they hit E0425 on the
  same gate an hour earlier, read 935-6fzk's comment, applied it correctly
  to their three new functions, and did not ask whether their OTHER change
  had invalidated the premise for the original — a comment treated as a
  rule to copy rather than a claim to re-check; the same shape as the
  criterion-2 miss esme caught, twice in one cycle, both on a requirement
  just read. Dropping `, test` is the right fix; the production entry
  (a two-line wrapper: facts_at then _from) is then uncovered, and the
  composition is where the halves get wired wrongly — later fix under
  793-zumy, not now: `wsl2_paravirtual_gpu_reason_at(root)` with production
  passing "/", the seam enumerate_render_nodes_at and wsl2_vulkan_facts_at
  already use, so one fixture-rooted test covers the composition on every
  host with the `, test` arm gone. Not folded into macbookair's in-flight
  land unless macbookair wants it: two hosts reaching for one function is
  how a fix gets written twice.
  macbookair's correction on their own promise: the pristine-worktree
  reproduction NEVER REACHED THE QUESTION — `cargo test --no-run` in the
  detached worktree died in build.rs on the untracked runtime asset
  (images/router/tillandsias-router-sidecar, 710-w9kc, "produce it with
  scripts/build-sidecar.sh"), rc 101, zero mentions of the function —
  inconclusive, not a refutation; the terminator check (rc present, zero
  mentions) is what kept "no dead-code error" from being read as a
  negative, the fifth absent-result instance tonight. Answered more
  cheaply and more strongly instead: their commits touch no .rs, and the
  sha256 of origin/linux-next's accel_probe.rs equals their working copy's
  byte for byte — a byte-identical file under the same toolchain gets the
  same verdict, no build needed. METHOD: when the question is "is this red
  mine or trunk's", file identity settles it in a second where a
  reproduction costs minutes and can fail for unrelated reasons. Note on
  the instrument: build.rs's refusal is a good one (names the artifact,
  cites the order, gives the command), and it makes a detached worktree a
  poor instrument for anything that compiles this crate — two hosts
  reached for it this session. Their fix: cfg narrowed, macOS test build
  compiles clean (rc 0); suite and the Linux zigbuild run before landing;
  the comment above the cfg records the open question for 793-zumy so the
  next reader finds it rather than rediscovers it.
- **Coordination pass 16:11Z** (macuahuitl): fired while the release-tier
  ci-full (890-27mv daily exercise) was running in this checkout, so the
  working tree was untouchable until it reported — the pass did its
  read-only half first (fetch, size the relays, read the notes from origin)
  and held the relay and the land behind the gate rather than run two gates
  in one checkout (1132-r4mt). Relays pending: windows-next two plan-only
  commits — esme's 1155-jurn note: THE DEFECT'S OWN DISCOVERER WALKED INTO
  IT AGAIN WITHIN THE HOUR, and the canary caught it — while verifying
  lenovinha's 1130-8zxn on esmeraldinha an arm was written as a heredoc
  piped through `wsl.exe -d … bash -lc`, read `stale:…` with rc 0 (which
  would have contradicted the guard's documented contract and read as a
  fail-open in lenovinha's own fix, in exactly the shape hunted all night),
  and the re-run from a script file with the canary at the top gave false→1,
  (exit 7)→7, the arm rc 1 three times — the contract was never violated,
  `$?` was mangled in transit. Lesson the row turns on: a rule you have to
  remember decays fastest for the person who just wrote it down; the canary
  is the thing that does not. osx-next: nothing yet (macbookair's cfg fix
  and release-preflight slice still on their side). Release-tier freshness
  on this host read `never:release-tier:no target/convergence/check-logs.jsonl`
  before the run despite yesterday's cut having run the release gate here —
  a finding for 890-27mv if it still reads never after this run (the
  instrument reads a record the tier does not produce here).
- **macOS lane unblocked** (macbookair, osx-next de9145859; the cfg drop
  2c60ff8d7 and the find -printf slice 2746ce14d ancestor-verified): both
  arms proven because a cfg change is where one arm is not evidence —
  macOS `cargo test` 521 passed, clippy 0, fmt clean, where it previously
  would not compile; Linux zigbuild rc 0 with 0 "never used", the production
  caller keeping the function alive. yolanda's answer is in the comment
  above the cfg (the wrapper was meant to stay covered, nothing covers it
  now, remedy is their later `_at(root)` seam), so the next reader finds a
  decision, not a puzzle. Relay next pass with the release-preflight slice
  (1135-z8gn: 24 remediable, floor 3, clamp-ca-material.sh's seven stat -c
  named as the next concentration). THREE ANSWER-SHAPED THINGS THAT WERE
  NOT ANSWERS in one cycle, theirs: a false "land refused" from a watcher
  reading ONE FIXED LOG PATH reused across lands (a previous run's verdict
  indistinguishable from this run's; the land was healthy, the gate log
  growing) — fixed by anchoring the watcher on the land's PID and a unique
  log per run (the coordinator's land-N.log habit is the same fix); a
  survivor check whose output was never read because it ran inside a
  backgrounded command (a guard whose output you do not read is not a
  guard; they cannot rule out having launched a second land over a live
  one — the CARGO_TARGET_DIR starvation shape); and the pristine-worktree
  run that died in build.rs before reaching the question. The code
  findings were sound; the instruments were what kept lying, and each one
  looked exactly like a result.
- **A filing collision on a negotiated hand-off** (lenovinha 1158-y3ad
  filed 15:49:43Z and claimed 15:49:51Z; coordinator 1160-nvzs filed
  16:05:53Z, same defect): lenovinha checked whether anything had LANDED
  before deciding (a landed measured result outranks an earlier claim);
  nothing had, so it is a filing collision, not a work collision — no cycle
  spent twice. Diagnosis corrected by the coordinator: not relay lag — the
  coordinator's next-order minted 1160 with 1158 present, so the claim was
  in the fold and the row was filed without reading it, an hour after
  writing the rule that demands that read. THE CONVERSATION IS NOT THE
  MECHANISM, from the other side of 943-unii. Resolution: 1158-y3ad live
  (three consumers routed through lww_entries, 7/7 new fixture, 310/310
  --lib, teeth against the pre-fix tree — the fields: arms fail and the
  scan guard names all three sites); 1160-nvzs superseded pointing at it
  (never deleted). lenovinha combined rather than replaced: the
  coordinator's LWW_CHANNELS const (legible to a source scan that cannot
  see a loop variable — 1157-ghmi's half) and their lww_entries as the only
  permitted reader, scan-guarded (1158-y3ad's half); lww_entries iterates
  the const; neither alone closes the class. FOURTH GATE-STEP PREFIX
  COLLISION (yoga at 205; lenovinha at 215, 255, now 280 against yoga's
  900-z3kv): the skill says pick the prefix after the integrate; the window
  is not merge-to-commit, it is commit-to-gate-FINISHING, six minutes in
  which any host can land a step — advice to pick later cannot close a race
  whose window is the gate itself; allocate at land time or stop ordering
  by scarce integers. Coordinator files it.
  lenovinha withdrew the relay-lag diagnosis (reached for because it is the
  explanation the fleet has measured, without testing whether it applied —
  the same move as the rest of the night) and named the finding inside the
  correction: `next-order` minted 1160 BECAUSE 1158 and 1159 were present,
  so the allocation step is already a read of the current fold and a
  freshness signal nobody treats as one. Row filed this pass: next-order
  reports the rows filed since the caller's last order ("minted 1160;
  1158-y3ad, 1159-… filed since …"), the canary and positive-control shape
  applied to filing — make the mechanism report rather than asking people
  to consult it. The symmetry, named rather than let pass: lenovinha
  claimed 1130-8zxn with an append-event and held a ready row all night,
  then said the conversation is not the mechanism; the coordinator filed a
  duplicate without running the check in the skill edited an hour earlier
  — same defect, opposite direction, both fluent in the rule at the moment
  of breaking it; the protection is not understanding it better.
- **1146-8j7i confirmed in situ on Git for Windows** (yolanda):
  `skip:salvage:unstageable:dangling`, the salvage proceeds, README on the
  ref, the dangling path absent — the shape specified. Deviations, both
  right: the `ln -s` from WSL (Git for Windows cannot create a dangling
  symlink); a local bare remote through TILLANDSIAS_SALVAGE_REMOTE so no
  probe ref needed a coordinator delete. Observation accepted: the probe's
  ref minted as `salvage/unknown/…` because a scratch repo carries no host
  identity — the two `salvage/unknown/` opsx refs on origin are explained
  by a scratch or forge checkout, not an unidentified host. yolanda
  reported NO claimable Windows work rather than manufacturing a claim
  (793-zumy's half is esme's; 997-e4v2's is macOS; 1132-r4mt yoga's;
  900-z3kv Linux and operator-gated; 829-dkuc operator-paired by its own
  next_action); their 793-zumy `_at(root)` wrapper waits on macbookair's
  cfg drop reaching trunk (this pass's relay).
- **macneo :40 cycle** (osx-next fb811c291, attested f9783e212 — the LAST
  of two MO-FULL lines, per their own job-text correction; relay next
  pass): closed 1127-xm3m, a second ready-but-landed row surfaced by the
  cites-the-order pass (`stale-candidate:1127-xm3m:1:04cb49cd1`), from an
  EXISTING green gate log with no rebuild — two hand-checked closures out
  of the candidate set, both genuine (1127-apa8, 1127-xm3m), so the pass's
  precision holds on the rows macneo has touched. THE CONTROL TOOK THREE
  TRIES and generalises to draining the list: the live crashloop.state
  carried the packet's exact damage frozen 46 s before the fix commit and
  untouched since — worthless alone, because a test that never executes
  writes nothing either ("fixed" and "never ran" are the same observation
  from the file). Attempt 1 grepped a gate log that had refused early on
  the citation guard and never reached the test phase; attempt 2 concluded
  the gate never runs the macos-tray tests — killed by the control that
  EVERY crate scored zero in that log (measuring the log's verbosity, not
  what ran); attempt 3, the completed green log, carries crate names,
  `test result:` lines, and the four guarded tests ran and passed. Rule for
  1144-jfr5's step: the citation proves a commit mentioned the order;
  closing additionally requires evidence the changed code PATH EXECUTED,
  and a row whose fix is reachable only through a test the local gate does
  not run is routed, not closed, from that host. Also, inside one host's own
  reasoning: `stat -f '%Sm' -t '%Y-%m-%dT%H:%M:%SZ'` prints LOCAL time with
  a literal Z — an mtime read eight hours off until the record's own epoch
  was decoded. 1152-y3bv handled: osx-next was in the triggering state at
  cycle start, merged --no-ff, predictor before each push, two pushes
  unrefused. Keychain: four gates since the operator's restart, none
  prompting.
  1158-y3ad landed and closed (lenovinha, ok:land:691c360e0, closure
  6b4d78860): hardcoded fragment-channel reads remaining on trunk = 0,
  verified against origin; carry_forward_gaps and both closure-evidence
  scans call lww_entries, which iterates the coordinator's const. Three
  refusals before landing, all correct, none about the change: a
  plan-binary resolved from a hardcoded target/ path behind `[ -x ]` (esme's
  locus-dependent -x finding, relayed approvingly an hour before writing it
  themselves — caught by violation:plan-binary-probe-usage, fixed through
  resolve_plan_binary); the gate-step prefix 280 collision (picked AFTER the
  integrate exactly as the skill says — the empirical case that the advice
  cannot close a race whose window is the gate); the fragments.rs conflict
  with the const, resolved by combining. Teeth against the pre-fix
  binary: `fields:` next_action suppresses the advisory (expected 0, got
  1); an evidence-free closure under `fields:` is refused (passed silently
  before); no hardcoded read (named all three) — both symptoms of one
  defect, opposite directions, in one fixture. The carry-forward arms were
  first written as "the advisory did not fire", which passes by ABSENCE;
  an arm that makes it fire first was added — lenovinha's second
  vacuous-by-absence catch tonight. 1160-nvzs clear to supersede.
- **Release-tier exercise on macuahuitl** (890-27mv daily; head 4213d5283,
  rc 1, 1502 s): freshness read `never:release-tier` before the run despite
  yesterday's cut having run the gate here (the record it reads,
  target/convergence/check-logs.jsonl, was not there — the instrument
  records exercised, not passed, and it now reads "last exercised
  local-ci-20260913T161117Z (0d ago)"). Seven pre-build litmus reds out of
  358 executed, in four causes: (1) FOUR forge fixtures on `podman image
  exists localhost/tillandsias-forge:v56.9.12.2` — the forge image for the
  installed VERSION is absent on this host (forge:latest and forge-base
  exist; the binary builds the versioned tag on demand at first launch) —
  environment, rebuilt by the coordinator; (2) litmus:git-mirror-vault-
  agent-auto-auth: DETERMINISTIC — the relay pushes to
  https://github.example.invalid and the credential helper's 1118-bscs host
  pin refuses it ("refusing to supply the GitHub token to host
  'github.example.invalid'"), a real security fix breaking a release-tier
  fixture that no --check gate runs; filed 1161-42pc, p1, handed to
  lenovinha (owner of 1118-bscs) with the flip at filing; (3) litmus:land-
  verdict-through-a-pipe: the fixture landed at mode 100644 (a937b7b75,
  1137-da83) and the litmus tests -x — restored, and a sweep found NINE more
  check-/test- scripts at 644 (the Windows-lane mode class; all restored in
  the index); (4) litmus:lww-channel-fields-alias: the coordinator's own
  1157-ghmi const refactor tripped the SOURCE PIN, exactly the false red the
  litmus's own comment predicts ("a refactor to a slice constant would fail
  this while the behaviour is intact") — pattern updated to the const and
  the loop. The exercise did its job: three of the four causes were
  invisible to every --check gate in the fleet.
- **1161-42pc fixed without the seam the coordinator specified** (lenovinha,
  declined on security grounds and said so): an env var the helper honours
  to allow a named host is a TOKEN-REDIRECTION PATH — anyone who can set an
  environment variable in that process points the helper at a host they
  control and receives the live GitHub token from Vault; logging it does not
  help because the log is written where the attacker already is; the
  helper's own header ("a credential helper must not rest on an assumption
  about its caller") rules out an assumption about the environment one
  layer down, and 1118-bscs exists because the previous version rested on
  exactly that. The finding underneath: NOTHING NEEDED A FAKE HOSTNAME —
  the fixture's fake `git` never dials, `$REAL_GIT` only inits and commits
  locally, and the cases assert credential-protocol behaviour and password
  generation tracking, neither of which depends on the host being
  unresolvable. Fix: the fixture asks with an allowlisted host; the
  production helper is UNCHANGED (+44/-2, fixture only); 7 cases pass,
  cases 1-6 unchanged. The pin gained coverage: case 7 makes the old
  accidental refusal deliberate (the production helper in situ refuses
  github.example.invalid, prints no password, names 1118-bscs) with a
  negative control beside it (the same helper still serves github.com —
  without it the arm passes for a helper that refuses everything). Teeth:
  neutering the allowlist reds case 7 by name. Rule for the row, theirs:
  NEVER WEAKEN A FAIL-CLOSED CREDENTIAL GATE TO ACCOMMODATE A TEST WHEN
  THE TEST CAN BE MADE TO SATISFY THE GATE — check whether the test needs
  the thing it asks for. The coordinator's seam text stays on the row as
  the shape refused and why. Sequencing: their land starts now; the row
  reaches trunk in the coordinator's in-flight land; the closure event
  follows their pre-push merge.
- **A third silence in the plan-only recipe** (yolanda, measured by the
  predicate): predictor CLEAN (only their commit on the first-parent line),
  containment guard PASSED (`ok:linux-next-merged:1`), and the lane still
  refused — `_lane_can_scope` over the range: merges=5, disqualifying=1,
  the disqualifier being a merge of origin/windows-next made at cycle start
  (7 behind with an unpushed merge, so no fast-forward), whose second
  parent (esme's 1155-jurn note, e3cf301d3) trunk has not taken; the scope
  is disqualified, the lane falls back to the FULL net diff, and trunk's
  fragments.rs appears in it. The recipe has THREE independent conditions
  and the predictor checks one: (1) predictor clean; (2) trunk contained
  (the guard that runs before the lane); (3) every merge's second parent
  already in trunk. And the consequence is stronger than esme and yolanda
  first said: once a host has merged its own platform branch, it loses the
  plan-only lane for EVERY subsequent plan push until the coordinator relays
  that content — a property of the history from that merge onward, not of
  the push. The predicate is correct; the recipe cannot promise the lane
  applies. For 1152-y3bv and the coordination skill: a fourth line — run
  `_lane_can_scope`'s own check, or "if you merged your platform branch
  this cycle, expect the full gate until the relay" — and a relay cadence
  the platform hosts can see. yolanda landed through the tool (correct once
  the lane does not apply); payload: esme's verification of 793-zumy's
  third arm on esmeraldinha with their three guards green first.
  1161-42pc landed and closed (lenovinha, ok:land:7a6f8c5f6, closure
  76e604655; images/git/git-credential-tillandsias.sh byte-unchanged; the
  release tier should be green on the next cut). OPERATIONAL FACT: their
  credential is INTERMITTENT, not expired — dead (push and gh auth status
  hang, "token in default is invalid"), alive (nine commits over three
  lands), dead again (refused:land:auth-failed on this row), alive seconds
  later (dry-run rc 0, re-ran, attempt 1 ok), no operator action between
  the last two; a genuinely invalid token does not start working on its
  own, so something upstream of the token drops or times out — network,
  credential store or GitHub-side, undistinguishable from one host; a
  fleet fact if others see it, not filed. Consequence: auth-failed IS
  RETRYABLE there, and the land script treats it as terminal (exit 5),
  right for a real expiry and a whole cycle for a blip — a single retry
  after a short pause would have saved this one; row filed by the
  coordinator. The re-provisioning ask is withdrawn from the operator's
  list as stated; the next auth-failed on lenovinha is not "the token died
  again". Their session: 1130-8zxn, 1158-y3ad, 1161-42pc closed; 1154-8ywc
  and 1159-g96c filed, unclaimed, p2.
- **1150-q462 completed** (yoga, code 74e28adbd, closure ok:land:23b42ef74,
  attested ba2a74a8f): the four competing-gate codes now bind a caller —
  the wrapper's pre-dispatch call branches on all five outcomes (2 names
  THIS CALL SITE as the thing to fix and says it is not a property of the
  host; 3 says the question could not be asked and is not a clean-room
  verdict; an unknown code says the grammar changed and the caller was not
  updated); no default that proceeds; still advisory, and an arm pins that
  none of the five stops the build — the sequencing rule survived contact
  with the implementation. Construction worth keeping: the fixture drives
  the case block EXTRACTED FROM THE SHIPPED WRAPPER BY MARKERS, not a copy
  (a copy is the 881-29me shape and rots), and the extraction failing is
  the suite's FIRST arm, so a fixture that can no longer find what it
  tests fails by name instead of passing vacuously. Third mutation-that-
  did-not-apply this session (a mangled no-op passed 8/8 and tested
  nothing; redone, 7/8 and 6/8 red): the normal failure mode of mutation
  testing, caught every time only by proving the diff non-empty first.
  1141-vf9w's remaining two belong to other hosts: the wsl.exe in-situ
  reading (1149-3v3n, yolanda) and a POSITIVE demonstration — the detector
  accusing a genuine stray on the host being promoted for — which replaced
  pirria's retired churn condition.
- **Coordination pass 18:11Z** (macuahuitl): relayed osx-next (macneo's
  1127-xm3m closure and cycle records, two attestations; 2 code files, 53
  insertions) and windows-next (yolanda's 793-zumy verification note
  through the tool, a windows-tray diagnostics record) in one land; the
  stale-row pass now prints closed-on for a sibling-branch closure not yet
  relayed (one this pass: the relay carries it, nobody is handed it); 91 of
  511 candidates otherwise, no hand-offs this pass — macneo and yoga are
  consuming the list themselves and closing genuine rows from it. The
  salvage sweep found one new ref since the ledger was created
  (refs/heads/salvage/yolanda/20260913-793-zumy) and filed it through --apply — the first
  automatic filing since 874-s8vf was archived. Trunk since the last pass:
  1161-42pc closed (lenovinha), 1150-q462 completed (yoga). Held row
  1164-cftu (auth-failed retry) lands with this pass.
- **OPERATOR DECISIONS 2026-09-13 ~18:30Z**: 900-z3kv is (a) — the
  documented reset clears the host-held share; yoga wires the clearer next
  cycle. The principle, in the operator's words: the platform prefers
  idempotency over legacy support; anything nuked on the way was meant to
  be nuked, like old configs from stale code; the way to exercise the
  correct new code is a system reset as the baseline, which is why `podman
  system reset --force` is not only allowed but preferred, and a full system
  reset is an abstraction layer to embrace. (The per-run consent for
  destructive smokes on workstations, 1004-vsh2, is a separate ruling and
  stands until the operator lifts it explicitly.) The fleet's GitHub token
  will be rotated at the next fleet restart and upgrade. The stale /tmp
  timing log on macbookair: approval relayed by the coordinator; macbookair
  removes it and confirms.
- **lenovinha is DOWN, and the Silverblue update is failing to apply**
  (operator report): the host was prompting for credentials (consistent
  with the intermittent auth-failed measured earlier — a credential helper
  or keyring prompt, not an expired token); the rpm-ostree update is
  blocked on kernel dependencies conflicting with layered packages, reads
  "ready, requires restart", and fails to apply each time; other hosts
  reportedly share it, so the Silverblue fleet (yoga, lenovinha) may
  behave unexpectedly. yoga asked for `rpm-ostree status` as the
  measurement. lenovinha's unclaimed rows (1154-8ywc, 1159-g96c) and its
  cron are suspended until the host returns; nothing of theirs is
  unpushed (ahead 0, clean, at last report).
- **829-dkuc, why operator-paired**: the remaining half is the sweep
  PROTOCOL — a scheduled run gated by check-deslop-due.sh that constructs
  (mutation, predicted-observable) pairs per finding across the corpus; it
  is a large fan-out over the tree, the shape that ended pirria's session
  and the shape the operator's token directive bounds, so the row asks for
  sweep-budget headroom or an operator-paired session before anyone spends
  it. pickup_role any; the natural host is macuahuitl (strongest,
  host-independent) under an explicit budget from the operator.
  yoga's measurement (raw, read-only): State idle, booted 44.20260912.0
  (kernel 7.2.4-200.fc44), rollback 44.20260911.0, nothing pending, staged
  or failed; layered `google-chrome-stable rocm`, local package
  opencode-1.18.19-1. `rpm-ostree upgrade --check` reports an available
  44.20260913.0 (2 advisories, 44 upgraded) NOT attempted. Honest reading,
  yoga's: this does not settle one-host-versus-fleet — yoga has not TRIED
  the version lenovinha is stuck on; "healthy" means N-1, and a host that
  never ran the thing is not evidence the thing works. Why yoga is the
  right test anyway: lenovinha's symptom is kernel dependencies conflicting
  with LAYERED packages, and yoga's `rocm` is kernel-coupled — a clean
  upgrade with rocm layered refutes the fleet reading; the same failure
  makes it a platform property. yoga did NOT stage it: staging a
  deployment changes workstation state and needs a reboot, which is the
  operator's call. Routed to the operator as a plain ask; yoga holds. If
  lenovinha's layered set differs from yoga's, the difference is where the
  conflict lives (unknown while lenovinha is down).
  macbookair's stale /tmp timing log: DONE, off the operator's list — moved
  aside first (the guard's preference), then deleted outright on the
  operator's direct word in their session ("we embrace destructive resets,
  our platform is idempotent and ephemeral by design"); described before
  deletion (13 lines, 1843 bytes, 2026-09-12T06:22Z litmus step timings
  under the host label Tlatoanis-MacBook-Air.local, all superseded by the
  live log); live log untouched (30,534 lines). cycle-metrics.sh now runs
  with no override and no two-logs refusal. Their caution on the skippable
  view, kept: the workspace test step's saved_ms_upper (5.09M ms over 34
  runs, 0% failures) is an UPPER BOUND on what skipping could save, not a
  measured saving, and that step is the one most likely to catch the
  cfg-split breakage that cost the lane two gates today — not to be acted
  on without weighing that. `attention:experts-never-called` is the expert
  telemetry (no expert lane used; substitution reported unknown by
  design), not the timing log.
  lenovinha is BACK (reported ~19:10Z after the operator's "down"): rpm-ostree
  idle, booted 44.20260911.0, rollback 44.20260910.0, nothing pending or
  mid-transaction — the failed apply left nothing staged. Layered:
  akmod-nvidia kmod-nvidia xorg-x11-drv-nvidia(-cuda) gcc gh git btop
  google-chrome-stable; the NVIDIA akmod/kmod stack is the layer class most
  likely to block a base bump (a kmod built against one kernel does not
  survive the next), and lenovinha (discrete GPU) versus yoga (iGPU+NPU,
  rocm layered) differ on exactly that axis. ADJACENCY, not a claim: `gh`
  is a LAYERED package on lenovinha; if the layer set was in flux during a
  part-applied update, a gh-provided credential helper behaving
  intermittently is no longer obviously a network blip — the two facts
  belong together. lenovinha deliberately changed nothing (no upgrade,
  rollback or layer change: an operator action on a machine someone uses).
  Asked, read-only: upgrade --check (kernel bump?), the rpm-ostreed journal
  for the failed apply's reason, kmod presence for non-booted kernels, and
  which credential helper git uses plus gh's version. Then 1154-8ywc.
  ROOT CAUSE of the Silverblue update failure (lenovinha, read-only, no
  deployment change): REPO SKEW at DEPSOLVE, not a stale kmod. The offered
  base 44.20260913.0 bumps the kernel 7.2.4 → 7.2.5; `akmods` carries the
  rich dependency `(kernel-devel-matched if kernel-core)`, kernel-core is
  present from the OSTree base so the conditional fires, and the updates
  repo (metadata 2026-09-12T00:52) does not yet carry
  kernel-devel-matched-7.2.5 for a base built 2026-09-13T00:50 — every
  listed kernel-devel-matched is refused because no repo kernel-core can be
  layered over an ostree base. The journal: "Txn Upgrade … failed: Could not
  depsolve transaction; 4 problems detected", fourteen times today; no
  finalize entries, no staged deployment — "ready, requires restart" comes
  from the non-depsolving --check (rpm-ostree's own warning: "--check and
  --preview may be unreliable") and GNOME Software; the apply then fails at
  depsolve every time and stages nothing. TRANSIENT BY CONSTRUCTION;
  self-clears when kernel-devel-matched-7.2.5-200 publishes. Remedies, all
  the operator's: wait; upgrade with the NVIDIA layer temporarily removed;
  or pin. The NVIDIA stack is implicated only because it drags in `akmods`;
  a host layering akmods without NVIDIA fails identically; the kmod matches
  the booted kernel and nothing is stale. Scope test: yoga has no akmods,
  so a clean apply of 44.20260913.0 there confirms akmods-not-GPU — the
  operator's call on their workstation. CREDENTIAL ADJACENCY RETRACTED by
  lenovinha, tested before it propagated: pushes do authenticate through a
  layered gh (`!/usr/bin/gh auth git-credential`, gh-2.97.0-2.fc44), but
  every upgrade failed at depsolve before touching the deployment, /usr
  unchanged since Sep 11, the layer set never in flux — adjacent in
  mechanism, unrelated in time; the intermittent credential stays a blip of
  unknown cause. Filed as a short operational row (docs, p3).
- **829-dkuc: first supervised de-slop sweep, landed** (macuahuitl, under
  the operator's budget; f4b9496a0): 29 findings, 11 sonnet pairing agents in
  worktrees + 1 opus judge, 1,024,451 sub-agent tokens, 918 s fan-out,
  ~22 min end to end; confirmed 6 deletions (net -49 lines, re-verified on
  trunk: cargo 161/176/539 green, detector at 0 per variable), refuted 6
  (every one a detector blind spot → four packets: env-prefix assignments
  after `$(`, Rust reads with defaults bucketed as gating, Rust doc
  comments and wrapper setters invisible, the detector's own comments
  counted as reads), inconclusive 2, downgraded 15, one behavioural packet
  (the forge launch nested in a never-taken conditional needs a fixture
  first). Three protocol findings, in the skill: the workers' worktrees
  were based on a STALE commit (the coordinator re-verifies on trunk); diffs
  come from worktrees, never from size-capped returned text (a real
  109-line deletion was downgraded on the artifact alone); and the
  net-negative rule per mutation drops every DOCUMENT verdict, so 12 of 29
  deliberate knobs stay listed until a registry line can count. The token
  counter's first non-lenovinha record: token_max now names this sweep.
  Filing collision avoided this time: next-order read before every filing.
- **1171-ccf2 sharpened by yolanda before taking it**: route (b) is
  unavailable — tillandsias-tray.exe exposes no capability-probe surface
  (its CLI is provision/reset/forge/status/diagnose/logs/version), so
  adding one is more work than route (a); route (a) ALREADY WORKS on
  yolanda: `target/debug/tillandsias.exe --capabilities` rc 0 reports
  accel_side=windows-host with the real AMD 860M and NPU rows, and
  host-capability-probe.sh --fragment emits a well-formed windows-host
  fragment. The difference is the same split as the .exe/ELF one: yolanda's
  target/ holds a native PE because they ran cargo directly in Git Bash;
  esme's holds an ELF because the sanctioned path (with-wsl2-builder's
  re-exec into the distro) produces Linux artefacts. Neither host is
  misconfigured; the sanctioned build path never produces the artefact the
  windows-host locus needs. The fix is therefore a build/release change,
  not a delivery: the Windows release carries tillandsias-headless.exe
  beside the tray, or the probe resolves where a Windows install puts it; a
  couriered binary rots at the next rebuild. yolanda takes it ahead of the
  793-zumy wrapper because it unblocks a second host.
- **The silent half of the Windows capability gap** (yolanda, found while
  scoping 1171-ccf2; corrects their own "route (a) already works"): it
  runs, and what it produces is WRONG. resolve_probe in
  host-capability-probe.sh admits any candidate whose `--inference-tier`
  exits 0; yolanda's ./target/release/tillandsias is a native PE dated
  2026-08-29 that predates accel_side and the present-unusable vocabulary,
  so the probe exits 0 and emits a well-formed fragment with zero
  accel_side — and the ledger already carries it: yolanda's windows-host row
  (2026-09-12T04:07Z) shows no GPU and no NPU on a host with an AMD 860M
  and an NPU, both present-unusable per the current binary; the matrix
  routes on that row now. Same command, two binaries, opposite answers.
  Polarity: esme's missing binary refuses LOUD; yolanda's stale binary
  publishes SILENT — the dangerous side; fixing only the loud half would
  hand esme a path to publish quietly wrong rows too. Ruling: (1) its own
  p1 row, yolanda's, first — resolve_probe refuses a candidate it cannot
  show is current (vocabulary probe, mtime fallback), named refusal, and
  the wrong row is republished as its closure; (2) the release carrying
  tillandsias-headless.exe stays 1171-ccf2, after (1). esme's 793-zumy
  lesson (correct token, live run, wrong binary) inside the probe's own
  resolver.
- **Silverblue scope confirmed** (yoga, after the operator ran the upgrade
  there): yoga booted 44.20260913.0 on kernel 7.2.5 with rocm layered,
  State idle, no failed or stuck deployment — noticed from the session
  banner's kernel change and confirmed rather than inferred. Read narrowly
  by yoga: it refutes "layered packages cannot take the new base" and says
  nothing about WHICH package conflicts on lenovinha; combined with
  lenovinha's root cause it says everything — yoga has no `akmods`, so the
  rich dependency never fires. Two hosts DISAGREEING is the information
  here (the variable is host configuration, not the platform), the mirror
  of the rule that two hosts agreeing is one datapoint. Note for 1165-g6wx.
  The sweep's land took four launches, three of them the coordinator's
  misses and one a real rule: a skill must be linked into every runtime
  directory the single-source check enumerates (.claude .opencode .codex
  .github .gemini) — the standalone check reads TRACKED links, so it passed
  on an untracked symlink and the gate refused; a kill command that carried
  its own pattern killed the call before the remaining links were made;
  and closing a multi_cycle packet must remove its plan/long-running.md row
  in the same commit. Landed ok:land:b902c1a64 attempt 2. Stale-binary row
  filed as 1172-dyvd (p1, yolanda, before 1171-ccf2).
- **The coordinator's boundary read its own claim fragments as startup
  dirt** (829-dkuc run): the claim set-field and claim event ran seconds
  BEFORE the boundary snapshot in the same command, so the snapshot recorded
  two untracked fragments as pre-existing dirt to preserve; the run then
  committed and landed them, and the guard refused `worktree differs from
  startup boundary` at finalisation — yoga's shape from the afternoon
  (their own test mutation recorded as startup dirt), from the other
  direction. Nothing lost: the files are tracked and on trunk. Rule: take
  the boundary before the first ledger write of the cycle, never after it.
  Cost of the 829-dkuc run, measured: 12 agents (11 sonnet, 1 opus),
  1,024,451 sub-agent tokens, 918 s fan-out, ~44 min end to end including
  four land launches (one skill-link rule, one self-kill, one long-running
  view rule, one push race), ~140k coordinator main-context; emitted via
  --emit-tokens, token_max now names it.
- **900-z3kv COMPLETED** (yoga, code 1e8536e01, closure ok:land:9c0a5343b,
  attested a233b6e0f): the Linux clean room is credential-cold and the
  runbook's claim is true for the first time since at least 2026-06. The
  operator's reasoning is on the row in their words, and it reframes the
  packet: the clearer does not make the reset destructive enough, it makes
  the reset ACTUALLY BE the baseline the platform already assumed; the
  four legs that reported a clean room that was not one were measuring
  that gap. THE GUARD CAUGHT A DESTROY PATH THE AUTHOR HAD MISSED: yoga
  enumerated skills/ and scripts/ by hand and found one
  (scripts/e2e-step2-linux.sh); the guard's new Linux arm found
  run_smoke.sh at the repository ROOT, outside every directory searched —
  written to prevent a future second copy, it found a present one on its
  first run, 803-49re's own argument ("a second copy is where the fix does
  not go") arriving against the person who had just quoted it. The arm
  matches EXECUTION, not mention (of the .sh files carrying the string,
  one executed it and four named it in comments, including
  selective-tillandsias-reset.sh which exists to AVOID a full reset);
  pinned both ways by measurement. Both runbooks now make one claim, and
  both destroy paths tee probe-credential-cold-state.sh into the findings
  so a run records which state produced it.
- **Coordination pass 20:11Z (pass 12).** Relay: osx-next 4 commits
  (macbookair, 1135-z8gn: `clamp-ca-material.sh` was INERT on macOS, not
  unidiomatic — `stat -c` is GNU-only and BSD stat rejects it, so clamp_dir
  and clamp_file returned 1 on every call and the CA-material clamp that
  makes a key 600 and a directory 700 never worked there; the portability
  advisory had counted seven instances and read as style; the script's own
  selftest went rc=1 five FAIL lines → 6 cases PASS). Thirteenth regime axis
  in the same family as the twelfth: an ADVISORY finding on one platform is a
  FUNCTIONAL break on another, and only the platform tells them apart.
  macbookair's second commit is a self-reported hazard worth its own line: a
  claim taken last cycle and never RELEASED at exit read as
  'no-op — status is already in_progress' this cycle; a stranded claim hides
  a packet from ready and from burndown until the 24h reaper, and the same
  host re-picking it is the only reason it cost nothing. lenovinha is BACK
  (the operator's 'down' was the deployment, not the session): 1154-8ywc
  (capability-row guard no longer fails open on age; confirmed on esme
  post-fix, 'signature 2 was a prediction') and 1165-xkjh (a guard that names
  a remedy that cannot run where the verdict fires; verified on esme across
  two loci; arm 22 is structural, not behavioural) both completed ~19:22Z.
  Metrics audit `rows=23 stems=23`: every host NOT-PASTING the cycle-metrics
  block, my own newest entry included (it carries `tokens:` and no
  `skippable:`); standing finding under 1001-q3zf/1074-96z9, no new packet.
  Stale-row pass `ok:stale-ready-rows:88/508:pass=cites-order`, six
  candidates: 1125-wi4d, 1126-w8rq (e357f3f87's third order), 1129-xm5z,
  1132-r4mt, 1141-vf9w (ready on purpose after the release), 1144-jfr5 (mine,
  the owned_files pass unbuilt); no `closed-on`; none handed this pass — the
  hosts that can verify them by execution are mid-cycle. Hand-off: 1165-g6wx
  → yoga by claim flip (Silverblue docs + read-only probe for the depsolve
  skew yoga measured and the operator confirmed on yoga's own upgrade);
  fallback named 1170-e5im. Salvage ref `salvage/yolanda/20260913-793-zumy`
  (6f6bb4ad7): ancestor of linux-next, windows-next and osx-next by the
  four-branch check, ledger line marked ` deleted` in this land, the remote
  ref deleted after it. Meta cycle 19:39Z landed at attempt 1 (1164-cftu;
  1166-99mk..1169-zw44 by one sonnet sub-agent, 222,478 tokens, 21.6 min,
  detector dead 23 → 16 on the tree).
- **A salvage-ref deletion refused an in-flight gate (yolanda, ~20:35Z; 1173-a5ng).**
  The protocol I followed — mark the ledger line ` deleted`, land it, THEN delete
  the ref — protects every gate that merges trunk after the marker, and nothing
  else. yolanda's 1172-dyvd land had merged trunk before 6857ce7f6 (the marker
  commit, 20:29Z); I deleted the ref at 20:31Z; check-salvage-refs-ledger.sh,
  wired into --check and reading the LOCAL ledger against origin's refs, refused
  their gate with `violation:salvage-refs-ledger:1` while trunk carried the
  marker the whole time. yolanda attributed before reporting (the ref theirs,
  the line my sweep's, the gap between the sweep and its own checker) and did
  not salvage — correctly, since a new ref recorded against a broken marker
  path is the last thing the ledger needed. Unblock was one message: re-run
  the land, its fetch-and-integrate step merges the marked line. Filed
  1173-a5ng: the checker falls back to trunk's copy of the file (a behind
  tree reads "merge trunk", not "outstanding rescue"; the negative arm does
  not move), and the sweep's header states the rule I now follow by hand —
  delete a salvage ref no sooner than the pass AFTER its marker lands. A
  timing rule reduces the race and cannot close it (a floor host's gate can
  run an hour); the fallback closes it.
- **1172-dyvd COMPLETED** (yolanda, ok:land:516d18cf1:attempt-1 on
  windows-next; relay due next pass). The resolver refuses a candidate it
  cannot show is current, by name, and continues; the exit-2 text now says
  "no CURRENT binary" so esme's missing-binary state and yolanda's stale one
  stop sharing a message. THE CHECK IS A VOCABULARY PROBE AND MTIME IS
  EXPLICITLY NOT THE REFUSAL — yolanda's departure from my "mtime as
  fallback", argued in the comment: accel_side's absence is a property of the
  binary, mtime of the filesystem, and a fresh clone would refuse every
  candidate on a blameless host. Arm 3 of the four-arm fixture is the proof:
  both fakes created in the same second, so any mtime rule ranks them
  identically and they get opposite verdicts. Mutation control reds the three
  primary arms and leaves the positive control green. The wrong row is
  republished: before, cpu/Host CPU and nothing else; after, cpu/AMD Ryzen AI
  7 350, gpu/AMD Radeon 860M (host-native-only, not container-reachable),
  npu/NPU Compute Accelerator Device (engine-missing). They verified my
  snapshot-race diagnosis before re-running (trunk's ledger copy 1 marked
  line, theirs 0) and the land passed first attempt. Incidental, checked not
  assumed: two Rust files (secure_wire_mode.rs, container_profile.rs) carry
  CRLF in their WORKING TREE and the committed blobs are LF — git normalised
  on add, the safe direction; the cause of the local CRLF is unknown and is
  two files, not the tree, so it is whatever wrote those two.
- **yoga: 1139-xe5m COMPLETED (224e29a52, closed 83f2a886e) and 1165-g6wx
  COMPLETED (cb8316c42, closed a1c2bd76b).** The capability envelope now
  carries `envelope_source=`/`accel_source=` measured|served|unknown, appended
  LAST on the one line the forge receives; the Silverblue skew row has its
  cheatsheet and a read-only probe. yoga had 1165-g6wx claimed and landed
  before my hand-off flip reached trunk — the flip was harmless (their
  completed event is later by LWW) and the hand-off message crossed their
  closure; no second host picked it up, which is the control that matters.
  Two bookkeeping items yoga FLAGGED rather than hand-edited, both correct
  calls: (1) 1139-xe5m's `unscoreable` block promised to move its closure
  text into `verifiable_closure` once the field existed — that is a
  multi-line LWW write, and set-field turns out to accept one (block scalar
  `|-` in a new fragment; measured on a scratch copy of the ledger under
  target/, never the real one), and `declared-closures-check` reads the
  `litmus:` token out of a status-channel value; the closure now names
  `litmus:capabilities-envelope-names-its-source`, bound in
  openspec/litmus-bindings.yaml under accel-capability-probe with a
  post-build spec that runs yoga's suite, and the unscoreable field is
  cleared (an empty value unsets). (2) 1165-g6wx's `owned_files` named
  docs/cheatsheets/runtime/… while both cheatsheet guards walk the root
  cheatsheets/ tree; the file is at cheatsheets/runtime/silverblue-updates.md.
  Corrected by a note event, not set-field: the field is a LIST and set-field
  stores a string — a silent type change on the fold, measured the same way.
  windows-next (1172-dyvd, 516d18cf1) relayed in this land, one pass early,
  because the closure bundle needed the full gate anyway.
- **Fourteenth regime axis: THE HOST'S OWN INSTALLED BINARY IS A CANDIDATE
  (1172-dyvd's fixture, first Linux run, land 18 refused rc=3).** yolanda's
  currency fixture drives resolve_probe through TILLANDSIAS_HEADLESS_BIN=<stale
  fake> and asserts the refusal; the resolver refuses and CONTINUES to
  ./target/release/tillandsias and `tillandsias` on PATH, and on macuahuitl
  the installed launcher on PATH is current, so arms 1 and 5 read "stale
  candidate produced rc=0" and "identical-age candidates got the same
  verdict". The header said "hermetic … no repo binary, no host state"; it was
  hermetic on the one host with no fallback candidate — the host that wrote
  it. Fixed forward in the relay (fixture only: a shadow `tillandsias` that
  fails --inference-tier prefixed to PATH, the probe run from the scratch dir;
  resolver untouched; still reds on the pre-fix resolver), yolanda told before
  the land so 1171-ccf2 merges the fix instead of meeting it. My first
  before-control ran the pre-fix fixture from a scratch copy and failed for
  the wrong reason (REPO_ROOT follows the script's path) — the same
  wrong-scope control shape as the detector's earlier today; the valid
  control is the gate log plus a re-run from the repo path. A fixture that
  claims "no host state" must SHADOW every path the code under test consults,
  not merely avoid setting them.
  yolanda REPRODUCED IT ON YOLANDA within the hour, so it was never Linux-
  specific: their release binary is current NOW because criterion (3) of the
  same packet made them rebuild it to republish the wrong row — the change
  the packet required removed the fixture's isolation in the cycle that
  created it. Their sharper statement of the defect: the fixture asserted on
  the PROBE's exit code, a property of the WHOLE candidate list, when the
  thing under test was the resolver's treatment of ONE candidate. "REGIME:
  hermetic" was hermetic-given-no-other-candidates — a condition stated as a
  property — the fourth fixture this week wrong about ITSELF rather than
  about the code (esme's inherited TOOLBOX_PATH, yoga's chmod under root,
  yoga's never-created symlink, this), with a twist: true when written,
  falsified by its own author's next step. A regime claim has to survive the
  rest of your own cycle, not just authoring time. They kept my fix as the
  right shape (isolation as a PROPERTY of the fixture, not an accident of
  the host) and asked for one line where the copy-the-script-into-scratch
  idiom is documented: REPO_ROOT follows the script, so a scratch copy
  re-roots itself — the same self-reference trap as their pin matching its
  own source earlier today.
- **1171-ccf2 decision (yolanda asked before implementing).** The Windows
  release stages tillandsias-tray.exe plus three scripts and nothing else;
  install-windows.ps1 puts it under %LOCALAPPDATA%\Programs\Tillandsias, which
  is NOT on PATH, so resolve_probe's third candidate never fires on a Windows
  install even with a tray present. Three closures were on the table: (a)
  stage tillandsias.exe and have the installer copy it beside the tray —
  necessary, insufficient alone; (b) (a) plus the installer prepends the
  install dir to the user's PATH; (c) (a) plus resolve_probe gains the
  install dir as a candidate. DECIDED (a)+(c), no PATH edits: an installer
  writing the operator's PATH on every install is a promise the packet does
  not need, and the reset principle covers state the platform owns, not the
  user's environment. Guards asked for: the candidate only when LOCALAPPDATA
  is set (WSL locus never consults a Windows path), MSYS path conversion,
  and the vocabulary probe applied to it like every other candidate. Install
  half: NOT on yolanda's machine (the line they held on the Vulkan ICD and
  were recorded right on) — it is esme's measurement on a PUBLISHED release,
  i.e. after the operator's next daily cut; the row flips to `implemented`
  with the resolver arm and the staging assertion as evidence and the install
  half named as what is LEFT; the coordinator routes the smoke to esme by
  claim flip when a release carries it, operator's per-run word for the
  destructive part as usual.
- **Coordination pass 22:41Z (pass 13).** Relays: none (osx-next +0,
  windows-next +0; trunk c6f42a113). Lands since pass 12: 990dc72f6 (1173-a5ng
  filed, plan-only lane), c6f42a113 (windows-next relay + the fixture fix,
  attempt 1 after one refused land). Messages since the last pass, all
  handled: yolanda's salvage-ledger refusal (my deletion race → 1173-a5ng),
  their 1172-dyvd landing and reproduction of the fixture regime defect on
  their own host, yoga's 1139-xe5m/1165-g6wx bookkeeping asks (done, landed),
  yolanda's 1171-ccf2 scoping question (decided (a)+(c), no PATH edits, install
  half to esme after the next cut). Stale rows `ok:stale-ready-rows:89/508`:
  the seven of pass 12 plus 1135-z8gn (6 commits cite it; macbookair released
  it to ready on purpose after the clamp-ca-material slice — a multi-slice row
  cited by every slice, the 1135-z8gn shape the pass documents), none handed.
  Hand-offs: none — yoga self-drained 1139-xe5m from plan_next at their own
  cadence, yolanda holds 1171-ccf2, macbookair and lenovinha are cycling, the
  floor (macneo, esme, pirria) has nothing floor-shaped in the queue and no
  report since; queue heads unchanged (776-jcf3, 804-deux, 793-zumy). Audit
  rows=23 stems=23, every host NOT-PASTING (standing). Salvage refs: nothing
  to delete; the one-pass grace rule applies to the next one.
- **Correction to pass 13's label.** The entry and its loop-status heading say
  22:41Z; the pass ran at 22:12Z (the fragment's file stamp, 221221z, and its
  --ts are right). The :41 cron fired at 21:41Z and its prompt was delivered
  when my previous turn ended, thirty minutes later — cron prompts queue behind
  a long turn, so a pass's real time is the delivery time on the clock, never
  the cron's minute. Label by the clock.
- **esme reports a standing approval from the operator, in their words:
  "destructive tests requested by Macuahuitl are approved by me."** Scope as
  esme recorded it, not widened: destructive runs the coordinator requests on
  esme; a peer's request or esme's own judgement still goes to the operator.
  esme restated the blast radius to the operator BEFORE they confirmed, and
  corrected their own first telling: the Windows row of the curl-install
  smoke does not podman-reset, it runs `wsl --unregister tillandsias` —
  DESTROYED: the enclave guest (Vault sealed store, mirrors, images), caches,
  vault-shamir-share-v1 and vault-root-token-v1 in Credential Manager
  (tillandsias-vm-uuid kept); SURVIVES: `tillandsias-build` (gate
  environment, cargo cache, models, the ollama serve). The Vault credentials
  are RE-PROVISIONED, not rebuilt. Coordinator's reading, stated to esme and
  here for the operator to correct: for runs I request, the standing approval
  is the per-run word given ahead of time, so 1004-vsh2's no-pause clause
  applies at the reset step; the workstation courtesies stay (blast-radius
  block first, salvage before reset, hard stop at anything reaching
  tillandsias-build or leaving the row's Windows lane). No run requested yet:
  the run is the Windows smoke of the NEXT daily release, serving 1171-ccf2's
  install-half closure and the routine smoke in one destruction.
- **Windows lane hazard (yolanda, measured): the land tool orphans its gate
  inside WSL when the outer process is killed.** The harness killed the land
  for low memory (542 MB free of 15.9 GB); `build.sh --check` kept running
  inside the distro for 30 more minutes, exited 0 and wrote the gate stamp;
  the land script that would have read the exit and pushed was dead. Cost:
  2476 s of gate and ~6.5 GB of vmmemWSL held for no landing — and vmmemWSL
  does not return memory on its own, so the orphan is what keeps the host in
  the state that caused the kill; the floor host is likelier to hit it and
  likelier to hit it again. Silent both ways: no landing, and a log that
  reads as a gate that stopped mid-phase. Decision: ONE row, filed by
  yolanda — the land tool ADOPTS an existing valid stamp for the same tree
  digest instead of re-gating (line 134's own debt), turning the orphan into
  a free landing on the next attempt; "die with the parent" would discard a
  green gate either way. Three instrument failures in the same hour, same
  class (a check that returns cleanly has not answered the question): `pgrep`
  does not exist under Git Bash, so `until ! kill -0 $(pgrep -f …)` declared
  the land finished on its FIRST pass (empty substitution, `kill -0 ""`
  fails, `! fail` is true — fails OPEN); `ps -W` cannot see into the VM, so
  a survivor check reported zero cargo processes while cargo ran (fails
  OPEN); `pgrep -f "build.sh --check"` under `sh -c` matched its own wrapper
  and reported still-running after the gate was gone (fails CLOSED). Rule
  carried: `command -v` the instrument before any liveness loop; an absent
  instrument and an absent process produce the same empty string.
- **macbookair (1135-z8gn, the sed -i class): a mutation arm that PASSES on
  macOS while its mutation silently never applies.** BSD `sed -i` reads the
  next argument as a backup suffix, so `sed -i 's/X/Y/' "$PRE"` binds the
  expression as the suffix and parses the file path as the script ("invalid
  command code f" on the leading /var); scripts/test-mode-only-regression-
  887-bz88.sh then asserts the reconstructed pre-fix guard passes the incident
  tree, gets the answer it wanted, and prints "arm 3 has teeth" — rc 0, on
  every macOS run. Its own `bad` branch anticipated "arm 3 may pass for the
  wrong reason". The other four sed -i sites (test-gate-stamp-memoization,
  test-hash-image-sources, test-source-slice-bounds ×2) fail LOUD (rc 1 with
  the sed error visible); only the mode-only one fails open. Fix shape agreed:
  write through a temp file (both dialects agree) AND every mutation arm
  proves the mutant differs before asserting the verdict — the 829-dkuc rule
  "prove the diff non-empty" placed in the arm, not the author's memory.
  Second advisory finding for 1130-i6xj, confirmed by execution: check-
  portability-idioms.sh counts MENTIONS, not actions — three flagged sites in
  test-litmus-mutation-arm-guard.sh are heredoc fixture data or a `bad`
  message string in a fixture whose whole subject (901-jtvi) is "a comment
  naming sed -i is not a caller"; of 9 sed -i reported, 5 are real. Same shape
  as 1169-zw44 (the dead-env detector reading its own comments as reads).
- **macbookair: 1135-z8gn sed -i executed sites landed osx-next 5d93b196a
  (claim released 0fbe26838, MO-FULL 8b541db09); 1174-jd8n filed** (the
  portability advisory counts mentions, not actions; closure requires the
  over-reported fixture to report zero AND the advisory's own fixture to keep
  its deliberate subjects, so a file-name exemption cannot satisfy it). The
  fail-open mutation arm is fixed both ways: temp-file form at all five
  executed sites AND the arm proves the mutant differs (cp to $PRE.premutation,
  cmp -s, bad() if identical) before asserting — falsified by a no-op mutation
  (rc 1 "mutation did not apply") and restored (rc 0 with the teeth line
  back). Baseline loud-fail 12 → 7. Left, not folded in: scripts/test-gate-
  stamp-memoization.sh exits 1 on macOS on `combined dispatch: memo_taken=no
  rc=2 (want 124=still working)`, byte-identical before and after their
  change; wants a timeout exit code, so plausibly `timeout` differing on that
  host. The count lesson, stated by the row that keeps teaching it: sed -i
  went 9 reported → 5 real, the fourth consecutive downward revision after
  someone READ what the pattern matched; a count converges by being read,
  not by being re-run. Relay of osx-next waits for the cut's back-merge.
- **yoga: 1132-r4mt advanced at 191d606db (MO-FULL 90dcbbe07), claim released,
  criteria 2 and 3 open.** Arm 5 exhibited directly: killing
  archive-plan-packets.sh --check mid-run on a clean tree leaves plan_tmp/,
  five plan_tmp_*.txt and scripts/archive-plan-packets-check.rb with no gate,
  no stray and no absent ruby involved; arms 4 and 5 are independent subjects.
  CORRECTION TO THE FLEET'S STRAY PROTOCOL, yoga's own sentence retracted by
  measurement: conmon parentage is how toolbox dispatch works, not how a stray
  looks — a healthy running gate's container-side build.sh has parent conmon
  while its launcher chain (toolbox run → podman exec) is alive. The
  discriminator is whether the HOST-SIDE podman exec for that container-side
  pid still exists. Anyone applying the earlier wording would have recorded
  every healthy gate as a stray; the skills-audit proposal for
  meta-orchestration carried that wording and is corrected before landing.
  Two instrument notes: plan_tmp's mtime is inherited from the copy source
  (it stats hours old the moment it is created, so dating an interruption
  from it places it early), and two ps captures matched an awk field index
  instead of a name, wrote an empty file, and read as "no stray processes".
  Unexplained, flagged: eight idle conmon-parented `/bin/bash -l` in yoga's
  builder container, cwd crates/tillandsias-headless, 2–4.5 h old, no
  children; a clean dispatch leaks none.
- **Coordination pass 00:12Z 2026-09-14 (pass 14; the :41 cron delivered
  31 minutes late behind the cut's diagnosis).** Relays HELD under the cut
  freeze, both carrying code: osx-next +5 (macbookair, 1135-z8gn's sed -i
  slice with the mutation-arm fix, claim released, attested) and windows-next
  +3 (yolanda, 1171-ccf2: the Windows release carries tillandsias.exe and the
  install dir becomes a probe candidate). Both relay in one land after the
  stage-2 back-merge, so the cut base stays the tree the release gate
  verified plus the wrapper fix that unblocks it. Trunk moved +6 under the
  freeze, all plan-only as agreed: yoga's 1132-r4mt claim, advance and
  attestation, lenovinha's 1159-g96c claim. Stale rows
  `ok:stale-ready-rows:89/509`, candidates unchanged, none handed. Audit
  rows=23 stems=23. Hand-offs: none — every capable host is on its own cron
  or holding a local commit for the all-clear; the floor has nothing
  floor-shaped until the cut publishes (esme's smoke). NEW HAZARD, measured
  while diagnosing the cut: two `scripts/local-ci.sh --phase pre-build` runs
  in one checkout collide on SHARED /tmp paths — the probe-usage determinism
  check tees /tmp/probe-usage-determinism-corpus.log from both, and reported
  "more than one verdict over the full corpus" in both concurrent runs while
  the lone release gate was green on it; the second run's pre-build litmus
  also slowed the first by ~2×. A local-ci run is a gate for contention
  purposes even when it holds no lock; one per checkout. The cut's red is
  diagnosed and fixed (1175-wuwr, the wrapper's competing-gate capture under
  set -e); the land, attestation and re-gate follow.
- **The cut's red, closed as a family (lenovinha) and owned (yoga).** Three
  members in one night, one shape — A NON-ZERO EXIT LOST OR ACTED ON
  INVISIBLY — and one remedy, `rc=0; out="$(…)" || rc=$?`: 1141-vf9w
  (`printf | grep -q` under pipefail reports failure on a successful match),
  1155-jurn (`$?` does not survive `wsl.exe -- bash -lc`), 1175-wuwr
  (`out="$(detector)"` under `set -euo pipefail` kills the wrapper silently
  between toolbox init and dispatch — the detector was WORKING PERFECTLY;
  its correctness is what killed the wrapper). yoga, who wrote both the
  block and its fixture: the fixture drove the extracted block under an
  explicit `set +e`, twice, so it asserted about a shell nobody ships and
  could not have seen the death no matter how many arms it grew — "the
  assertion gets reviewed and the scaffolding that builds its premise does
  not". lenovinha's rule for the instrument that found it: AN INSTRUMENT
  WHOSE MOST LIKELY OUTPUT IS A NEGATIVE HAS TO BE HARDENED BEFORE THE
  NEGATIVE IS TRUSTED — the empty env diff was load-bearing, and it was only
  trustworthy because the dump had been made collision-proof first; two runs
  on one filename would have diffed a run against itself and drawn the same
  conclusion from nothing. Third instance of the shape the same evening: the
  two-sweep /tmp collision producing a false determinism red. Rule kept:
  one sweep per checkout, beside the one-gate lock. Meta cycle 23:41Z landed
  62b3ae68b, attested 7a089997d; the re-gate runs on it.
- **yoga refined the consumer fixture (81610b9b5, held for the back-merge
  note): errexit does not single out code 1.** A bare `_cg_out="$(detector)"`
  exits the wrapper on EVERY nonzero status, so codes 2 (caller contract), 3
  (could-not-run) and an unrecognised code died at the same line, and their
  arms still drove the block under `set +e`. Three more strict arms through
  drive_strict; measured 14/14 post-fix, 9/14 on the pre-fix capture form
  with the three new arms red beside the two landed ones — and every lax arm
  green in BOTH, which is the finding: the lax arms cannot see this and never
  could. The strict arms defend the `|| _cg_rc=$?` FORM; without them a later
  edit could restore the bare assignment and leave 1 and 0 green while 2, 3
  and 9 die silently, worse than before the fix because the fixture would look
  like it was watching. The lax drive and arm loop stay on `set +e` on
  purpose (they assert which case arm fires, observable only if the shell
  survives to reach it), now BOUNDED by the strict arms rather than an
  unexamined convenience. lenovinha's qualifier on the instrument rule: harden
  when the negative ELIMINATES a hypothesis (someone stops searching on it),
  not when it merely fails to confirm.
- **yolanda reported a freeze breach that was not one, and found a real gap
  doing it.** They pushed 1171-ccf2's code to windows-next at 23:37Z inside
  the cut window and held everything after; the freeze holds code lands on
  LINUX-NEXT only (the branch the release gate verifies), platform-branch
  pushes move nothing the gate reads, and their relay is the coordinator's,
  held until the back-merge — so nothing to revert and the cut base is
  untouched. Told them so; the standing wording of the freeze in the memory
  and the skill must say "linux-next", and tonight's messages did. The gap
  they named stands regardless and they file it: a freeze is a rule with no
  mechanism — the pre-push hook checks the trunk merge and the gate stamp and
  never whether a freeze is live, and on a 41-minute gate the window between
  "I checked" and "it pushed" is long enough for a freeze to begin inside it.
  Shape requested: a live freeze marker on origin the hook consults for CODE
  pushes to the frozen branch, plan-only exempt, set and cleared by the cut
  runbook at the gate start and the back-merge push. Order numbers 1174-u5wp
  and 1174-6r4k are distinct by design (the suffix exists because the number
  is a per-fold sequence and hosts mint on different branches). 1171-ccf2 is
  implemented at 740e93552; esme's measurement on a published release is
  what is left.
- **macneo (:40 cycle, attested f06c03708): the plan/issues differential,
  measured as the A/B the packet 1142-85zx implied but nobody had run.** Same
  floor-tier Mac, adjacent ledger-only cycles, one variable: a plan/issues
  note in the diff forces the full `./build.sh --check` (~1000 s regime);
  without it the plan-only lane accepted in 16 s wall clock and carried TEN
  fragments (yoga's loop_status and attestations among them). THE
  INTERACTION, theirs to name and mine to own: the per-host drill convention
  (one plan/issues file per host, adopted to stop concurrent appends
  corrupting one file) MULTIPLIES this defect — every host now writes a
  plan/issues note on its cadence, so the forcing rate scales with fleet
  size; macneo paid a full gate on each of its last two cycles for
  markdown-only diffs and became a producer of the starvation it reports by
  following the fix. Also measured: a push rejected as behind (origin moved
  inside the cycle) cost seconds to retry BECAUSE the diff was plan-only;
  under the packet's failure mode the same race costs a full gate per
  attempt — starvation is duration MULTIPLIED BY retries, and only the
  retries explain refused:land:attempts-exhausted. Released back to ready
  rather than implemented: widening gate-stamp's skip list is a trunk-gate
  owner's change and needs the memo verdict (ok:gate-fresh-except-plan) plus
  the arm asserting the issue-citation guard still runs on an issues-only
  diff (881-29me), which macneo tripped for real this week. Positive control
  on the absence: the three plan globs ARE in gate-stamp.sh's skip case and
  plan/issues is not. Routed: macuahuitl takes 1142-85zx in its next meta
  cycle after the cut, sized against N writers. Keychain: five prompt-free
  gates since the operator's restart.
- **v56.9.13.1 CUT (2026-09-14, on the operator's instruction).** PR #115
  merged at 5399da211 after the re-gate on 7a089997d (rc 0, 1522 s, 358/358
  pre-build litmus, 33/33 checks; the first gate on 0c53aa4ae was red on
  1175-wuwr); bump PR #116; tag v56.9.13.1 at main 6b8342f3f; back-merge
  pushed on linux-next at f51aa955e with the README row (twelve v0.4 rows
  distilled into one span, ten rows now), the work-queue line and
  1175-wuwr's closure; release run 34794577946 dispatched. Cut base predates
  yolanda's 1171-ccf2 windows-next code and macbookair's sed -i slice; both
  relay next pass. All-clear sent to yoga, lenovinha, yolanda, macbookair.
- **lenovinha: 1159-g96c blocked on a HOST RESOURCE CEILING, relayed rather
  than retried.** Two land attempts SIGKILLed by the system for low memory
  in the same phase (clippy strict + listen-vsock on tillandsias-headless),
  tree intact both times; the 1047-h88p cap already resolves to the floor
  (13 GB < 16 → CARGO_BUILD_JOBS=1) and one rustc still exceeds a 13.8 GB
  host beside a desktop session and an agent. Marginal, not absolute: five
  packets landed through the same gate on the same host tonight; the
  back-merge moved the line, not the host. Decision: push work/1159-g96c,
  the coordinator relays it in the next pass's single land with the platform
  relays. Row to file (theirs): the ceiling is a step function with no rung
  below one job, and a gate killed for memory leaves an empty log
  indistinguishable from a hang — a named pre-gate memory floor and a
  post-mortem OOM read (refused:gate:oom-killed) are the ask.
- **lenovinha: the work/ relay push is refused too (stamp required), and the
  answer is the lane that already exists.** `git push origin
  HEAD:refs/heads/work/1159-g96c` → "plan-only lane: not applicable — new on
  the remote; full gate required" then "the tree changed since ./build.sh
  --check last passed (12 paths)" — the twelve paths being the back-merge
  they were told to take. Filed 1176-fn2p (the gate cannot report its own
  OOM; 1047-h88p's ceiling is a cliff with no rung below one job) and
  1177-k4jq (the relay cannot rescue a host that cannot gate, because the
  work/ ref demands the stamp; the ask is a hand-off of an UNGATED tree
  marked as such, negative controls: platform branches and main unchanged,
  the coordinator still gates before trunk). Coordinator's answer: the
  ungated hand-off lane exists — since 1146-8j7i the salvage net handles a
  clean tree with an unpushed commit (ok:salvaged-commits:<ref>:<sha>) and
  pushes the commit object with authorship intact to a salvage ref the hook
  accepts; 1159-g96c relays from it, gated here, next pass; the work/ lane is
  the GATED hand-off by design, so 1177-k4jq may reduce to naming the choice
  in the refusal text plus docs. Fourth member of tonight's family, in
  lenovinha's own command: `git push … | tail -3 && echo pushed` reported a
  failed push as pushed (the `&&` saw tail's status) forty minutes after they
  wrote about the family; the real refusal was a stale plan binary
  (1129-4su6), fixed by rebuilding one crate.
- **lenovinha salvaged 1159-g96c through the existing lane:**
  `ok:salvaged-commits:refs/heads/salvage/lenovinha/20260914-1159-g96c:477e5ed77`,
  confirmed on origin (the `-commits` verdict, not `-local`: the copy survives
  a re-clone; 4e38b5a29 reachable, authorship and message intact). Relay onto
  linux-next in the next pass; ledger line then; deletion one pass after the
  marker. 1177-k4jq corrected on the row (c5f41fd3d) and REDUCED: work/ is
  the gated hand-off by design and salvage/ the ungated one, so the defect
  is that the refusal never names the choice — refusal text plus docs,
  negative controls unchanged. The actionable half, in their words: A TOOL
  WHOSE NAME DESCRIBES ITS ORIGINAL CASE WILL NOT BE FOUND BY SOMEONE IN ITS
  EXTENDED CASE — salvage-dirty-worktree.sh reads as a dirty-tree tool and
  1146-8j7i's clean-tree extension was invisible at the moment it was
  needed; lands in the skills batch beside the salvage rule. The evening in
  one line, theirs: fluency in a failure mode is not protection from it — the
  status-lost family caught yolanda, esme, macuahuitl and lenovinha in turn.
- **yoga landed 1150-q462's strict-regime arms at 7c8f203e6 (attempt 2: attempt
  1 gated green and lost the push race to the back-merge and the release
  traffic; the tool re-fetched, re-merged and re-gated on its own; merged, not
  rebased, as the unpushed set carried a merge).** The row's event now says,
  in yoga's words, that the causal chain for the cut's red ran their fixture →
  their block → the release gate, and the fixture is the link that should have
  caught it.
- **Coordination pass 02:05Z (pass 15; the 01:41Z cron delivered behind the
  release watch).** Freeze over: three relays in one land — osx-next +12
  (macbookair's 1135-z8gn sed -i slice with the mutation-arm fix, claim
  released, macneo's attestation), windows-next +6 (yolanda's 1171-ccf2 at
  740e93552, the held merge, the 1174-u5wp filing), and lenovinha's salvage
  ref 477e5ed77 carrying 4e38b5a29 (1159-g96c, authorship intact) — merged
  --no-ff, zero unmerged paths each. Salvage ledger line filed for the ref
  (ok:salvage-sweep:refs=6:new=1:filed=1; ok:salvage-refs-ledger:7); it is
  deleted no sooner than the pass after this marker lands. Trunk had moved
  +10 since the back-merge (yoga's 1150-q462 strict arms at 7c8f203e6 and
  ledger traffic). Stale rows `ok:stale-ready-rows:90/513`, none handed.
  Audit rows=23 stems=23. Hand-offs: none — 1142-85zx is macuahuitl's next
  meta cycle (macneo's A/B on the row), the floor's smoke is running on esme
  (v56.9.13.1, Windows row, requested with the tag). Release run 34794577946:
  Linux and Windows jobs green, macOS tray job still running at 02:11Z; the
  three-set asset assertion waits on it.
- **v56.9.13.1 PUBLISHED.** Release run 34794577946 completed success on all
  three jobs (Linux musl at ~01:1xZ, Windows tray ~01:5xZ, macOS tray
  ~02:1xZ; ~75 min end to end, the macOS job the long pole). Asset assertion
  by name, all three sets present: tillandsias-linux-x86_64 + SHA256SUMS,
  tillandsias-tray-56.9.13.1-windows-x64.zip + tillandsias-tray.exe +
  SHA256SUMS-windows, tillandsias-tray-56.9.13.1-macos-arm64.tar.gz +
  Tillandsias.dmg + SHA256SUMS-macos; 32 assets; MSIX absent (unsigned,
  withheld by design). Prerelease (daily channel). Linux smoke artifact:
  https://github.com/8007342/tillandsias/releases/download/v56.9.13.1/tillandsias-linux-x86_64
  The cut ran ~3h40m from the operator's word (22:26Z) to publish (02:1xZ):
  25 min first gate (red), ~1h diagnosis, 3 min land, 25 min re-gate, ~10
  min bump check, ~10 min back-merge check, ~75 min workflow. The
  skills-audit proposal "assert all three sets, do not display" was applied
  by hand here and lands in the release skill with the batch.
- **Land 22: ok:land:1dd840e4d:attempt-1** — the three post-cut relays
  (osx-next, windows-next, lenovinha's salvage ref with 4e38b5a29) gated on
  Linux for the first time and green; osx-next and windows-next contained in
  trunk, 4e38b5a29 contained; lenovinha closes 1159-g96c on it. The relay
  list for the next pass is empty.
- **esme: v56.9.13.1 Windows smoke PASS (report 04ae40da2, host-qualified).**
  install exit 0, sha256 ok, tray 56.9.13.1 (6b8342f3f) exact; reset:
  terminate 0, unregister 0, credentials cold, tillandsias-vm-uuid preserved,
  tillandsias-build Running (--terminate used, not wsl --shutdown, to keep
  it); provision cold 99 s, warm 17 s; wire reachable, wire_version 3, phase
  Ready; diagnose exit 2 (the guest idled between calls). Sections 0–3
  covered, 3b and 4–4c NOT RUN. Blast radius held; unpushed work bundled
  outside the checkout before the reset. The three briefed expectations
  confirmed (stale:capability-row-expired is the fix; due:no-capability-row
  from the builder distro is 1159-g96c; 1171-ccf2's absent headless exe is
  expected in this cut). DIVERGENCE, recorded not filed: the documented
  post-provision idle-shutdown says a distro restart restores the wire with
  no intervention; here seven polls over four minutes stayed 10060 with the
  guest Running and both units active, and only a warm --provision-once
  restored it. RUNBOOK FINDING (to file, windows): PowerShell 5.1 +
  ErrorActionPreference=Stop + `*>&1` turns any native stderr line into a
  terminating ErrorRecord — the tray's benign "Failed to set locale" aborted
  --provision-once MID-PROVISION and the half-provisioned guest still
  satisfied the destruction-marker assertion (a naive re-run reads fresh
  while resumed); remedy Start-Process -Wait -PassThru with redirected
  streams; and $LASTEXITCODE came back EMPTY for a native call in that
  harness, so a canary (cmd /c exit 7 must report 7) precedes every
  assertion. NEAR-MISS: a stale checkout read "NO LEDGER ROW for
  v56.9.13.1" — order 380 would have filed the release as undescribed; the
  merge produced the row. HELD: 1155-jurn's canary push, because esme's gate
  came back red at 53 min on capabilities-envelope-names-its-source 1/6
  inside the gate, 6/6 standalone on the same tree — the arm name requested.
- **Fifteenth regime axis (esme, measured): WHICH ARTIFACT.** The envelope
  suite (yoga's, bound by the coordinator as a post-build litmus tonight)
  resolves `BIN="${TILLANDSIAS_BIN:-$ROOT/target/debug/tillandsias}"`, a
  hardcoded in-tree path; on every Windows host with-wsl2-builder re-execs
  with CARGO_TARGET_DIR redirected, so esme's `./build.sh --check` compiled
  the headless crate into /root/.cache/tillandsias-wsl2-target (17:08) and
  the fixture graded the 09:02 in-tree binary, which predates the
  implementation (16:55): five of six arms red with accel_source='' (the
  field ABSENT, not wrong); standalone 6/6 later because the in-tree binary
  had since been rebuilt. The fixture is hermetic on the cache
  (XDG_CACHE_HOME=$TMP) — only the binary could differ. Same family as
  1154-6big and the resolve_target_binary reorder: a consumer resolving an
  artifact from a path the build did not write. Row to file (esme, linux
  pickup): route the suite and every sibling that hardcodes target/debug
  (executed paths, not mentions) through resolve_target_binary honouring
  CARGO_TARGET_DIR; closure arm plants a stale in-tree and a current
  redirected binary. Green on Linux twice tonight because the target dir is
  not redirected there. esme's 1155-jurn push stays held until a gate proves
  green — correct.
- **esme filed both (3f45bd299): 1178-eg49** (Windows runbook: PowerShell
  5.1 NativeCommandError aborts provisioning on a benign stderr line; the
  half-provisioned guest STILL satisfies the destruction-marker assertion
  because a partial provision writes a vhdx that postdates the marker, so a
  re-run reads fresh while resumed; remedy Start-Process -Wait -PassThru with
  redirected streams plus the exit-code canary, both exercised on the host;
  section 0 anticipates the empty-status class for bash and not PowerShell)
  **and 1179-yshc** (fixture, linux): ONE violator, not a class — nine
  fixtures mention target/debug, exactly one executes a hardcoded path (the
  envelope suite); 721-nyev already settled the convention and a sibling's
  own comment records its first version being refused for the same thing.
  Deliverable: resolve through resolve_target_binary, TILLANDSIAS_BIN
  override kept, the DEFAULT was wrong. Regime on the row. CORRECTION from
  esme to a figure they gave earlier: the plan-only lane's stale-binary
  refusal is re-armed by ANY Cargo.lock change in the workspace, not only
  plan-crate edits — three release rebuilds (~2m22s each) in one cycle to
  push ledger fragments; the guard is right (1129-4su6), the frequency is the
  defect; goes on 1152-y3bv as a note. Routed: 1179-yshc → macuahuitl's next
  meta cycle with 1142-85zx.
- **macbookair reports a STANDING consent from the operator for destructive
  work on macbookair** ("yes, and treat it as standing": the destructive
  macOS smoke and 804-deux part 2's VM rebuild, now and on future cycles;
  their framing: "we embrace destructive resets, our platform is idempotent
  and ephemeral by design"). Recorded as macbookair's report of the
  operator's words, scoped to that host. Routing change: 804-deux part 2
  (end-to-end cache survival across a VM rebuild, the p1 declined every cycle
  on the consent rule) is claimable unattended on macbookair from their next
  cycle; the macOS smoke runs when a release publishes, findings as packets,
  report host-qualified. macbookair is running the v56.9.13.1 macOS smoke
  now — the first real test of their clamp-ca-material fix in a shipped
  artifact (the script was wholly inert on macOS before it: `stat -c` is
  GNU-only); the sed -i slice is NOT in this release and they will say so
  against any fixture-portability finding.
- **DUPLICATE FIX ON 1142-85zx, mine, by the rule I wrote.** I claimed the
  row at 03:41Z with a set-field in this checkout and launched a sub-agent
  without pushing the claim; yoga's plan_next still offered it, they claimed
  on trunk (226d19f06), fixed (236329190) and closed (2c6d108f6) while my
  agent worked; my land refused on the merge conflict. "A hand-off is a claim
  flip ON TRUNK" — a claim that stays local is not a claim, and the positive
  control (plan_next no longer lists it) was never run against origin. Cost:
  one sonnet sub-agent (139,330 tokens, 10 min) and one refused land; the
  winner is yoga's (it also fixed the fast-refusals counter that would have
  refused mine), mine dropped by rebase before landing, per
  on-a-duplicate-fix-hold-never-drop — the loser holds, the winner is on
  origin. Rule for the next cycle: push claims through the plan-only lane
  BEFORE spawning the agent, and run the control against origin's fold.
- **The second reading of 1142-85zx (yoga's ask, answered from the salvaged
  ref).** Two hosts, same constraint, same two decisions arrived at
  separately: top-level only (maxdepth 1) and the citation guard wired into
  the memoised-plan arm. Mine lacked the 1087-h2z9 counter excision only
  because my agent never ran test-gate-fast-refusals.sh. What mine had that
  yoga's did not: arm 6c, a mutation control IN THE ARM (their falsification
  was five hand-run mutations, "the control in the author's memory"). And
  what yoga measured that my review missed: arm 6c builds its mutant by
  PROVENANCE (`git show HEAD:` cmp'd against the worktree), which differs
  only while the fix is uncommitted — on every host that has merged the fix
  it reds permanently, accusing the checkout of an uncommitted change; a
  fixture that asserts its own change has not landed. I verified "pre-fix
  red" and never asked what the arm would print a day later. Resolution:
  yoga rebuilds the mutant BY CONTENT (strip the two constructs, cmp proves
  the strip applied and names itself on a no-op strip, require the
  issues-only change not to reach the memo verdict), lands it under my name
  citing arm 6c and refs/heads/salvage/macuahuitl/20260914-1142-85zx
  (59009673e); the ref stays until the arm is on trunk. Rule kept: a
  mutation control must construct its mutant from content, never from where
  HEAD happens to be.
- **macbookair: v56.9.13.1 macOS smoke PASS (a09ff4884), and the clamp fix
  verified in a published artifact.** Clean room under the standing consent:
  install exit 0 into /Applications (no ~/Applications fallback), tray
  56.9.13.1 (6b8342f3f) exact; reset removed 2.3 GB of state plus the sparse
  rootfs.img with residue asserted empty and sizes measured BEFORE removal so
  a no-op destruction could not pass as a clean room; provision exit 0 with
  the full 528 MB Fedora image re-downloaded, rootfs postdating the
  destruction marker; diagnose exit 0. No product findings. The lane's ledger
  claim (1135-z8gn's clamp-ca-material fix) verified by executing the shipped
  source.
- **macbookair: 804-deux part 2 VERIFIED end to end (111de1387)** — the row
  had carried "UNVERIFIED: needs a re-provision, not authorised" since
  2026-08-19; the standing consent made it available. Seeded so survival is
  provable byte-wise (a 61 B marker plus 2 MiB of /dev/urandom ballast,
  incompressible), rm -rf $VM_DIR only with the cache untouched, then
  --provision: both files sha256-identical across the rebuild, rootfs.img
  nine seconds old at the check (a genuinely new VM), and the ballast
  present in the NEW guest via --exec-guest rc 0. The consent rule held the
  p1 for 26 days; the operator's word closed it in one cycle.
- **Coordination pass 04:05Z (pass 17; the 03:41Z cron delivered behind the
  meta cycle's land).** Relays: osx-next +5 (the two above plus attestations)
  in this pass's land after the meta cycle's; windows-next +3 (esme's rows
  and smoke PASS) already merged in that cycle's land. Salvage refs on
  origin: lenovinha's 1159-g96c (line marked deleted in the cycle's commit;
  the ref is deleted the pass AFTER that marker lands, i.e. next pass) and
  the new macuahuitl/20260914-1142-85zx (yoga's second reading; line filed
  by this pass's sweep; kept until the content-built arm 6c is on trunk);
  five older pirria/unknown refs unchanged. Stale rows
  `ok:stale-ready-rows:89/513`, none handed. Audit rows=23 stems=23.
  Hand-offs: none — macbookair self-drained 804-deux under the standing
  consent, yoga takes the arm-6c rebuild, lenovinha closes 1159-g96c, esme
  re-gates 1155-jurn after 1179-yshc lands.
- **Arm 3d on trunk at 7a6b3ecef (yoga, co-authored to macuahuitl):** arm
  6c's idea with the construction changed — the mutant stripped from a copy
  of the SHIPPED stamp (the skip-glob case arm and the plan_digest find), cmp
  proving the strip applied and naming a no-op strip, the issues-only change
  required NOT to reach ok:gate-fresh-except-plan (verdict
  stale:tree-changed-since-gate); 11/11, mutation-tested 9/11 with the
  no-match patterns red by name. yoga's own words on the cmp check: they had
  produced that exact false pass twice in this row's work and still drafted
  the strip without asking what it would do if it matched nothing — the
  control is in the arm now. The row's event carries both hosts' halves.
  The salvage ref macuahuitl/20260914-1142-85zx has done its job: line filed
  and marked deleted this pass, ref deleted next pass. yoga idle, lock free,
  level with origin — 1176-fn2p is the hand-off (a 14 GB Silverblue host
  under the same 16 GB cliff lenovinha measured; the OOM-signal row is
  measurable there), claim flipped on trunk after the in-flight land pushes.
- **macbookair: 804-deux story complete (attested 437988c82, claim released).**
  Both halves deliberately: the host half alone proves only that rm -rf
  missed a directory; the guest half proves the freshly provisioned VM
  re-attaches the virtiofs share and sees the surviving bytes; the ballast is
  /dev/urandom so "survived" cannot be misread as "recreated". Two items
  remain, neither consent-shaped: (a) the populated-cache models-versus-images
  split needs a forge run pulling a real engine and model — macbookair did
  NOT substitute the 2 MiB ballast for that figure ("a synthetic number
  standing where a measured one belongs is the thing this fleet keeps getting
  bitten by"); --exec-guest works on this path (rc 0, waits for Ready), so
  the probe exists; 830-xsk2's CFRunLoop timeout is a different path.
  (b) SCOPE, decided by the coordinator under the operator's reset ruling and
  surfaced as decided: model_cache_dir() sits under $CACHE_DIR, so the smoke
  and uninstall destroyers wipe the models dir (~2.47 GB re-downloaded per
  smoke; the dir was ABSENT when 804-deux started because the same host's
  smoke had wiped it hours earlier). The clean room stays clean: 804-deux's
  deliverable was survival across a VM REBUILD, a different lifecycle from
  the smoke's destruction; the cost is a measurement on the row. A
  keep-models knob for smoke runs is one line and the operator's word.
- **OPERATOR DECISION (2026-09-14): "let's add the keep models flag to our
  resets."** Filed and claimed 1181-bkem on trunk BEFORE any agent started
  (control 0), with 1182-2vaz beside it. Shape decided from where the
  models live (cache_root()/models): Linux keeps them already (the podman
  reset and the credential clearer never touch ~/.cache/tillandsias/models —
  the flag is a documented no-op there and the Linux step-2 script now says
  so in one line); macOS wiped them because both smoke runbooks rm -rf the
  whole cache dir inline — the destroy moves into scripts/e2e-step2-macos.sh,
  one source for both runbooks (803-49re), honouring
  TILLANDSIAS_RESET_KEEP_MODELS=1 with the spared dir NAMED in the residue
  line so a kept-models run cannot read as a clean room by accident;
  uninstall.sh --wipe honours it on both; Windows cannot spare weights that
  live inside the distro's vhdx (806-a4tu) — 1182-2vaz moves them to a
  host-side mount first, the macOS virtiofs share's shape. Default unchanged:
  the clean room stays clean (the 2026-09-13 reset ruling); the flag is
  opt-in per run. Implemented by a three-agent workflow (two sonnet
  implementers on disjoint files, one opus verifier re-deriving the mutation
  controls and grepping the flag's reach).
- **yoga: 1176-fn2p completed at be9f54100 (closed 13aacb6c8, attested
  3850ece4b), fixture 12/12, both negative controls armed.** Stated on the
  row so it is not misread as a fix for lenovinha's two kills: THE FLOOR
  WOULD NOT HAVE CAUGHT THEM — the floor catches the START state and their
  host had enough memory to begin; it ran out inside clippy, the RUN state,
  which the OOM post-mortem covers. Floor default 1 GiB MemAvailable (not
  MemTotal — lenovinha's total was constant across five successful lands and
  two kills the same day), with an arm asserting the shipped default stays at
  or under a quarter of a completing host's headroom, so a later tightening
  reds it. INSTRUMENT LESSON for any host reading a kernel log:
  `journalctl -k -g <pattern>` prints "No entries" and exits 0 BOTH when the
  window is quiet and when the user cannot read the kernel journal —
  identical output for opposite facts; the probe asks whether ANY kernel line
  is readable before concluding, and degrades to could-not-run otherwise;
  a post-mortem built on dmesg would silently answer not-OOM on every
  Silverblue host (dmesg: "Operation not permitted" unprivileged). Three
  land attempts, all gate-green, two lost to the push race; the floor ran
  live each time (ok:gate-memory:11654MB available, floor 1024MB). Out of
  scope by the row: no rung below one job (1047-h88p untouched); the relay
  lane's stamp requirement (1177-k4jq) still open — handed to yoga by claim
  flip on trunk after this.
- **yoga: 1177-k4jq completed at 5f4b122e2 (closed 30a1b81b4, attested
  46000d4b9), fixture 8/8, both negative controls armed, the gate itself
  unchanged — only the signpost moved.** Verified before building: the
  hook's section 0 exempts refs/heads/salvage/* by design (872-c9nd) and
  salvage-dirty-worktree.sh covers the clean-but-stranded commit since
  1146-8j7i, so the ungated hand-off was reachable from lenovinha's state and
  what was missing was one sentence in the refusal a stuck host actually
  reads. Deviation corrected on the row: the fixture is
  scripts/test-refusal-names-the-ungated-lane.sh, not the reserved
  test-work-ref-accepts-ungated-tree.sh — a filename promising the design the
  reduction replaced would be a false claim sitting in the tree. An arm the
  row did not ask for: the NAMED remedy covers the state that reaches the
  refusal (a refusal naming a command that cannot help is worse than one
  naming nothing). DRILL LESSON, the same one twice in two cycles, in yoga's
  words: the fixture's first version extracted the whole refuse() body and
  two mutations that DELETED the echoes still passed 8/8 — the comment block
  above them names the same command, so the matcher matched the prose ABOUT
  the fix; it now scans only the echo lines, which is what a user reads.
  Scan declarations, not substrings — and run the mutation even when the
  arm looks obviously right.
- **yoga: 1173-a5ng completed at be5a3275e (closed 75d3ed5d1, attested
  09e4523db), fixture 7/7 at the filename the row named; live check
  ok:salvage-refs-ledger:8.** The checker consults trunk's copy before
  calling a deleted ref an outstanding rescue (a behind tree gets
  ok:…:marker-on-trunk:<ref> and a MERGE TRUNK line); sweep-salvage-refs.sh's
  header carries the one-pass-after-the-marker rule, stated as a REDUCTION,
  not a guarantee (a floor host's gate runs an hour) — both mechanisms, not
  either. Two things to carry: the fallback keys on the MARKER, not on the
  line naming the ref (matching the ref alone would forgive every
  outstanding rescue silently; an arm reds on exactly that mutation); and
  `git show <ref>:<path>` on a missing ref exits non-zero writing ZERO
  BYTES, indistinguishable from "read it, found no marker" when the rc is
  discarded — the helper returns a distinct code and the caller REFUSES,
  saying the behind-tree case could not be ruled out (yoga had reported a
  fabricated hazard from that exact mistake before). Three fixture bugs the
  fixture caught, recorded rather than re-run quietly: the ledger line
  written from memory had the wrong field order; the first version created
  NO remote and assumed that made the ref absent — it made ls-remote FAIL,
  so the checker took its origin-unreachable skip and the reachability half
  never ran (an unreachable remote and an empty one are different facts,
  this packet's own distinction one layer down); a fourth mutation failed to
  apply through a quoting error and printed 7/7 from an unmutated file.
  Both of tonight's salvage refs are safe to delete next pass. yoga idle
  again → 1174-6r4k handed by claim flip on trunk.
- **yoga: 1174-6r4k completed at bff49e06c (closed f844f4e1f, attested
  f2276d74e), 14/14 in the existing scripts/test-release-tier-freshness.sh.**
  The daily exercise can no longer be skipped by a diagnostic run.
  CORRECTION to the row as I filed it: no dispatch=ci-full marker exists in
  the check-log index (_stamp_dispatch writes `dispatch` into the GATE STAMP;
  a check-log record carries ci_run_id, ci_phase, check_id, status,
  source_log, archived_log, sha256, duration_ms) — the discriminator is phase
  coverage alone, from the writer's own vocabulary: CI_PHASE "all" for a
  whole run, or records covering pre-build AND post-build AND runtime. Two
  design points: an index holding ONLY phase-only runs reports never, not
  fresh (the same fact as no index; reporting it green would be the defect in
  its purest form), and ignored runs are named with their coverage, because
  silence would read as "nothing newer". The writer honours
  TILLANDSIAS_CHECK_LOG_INDEX now. DRILL LESSON, yoga's: the FIXTURE'S OWN
  HELPER was part of the subject — rec() hardcoded ci_phase "pre-build" while
  every arm meant "a run", so once the guard could tell a full tier from a
  phase-only one, every pre-existing arm was writing a partial run and the
  guard correctly refused to call any of them a tier answer; five of fourteen
  arms rewritten. A fixture written before a distinction exists encodes the
  absence of that distinction, silently. yoga idle again → 1174-u5wp handed.
- **yoga: 1084-nzqc completed at 59225de1d (closed 62fdc9c91, attested
  23b249bcd)** — both SIGPIPE-guard escapes closed (an absolute-path producer;
  a pipeline split across `\` continuations), the 1069-c9w6 fingerprint
  flagged, the pre-fix guard measured green on the same tree; fixture 8/8,
  five of eight arms negative controls. **1174-u5wp RELEASED back to ready at
  86765770a, not started, by design:** it arrived mid-cycle while 1084-nzqc
  was in flight and the cycle was already attested; it changes the tool every
  host lands with, so it gets a fresh cycle with its own boundary; yoga takes
  it at their next cron unless reassigned. Design note from them: adopting
  an existing valid stamp cannot weaken anything, because the pre-push hook
  re-verifies the stamp against the tree at push time. DRILL, both theirs:
  (1) the fix refused its own land, correctly — four REFUSED lines, every one
  heredoc test data in the fixture; a fixture for a class guard must CONTAIN
  the patterns it flags and the guard scans the diff; the project's answer,
  assemble the needle at runtime (980-ja2m), not `# sigpipe-ok:` (that would
  have silenced the refusal and lied, and one arm exists precisely to test
  that the marker still exempts a folded line). (2) Four fixture defects,
  every one a green arm asserting nothing: the rc died in a subshell
  (`_rc=$?` inside a function the caller ran as `$(…)`) so all four negative
  controls passed trivially; one negative control could not reach the check
  it appeared to guard (its file was not in the diff) — only the mutation
  found it; BS='\\' wrote TWO backslashes, an escaped backslash rather than
  a continuation, so the continuation arms exercised shell that does not
  continue — caught by cat -A on the generated file, not by the 8/8.
- **Coordination pass 06:11Z (pass 19; the 05:41Z cron delivered behind the
  keep-models land).** Relays: none (both platform branches contained).
  Trunk in the last 90 minutes is yoga's: 1173-a5ng, 1174-6r4k, 1084-nzqc
  closed; 1174-u5wp claimed by hand-off and released back to ready, not
  started, by design (a land-tool change gets a fresh cycle). Both salvage
  refs deleted this pass under the hook's named override, one pass after
  their markers landed and with yoga's trunk fallback (1173-a5ng) now
  protecting any behind tree: lenovinha/20260914-1159-g96c and
  macuahuitl/20260914-1142-85zx. Stale rows `ok:stale-ready-rows:89/509`,
  none handed. Audit rows=23 stems=23. Hand-offs: none — yoga takes
  1174-u5wp at their cron; the floor has nothing floor-shaped; macbookair's
  next is the 804-deux split measurement; esme re-gates 1155-jurn. This
  pass's records ride the plan fast lane for the first time: 1142-85zx put
  plan/issues on it, so the drill fold no longer forces a full gate on every
  other host.
- **yoga: 1174-u5wp completed at f80ea839a (closed f8a0b41c5, attested
  5643619a9), fixture 7/7, four of seven arms negative controls.** Two
  departures from yolanda's filing, both on the row: the stamp check sits
  AFTER the integrate, not on entry (the fetch-and-merge changes the tree, so
  a stamp consulted before it describes a tree the tool is about to replace;
  a no-op integrate — yolanda's case — leaves the stamp valid, the case worth
  catching); and the union debt VETOES adoption — the file already carried
  1056-5344's note that the gate is mandatory whenever
  .git/tillandsias-union-ungated exists "because a future 'skip the gate when
  nothing changed' shortcut must not silently inherit it": this IS that
  shortcut, a comment written for a change that did not exist yet and exactly
  right; scope must be `full` because the hook enforces verify and scope
  separately. Safety argument, mechanical: the stamp is already what the
  pre-push hook trusts and binds to a tree digest, so adoption grants
  precisely the authority the hook grants seconds later. Verified live twice:
  with edits in the tree the stamp read stale and the gate ran; the row's own
  land printed exactly one ok:land-adopts-valid-stamp line — a later attempt
  adopting the stamp an earlier attempt had earned, the saving the row is
  about on the landing that introduced it. Unverified, as yolanda left it:
  whether the same orphaning happens on macOS or on Linux without a WSL
  boundary (the kill-and-survive mechanism is not Windows-specific; the
  memory hold is) — a cheap check for macbookair or macneo with a spare
  cycle. yoga idle → 1151-td46 handed by claim flip on trunk.
- **yoga: 1151-td46 completed at 213d1ce24 (closed 760678088, attested
  1943f4f06), fixture 11/11, plan suite 310 passed.** FLEET-FACING CHANGE:
  set-field now REFUSES a write that drops lines from a long-form field
  unless `--replace` is passed with the reason; `--append` merges with a
  dated `[ts host]` attribution line. The rule is DROPPED LINES, line-exact:
  adding a line while keeping every old one verbatim needs no flag; editing
  a line in place counts as dropping it — esme's three losses were a
  rewrite of a field another host had written into. The 1136-n8sh discharge
  (move unscoreable into verifiable_closure, then clear unscoreable) now
  needs --replace on the clearing write; row text across the ledger still
  says "clear it" without the flag. The packet's own failure mode, committed
  by yoga while fixing it and reported rather than hidden: a live probe of
  --append wrote a real fragment onto 1132-r4mt's next_action (seconds old,
  uncommitted, removed) — which is why the fixture is hermetic against a
  throwaway ledger. Three fixture defects and one wish: a relative binary
  path after every arm cd'd (ten arms reported "the guard did not refuse" at
  rc 127 — tool-resolution-after-cd, the class that once cost a platform
  outage); "a refused write leaves no fragment" passing because nothing had
  executed (now conjoined with the refusal's rc); a `show` subcommand the
  binary does not have; and an arm asserting that extending a line in place
  should pass without a flag — a WISH, the row said otherwise, the arm was
  changed, not the guard. yoga idle → 1163-3krg handed.
- **Coordination pass 08:11Z (pass 20; the 07:41Z cron delivered inside the
  07:39Z meta cycle).** Relays: windows-next +2 (esme's 1155-jurn claim
  publication, plan-only) merged into the cycle's branch and lands with it;
  osx-next +0. Trunk since the cycle started: yoga claimed 1163-3krg on
  trunk themselves after my push of the hand-off was refused — the working-
  tree hook was under edit by the cycle's own sub-agent (1152-y3bv), and a
  dirty hook refuses its own push; my control read the LOCAL fold and
  printed 0 for a claim that had not landed, and I messaged the hand-off
  before reading the push's output. Corrected within minutes; the rule
  gained its precondition: the control means nothing unless HEAD equals
  origin after the push, and no push from a checkout whose hook is under
  edit is trustworthy — hand off by asking the peer to claim on trunk.
  Stale rows `ok:stale-ready-rows:89/505`, none handed. Audit rows=23
  stems=23. Hand-offs: none this pass (yoga on 1163-3krg; esme re-gating
  1155-jurn; macbookair asked, as a plain measurement for their next cycle,
  whether the outer-process-killed-child-survives orphaning reproduces
  without a WSL boundary, per yoga's 1174-u5wp note).
- **macneo (:40 cycle, 2c88f0b26 through the plan-only lane in the seconds
  regime): 1084-x8ya assessed against landed work and released back to
  ready, closer than the row reads.** Criteria 1 and 3 now have a mechanism
  that does not ride the dead wire (the guest writes guest_binary_sha256
  into provision.state; vz.rs surfaces it through PROVISION_STATE_SHARE_TAG,
  a host-visible share read with read_to_string); criterion 2's cause is
  named (the PSK keyed to the HOST binary rather than the guest's, so
  mismatched binaries derived different PSKs and NNpsk0 failed at message
  one as `noise: input error` — the version-skew hypothesis retired for the
  row's second candidate); criterion 4 untouched (`activating` has zero
  occurrences in diagnose.rs). The half owed, said plainly: HandshakeFailure
  ::classify landed (04cb49cd1) and is referenced in exactly ONE file,
  secure_stream.rs — nothing in the macOS tray consumes it (positive
  control: the symbol resolves, so the absence is real); (a) is now a wiring
  job and the fixture needs a PeerSentNoUsableFrame arm. (c) reduces to one
  file read on a host with a running guest (provision.state off the share,
  guest_binary_sha256 present, well-formed, matching the staged sha256) —
  a macbookair by-product of a tray cycle. THE 1151-td46 GUARD CAUGHT A
  MATERIALLY WRONG ASSESSMENT BY DESIGN, first time: macneo's first pass read
  two of four criteria and was about to record "both criteria appear met";
  set-field refused the next_action rewrite with would-drop-prose, naming
  six lines of another host's text that named criteria 3 and 4 and a
  three-step plan; --append kept all five prior warning lines; the
  over-claiming event was replaced before it landed. RELEASE HOLD lifted on
  evidence (tag contained in both branches, VERSION 56.9.13.1, PR #116
  merged, ordinary claim traffic resumed) — their note stands: an announced
  END is better than hosts inferring completion from tags; the all-clear
  went to four hosts by message and to the ledger by loop-status, not to
  macneo. Keychain: six prompt-free cycles since the restart.
- **yoga: 1163-3krg completed at ff91de860 (closed 71da340fc, attested
  ad19db58c)** — `next-order --since 1157` lists 1158-y3ad and 1160-nvzs four
  lines apart, the collision visible from the tool that caused it. Two
  defects of theirs, recorded rather than re-run: the first cut identified
  the caller with resolve_writer_host(), which falls back to the OS name, so
  on every Linux host the baseline silently became "the highest order any
  linux host filed" (it read 1182, one of the coordinator's rows — the
  duplicate this row exists to prevent, wearing the fix's clothes); the
  caller is a WORKSTATION now. And 1063-363b's defect committed while
  closing: backticks in an INLINE set-field value were command-substituted
  and the stored prose lost a word — --summary-file protected the long text
  and not the short one; corrected from a file with --replace, whose
  old-beside-new print is how the missing word was visible at all.
- **THE THIRD ERREXIT ASSIGNMENT IN A DAY, and the fixture construction
  that could not see any of them.** macbookair proved every macOS gate died
  at build.sh's consumption of the 1176-fn2p memory-floor probe: `_mem_out=
  "$(probe)"` under `set -euo pipefail` with the probe's rc 3 (could-not-run:
  no /proc/meminfo) aborted the shell before the `case` written to wave
  darwin past — the comment above it names darwin by name and was
  unreachable; the log ended at "Fast refusals…" at 606 bytes and read as a
  killed child, and nothing had been killed. Fixed forward from macuahuitl
  in this land (`_mem_rc=0; _mem_out="$(…)" || _mem_rc=$?`) with a consumer
  fixture (rc 3 proceeds with the warn, rc 0 proceeds, rc 1 stops, the
  pre-fix form dies on rc 3). THE DEEPER FINDING, measured in isolation:
  bash IGNORES errexit inside a `( set -e; … )` subshell that sits in $(…)
  or a pipeline — the construction both 1175-wuwr's strict arms and the
  first draft of this fixture used — so those arms let the pre-fix mutant
  print the sentinel and could not see the death they existed to pin; the
  1175 arms' landed "red on the pre-fix form" came from something else.
  Both fixtures now drive the block from a driver file in a SEPARATE bash
  process and read the output back from a file: the fixed block proceeds,
  the pre-fix form dies (rc 1 / rc 3, empty output). Rule: a fixture for a
  set -e block runs it in its own process, never in a captured subshell.
  macbookair's generalisable arm, adopted: a could-not-run probe must reach
  its handler under set -e.
- **Salvage refs: the sweep filed 14 NEW lines this pass (refs=19).**
  macbookair's tlatoanis-macbook-air/20260914-804deux-blocked-on-1183-j9dk
  (relayed in this land: 804-deux part (a) blocked, 1183-j9dk filed p1 — the
  inference container cannot write the macOS model-cache virtiofs share,
  presented root-owned 0755 to uid 1000, so ollama's self-install FATALs and
  the cache can never populate on macOS; images half measured at 6.1 G) and
  thirteen others from the fleet's hosts, filed by the sweep from ls-remote;
  read which are rescues and which are done next pass before any deletion.
- **yoga: 1104-w9np completed at 73e6b2902 (closed 7995741e4, attested
  8ba2042f9), fixture 10/10, bound in build.sh.** The cross-branch claim
  check told lenovinha to keep their hands off their own finished work
  (1071-adhj stranded in_progress for a day with every criterion met because
  their claim came back at them from osx-next and windows-next after routine
  integration); the new verdict is an OK, not a refusal with nicer words:
  own-claim-reflected:<packet>:<branch>, exit 0, the work is the reader's to
  resume or release. SAFETY PROPERTY, since this weakens a refusal:
  ambiguity fails toward the OLD verdict — an empty, unreadable or
  unrecognised host is NOT "mine" and still refuses (treating a sibling's
  claim as your own is 814-iyu7); that arm passes on the pre-fix code too,
  correctly, a control for the fix rather than the defect. 1012-hu7d handled
  with it: a claim written with --host yoga and a later fragment written
  without (the platform bucket) are one host wearing two labels, so _is_me
  accepts the node name, TILLANDSIAS_WORKSTATION, TILLANDSIAS_HOST_KIND and
  the platform constant. The parser arm reports that it ASSERTED NOTHING
  rather than passing — which caught their own fixture bug (its first
  version sourced the check, hit the usage path, and reported a parser
  failure about a function never defined). Negative result stated: no other
  cross-branch verdict under scripts/ can reflect a claim back. yoga is
  self-draining on their cron; no hand-off needed.
- **Coordination pass 10:11Z (pass 21): a SALVAGE REF FLOOD from `--help`.**
  The sweep had filed fourteen new ledger lines last pass, read blind from
  ls-remote; read this pass with the four-branch ancestry check: sixteen refs
  named salvage/<host>/20260914---help[-HHMMSS] — nine under toolbx (yoga's
  toolbox hostname, 1012-hu7d's two-labels shape one more time) pointing at
  yoga's LANDED commits, seven under yoga at 04:55:26–04:55:49Z pointing at
  commits on NO branch, one from macbookair. Mechanism: scripts/salvage-dirty-
  worktree.sh has no usage guard, so `--help` is taken as the slug and, since
  the 1146-8j7i clean-tree extension, a clean HEAD is pushed under it — every
  probe of the script for usage mints a ref, and the ledger check then
  demands each be marked before deletion. Fixed forward this pass (a
  coordination-side guard): an empty, -h, --help or any leading-dash
  argument prints usage and exits 2 pushing nothing, a slug is
  [A-Za-z0-9._-]+ not starting with a dash, with a fixture arm; the integrated
  `---help` lines marked deleted this pass, refs deleted next pass; the seven
  un-integrated ones held until yoga says what they are. The ledger's 22
  lines were honest about the refs and silent about their meaning — a
  sweep that files from ls-remote records existence, not rescue; the
  ancestry read is the other half and it happens at the pass after.
  Guard landed in this pass's land: `--help`, `-h` and any leading-dash
  argument refuse with exit 2 pushing nothing; a slug is [A-Za-z0-9._-]+;
  fixture scenario `usage` plus a litmus step; live probe on macuahuitl:
  refused:salvage:usage, origin's ref count unchanged at 23. Fourteen of
  twenty-six ledger lines are marked deleted (the integrated `---help` refs
  and macbookair's relayed rescue); the un-integrated seven wait for yoga.
  Relay this pass: osx-next +2 (macneo's attestation). Stale rows
  `ok:stale-ready-rows:89/503`, none handed. Audit rows=23 stems=23. Trunk
  since the cycle: yoga's 1104-w9np. Hand-offs: none — every capable host is
  on its cron; the floor has nothing floor-shaped.

**Pass 22 (2026-09-14T12:11Z) — the flood's cause was a gate-bound fixture,
not usage probes (yoga, 10:40Z).** The sixteen `salvage/<host>/20260914---help`
refs were minted by arm 5 of `scripts/test-refusal-names-the-ungated-lane.sh`
(1177-k4jq), which asserted the remedy is "runnable and self-describing" BY
RUNNING `salvage-dirty-worktree.sh --help` — and that fixture is bound into
`./build.sh --check` at 320-1177-k4jq, so every gate on every host pushed a
ref. Yoga fixed the arm to read the property (`-x`, `bash -n`, the header)
at fabfcfe89 (MO-FULL 6c29d1f5e) and swept scripts/ and build.sh for other
gate-time invokers (none). Macuahuitl's usage guard (pass 21) closes the
class; the two land in the same hour without touching each other's files.
Lesson, yoga's words: a fixture that probes a tool by INVOKING it is not
reading the tool, it is USING it — and a tool whose job is to write to origin
will write to origin. The rule about hermetic fixtures was applied to the
ledger and not to origin's refs.
The seven 04:55Z `salvage/yoga` refs (ancestry none): yoga inspected all
seven by content — each carries only the hook and the fixture in yoga's own
mutation states; 7ee26fdeb is byte-identical to the landed commit. Owner's
disposition: throwaway. Marked ` deleted` this pass; refs deleted next pass
(grace rule: the marker lands before the ref vanishes, 1173-a5ng).
The macuahuitl zero settled by yoga's falsifiable prediction (10:55Z): the
script does `git update-ref` BEFORE the push and keeps the local ref on a
failed push (1103-i7xq), so a credential-less builder must hold local
`salvage/…---help` refs with no counterpart on origin. Measured here:
three local `salvage/toolbx/20260914---help-{052055,061909,083616}` refs,
none on origin — the builder on this host is also hostname toolbx and has
no push credential, so the arm's `|| true` swallowed a failed push each
gate. Instrument note from both hosts: `git for-each-ref 'refs/heads/salvage/*'`
returns ZERO for these three-deep refs (one segment per star); `**` is the
glob. A single-star zero is indistinguishable from an absence.
Counts on record, both hosts agreeing after one withdrawn amendment: 17
flood refs on origin = 9 toolbx (bare + 8 timestamped) + 7 yoga + 1
tlatoanis-macbook-air; 8891fab22 is the toolbx 074445 line, patch-equivalent
on trunk (`git cherry` −), its ` deleted` mark stands. Yoga's note for the
smallest register of the shape: an error introduced while correcting an
error, against numbers their own `uniq -c` had printed two messages earlier
— reading your own output is not the same as reading it again.
Pass 22 state: drift win=0 osx=0 main=0, nothing to relay. Trunk since pass
21: yoga's 1177-k4jq fixture fix (fabfcfe89), yoga's 1109-t8kw part 1
(d1a9516cc: three more fixtures that scored a correct refusal as a
failure), macuahuitl's 1153-j2nm (claims on platform branches reach trunk
at claim time: scripts/push-plan-fragments-to-trunk.sh, 25-arm fixture with
the real hook, litmus, methodology MAY/MUST; the platform-regime
measurement handed to macbookair for their 1183-j9dk claim). macbookair
claimed 1183-j9dk on osx-next and announced the vz.rs write scope (nobody
else on it). Stale rows 89/502, none handed. Audit rows=23 stems=23. Hosts
not reporting this window: yolanda, esme, macneo, lenovinha, pirria — not
directed. One new instrument fact from 1153-j2nm's review, for the drill's
standing list: git hands pre-push the remote's CURRENT tip, so a trunk that
moved after your fetch surfaces as the hook refusing on a base it lacks —
never as "[rejected] (fetch first)"; detect a push race by refetch-and-
compare, and a wording regex is a fixture that encodes the hook's absence.
Yolanda (12:20Z) found the flood's THIRD face, the one only their regime
shows: inside WSL (1131-iax2, no push credential) the fixture's `--help`
salvage did not fail, it HUNG — `git push` blocked waiting on a credential
for 3h10m with the gate's log untouched (two 41-minute gates plus three hours
lost on that host tonight; esme would hit the same wall). Bounded inside the
distro: `timeout 25 bash scripts/salvage-dirty-worktree.sh --help` → rc=124
after printing ok:salvaged-local. Both landed fixes (the usage guard, the
read-not-run arm) close the trigger; neither closes the hang face of a REAL
salvage on a credential-less host — handed to yolanda as a row of their own
(GIT_TERMINAL_PROMPT=0 on the salvage push, a bounded timeout), pre-fix hang
measured the way they did tonight. Yolanda's phrasing for the class: a
`--help` probe has to be an assertion about ZERO side effects, and this one
produced the maximum side effect the script is capable of. Yolanda is
unblocked by merging trunk (both fixes predate their snapshot); 1183-2s7a
lands with their re-gate.

**Pass 23 (2026-09-14T14:11Z) — the flood's refs are gone; nothing to
relay.** Deleted from origin under TILLANDSIAS_SALVAGE_DELETE_OK=1, one push
for the seventeen `---help` refs (toolbx 9, yoga 7, tlatoanis-macbook-air 1)
and one for macbookair's 804deux rescue, whose tip's five files (macneo's
fragments) diff empty against trunk; every deleted ref's ledger line had
carried its ` deleted` mark for at least one full pass (the grace rule from
yolanda's refused gate on 2026-09-13). Origin now holds five salvage refs,
all older than the flood (pirria 3, unknown 2), lines unmarked, refs kept.
Sweep filed nothing new; ledger check ok:26. Drift win=0 osx=0 main=0.
Trunk since pass 22: yoga's claim of 865-r6dt. No messages since yolanda's
12:20Z report; no host idle by report; hosts silent this window (esme,
macneo, lenovinha, pirria) not directed. Stale rows 89/501, none handed.
Audit rows=23 stems=23.

**Pass 24 hold — yoga, 14:30Z: a red release gate whose tree was not red.**
865-r6dt closed as an audit (both defects it names were already fixed,
measured). The finding that matters fleet-wide: litmus:release-gates-run-
locally went RED at step 20/20 on any host running ./build.sh --ci-full with
TILLANDSIAS_FORCE_CHECK=1 in the environment, and the failure named the
wrong thing (`memo hit path wrong`, which reads as broken memoization).
Mechanism, internal to the fixture: case 11 runs build.sh --check and
requires the memo to be TAKEN; case 12 asserts that FORCE_CHECK=1 BYPASSES
the memo; case 11 never cleared the variable, so an ambient forced check
fails case 11 by case 12's own contract. Fixed at be9f971d0 (1184-u5mg), one
assignment; three regimes measured (14/14 clean, FAIL with the variable,
14/14 after the fix with it still set). Not a budget kill: 898.5s against a
900s budget, rc=0. THE TREE WAS NOT RED; THE INVOCATION WAS — say it in that
order, because the first read of a red release gate is "what broke on
trunk". Same class as 1109-t8kw (a fixture that does not construct the
environment it asserts about scores correct behaviour as a failure) and
recorded on that row too. Yoga's second lesson, for the standing list:
reading a silent step cost two wrong conclusions — "stdin inherited and
blocking" (refuted: fd 0 was /dev/null, the shell sat in do_wait on a
child) and "zero CPU means blocked" (refuted: pstree showed a five-deep leaf
pipeline of short-lived plan-binary runs turning over between samples). A
wrapper accumulates no CPU by design: MEASURE THE LEAF, NOT THE PID YOU
HAPPEN TO HOLD — the same error as the stripped-PATH scan the cycle before.
Open hand-off: 1109-t8kw part 2 needs an AT-RISK low-end host (yoga prints
SAFE and has no tier set); route to esme/pirria/macneo when one reports.
Yoga (15:50Z): 1184-tj2q filed and fixed in one cycle (e0d9acca4, closed
89e74080b) — set-field on a LIST-valued field read the list as `<unset>` and
wrote a scalar; one ok: write and the row vanished from every tag query,
including the tags it already had; capability_tags is load-bearing in
847-wgy4's tier gate. Fixed by REFUSING (exit 2; the owner amends the base),
not by teaching the LWW channel to carry sequences. Yoga's own 1151-td46
prose guard had a hole exactly there: it refuses a write that DROPS LINES,
and a list read as unset has no lines to drop. Coordinator's sweep on trunk:
zero set-field writes to any list field in any fragment — no scalarised row
exists. Found on the route: the third consecutive cycle the selector offered
yoga a batch it cannot work (1109-t8kw needs an at-risk floor host; 405
needs provider budget), so yoga went to make the ledger express the routing
and hit the defect. The tier tag for 1109-t8kw is the coordinator's call:
`low-end` added to its capability_tags in the base at this pass.
Macbookair (16:15Z), a BLOCKER in the helper that landed at 12:10Z, measured
exactly: push-plan-fragments-to-trunk.sh refused every relay from every host
with `trunk-fold:violation: … depends_on -> unresolved reference`, 96
referents, none of them any fragment being relayed. Root cause proven by
rebuilding the tree twice: the fold check materialised trunk's index.yaml +
index.d ONLY, and the referents live in plan/archive/packets-*.yaml (tree A
without the archive: violation; tree B with `git archive $base
plan/archive`: ok, 944 packets). Green in every real checkout because the
archive is present there — and the fixture's scratch ledger never had one:
green on one regime, the scratch. The script's own hint ("push its filing
fragment too") pointed away from the cause. Invariants held (HEAD, porcelain,
index, branch unchanged); the hook never ran, so the lane line 1153-j2nm
wants from a platform host is still unmeasured. Fixed at this pass: the
archive extracted beside index.d, and a fixture arm that materialises THIS
repository's trunk fold and requires check to pass, so the missing regime is
measured on every gate. Also from macbookair on 1183-j9dk: the mechanism
they filed was WRONG and is corrected on the packet — not Unix permissions,
not uid: the container is denied at mode 0777, `chown` in the share exits 0
without applying, and `--security-opt label=disable` makes the write SUCCEED
against an Enforcing guest. It is SELinux confinement against that mount;
all three candidate fixes in the deliverable target the wrong layer, and
the chown shape is impossible outright (VZSharedDirectory has no ownership
parameter). The scorable half landed (osx-next 2d1e3661f, relayed this
pass): the entrypoint's mkdir failure is fatal where it happens, naming uid
and mount owner, 7 arms + mutation control, 0/5 red on unfixed code. Open:
the exact AVC — ausearch HANGS on stdin under --exec-guest and hard-killed
two probes; run it `</dev/null`. 804-deux (a) stays blocked.
Macneo (16:12Z): ledger-only cycle landed 1f058bfc5 through the lane;
1084-x8ya skipped deliberately (Rust wiring or a live VM, not a cargo-check
lane — say so, so the urgent marker is not read as the lane ignoring it).
718-jqt5 measured without compiling: criteria 1 and 4 met, but the
reproducibility key is the EPOCH, not a seed (`forgotten` has no --seed;
its own test is named forgotten_is_reproducible_without_a_seed) — restate
criterion 4 and have the command print the epoch it used; criterion 2 unmet
in both halves, and the "absent endpoint degrades to the deterministic
list" half FAILS where the condition is live: experts-probe l0=ready
l1=unset l2=unreachable, a story-shaped question returns a typed
`unsupported:` refusal, rc 0 — a host with a working endpoint cannot see
this. Macneo's own correction, four loop-status entries deep: "experts
report source=absent on this host" was cycle-metrics' artefact being absent,
not the expert layer being down (experts-probe answered); cycle-metrics'
experts field describes its artefact, experts-probe describes the host, and
they are not interchangeable.
Macneo (16:35Z) on 1109-t8kw part 2: verdict word SAFE, TILLANDSIAS_HOST_TIER
unset — does not qualify on either half, same as yoga; positive control
before reporting the negative: the probe re-run with the identity forced off
(useConfigOnly, empty author/committer env) printed AT-RISK, so SAFE is a
real negative. CORRECTION TO THE COORDINATOR'S ASK, worth keeping: I called
it "the memory-tier probe" and it is not a memory probe at all — it is `git
init` + `git commit --allow-empty` in a fresh temp dir, a test of whether git
can manufacture a commit IDENTITY outside a configured repo (macneo has
user.name/email unset globally and still prints SAFE because git falls back
to system user + hostname unless useConfigOnly is set). Nothing in it reads
memory; grepping scripts/ for AT-RISK finds no script by that name (control:
SAFE finds several). A host sent for "the memory-tier probe" would go to
check-gate-memory-floor.sh or measure-inference-tier.sh and measure the
wrong thing. The low-end TIER half is a separate condition; the two got
fused in the ask. Lead for whoever holds the row: if part 2 cares about the
identity fallback, say so by name; if the probe is a proxy for something
else on esme/pirria, check the proxy still holds before those hosts spend
1-2h on the litmus runs. Row still waits for esme or pirria.
Pass 24 (2026-09-14T16:11Z) state: osx-next +3 relayed (macbookair's
1183-j9dk scorable half and their 1153-j2nm measurement); windows-next 0.
Trunk since pass 23: yoga's 1184-u5mg and 1184-tj2q, macuahuitl's
1162-qbrx (land-time gate-step prefix allocation; first live run of the
block on its own land: no collision). 1109-t8kw tagged `low-end` in the
base. The helper's archive fix lands with this pass. Stale rows 89/500,
none handed. Audit rows=23 stems=23. Hosts silent this window (esme,
yolanda since 12:20Z, lenovinha, pirria): not directed.

**Pass 25 hold — esme, 17:12Z: 1155-jurn closed on both Windows hosts.**
Merged by yolanda at e6f675d18; canary 7/7 on both hosts with arm 7 firing
live on each — the wsl.exe transport drops exit status on yolanda too, so
the defect is the platform's, not one host's. Daily macos-tray probe green
(cargo rc=0, 70s cold target); findings in
plan/issues/probe-macos-tray-on-windows-findings-2026-09-14.md. Two
decisions taken by the coordinator on esme's evidence: (1) NO cycle-preflight
advisory for the dropped status — preflight never crosses the hop (`grep
wsl.exe scripts/cycle-preflight.sh` is empty), the condition is permanent,
and a true line firing forever with no action attached trains hosts to skip
the block; the convention lives here instead: A WINDOWS HOST LEARNS THAT ITS
CHANNEL LIES ONLY BY RUNNING THE CANARY — run it before trusting any
wsl.exe exit status, and measure in script files whose stdout tokens
survive the hop. (2) 1155-jurn's caller routing: REFUSE stands (yolanda's
implementation and argument) — a wrapper that reconstructs a status the
transport dropped hides the platform's lie behind a number that looks
measured; refusing puts the choice at the point of use. Esme asked to run
the git-identity probe for 1109-t8kw part 2 (report the verdict word; the
flip is the hand-off).
Esme (17:30Z) on 1109-t8kw part 2: verdict word AT-RISK at the Windows/Git
Bash locus (`git commit --allow-empty` rc=128, "unable to auto-detect email
address (got 'bullo@Esmeraldinha.(none)')" — no global identity; this repo
works only through its REPO-LOCAL identity, which a scratch checkout does
not inherit, the packet's own predicate); SAFE inside the tillandsias-build
distro (autodetect works there). TILLANDSIAS_HOST_TIER unset. The verdict is
LOCUS-DEPENDENT and the row did not say which locus it meant; esme checked
the consequence: scripts/run-litmus-test.sh does not re-exec through
with-wsl2-builder (its only MINGW reference is platform naming), so
invoking it from Git Bash keeps the AT-RISK locus and the measurement is
real; ./build.sh would not. Coordinator's reading: AT-RISK-in-fact on a
low-end host is the property; the env var is the selector's routing, not
the precondition; row flipped to esmeraldinha at the Git Bash locus. Esme's
near-miss, 1155-jurn's shape on a different substitution: the first distro
probe ran `$(mktemp -d)` INSIDE the `wsl.exe -d … -- bash -lc '…'` argument
string; the substitution came back EMPTY in transit, `git init` ran in the
home directory instead of a fresh one, the commit succeeded there, and the
probe printed DISTRO_SAFE about a world it never built — this packet's own
subject reproduced while measuring it. The re-run pipes the script on
stdin, prints its tmpdir, and refuses with PROBE_INVALID when mktemp returns
empty. A value written in the argument string is not the value the far side
sees.
Esme (17:45Z), the hazard's nastier generalisation, FLEET-RELEVANT: the
same first probe did more than misreport. With `$(mktemp -d)` mangled to
empty inside the wsl.exe argument string, `cd` failed ("null directory")
NON-FATALLY and the shell stayed in its inherited cwd — which, for a wsl.exe
call from the harness, IS the live checkout under /mnt/c — so `git init -q`
re-inited the live repo and `git commit --allow-empty` landed an empty
commit ON WINDOWS-NEXT (26ed73ba9, tree-identical to d7db273f3, unpushed,
removed once the litmus run stopped reading the tree). A FAILED cd IS NEVER
NOWHERE: the fallback location is wherever you already were. Any fleet
probe of the form `cd "$(mktemp -d)"; <mutating command>` sent through a
wsl.exe argument string has this shape, and on a host whose branch pushes
automatically it would not have stayed local. Load-bearing guard, in this
order: print the tmpdir, refuse (PROBE_INVALID) when it is empty, and make
the cd FATAL (`cd "$d" || exit`) — the PROBE_INVALID check alone is the
half that only prevents the false verdict. Esme's corrected runner does all
three; the first did none. Part 2 of 1109-t8kw is running at the Git Bash
locus with the AT-RISK probe embedded in the same log as the verdicts
(PROBE_COMMIT_RC=128, TIER unset), never through build.sh. Reading the flip
correctly took esme three tries and the reason generalises: `git show
origin/linux-next:plan/index.yaml | grep` reads the folded BASE, which
fragments override; grepping fragments for the ORDER finds nothing because
set-field addresses the packet by its long packet_id; `tillandsias-plan
status` in a detached worktree at origin/linux-next is the computed answer
(in_progress; `next any` 0). Computed, not grepped.
Esme (17:58Z): 1109-t8kw part 2 MEASURED at the Git Bash locus, closure NOT
met — meta-orchestration 20/3/1 (510s), forge-environment-discoverability
15/9/1 (1163s), both rc=1; the AT-RISK probe re-executed inside the same
script as the runs (PROBE_COMMIT_RC=128, TIER unset). THE SPLIT IS THE
FINDING: (A) six are the row's own class — credential-channel-check-shape
8/10 pins `env PATH=/usr/bin:/bin` and MINGW keeps git only at /mingw64/bin
(proven single-variable: that PATH → missing:no-credential-channel; with
/mingw64/bin → ok:forge-git-mirror); four die on `jq … /proc/self/fd/0`,
absent on MSYS (counted on the shared error text, NOT individually
reproduced — flagged as such); two grade git's CRLF warning as the
verdict, salvage-net-roundtrip step 9 at rc=0. (B) TWO are floor-tier
BUDGET, not assertion failures: capability-manifest-guard (rewritten
af7529a26 under 1114-p2ht) TIMED OUT at a 300s single-step budget (300.6s,
killed and censored) — "red again" would have been true as a verdict and
false as a claim; build-cache-sweep-trigger the same at 30s. (C) THREE
unclassified on purpose: empty `output=` cannot separate an assertion
failure from an absent MCP server from a swallowed error — re-run with each
arm's output captured to a FILE. Coordinator's judgements: part 1's
grep-shaped predicate (git-init-without-identity) undercounts — the sweep
gains a run-based half (exactly esme's method); the six fixes go to a child
row for yolanda by mechanism, group B to its own tier-budget row, group C
back to esme with file capture; 1109-t8kw returns to ready with
next_action naming the children. A worktree C:/wt-cl on branch claim-1109
at f93650214 on esme's host was reported as "not mine" and, ten minutes
later, corrected by esme themselves: `git log -1 claim-1109` names
esmeraldinha, 2026-09-06, their own abandoned claim worktree — "I did not
create it" was not recognising their own work from eight days ago, stated
to the fleet as a fact about the world rather than a gap in knowledge.
Integrated four for four with a positive control; removed on the
coordinator's say-so. The question to yolanda was retracted.
Yolanda (18:10Z): C:/wt-cl was never theirs (no claim-1109 branch, local or
tracking; f93650214 is in their object store as any fetched commit is —
"presence proves nothing either way", said so nobody reads it as evidence
later). The check turned up a stray worktree of THEIR OWN, unknown to them:
C:/Users/…/Temp/tw, detached at b8ac355fb (release 56.8.31.3, 2026-08-31),
survived two weeks and several dozen cycles unnoticed; verified BEFORE
removal (zero untracked, zero modified, tip contained in windows-next,
linux-next and main), 4.5M reclaimed, `git worktree list` now one entry,
main tree clean through it with a land mid-gate. Standing check worth
running per host: `git worktree list` — the whole sweep. Yolanda's
correction of their own earlier claim: "wiring the 1155-jurn fixture into
build.sh makes it inert on the hosts it is about" was true of THEIR
implementation (skipped wholesale off MSYS, so inside the gate's WSL
re-exec it would skip on every host always), not of esme's, which skips
only the live arm while arms 1–6 run in-gate; they generalised from their
own defect; esme's is the one that landed, theirs discarded. Yolanda's
landing in flight: esme's work/1155-jurn merged at e6f675d18 with the
second-host confirmation, 1183-2s7a, 1184-jqqg, the note pinning
1171-ccf2's closure to the NEXT cut, and a record of why two hosts built
1155-jurn. They will take the six-fixture child row from plan_next windows
after the relay; their read of the CRLF-at-rc=0 mechanism: the one most
likely load-bearing elsewhere, since rc=0 is invisible to every caller that
reads only status.
Esme (18:20Z), group C classified with file capture (windows-next 0fbc3ba95;
report plan/issues/litmus-1109-t8kw-group-c-classified-2026-09-14.md): none
of the three was silent by accident — one ends its failing branch in a bare
`exit 1` inside a loop, one has a single silent exit path beside a counting
one, one chains `grep && jq -e && echo` so any broken link yields nothing;
"empty output" was a property of the FIXTURES, never evidence about the
system under test, which is why they cost a second pass. (1) plan-answer-
envelope-citability 6/21 → group A: `jq` emits CRLF on MSYS and `\r` is not
in the default IFS, so word-splitting leaves it on every field but the last
(item 1 len=68 ending `\r`, the same id assigned directly len=67 matches;
the last citation is clean, which is why exactly one of two failed) — the
third CRLF instance, ONE mechanism: on this locus text through a pipe
carries `\r`, and any fixture that word-splits or string-compares it asserts
a property of the host. (2) project-answer-synthesis-refusal-typed 3/10 →
group A: the envelope says inference_reason=endpoint-timeout where the arm
pins endpoint-unreachable; lib-inference-state.sh maps curl 6/7→unreachable,
28→timeout at --max-time 1, and the connect attempt takes ~2s on the Windows
stack against ~0s in the distro — the deadline, not the exit code (esme's
first hypothesis, "curl's dead-port exit differs by platform", was FALSE:
plain curl exits 7 on both; the plain-curl control run before writing it
down is the only reason the plausible version did not ship). (3) citation-
frame-and-caller-relation 8/8 → NOT classified but narrowed: its only silent
exit is `grep -q FAILED && exit 1`, so the empty output DOES establish that
`cargo test -p tillandsias-plan` printed FAILED — real failing tests, not a
build break; which tests, and whether for a Windows reason, needs the cargo
run (314s, the slowest arm in its spec — on a floor host a re-run could
time out and wear group A's colour as a group B red). Net: group A 6→8 with
four mechanisms (PATH pin without /mingw64/bin; /proc/self/fd/0 on MSYS;
CRLF through pipes ×3; a curl exit vocabulary pinned to one locus), one arm
open for a capable Windows host. C:/wt-cl removed; the branch ref
claim-1109 kept (ancestor of all four; a ref costs nothing and is not
deleted on a tidying impulse).
Pass 25 (2026-09-14T18:11Z) state: windows-next +10 and osx-next +4
relayed (esme's part-2 and group-C measurements and reports, the
macos-tray probe findings, macbookair's 1153-j2nm measurement). Filed:
1186-w3ph (windows — the eight MINGW fixture reds by four mechanisms plus
the open cargo arm, for yolanda) and 1187-iij8 (litmus budgets by tier —
the floor measures, a capable host lands). 1109-t8kw back to ready with
part 1's method changed (a run-based half). 1155-jurn: REFUSE recorded as
the coordinator's decision; no preflight advisory. Trunk since pass 24:
1162-qbrx completed, 1153-j2nm completed on macbookair's measurement,
1185-9qx6 filed (the release-tier freshness guard is blind to ci-full —
the index has only ever held pre-build phases), the two release-tier
litmus reds fixed forward, yoga's claim of 1110-c4nf. Stale rows 89/499,
none handed. Audit rows=23 stems=23. Hosts silent this window (lenovinha,
pirria): not directed.

**Pass 26 hold — lenovinha restarted (18:25Z) and asked for instructions.**
Synced, clean. Handed 1185-9qx6 (the release-tier freshness guard blind to
ci-full) as a claim flip on trunk (973835b57; `next linux` reads 0), with
1187-iij8 as the named fallback; cadence 2h at :51; no destructive smoke
(no standing consent on this host); avoid list named (1186-w3ph yolanda,
1110-c4nf yoga, 1183-j9dk/804-deux macbookair, 1109-t8kw part 1 needs an
AT-RISK host). Yoga's 1110-c4nf fix landed at 86ac0e26d (the seed-override
arm's 120s budget aborted the triage litmus before its own step ran — the
budget was the defect, raised to 300s; 1187-iij8's class, on a fat host).
Pirria restarted (18:35Z, CachyOS 7.2.4-3, synced, clean) and asserted that
destructive resets are "expected and intended here" — a peer's standing
consent is not the operator's: no destructive smoke ordered; the Linux
curl-install smoke of v56.9.13.1 on pirria goes to the operator as a plain
ask. Handed as measurements (floor tier, no build): the git-identity probe
(verdict word + tier var; if AT-RISK, 1109-t8kw part 1's run-based re-sweep
at the Linux-floor locus, separating MINGW-isms from floor-isms) and
1187-iij8's two arms timed at their locus as a note on the row; cadence 4h
at :21.
Operator (18:45Z): "Yes I've authorized pirria to run system reset as per
your directions." Recorded as standing consent for the smokes the
coordinator directs on pirria (esme's and macbookair's shape); the
v56.9.13.1 daily-channel curl-install smoke dispatched to pirria with the
operator's words, results to land on linux-next through the lane.
Operator (18:50Z): "Lenovinha is back, which is a much stronger silverblue
host, and Yoga is also around, prefer them for interchangeable linux work."
Routing rule from here: generic Linux rows go to lenovinha first, yoga
second; macuahuitl keeps coordination, relays, the release-tier exercise,
cuts, and host-specific work. Applies to the coordinator's own meta cycles:
drain coordination-shaped rows, hand the rest as claim flips.
Pirria (19:28Z): AT-RISK, TIER unset; 1187-iij8's two arms PASS at their
locus (capability-manifest-guard 182.6s of 300s, build-cache-sweep-trigger
1.7s of 30s; note on the row at 4b5593c4e) — THE FLOOR IS NOT ONE REGIME:
esme and pirria are the same tier by the row's own criterion and the same
arm sits 1.6x apart on opposite sides of the budget; tier does not predict
speed, and a tier-keyed multiplier would find no key on either (TIER unset
on both) — evidence for 1187-iij8's arm (a), a BUDGET tally distinct from
FAIL, and against arm (b); esme's timeout reads as a MINGW-ism. Both spec
suites green on pirria's Linux floor (24/0/1, 23/0/1), which is also part
2's owed artifact on a Linux at-risk host — so the twelve reds esme found
are MINGW-isms, not floor-isms. Caveat pirria did not hide: every
invocation emitted warn:litmus-degraded-no-yq (yq absent, unprovisionable:
the builder is Silverblue-only, pacman wants a sudo password); neither
named arm references yq, so their two verdicts stand; the other 45 arms'
counts need a re-run on a host with yq. 1109-t8kw part 1's run-based
re-sweep flipped to pirria on trunk, to start after the smoke.
Lenovinha (19:50Z): 1185-9qx6 implemented (option (a): record-ci-phase-
result.sh + TILLANDSIAS_CI_RUN_ID through local-ci.sh + build.sh recording
post-build and runtime with real status; fixture 8/8, arm 2 reproduces the
pre-fix never; bound at 345-1185-9qx6), gated green in 993s — and REFUSED
AT THE PUSH: refused:land:auth-failed, "could not read Username for
https://github.com"; the preflight had answered ok:gh-keyring-push-verified
at 18:52Z and answered missing:no-credential-channel at 19:47Z. The gh
credential was EVICTED mid-cycle — 1025-a896's shape (a re-auth on a sibling
host evicts the others'); no re-auth run on lenovinha. Stranded at a LOCAL
salvage ref only (refs/heads/salvage/lenovinha/20260914-1185-9qx6 →
2a9d48d43: dc4721a09 the fix, 2a9d48d43 the records incl. 1188-mm9y), which
survives a re-clone only once someone pushes it. Operator ask: re-provision
the gh credential on lenovinha. Lenovinha's scope correction, adopted:
`./build.sh --ci-full` ALONE exits after the pre-build gate and never runs
post-build or runtime — the tier is exercised only by `--ci-full --install`;
the daily exercise's driver now runs `--ci-full --install` (1122-6sqz accepts
the install). 1188-mm9y (filed, unpushed): the installed launcher's version
label is include_str!(VERSION) at COMPILE time — v56.9.12.x beside a VERSION
of 56.9.13.1 is equally consistent with a stale artifact and a current binary
bumped after its build; nothing distinguishes them because the headless
crate bakes no commit SHA.
CORRECTION from lenovinha (20:00Z): NOT an eviction and NOT a sibling
re-auth — the login keyring LOCKED on lenovinha between the 18:52Z check
and the 19:37Z push (busctl: org.freedesktop.Secret.Collection Locked →
true; gnome-keyring-daemon running; ~/.config/gh/hosts.yml unchanged since
2026-08-20; `gh auth status` HANGS waiting on an unlock a headless session
cannot answer — a sibling re-auth would have produced a clean 401). The
operator's remedy is an UNLOCK on lenovinha, not a re-provision; a re-auth
would have taken the fleet's token out for a lock that a passphrase fixes.
Filed 1189-2ra5 (p1): check-credential-channel.sh has no arm for a
locked-but-present keyring, so that state falls through to
missing:no-credential-channel, whose obvious remedy is `gh auth login` —
the one action 1025-a896 forbids; Locked is a boolean readable over a bus
the guard already reaches; the arm is absent. The salvage ref now carries
three local commits (67b6473dc). The coordinator's first ask to the operator
("re-provision") was wrong and is corrected to "unlock the login keyring on
lenovinha".
Reconciliation reader on 1141-vf9w (not in the story, found on the way): four
of five criteria met and green (test-dispatch-reap 11/11, test-no-competing-
gate 13/13, test-competing-gate-consumer 14/14), but criterion 3 — build.sh
refuses to start beside a stray gate — is unmet in TWO layers: build.sh's
call site ends in `|| true` and discards the detector's exit code, so
flipping TILLANDSIAS_COMPETING_GATE_ADVISORY=0 today changes nothing; and
promotion still needs the detector to accuse a genuine stray on the host
being promoted for, plus 1149-3v3n's wsl.exe host-side call. Yoga's row;
recorded here so the flag is not read as a switch.
Reconciliation on 1063-nraf: the fixture-orphan scan still does not exist
(audit-guard-activation audits check-*.sh, the wrong population); an ad hoc
rescan finds 14 scripts/test-*.sh referenced by nothing today, among them
the coordinator's own test-gate-memory-floor-consumer.sh (1176-fn2p, written
this morning, bound at 067-1176-fn2p this cycle) and macbookair's
test-inference-mkdir-fatal-1183-j9dk.sh (told). A fixture written on the day
of a fix and not bound the same day is the shape the scan exists to catch.
Pirria (20:05Z): v56.9.13.1 daily-channel smoke PASS end-to-end on the
Linux floor (install 262.6s, reset 20.8s, init-pristine 439.9s, forge-lane
822.9s, health 0.2s; version line exact; vault initialized from a genuinely
cold room; 1149-vgn2 verified from both sides). Report at
plan/issues/smoke-e2e-findings-v56.9.13.1-2026-09-14-linux-pirria.md
(2b9cc56a5). The ledger row's claim 900-z3kv is SPLIT: the end state works,
the mechanism is incomplete — the clearer could not remove
~/.cache/tillandsias/vault-data (subuid-owned 100100; rootless rm refused),
printed warn:clear-vault-credentials:partial and EXITED 0 beside three
empty-store assertions; `podman unshare rm -rf` removed it and flipped the
probe warm→cold, and only then did --init derive the first-boot dummy key —
the resync path ran for the first time, after a hand fix. Three findings
filed: the partial clear (with the remedy), the smoke evidence dir never
cleared between runs (a stale 03-init-exit.txt from 2026-09-13 read as this
run's result to an out-of-band poll), and the cold-room lane never reaching
committable work (filed on the in-forge agent's request, who refused to
commit from a doomed container — correct). Coordinator's ruling: the
guard-stop IS §4's expected cold-host outcome; no scoped token. 1134-u934
is fixed in this cut and unclaimed (vault container stops in 1s, exit 0,
against 10s grace; pre-fix 30s and Exited 137) — credited at the pass. Not
checked, named: 1139-xe5m, 1154-8ywc/1165-xkjh, 1118-dwgx, 1159-g96c,
1175-wuwr.
RETRACTION from macbookair (20:15Z) of the 1183-j9dk mechanism recorded
under their name at pass 24: the SELinux-confinement conclusion is
WITHDRAWN. With an empty cache and a freshly booted guest, the packet's own
plain reproduce (`-v <share>:…:rw`, no --security-opt, container uid 1000)
SUCCEEDED 4/4 at 20:06–20:07Z; `ausearch -m avc </dev/null` shows only
unrelated nft denials on /dev/ptmx. The SELinux inference rested on one
discriminator (plain DENIED vs label=disable OK) and the plain run now
succeeds, so label=disable distinguishes nothing; the original
Unix-permissions claim was already dead on the mode-0777 arm. Three
mechanisms asserted and withdrawn on one packet, all macbookair's, and the
drill carried the third on their say-so. Checked-not-assumed invariants:
inference image 91a800b57328 created 07:58Z (before the failing probes),
guest provision.state 03:53Z, host share 501:20 0755 empty, virtiofs
rw+seclabel, Enforcing, container_file_t — not a rebuilt image, not a
reprovisioned guest, not a changed directory. Something state-dependent
separates the ~11:56Z failing regime from the ~20:06Z passing one; NOT
named. State: mechanism UNRESOLVED, defect NOT CURRENTLY REPRODUCING — no
fix is to be implemented against this packet on current evidence.
Recorded on the packet's next_action and in plan/issues/model-share-
denial-mechanism-2026-09-14-macos-macbookair.md ("SECOND CORRECTION"). What
survives: the fail-loud half, now bound (bddf183c1: "inference-mkdir-fatal-
1183-j9dk: 7 passed, 0 failed" in the gate log), and binding it forced a
fix — its uid-0 path called bad(), so a root gate would have refused every
land with a content verdict about a guard it never ran (1141-vf9w's shape);
now STEP_SKIP_EXIT=2, verified across four regimes with an id shim. 804-deux
(a) may be unblocked; macbookair re-measuring through the real engine
self-install path rather than the probe that disagreed with itself.
THIRD CORRECTION from macbookair (20:20Z, supersedes the retraction above):
1183-j9dk DOES reproduce — the probe was wrong, not the defect. The real
engine self-install path fails now, empty cache, fresh guest: "mkdir: cannot
create directory '/home/ollama/.ollama/models/.tools/ollama': Permission
denied". The packet's own reproduce did a SINGLE-level `mkdir -p
<mount>/.tools`; the product does TWO levels (`${OLLAMA_MODELS}.tools/ollama`);
the first succeeds and the failure is creating a directory INSIDE the one
just made — the 4/4 "succeeded" measured a different operation. The stated
reproduce was insufficient and is itself a finding; replaced on the packet
(use the nested form or run the image's entrypoint directly). Mechanism:
first offered as virtiofs attribute-cache incoherence (the same directory
listed 0 0 as a parent entry and 1000 1000 as itself), then NARROWED by
macbookair themselves within minutes: on a fresh boot both reads agree at
0 0, so the 1000 1000 was a within-session view — record it as a CANDIDATE,
not a mechanism. What is solid and reproducible: (1) the entrypoint fails at
the nested mkdir, repeatedly; (2) a single-level mkdir in the mount root
succeeds as uid 1000; (3) a directory the container creates reads uid=0
gid=0 mode=755 on a fresh read — the share does not hold non-root ownership;
(4) chown in the share returns 0 and does not apply. Plain reading: the
container can create an entry in the mount root, the entry comes back
root-owned, so nothing can be created inside it — and the engine needs
exactly that nested create; deliberately NOT called settled ("it accounts
for the observations" was the claim the last three times). 804-deux (a)
STAYS BLOCKED; the cache is left empty on both sides on purpose, because a
populated .tools hides this completely — which is how it survived until the
clean-room smoke. The guest's running image (91a800b57328, 07:58Z) predates
the entrypoint fix, so it still prints the old order-313 WARN and falls
through; once rebuilt, the same failure announces itself FATAL at the mkdir
with the uid and mount owner named — the case the fail-loud half was landed
for. Lesson macbookair states for the drill: three mechanisms asserted and
withdrawn on one packet, and each time the pattern was asserting a mechanism
before re-running the bare failure through the product's own path.
Pass 26 (2026-09-14T20:11Z) state: windows-next +8 relayed (esme's 1155-jurn
canary merged by yolanda with the second-host confirmation, 1183-2s7a,
1184-jqqg, the 1171-ccf2 next-cut note) and osx-next +4 (macbookair's
1183-j9dk fixture bound at 345-1183-j9dk with its root-path skip, the third
correction). Trunk since pass 25: the 19:09Z reconciliation story
(1140-i2b6 obsoleted, 966-7umc completed, four rows released with what is
left), 067-1176-fn2p bound, pirria's smoke report and its three findings as
rows (1188-vixu, 1189-7yvu, 1190-swen), 1134-u934 credited, 1109-t8kw part
1 flipped to pirria, 1185-9qx6 flipped to lenovinha (stranded locally
behind the locked keyring). Stale rows 88/503, none handed. Audit rows=23
stems=23. Hand-offs this window: lenovinha (1185-9qx6, fallback 1187-iij8),
pirria (two measurements, the smoke, then part 1), esme (part 2, done).
Note for the next lander on any host: lenovinha's unpushed 345-1185-9qx6.step
now collides with 345-1183-j9dk on trunk — the first real run of 1162-qbrx's
allocator will be their land, and its `gate-step-prefix: … -> …` line is the
live confirmation that row still owes.

**Pass 27 hold — yoga (20:30Z): 1110-c4nf complete** (86ac0e26d /
d616a1d96 / MO-FULL 6cb07aeee): step 23 of litmus-cycle-batch-triage-shape
now diffs the porcelain and NAMES the paths that appeared instead of
comparing two opaque strings — archive-plan-packets.sh --check's known leak
is attributed by name and no longer convicts the selector; falsified in the
useful direction with a seeded concurrent writer. Step 5's budget raised
120s→300s (2m24s uncontended; it had been aborting the test before step 23
ran; 26/26 now). Two reds left open OUTSIDE that packet, both uncontended on
today's linux-next, same class (the selector at ~14s per invocation against
a 120s arm budget — 1187-iij8's class on a FAT host): litmus:capability-
routing-shape step 1/5 TIMEOUT, and litmus:local-ci-self-clean-evidence step
4/5 rc=1 (centicolon dashboard render). Flagged, not claimed; yoga asked to
file them through the lane as rows with their measurement and take them if
their next cycle has room (interchangeable Linux → yoga/lenovinha).
Yoga (20:45Z): both reds filed and landed at 8f7c1573c — 1191-vrjf and
1192-xv4n, ready. 1191-vrjf is NOT the centicolon renderer: it is a NUMERIC-
LOCALE defect — update-convergence-dashboard.sh formats percentages with
bash printf under the CALLER's LC_NUMERIC, and yoga runs fr_FR.UTF-8;
reduced at the prompt: `printf '%.1f' 89.8989898989899` → rc=1 "nombre non
valable", `LC_ALL=C` → 89.9, and the values printf does accept come out as
"89,0" with a decimal comma into a file other tools parse — the abort is the
loud half, the comma the quiet one; the row says exporting a locale from the
litmus step is not an acceptable fix. 1192-xv4n cites 1187-iij8 with a fact
that row lacked: a FAT host misses the budget by 14% (test-capability-
routing.sh 2m17s uncontended, 8/8 standalone, against 120s), and a second
point in the same suite (cycle-batch-triage-shape step 5, 120s against
2m24s, fixed in passing at 86ac0e26d). The general shape: a budget miss does
not fail one arm, it TRUNCATES the test and the arms after it report nothing
while looking covered; the row asks for a guard on budget-vs-last-measured-
cost rather than a blind sweep. A new regime axis for the standing list: the
caller's LOCALE — a numeric format under LC_NUMERIC≠C is a different
program.
Lenovinha (20:55Z): the operator unlocked the keyring; the salvage ref was
pushed FIRST and verified on origin by ancestry (ok:salvaged:…:5fa2e038f),
then 1185-9qx6 integrated, re-gated green and landed on attempt 1 — evidence
1e3e1e01e (the rebase rewrote the SHA; the earlier dc4721a09 is a ghost,
1024-c3h3), land ok:land:5e92fda4d:attempt-1; record-ci-phase-result.sh,
test-release-tier-freshness-reads-ci-full.sh and 355-1185-9qx6.step verified
on origin by tree. THE ALLOCATOR'S FIRST LIVE COLLISION: a sibling took 345
(macbookair's 1183-j9dk step) during the hour lenovinha's push was blocked,
so the blocked window became exactly 1162-qbrx's race; the land tool moved
345 → 355 (ok:gate-step-prefix:reallocated:1) and landed without a re-gate.
Lenovinha's line for the drill: A PUSH-BLOCKED HOST IS A PREFIX-COLLISION
GENERATOR. 1189-2ra5 is now a real claim on trunk (the flip pushed; the
selector reads 0), worked next on the :51 cadence. Salvage ref
refs/heads/salvage/lenovinha/20260914-1185-9qx6 stays on origin until the
sweep files its line and marks it (22:11Z), deletion the pass after.
Pass 27 (2026-09-14T22:11Z) state: osx-next +2 relayed (macbookair's
attestation); windows-next 0. Trunk since pass 26: yoga's 1191-vrjf and
1192-xv4n filed, lenovinha's 1185-9qx6 landed through the allocator's first
live collision (345 → 355), 1189-2ra5 claimed by lenovinha, the 1162-qbrx
live note. Salvage sweep filed one line (lenovinha's 1185-9qx6 ref, ancestry
none because the land rebased it); all four of its commits are
patch-equivalent on trunk (`git cherry` −), line marked deleted, ref goes at
00:11Z. Stale rows 88/505, none handed. Audit rows=23 stems=23. Hosts
silent this window (esme, macneo): not directed; every capable host is on
its own claim.

**Pass 28 (2026-09-15T05:39Z) — the coordinator was down for seven hours and
the fleet did not stop.** macuahuitl's session ended when the operator's
Fable credits ran out; the operator upgraded and restarted the host (kernel
7.2.4 → 7.2.5) and brought the coordinator back on Opus 5 at 05:39Z, a gap
from the 22:11Z pass. Session-only crons do not survive a restart and were
re-armed by hand (2h coordination at :41 local, 4h meta at :09, daily
release-tier at 09:09); the scratchpad path changed, so the ci-full driver
and the land relay were re-seeded — the driver now runs `--ci-full --install`
per lenovinha's 1185-9qx6 finding.
WHAT THE GAP COST AND WHAT IT DID NOT. Relay backlog at return: windows-next
+11, osx-next +35, trunk +26 — the coordinator is still the only path by
which platform CODE reaches trunk, and a seven-hour absence is a 46-commit
queue. What it did NOT cost is plan visibility: macbookair and macneo pushed
their fragments straight to trunk through scripts/push-plan-fragments-to-trunk.sh
all evening ("plan(tlatoanis-macbook-air): 4 fragment(s) to linux-next from
osx-next"), so claims, closures and filings stayed fleet-visible with no
coordinator in the loop. That is 1153-j2nm doing exactly what it was built
for, measured by a seven-hour natural experiment nobody designed.
LANDED IN THE GAP, all by hosts working their own crons: lenovinha closed
1189-2ra5 (a locked keyring is now named as locked, not as no credential at
all — the row their own blocked window produced), 1125-92xa (the Rust writer
joins the shared metrics path) and 1193-yw6u (TRUNK WAS RED ON MACOS: no
macOS host could land code until the guard regression was fixed at
660e092c8 — "the absence of coreutils is not an answer about the
credential"); pirria landed 1109-t8kw part 1 (two fixtures assumed a plan
binary the host supplies) and then corrected their own yq claim — the
toolbox has it; yolanda got mechanisms 1 and 2 of 1186-w3ph (the PATH pin
that omits where MINGW keeps git; emit_frame reading stdin by fd path, which
MSYS jq cannot open) with a vacuity finding; esme measured 1187-iij8 on the
floor and reports NEITHER PROPOSED FIX WORKS; macbookair and macneo worked
690-w94k (a discarded CFRunLoopRunInMode result turned a park into a spin),
830-xsk2 (the in-guest hop is blocked by seccomp alone) and the 1183-j9dk
retraction chain.
NEW ROWS FROM THE GAP, all three worth the fleet's attention: 1194-davi — a
platform-scoped gate arm is invisible to every host not on that platform, so
it lands through a gate that cannot run it (1194-smtb obsoleted into it as a
duplicate, carrying the symmetry); 1195-m9vi — a macOS host can be wedged out
of the plan lane entirely, not just slowed (macneo's stranded evidence;
macbookair later retracted the independence half and narrowed the row);
1196-5hva — the fleet heartbeat detects a blocker only from a plan/issues
marker, so a blocker filed as a ledger packet is invisible to it (lenovinha,
who then filed against their own exit criteria: "my own exit criteria do not
match reality").
Pass 28, the relay's own finding: the union gate refused with three E0433s
in crates/tillandsias-vm-layer/src/vz.rs — 690-w94k's new test calls
`boot::pump_cf_loop_for`, and `pub mod boot` is #[cfg(target_os = "macos")]
while `mod tests` is #[cfg(test)] only, so it compiles on the author's Mac
and on no other platform. The eleventh regime axis (cfg(target_os)) for the
third time in this file: the two tests immediately BELOW it already carry a
comment from 804-deux naming the failure and the fix, and the new one was
written above them without it. A precedent recorded as a comment beside the
code did not reach the next author — which is the argument for 1194-davi's
notice, recorded there as the mirror-direction instance. Fixed forward on
the relay (gate the test, not the module: a CFRunLoop park-versus-spin is
genuinely macOS-only). Standing rule for macOS hosts, unchanged since
2026-09-13: when a struct or module changes under a cfg, compile the other
platform's arms before landing — `cargo zigbuild -p <crate> --target
x86_64-unknown-linux-musl` does it on a Mac and the lane already has zig.
Pass 28, three more from the hosts while the relay gated:
OPERATOR RULING (via lenovinha, 1196-5hva) — A DURABLE LEDGER SIGNAL NAMES A
CAPABILITY, NEVER A HOST. Their reasoning is the part that outlives the row:
which hosts exist, how many, what hardware, which agents and harnesses run
them are all ephemeral and subject to change, and the system is meant to
converge on "forge" and be agent-agnostic. So a blocker reads "blocked by
linux builder" / "blocked by igpu host" / "blocked by npu host", in some
CRDT-compatible blocked-by field, and never "blocked by yoga". This retired
lenovinha's own design before it landed (it attributed blocks through the
status channel's host field) and needed no new inventory, since the
capability matrix is already the roster source. The distinction to keep: a
CLAIM is a transient fact about who holds a row now and is legitimately
host-keyed; a BLOCKER is a durable statement about what the row NEEDS and
must be a capability token. Applies to this drill's own prose and to
next_action text, which have been writing "needs esme" where they should
write "needs an at-risk low-end host that can gate".
LENOVINHA, 1196-5hva part 3, independent of that redesign and landing on its
own: 864-w7rc's blocked detection HAS ONLY EVER WORKED FOR SILENT HOSTS. The
wedged branch returns before the blocked branch, so a host that keeps
committing never reaches the blocker lookup — and filing what blocked you IS
a commit. A detector that cannot see a host that is talking reports quiet as
healthy. On top of macneo's finding that its trigger value was written twice
in project history: doubly dead.
MACBOOKAIR, correcting the coordinator's own recommendation on 1194-davi
within the hour: `cargo zigbuild --target x86_64-unknown-linux-musl` without
`--tests` builds the LIB ONLY, so it never compiles cfg(test) code and reads
green while looking at nothing — the check their standing pre-land rule ran
before landing the ungated test. With `--tests`: error[E0433] x3, rc=101 on
their Mac. A recommended check that cannot fail is worse than none. Their
probe lesson from the same hour, the shape that bit three lanes tonight:
`git show "$ref:path"` in a for loop under zsh mangles the ref, `2>/dev/null`
hides the failure, and `grep -c` on an empty stream answers 0 — THE ABSENT
RESULT AND THE NEGATIVE RESULT RENDER IDENTICALLY. Byte counts and a positive
control are the standing remedy.
Pass 28, pirria's report and one artifact worth the diagnosis:
AN ORPHANED VERSION BUMP IS NOT AN INTERRUPTED RELEASE. pirria found VERSION
56.9.13.1 → 56.9.15.1 plus Cargo.lock and four crate manifests, uncommitted
and unattributed, written 2026-09-15T00:29Z, and correctly refused to resume
it — tagging and firing a workflow_dispatch is outward-facing and was not
their cadence to take. Diagnosis, positive rather than by absence: build.sh's
install path calls `scripts/bump-version.sh --bump-build` unconditionally
unless TILLANDSIAS_SKIP_VERSION_BUMP=1, and on a new UTC day bump-version.sh
yields <y>.<m>.<d>.1 — 00:29Z is 29 minutes into 2026-09-15, so 56.9.15.1 is
exactly what a local build produces. The release path is EXCLUDED, not merely
unevidenced: merge-to-main-and-release computes its candidate version in a
layout-preserving SCRATCH directory precisely so the real VERSION file is
never touched, and the real bump lands on a release/version-bump-<v> branch
committed in the same breath — an interrupted release leaves a committed
bump on a branch or nothing, never an uncommitted bump on linux-next.
Corroborating: VERSION reads 56.9.13.1 on both linux-next and main, no
v56.9.14 or v56.9.15 tag exists anywhere, and there is no open PR
linux-next→main. Stash dropped; the daily cut goes to the operator as a
question, never inferred from an artifact.
1109-t8kw PART 1 LANDED (224c0f16c, b3ed43dae), and the result is the
argument for the method change rather than just a pass: across 713 files the
three GREP-SHAPED predicates found nothing — tier 13→0, hostname 22→0,
inherited git identity 67→0 — while the fourth, tools-assumed, found two real
hits AND BOTH WERE FOUND BY RUNNING. Hit 2 is the sharper one:
litmus-plan-only-push-lane-shape.yaml step 11 is step 10's mutation control
and was PASSING FOR THE WRONG REASON, because a host with no resolvable plan
binary hands it the refusal it expects for free — the same family as an exit
criterion the unfixed code already satisfies, one level up, in a control.
methodology-accountability at that locus 26/3 → 28/1.
AND WHY THAT LOCUS FOUND THEM: yq was absent from pirria's host PATH, and a
yq-present environment clears the lane's first validator gate and never
reaches the fold check behind it — so an equipped host's sweep would have
reported a clean floor. That is an argument for KEEPING at least one
deliberately under-provisioned locus, not for provisioning this one; nobody
should "fix" that host's tooling on the grounds that it is missing something.
pirria's own correction beside it: they had called yq "unprovisionable" after
reading a script header instead of asking the host, which has it in a
toolbox at v4.47.1 — the degraded counts are owed a re-run as a local chore.
NAMED AND DELIBERATELY NOT CLAIMED by pirria: litmus:release-gates-run-locally
step 20 (gate-stamp memoization, 765-tkq2) passes standalone 14/14 there and
fails only inside the spec run, so the mechanism reads as git-dir-local stamp
state shared across steps 13–20, not a host-inherited precondition. Symptom
match is not membership; left for a linux builder with the mechanism named.
HAZARD from the same artifact, and it survives the diagnosis: pirria did NOT
run that build. Their last gate finished before their 16:35 commit and the
session ended there, so SOMETHING ON THAT HOST RAN A BUILD AT 00:29Z WITH NO
PERSON PRESENT. The bump is harmless; the caller may not be, because
bump-version.sh sits in build.sh's INSTALL path — the path that ends by
replacing the host's installed launcher. An unattended build is an
unattended reinstall, and the fleet already has that shape on record (a gate
run replaced an operator's local build with the tree's label, 2026-09-11),
diagnosable then only because a person had run the gate. pirria is filing it
with local evidence: the build log or $GIT_DIR gate stamp and its mtime,
`systemctl --user list-timers` and any tillandsias unit, whether the tray or
a forge was up at 00:29Z and whether either builds unprompted, and the
installed launcher's --version against trunk's VERSION — if the installed
label moved to 56.9.15.1 the install half fired too, and THAT is the finding
rather than the bump. Standing consequence meanwhile: never reason about
what a host did from its worktree VERSION.
Practice worth copying, from the same exchange: pirria verified the mechanism
on their own host before acting on the coordinator's report (build.sh:878,
bump-version.sh's --new-day arm), and read the stash content before an
undoable drop — 9 lines across 6 files, no work bundled in. Verify, then act;
a drop is not undoable and a report is not a measurement.
MACNEO'S RETRACTION, and the operational question it leaves behind — the most
useful thing to come out of the red-trunk window. macneo had claimed the
plan-lane wedge was INDEPENDENT of the credential guard and that closing
1193-yw6u would not clear it. Wrong, retracted on 1195-m9vi: the wedge
cleared the moment trunk went green. What survives is narrower and better,
because it is a controlled pair — two macOS hosts on the SAME trunk in the
SAME hour, one with plan-lane egress and one without, and the predictor is
STAMP FRESHNESS. macbookair held a valid gate stamp from a land predating the
bad commit, so the lane adopted it and they could still push; macneo held
none and was wedged. SO THE QUESTION TO ASK AT A RED TRUNK IS: WHICH HOSTS
HOLD A VALID STAMP — that predicts who can still speak, and therefore who can
file what blocked them. Runs first at the next red trunk.
OPEN, AND NOT ADOPTED ON A RELAY: macneo reports their operator approved a
fleet-wide blocked-declaration convention (no host currently declares a
blocker in the form the heartbeat reads, so adopting it binds every host, and
methodology makes that scope expansion the operator's each time — yoga
surfaced it rather than agreeing it peer-to-peer, which was correct). macneo
is adopting it on macneo only. The coordinator is NOT propagating it on a
relayed approval: binding six hosts is where "the operator approved this"
and "the operator told the coordinator this" differ, and the operator is
reachable. Put to the operator directly this pass. If confirmed it enters the
standing instructions like cite-by-symbol did. NOTE FOR THE CALL SHAPE, since
two operator decisions landed on one field tonight: `set-field <order> status
blocked --host <host>` composes with the capability ruling ONLY if `--host`
is understood as WRITER ATTRIBUTION — who declared the block — while what
blocks goes in the blocked-by content as a capability token. Stated
carelessly the convention would hard-code the roster into the field the
operator just ruled must not carry it.
RETRACTION, one hour later, of the "unattended build" hazard recorded above —
THE PREMISE WAS FALSE AND THE COORDINATOR IS THE ONE WHO AMPLIFIED IT. pirria
read their shell history: the build was ATTENDED. The operator sat down after
their own upgrade and reboot (boot 17:25:41), curl-installed the published
release at 17:29:00, cd'd into the checkout at 17:29:46, ran `./build.sh
--install` at 17:29:52 — the VERSION bump lands at 17:29:55, three seconds
later — checked `tillandsias --version` at 17:34:20 and exited at 17:34:44.
Every timestamp in the chain belongs to that one human session. pirria also
ruled out the mechanism I asked them to hunt: no user or system timer
mentions tillandsias, no autostart entry, no build.sh reference in any shell
rc, no tillandsias systemd unit at all — so no unattended path exists on that
host to have done it.
THE SHAPE, and it is the coordinator's to own. pirria said "I did not run
build.sh at 17:29", which was TRUE, and then let it imply nobody did; I took
that and escalated it into a fleet hazard with a filing request. Neither of
us read the shell history, which was one cheap command and settled it
instantly. That is absence-of-evidence twice removed: a host reasoned from
its own absence to nobody's presence, and the coordinator amplified a peer's
negative into a fleet finding without asking what would have shown the
positive. Before escalating any "nobody did X" — ASK WHAT WOULD SHOW THAT
SOMEBODY DID, and run that first. Same family as the zsh probe and the
missing-yq inference from the same night: the absent result and the negative
result render identically.
WHAT SURVIVES, and only this: `build.sh --install` leaves VERSION bumped and
uncommitted in the worktree by design, and a later reader who finds it can
mistake it for an interrupted release — which is what happened. The
diagnosis chain above (the release path CANNOT produce an uncommitted bump on
linux-next) stands and is the durable part. Not a fault, no packet, and
pirria was right to decline to file one. Also observed and not a defect: the
install half did fire, so that host's launcher now reports v56.9.15.1, a
label on no branch, overwriting the published v56.9.13.1 its own smoke had
asserted four hours earlier — the operator's own machine, their own command,
and they read the version back immediately afterwards.
THE CAPABILITY RULING IS A UNION, NOT A SUBSTITUTION — refinement relayed by
yoga, and it corrects what this drill said two entries ago. Asked directly
whether the field should be host or capability, the operator answered "use
both: CRDT style". So blocked_by takes BOTH token kinds ADDITIVELY: a
colon-bearing token is a capability (kind:macos, schedulable:npu,
tier:gpu-rocm) matching whatever host answers to it, a bare token is a host
identity, and the reader unions them — two writers can name one block
differently without knowing about each other, and neither write needs
rewriting when the roster turns over. `status blocked --host` therefore works
through the bare-token path exactly as approved. The coordinator had written
"capability, never a host" from the first relay and was about to propagate a
rule that strips a half the operator kept; corrected. The durable guidance is
weaker and truer: prefer the capability, because a bare name is the half that
dies when a host is renamed or retired — do not forbid it. THREE references
now, not two: a CLAIM (who holds the row, host-keyed, expires within the
hour), WRITER ATTRIBUTION on a blocked declaration (who DECLARED it,
host-keyed), and BLOCKED-BY CONTENT (what the row NEEDS, capability
preferred). macneo's cron text named only `--host` and stopped, which says
nothing about the content and would have put the blocker's identity in the
only field the text names; rewritten once pointed out, which is the failure
mode to watch for when the instruction goes out.
A KILLED GATE IS NOT A GATE DEFECT — macneo, correcting their own suggestion
to yoga, and it closes an open question rather than opening one. They had
proposed yoga's killed gate was check-gate-memory-floor.sh failing to refuse
by name; yoga measured instead of accepting it, and the gate's floor check
fired CORRECTLY, reporting 12510MB available against a 1024MB floor with zero
kernel OOM records. The actual killer was the AGENT HARNESS's own low-memory
guard reaping the background command it was tracking — a layer above both the
gate and the kernel, which the gate cannot see, on a 14GB host, so it is not
a floor-tier property and a tier-scoped fix would miss it. 1176-fn2p worked.
This is the same shape macuahuitl measured during a cargo gate with 50 GiB
free, and the REMEDY IS ALREADY IN DAILY USE HERE: take the process out of
the harness's hands — `setsid nohup <script> < /dev/null > log 2>&1 &` from a
script FILE, the script echoing a terminal `rc=` marker, and a Monitor
watching the log for verdict lines rather than the command being held. Every
land on this host is detached that way and none has been reaped since. Passed
to both hosts. Standing rule: when a gate dies mid-run, check the harness
layer before the gate.
AND THE OTHER HALF OF "WHY THE GATE LOOKED STUCK", yoga, same night, two
hours lost to it: their `until ! pgrep -f "build.sh --check"` wait-loops were
matching EACH OTHER'S command lines, so no loop could exit and every new
check reported RUNNING off its siblings — while the gate had been finished
for an hour and fifty minutes. This is the pgrep self-match hazard in its
worse mode: SIBLING match, invisible to the usual remedy of splitting the
pattern, because the literal is not in this command but in the concurrent
one. The symptom is distinctive and worth recognising — A WAIT THAT NEVER
ENDS WHILE REPORTING PROGRESS, where the progress is waiters observing each
other. yoga notes they hit it twice in their own instrumentation after
writing a packet about the same class (the enclave guard accusing its own
fixture two hours earlier). The fix is not a better pattern: STOP ASKING THE
PROCESS TABLE. Have the work write a terminal `rc=` marker as the last line
of a detached script and wait on the MARKER with a Monitor — two waiters on
two markers cannot see each other. That is the same recipe the harness-reap
entry above arrives at from the other side, so one shape closes both: a
script FILE, `setsid nohup … < /dev/null > log 2>&1 &`, an unambiguous
terminal rc= line, and a Monitor on the log.
THE GENERALISATION THAT OUTLIVES BOTH, yoga's, and the reason the recipe is
written as mandatory rather than advisory: A RULE APPLIED BY JUDGEMENT GETS
SKIPPED EXACTLY WHEN SOMEONE IS CONFIDENT, and confidence is what the author
of the rule has — they hit the sibling-match hazard twice in their own
instrumentation on the day they filed a packet about the class. So the
detached-script-plus-rc-marker shape is to be used for EVERY long job, never
for the ones that look risky enough to warrant it. A rule that asks "does
this case need it?" has already lost to the person most sure it does not.
1118-zvai COMPLETE (yoga, 68a7eed68 / 3c2421b16 / MO-FULL 49f523ccf): both
enclave create sites pass --internal, and the guard now sweeps 732 shell and
235 Rust files instead of a hardcoded list of three. LEFT OPEN AND FILED NOT
FIXED, 1193-e6kv: the shell launchers never mention the egress network, so
the proxy — the one member spec:enclave-network requires to be dual-homed —
sits on an internal network with no way out; untouched by this fix in either
direction.
TWO FINDINGS FROM THAT CYCLE WORTH MORE THAN THE ROW. First, THE POPULATION A
CHECK IS POINTED AT IS A REGIME. Pointed at three hand-picked files the
matcher was correct; pointed at the tree it accused four tillandsias-logging
files whose only sin is the word "network" in a log field, and then refused
YOGA'S OWN FIXTURE, whose deliberate bad example is indistinguishable to a
sweep from a real launcher. yoga's formulation: a matcher safe against a list
is not safe at tree radius, and NOTHING ABOUT THE MATCHER CHANGES — only what
it is pointed at. Same shape as promoting a check from --ci-full to --check,
one level down: widening a guard's population is a blast-radius change and
needs re-measuring, not review. Two remedies they rejected, and the reasons
are the reusable part: excluding the fixture BY FILENAME is the instrument
this very order replaced, and an IN-BAND EXEMPTION MARKER is worse than it
looks because the marker travels into the generated temp repo and suppresses
the drift the case asserts, leaving a fixture that passes while testing
nothing. They assembled the verb at runtime instead — the rule this drill
already carries for diff-scanning guards.
Second, A CONTROL THAT PRINTED GREEN WITHOUT CONSTRUCTING ITS PREMISE, with a
mechanism worth naming: re-running old-guard-versus-new AFTER committing the
fix, yoga reverted with `git stash`, which reverts nothing when the change is
already committed. The broken tree was never built, so the new guard duly
said ok. Caught only by the mismatch with the earlier result, not by anything
in the control. Redone by copying the pre-fix files explicitly and PROVING
THE TREE BROKEN FIRST. Standing form: a control asserts its own premise
before it asserts a conclusion, because "I reverted" and "the revert was a
no-op" render identically — the night's third instance of that one shape.

**Pass 29 (2026-09-15T06:11Z) — a quiet pass, and the quiet is the finding.**
Drift zero on both platform branches, nothing to relay, trunk unmoved since
the previous push. Stale rows 89/506, audit rows=23 stems=23. Three live
claims after yoga closed 1118-zvai: 1186-w3ph (yolanda), 1196-5hva
(lenovinha), 1109-t8kw (pirria). No host reported idle and none was directed.
NINE ROWS FILED IN THE LAST TWELVE HOURS SIT READY AND UNHELD: 1187-iij8,
1188-vixu, 1189-7yvu, 1190-swen, 1191-vrjf, 1192-xv4n, 1193-e6kv, 1194-davi,
1195-m9vi. That is a healthy backlog rather than a stall — every capable host
is either holding a claim or draining plan_next on its own cron — but it is
worth naming that the night produced findings faster than the fleet consumed
them, which is what a coordinator outage plus five hosts measuring in
parallel looks like. One of them is LOCUS-BOUND and should not be picked by
whoever is free: 1191-vrjf (bash printf under LC_NUMERIC) reproduces only on
a host whose locale is not C, which today means yoga; a C-locale host would
find it green and report it fixed.
HAZARD, and it is about the fleet's own record rather than the product: THE
PER-HOST CYCLE RECORD HAS GONE STALE WHILE THE WORK IS REAL. Newest
loop_status entries by host at this pass — macuahuitl 09-15, macneo 09-15,
pirria 09-14, yoga 09-14, lenovinha 09-12, tlatoanis-macbook-air 09-06,
yolanda 09-06 — while yolanda landed 1186-w3ph mechanisms tonight, macbookair
landed 690-w94k and the 1183-j9dk chain, and lenovinha closed three rows.
loop_status is where a host's cycle is durably legible to everyone else, and
the metrics audit passes on stem COUNT (rows=23 stems=23) without noticing
that a stem's newest entry is nine days old — so the instrument reports
healthy while the record decays. The cross-host recurrence audit reads the
NEWEST entry per host by design, which means it has been reading nine-day-old
cycles for two hosts and calling that current. Plain ask to each host at its
next report, not a directive: write the loop_status entry at the end of the
cycle, the way the relay taught everyone to push fragments. Worth a row if it
recurs after the asks.
Daily maintenance still reads due:stale:2026-09-14 after the host upgrade and
restart; it belongs to the meta cycle, which takes it at its next fire.

**Pass 30 (2026-09-15T08:11Z) — nothing to relay, and three instrument
defects, one of them the coordinator's own.**
THE COORDINATOR EXECUTED ITS OWN LEDGER PROSE. Filing 1197-82rm, I wrote the
fragment through an UNQUOTED heredoc, which this drill and the coordinator's
own standing memory forbid for exactly one reason: backticked prose is
COMMAND SUBSTITUTION. Three phrases ran on the host — a cargo clean (which
deleted the 586 MiB the meta cycle had just rebuilt), the plan binary with no
arguments (which dumped its usage), and a one-crate release build (which put
the binary back, 39.76 s). Net effect on the host: none, by luck. Effect on
the fragment: three holes where the prose had been, reading "() as part of
the sanctioned action" and "falls through to  on PATH".
THE PART WORTH THE DRILL IS NOT THE MISTAKE, IT IS WHAT DID NOT CATCH IT.
`validate-yaml` returned ok and `check --strict-fragments` returned ok on the
corrupted fragment, because a hole in prose is still valid YAML — the guards
were green on a document whose content had been replaced by command output.
Caught only by reading the command's own output and asking why a cargo clean
appeared in it. A quoted heredoc plus sed for the substitutions is the rule;
the fragment was untracked and never committed, so it was deleted and
rewritten rather than corrected in place.
EXPIRE-CLAIMS AGES AND ATTRIBUTES BY THE WRONG RECORD — filed 1198-7q95, p1,
and it nearly cost a live claim. The sweep reported
"expire-candidate 888-miiy 2026-09-01T23:04:53Z claimant:lenovinha", and on
that basis the coordinator asked lenovinha to release a two-week-old claim.
lenovinha REFUSED THE PREMISE WITH EVIDENCE and was right: the only
in_progress write on that row is dated 2026-09-15T07:36:36Z and landed as
b2f1b4249 "claim(888-miiy): yoga" — 35 minutes before the ask, by a different
host. Verified independently here before filing: both of the sweep's fields
come from the row's newest EVENT (type=progress, 2026-09-01, host lenovinha),
neither from the status write that set in_progress. Under --write it would
have returned a live claim to ready — the 1140-d6ni shape produced by the
instrument that exists to prevent it. A second defect sits beside it: the
status write's host reads `linux`, the PLATFORM, because set-field defaults
it, so two hosts on one platform are indistinguishable exactly when a sweep
needs to know whose claim it is; the agent_id does carry the workstation.
THE CACHE SWEEP REMOVES THE PLAN BINARY — filed 1197-82rm. The sanctioned
end-of-cycle sweep ran a cargo clean and took target/release/tillandsias-plan
with it; the next ledger read failed. It did not break THIS host only because
resolve_plan_binary falls through to the installed copy on PATH — 1172-dyvd's
axis 14 arriving in the maintenance path, so the hosts where the sweep is
harmless are exactly the hosts that cannot observe it. A checkout without an
installed copy loses its plan lane until it rebuilds: 40 s here, minutes on a
floor host, at an unpredictable moment.
LENOVINHA'S GENERALISATION, from their own cycle, and it names the night:
EVERY INSTRUMENT FAILURE THEY HAD WAS IN THE THING WATCHING THE WORK, three
times — a pkill that matched its own watcher shell, the harness reaping their
background waiters twice, and a "stall" they reported that was their monitor
hardcoding gate-attempt-1's log while the land had moved to attempt 2 after
losing a push race. Add yoga's sibling-match wait-loops and this coordinator's
own executed prose and the count for the night is five, none of them in the
work itself. Their loop_status is fixed (559a17ae2) after the coordinator's
ask, covering five landings it had skipped.
MACNEO USED THE FREEZE WITHIN MINUTES of it landing, and brought back a
control lesson about it: their hand query for refs/tillandsias/freeze/
returned empty AND so did a control query for refs/tillandsias/* generally,
so the absence proved nothing until they listed all 546 refs and found the
only non-branch prefixes are HEAD and refs/pull/*. An uncontrolled empty
reads identically whether the freeze is absent or the namespace is
unqueryable. scripts/release-freeze.sh status already separates those — a
failed ls-remote is refused:freeze:unreachable, an empty one from a reachable
remote is ok:freeze-none — and the fixture's set-then-read round-trip is the
namespace's positive control. Use the tool rather than a hand query.
MACNEO on 824-6qxh, released rather than claimed: the floor tier cannot
produce slice (2)'s low-end bands, and NOT for the hardware reason the row
anticipates. measure-bands.sh (at scripts/refusal-calibration/, not scripts/ —
macneo nearly reported the instrument missing after searching the wrong
directory, caught by a positive control) requires --model, --index-dir and
--questions, and its index and queries must share an embedder. On macneo:
experts-probe reports l1=unset with no embed endpoint, and BOTH candidate
index dirs exist but are EMPTY. Two independent blockers. So the slice is
blocked on the floor host having a live embedder and a populated index, and
the qualifying host has neither — an OPERATOR question (provision macneo as
the floor-tier band reporter, or defer the low-end reading and take the bands
from a host that has both), not plan work.
TWO EXPIRY CANDIDATES, dispositioned rather than swept: 1155-jurn is FINISHED
but still reads in_progress on trunk (esme's canary merged at e6f675d18, 7/7
on both Windows hosts) — asked esme to land the closure, since closing on a
message rather than evidence-in-hand is how unfinished work gets marked done.
888-miiy is the false positive above; nothing expired.
888-miiy COMPLETE (yoga, d3c9c929d / 70f1fbea6 / MO-FULL d051efa66):
criterion 4's WITH-endpoint half demonstrated at fixture and gate level, and
lenovinha's no-endpoint half from 2026-09-01 stands as the other side. THE
BRANCH IT REQUIRED CONTAINED THE PACKET'S OWN DEFECT, which is the
transferable part. Scenario 7 of test-groundtruth-corpus-declaration.sh
derives sp_skip by sed-ing `skipped=N` out of a groundtruth-result line; a
HARNESS ERROR prints no result line at all, so the sed yields empty,
${sp_skip:-0} becomes 0, and the condition reads 0 as "nothing skipped,
therefore graded" and announces "ok: this host HAS an index". sp_rc was
captured two lines above and never consulted on that path. A harness error
rendered as a graded result — 888-miiy's own class, inside the arm written to
fix it. THE SHELL DEFAULT IS THE MECHANISM: ${x:-0} did not paper over a
missing value, it invented a FAVOURABLE one. Standing form: whenever a value
is parsed out of a producer's output, consult the producer's exit status on
the same path, and ask of every ${x:-N} what it says when the producer never
ran — if the answer is a specific good number, the instrument cannot report
its own absence.
AND NO ENDPOINT-LESS HOST CAN REACH IT: they return at the skip branch above,
so only the WITH-endpoint side sees it — exactly the half that had never run.
That is the argument for insisting BOTH branches of a two-branch arm get
exercised rather than one, and it generalises past this row.
Falsified three ways on the fixture's own condition, extracted verbatim and
diffed against the source first because a paraphrased condition proves
nothing: fixed+dead grader → BAD naming the rc; fixed+real grader → OK,
graded, unchanged; old+dead grader → the false green. THE MIDDLE ROW IS THE
CONTROL — the change moved the wrong verdict and left the right one alone.
TWO SELF-CORRECTIONS yoga put on the row rather than burying: they claimed
this host had no spec index after checking ~/.cache alone, when it lives in
the podman volume and the litmus precondition text enumerates all five rungs
including that one — and the archived 789-nc2s note records macuahuitl making
the same mistake for the same reason, so it is a repeat at fleet level. And
yoga's own audit of a neighbouring packet on 2026-09-14 cited this arm's
green as evidence the index was supplied; that conclusion survives on other
grounds (the glob independently grades 33/33) but the evidence it leaned on
could not tell a graded run from a dead grader.
PROCESS, worth every host's records: yoga released the checkout lock while
finalize was still pushing the MO-FULL record. Nothing contended and the
record landed clean, but THE RELEASE BELONGS AFTER THE CYCLE'S LAST COMMIT,
NOT AFTER THE MARKER LINE PRINTS — `mo-full-attest.sh record` moves HEAD, so
the marker is derived at a head that still has to be pushed, and the lock has
to cover that push. 892-pfnd checked and does not reproduce on yoga: no
proxy:3128 in containers.conf, proxy running, 54 images — checked, not
assumed.
TRUNK WENT RED ON macOS A SECOND TIME IN TWO CYCLES, AND THE SECOND ONE WAS
THE COORDINATOR'S (1197-y6g6, macbookair; fixed at 490492074). ARM 3b of
test-pre-push-honours-a-live-freeze.sh — landed by macuahuitl an hour
earlier — failed 18/19 on a PRISTINE detached worktree of origin/linux-next
with "./build.sh --check has never run in this checkout". Reproduced here
before changing anything, by running the same fixture with tillandsias-plan
absent from PATH: identical failure on Linux.
THE MECHANISM IS 1172-dyvd's AXIS 14 FOR THE THIRD TIME TONIGHT. The scratch
repo has no target/, so resolve_plan_binary walks past every checkout
candidate and reaches `command -v tillandsias-plan`, which succeeds on a host
with an installed copy and fails on one without. The arm was green on its
author's host because of a candidate NOBODY HAD DECLARED. Of the three lane
fixtures in this tree, the new one was the only one that did not export
TILLANDSIAS_PLAN_BIN — and test-pre-push-plan-lane-after-merge.sh carries a
header about paying for precisely this, read two hours before the fixture was
written. A precedent recorded as a comment beside the code did not reach the
next author, which is the same sentence this drill wrote about 690-w94k
yesterday.
THE OVER-CLAIM IS WORTH MORE THAN THE RED, and it is macbookair's finding:
ARM 3b read as "the plan-only lane is a STAMP-FREE ESCAPE HATCH", and the real
contract is stamp-free but NOT validator-free (1124-7f3u fails it closed
without one). That distinction is load-bearing because the escape hatch is
what a host with a red trunk depends on to keep writing to the ledger at all
— 1195-m9vi's subject — so an unwritten precondition on it is worth STATING
rather than papering over. The arm was not made to pass by restoring the
stamp it deliberately removes: it now names the real contract, resolves and
exports the validator, prints the lane's own decline reason on failure
instead of grepping only for FROZEN|refused and swallowing it, and SKIPS BY
NAME when no validator resolves so a host without tooling cannot red the gate
for missing tooling. Verified both ways: 19/19 with a validator, named skip
and 18/18 without.
SCOPING CALL on 1194-davi, since macbookair asked and the coordinator holds
that row's shape: IT KEEPS ITS SCOPE. 1194-davi is about arms SCOPED to a
platform, in both directions, and its deliverable is a notice derived from the
scoping itself. What bit here is a different class with an established remedy
— an undeclared host candidate (1172-dyvd: a fixture must shadow or declare
every path the code under test consults). Widening 1194-davi to cover both
would hand it an inventory it cannot derive and blur the one thing it can
mechanise. Recorded instead as the third axis-14 recurrence; 1197-82rm is the
maintenance-path instance of the same axis, filed an hour before this one.
890-y72v COMPLETE (yoga, 4fc7be930 / 8f19d7671 / MO-FULL 359438f00): wire
v3→v4, DeliverCredentialsReply carries an accept/reject discriminator, three
tray sites consult it. CLOSED PARTIALLY ON PURPOSE, with the remainder filed
as 1200-ih38 and the trap named: `Accepted` means STORED AND PERSISTED, not
"authenticates against a live vault", and the share that does not open the
vault — the operator's 2026-08-17 failure, the case that produced the packet
— still reports Accepted, because nothing on the deliver path asks the vault
anything (the unseal happens later in ensure_vault_running, spawned after the
reply is sent). Widening the word would have reintroduced this packet's own
failure mode one level up. The trap on the remainder: a host with no vault
running must NOT manufacture a Rejected, because "could not check" and
"checked and refused" are different answers and `Unstated` already exists for
the first — a three-way world, refusing to be flattened into two.
THE VERIFICATION LESSON, and it is the fleet's third instrument finding today:
`cargo check -p tillandsias-macos-tray` on Linux COMPILES ONLY THE CRATE'S
DEPENDENCIES — a deliberate syntax error planted in the target file produces
ZERO errors and rc 0. "I cross-checked it" can mean nothing was checked. yoga
held the change unlanded on work/890-y72v until macbookair compiled it, and
macbookair falsified their own instrument first: planted error → rc 101, two
errors on lib AND --tests; restored byte-identically → rc 0. Neither host
overclaimed — the report reads "the types line up at all seven sites on
macOS", NOT "macOS verified", because a compile is not a run and the v3→v4
behaviour against a live guest is unproven by either. Same shape as
macbookair's zigbuild-without---tests finding this morning: PLANT A
DELIBERATE ERROR AND CONFIRM THE INSTRUMENT REPORTS IT before trusting its
green.
A NUMBER STANDING PROXY FOR A REFUSAL, made explicit rather than left silent:
the v4 bump is safe only because the handshake refuses a mismatched peer, and
macbookair's p2 on 54a9471a1 established that neither refusal is tested —
what is pinned is the version CONSTANT. yoga's change lays a second
transition on that unproven mechanism; they offered to hold, macbookair
argued that holding does not make the refusal tested and only leaves a live
defect standing, and yoga accepted. macbookair has taken the refusal test as
their next slice. Ask of any constant-pinning guard what BEHAVIOUR the number
stands in for, and whether that behaviour is tested anywhere.
THREE THINGS CAUGHT BY GUARDS RATHER THAN BY THE AUTHOR, which is the system
working: the version pin went red on the legitimate bump; the pre-push hook
refused the work/ branch for want of a gate stamp, and RUNNING THE GATE
RATHER THAN REACHING FOR --no-verify is what surfaced the pin; and
macbookair's --tests advice found error[E0063] in yoga's OWN crate — plain
check rc=0, --tests found a broken fixture — before anything else ran.
AND YOGA'S SELF-CORRECTION, which is the sharpest line of the exchange: they
said all seven sites would break at compile time. Three did not. Those three
match `{ success: true, .. }` and THE REST PATTERN ABSORBED THE NEW FIELD
SILENTLY — so they needed rewriting rather than getting a reprieve, and "a
reader trusting the compiler would have shipped the old behaviour under a new
wire version". A rest pattern makes the compiler stop being a change detector
exactly where you are relying on it to be one.

**Pass 31 (2026-09-15T10:11Z) — osx-next relayed, and the coordinator's own
red is closed on the macOS side too.** windows-next 0, main 0, osx-next +12
relayed in one land: macbookair's 1084-x8ya criterion-4 pin (a guest still
coming up is not a failure), step (b) landed at 5ba5e30ea with (c) routed on,
and their records for 1197-y6g6 — including the sentence this coordinator
adopted verbatim into the fixture, THE LANE IS STAMP-FREE BUT NOT
VALIDATOR-FREE. One code path in the relay (the macOS tray's diagnose.rs), so
a full gate rather than the lane. Stale rows 88/507, audit rows=23 stems=23,
no live freeze, no gate-step prefix collision.
1155-jurn REMAINS in_progress AND REMAINS UNTOUCHED. It is the one expiry
candidate left after 888-miiy closed, and it is the finished-but-open case,
not a stalled one: esme's canary merged at e6f675d18 with 7/7 on both Windows
hosts. esme is offline and the ask to land its closure is queued for their
next connect. NOT expired and NOT closed from here — closing on a message
rather than evidence in hand is how unfinished work gets marked done, and the
expiry sweep that would otherwise have swept it is itself under repair
(1198-7q95), so acting on its list right now would compound two faults.

**Pass 32 (2026-09-15T12:11Z) — nothing to relay, and the sharpest hazard of
the pass is that the gate caught a rule its author already holds.** All three
siblings level: windows-next 0 ahead, osx-next 0 ahead, main 0 ahead. Every
host's landed work is on trunk, so there is no relay this pass and no land of
somebody else's commits — the first pass since the restart where the
coordinator's single-point-of-failure role had nothing queued behind it.
ARM 4 OF MY OWN 1198-7q95 FIXTURE WAS WRITTEN AS `if ! <pipeline> && [ … ]`
AND THE LAND REFUSED IT, rc 3, 795-imz3. The refusal is correct and the shape
is 1076-kft9: under pipefail a SIGPIPE from `grep -q` can invert the guard, so
the arm could have passed for the wrong reason — in a fixture whose ENTIRE JOB
is to discriminate one output from another, and which I had just finished
arguing needs no mutant because arms 1 and 2 differ in output rather than in
source text. That argument was right and it did not protect arm 4. The rule is
in this coordinator's own memory, written down, and it was skipped anyway,
while writing carefully, on a row about instrument correctness. A rule applied
by judgement is applied when you remember it; the gate applies it every time,
and that difference is the whole reason the gate step exists rather than a
paragraph in a skill. Fixed by capturing the count and the token into
variables — no arm in that fixture now consults a pipeline's exit status.
THE CHANNEL IS RIGHT NOW AND THE GRANULARITY IS STILL WRONG. With 1198-7q95
landed the live sweep reports exactly one candidate, 1155-jurn, and reports it
as `claimant:windows`. That is the correct host string: it is what the claim
recorded, and 772-4se9 makes the platform default deliberate. But esme and
yolanda are BOTH windows, so the sweep that now reads the right channel still
cannot say which of two hosts holds the row. An hour ago this coordinator
asked the wrong host to release a live claim because the sweep read the wrong
channel; the same wrong message is still constructible from a sweep that reads
the right one, one layer down. That is 1201-hsf9, filed this cycle with three
routes and no decision, and it is the transient counterpart to the operator's
ruling that a BLOCKER names a capability: a blocker should name a capability
because the roster is ephemeral, and a claim should name a workstation because
only a workstation can be asked to let go.
THE RECURRENCE INSTRUMENT HAS ZERO INPUTS, FLEET-WIDE, THREE DAYS AFTER THE
RESTART. `scripts/loop-status-metrics-audit.sh` reports rows=23 stems=23 — no
dropped stem, the check that matters for the two-host trigger — and then
reports 23 of 23 stems NOT-PASTING. Every host, including macuahuitl: my own
last paste was 2026-09-05. So `recur:` and `skippable:` have had no fleet data
for ten days, which means the cross-host recurrence audit that is supposed to
run once per pass has nothing to audit and cannot, even in principle, fire its
two-or-more-hosts trigger. The audit's own rule says an empty result is a
finding about the HOST and never "no candidates"; twenty-three empty results
is a finding about the instrument's reach. It is an order-531 shape one level
up: the audit reads as running because it produces output every pass, and the
output is the same null every time. Not filed as a new row this pass — it
belongs to the existing metrics work — but recorded here so the next
coordinator does not read a clean audit line as a clean fleet.

**Pass 32 addendum (2026-09-15T12:20Z) — the pass-32 record above is WRONG
about macbookair, and their correction is sharper than the thing I got right.**
I wrote that their slice "was taken by message" and that from trunk this is
indistinguishable from an idle host. The inference was right and the premise
was false: they DID file it, 1201-t6ms, flipped to in_progress this cycle,
committed locally at cfa791d41 — and they verified my blindness rather than
asserting it, running `git grep -l 1201-t6ms origin/linux-next -- plan/index.d/`
with a control search proving the probe discriminates. The claim is riding an
IN-FLIGHT LAND that is still in the gate.
THE REAL SHAPE IS ONE LEVEL DOWN FROM MINE AND THEY NAMED IT THEMSELVES: the
claim fragment was batched into the same commit as the code and handed to a
gate, so from trunk it is silence for the whole duration of a build — minutes
on that host. The plan-only lane exists precisely so a claim does not wait on
a build, and the discipline is to push the status flip ALONE, BEFORE the work
starts. They have taken that as the rule and will push 920-pxg6's flip to
osx-next as a plan-only commit before starting. So the coordinator's
"indistinguishable from silence" was true of the window, not of the host, and
the remedy is the lane rather than a message.
A COLLISION I ALMOST ESCALATED, DISSOLVED BY ONE COMMAND. Their 1201-t6ms and
my 1201-hsf9 share an order number, allocated minutes apart on two hosts,
because `next-order` reads the fold of the local branch and a packet in flight
through a gate is invisible to it. I was about to file that as a hazard — the
same in-flight-is-silence shape hitting the allocator instead of the claim —
and checked first: `ls plan/index.d | grep -oE '[0-9]{3,4}-[a-z0-9]{4}' | sort -u
| cut -d- -f1 | sort | uniq -c | awk '$1>1'` returns FIFTEEN order numbers
already used twice or more, including 1176, 1194 and 1197, all filed by this
coordinator in the last two days. Duplicate order numbers are the ledger's
normal state and the four-character suffix is load-bearing, which is why every
reference in this file carries it. Not a defect, and the check that dissolved
it cost one command against a paragraph of prose I would have had to retract —
the pirria shape from pass 29, caught before broadcasting this time.
THEIR FINDING IS WORTH MORE THAN THE STATUS THEY WERE ASKED FOR. 1201-t6ms is
the SERVER-side wire-version refusal: the server refuses a mismatched client at
`if first.wire_version != WIRE_VERSION` by logging and returning, nothing
exercised it, and v3 and now v4 both rest on it. Two tests, and the second is
the one that matters — a positive control requiring a MATCHING peer to still
get its HelloAck, because the refusal alone asserts "you got nothing" and a
dead handler satisfies that perfectly. Deleting the branch reds the refusal
while the control stays green, which is what proves the mutation was surgical.
It also corrected their own p2 that yoga had relied on: they had claimed
NEITHER refusal was tested, and the client half was covered by 1032-62rx. The
asymmetry is the finding — that test's own doc says the client arm is
UNREACHABLE against a current server, so the tested arm serves only a peer old
enough to answer without validating, while the arm gating a live mismatched
peer was the untested one. A test can be green, real, and pointed at the
reachable half of the pair.

**Pass 32 addendum 2 (2026-09-15T12:24Z) — macneo answered with the REGIME and
the regime was the whole answer, and the floor tier turns out to be blocked on
tooling rather than on being the floor.** I asked for the yq question before
the counts and named "yq is absent here too" as a complete answer; macneo
returned exactly that and ran nothing, rather than producing 47 numbers that
would have repeated pirria's caveat. A second DEGRADED run is not a second
regime. That is the instruction working, and it is cheaper than the run.
THEIR PROBE WAS BETTER THAN THE ASK. `command -v yq` was checked under BOTH
the agent's non-login PATH and an augmented one carrying ~/.cargo/bin,
/opt/homebrew/bin and /usr/local/bin — deliberately both, because PATH
composition had produced a false MISSING on that host earlier this week — with
`command -v jq` resolving to /usr/bin/jq as the control that the probe
discriminates. They then checked the runner's SECOND source,
${PROJECT_ROOT}/target/litmus-runtime/bin/yq, with a tree-wide find controlled
by locating target/release/tillandsias-plan the same way. Two sources, two
controls, one negative that can be trusted. This is 1172-dyvd axis 14 answered
BEFORE it bit, on a host that had every reason to answer it carelessly.
AND THE DISTINCTION THAT MAKES IT ACTIONABLE: pirria's yq is UNPROVISIONABLE —
the runner's auto-provision branch requires `toolbox`, which is Silverblue-only
— while macneo's is one command away, brew present at /opt/homebrew/bin/brew
and yq a bottled stable formula at 4.53.6. So the 45 arms that currently have
NO host in the fleet able to produce them have a candidate. macneo did NOT
install it, and was right not to: adding a package to a workstation is a
configuration change of the same class as the embed-endpoint provisioning
already queued on 824-6qxh, and not a cargo-check-only lane's call to make
unilaterally and report afterwards. It is now ONE operator decision, not two.
THE SHAPE, WHICH MACNEO NAMED AND WHICH BELONGS HERE INDEPENDENT OF ANY ROW:
this fleet now wants THREE floor-tier measurements from macneo — 824-6qxh's
low-end bands, 1187-iij8's yq-present arms, and 1109-t8kw part 2 which they
disqualified on SAFE — and TWO OF THE THREE ARE BLOCKED ON THAT HOST LACKING A
TOOL OR AN ENDPOINT rather than on anything about its tier. This sharpens the
standing rule that an under-provisioned locus is an instrument: it is an
instrument for the code paths an equipped host cannot reach, and it is sparse
in precisely the ways that stop it REPORTING what it reaches. Both halves are
true at once. The remedy is not to "fix the floor" — that would destroy the
instrument — but to distinguish the sparseness that is the measurement from
the sparseness that is only a missing binary, and to provision the second
while leaving the first alone. yq is the second kind; so is an embed endpoint.

**Pass 32 addendum 3 (2026-09-15T12:33Z) — THE RELEASE TIER HAD NEVER RUN ON
YOGA, AND IT HAS NEVER RUN HERE EITHER.** yoga landed 890-27mv's cadence half
(b1f4ada5e, attested 5223471de, both verified on trunk) and left the row
in_progress, correctly: its bar is a fresh green and the first full-tier run
was red. The number is the report. `never:release-tier`, 35 records on that
host, EVERY ONE phase-only. One run produced THIRTEEN red litmus tests on a
machine that has completed attested cycles daily for weeks.
I RAN THE SAME CHECK HERE BEFORE WRITING ANY OF THIS DOWN, and macuahuitl
answers `never:release-tier:no target/convergence/check-logs.jsonl on this
host — the release tier has NEVER been exercised here`. There is no
target/convergence directory at all. This is the COORDINATOR: the host that
relays every platform branch, lands for hosts that cannot, and gates what
reaches trunk, and it has never once run the tier the release gates on. The
daily 09:09 exercise exists as a cron and has not yet fired since the restart.
So yoga's thirteen reds are not a yoga finding; they are the first sample from
a fleet where nobody knows what the release tier says about their host, and
the coordinator is the least-sampled host of all.
THE MECHANISM, WHICH IS THE PART TO CARRY: one of the thirteen was YOGA'S OWN
and it is the packet's thesis landing on its author. Their 3 -> 4 WIRE_VERSION
bump in 890-y72v (4fc7be930, on trunk) broke litmus:guest-container-metrics-
wire-shape step 2/7, which pins the constant from the observability-metrics
side. It landed GREEN — through `./build.sh --check`, through a work/ hand-off,
through macbookair's macOS compile — because --check DOES NOT EXECUTE THE QUICK
TIER. THE PIN WORKED AND THE CADENCE DID NOT, and it sat red for days with
every gate in the fleet reporting success. They fixed the literal, named what
earned it per that step's own comment, and swept first: only two live pins on
the constant exist repo-wide, both now 4. That is the sweep-before-edit
discipline doing its job, and it is worth saying that the defect was found by
RUNNING THEIR OWN WORK rather than by review.
FILED AS 1201-9it2 (verified on trunk at
plan/index.d/20260915t125500z-1201-9it2-cross-tier-blind-spot-yoga.yaml): a
pre-land NOTICE naming the arms a change touches that the author's gate will
not run, advisory and not refusing, silent when nothing tier-scoped is touched
— its own two negative controls. Filed at macbookair's hand-off because this
coordinator ruled 1194-davi keeps its PLATFORM scope; 1201-9it2 is the same
structure cross-TIER on a single host, which is the right split.
FIVE OF THE THIRTEEN ARE 1187-iij8's CLASS AND THEY ARE NOT CONTENDED — the
runner's own cpu.pressure line says so. cycle-batch-triage 14/26 at 15s,
capability-routing 1/5 at 120s, forge-experts-discoverability 10/13 at 30s,
and both mirror container arms at 300s and 420s. With pirria's floor numbers
and esme's MINGW kill that is now five data points across four files, and it
argues for the GUARD 1192-xv4n proposes over five hand-raised budget numbers.
It also settles the direction pirria's measurement pointed: budgets are not a
tier problem, they are a budget-tally problem.
TWO MORE OF YOGA'S OWN DEFECTS, both caught only by running their own work.
The installer REFUSED ITS OWN TEMPLATES, because its placeholder guard matched
the comment that documents placeholders — a guard reading its own
documentation as the thing it forbids. And a fixture arm passed VACUOUSLY:
`grep -l` over files that do not exist prints nothing, and on the first run the
render had failed entirely, so the arm reported green about a world that had
not been built. That is the eight-MINGW-fixtures shape (1186-w3ph) reappearing
in a different file, and it is why a negative needs a positive control.
NOT ARMED, AND CORRECTLY NOT: the timer is written, gated and fixture-covered
but not enabled on yoga. Installing a recurring job changes host state outside
the checkout and outlives the session, and 856-s56y's precedent is that the
OPERATOR runs the installer. `scripts/install-release-tier-timer.sh
--interval 24h`, per host. Queued to the operator as its own ask, alongside
macneo's provisioning — both are "let a host report what it cannot currently
report", and both are configuration changes no agent should make for itself.
THE HANDSHAKE CORRECTION ARRIVED TWICE, INDEPENDENTLY, WHICH IS THE FLEET
METHOD WORKING. yoga's landed commit said "neither handshake refusal is
tested"; macbookair reached the same correction from the other side while
landing the server half (cfa791d41, relayed this pass). The client side WAS
tested by 1032-62rx. Two hosts converging on one retraction without either
being told is worth more than either's confidence was.

**Pass 32 addendum 4 (2026-09-15T13:02Z) — correcting the label I used one
addendum ago, because yoga retracted it and my own text carries it.** Addendum
3 called the five not-contended budget misses "1187-iij8's CLASS". yoga has
since withdrawn that framing about their own report: they described the five
that way "as though tier were the axis", and on the cross-host data the axis
is not tier at all. The label is wrong even though the sentence after it is
right — addendum 3 goes on to say budgets are a tally problem and not a tier
problem, so the record contradicts its own heading. 1187-iij8's title is about
a FLOOR-TIER timeout, so naming that row as the class silently reasserts the
axis the evidence removed.
WHAT THE FIVE ACTUALLY SHARE is a budget miss tallied as an assertion failure,
on hosts that the runner's own cpu.pressure line says were NOT contended. The
three regimes agree with each other and disagree with the tier story: pirria
at the Linux floor came in at 182.6s against a 300s budget and was NOT killed;
esme was killed at 300.6s on the SAME arm at the MINGW locus; yoga's five
misses are on a fat host. A floor host under budget, a fat host over it, and a
kill that reads as a MINGW-ism. Tier does not predict speed. The class is
BUDGET-TALLY, it is 1192-xv4n's subject rather than 1187-iij8's, and yoga has
said they will not carry the tier framing forward. Neither will this file.
Worth keeping as a shape: a correct conclusion can travel under a wrong label,
and the label is what the next reader greps for. This one would have routed a
tally fix to the floor-tier row for as long as the phrase survived.

**Pass 32 addendum 5 (2026-09-15T13:58Z) — TWO OF THIS COORDINATOR'S OWN EXIT
CRITERIA WERE WRONG AS FILED TODAY, both caught by the implementer reading the
code, and they are the same shape.** yoga landed 1187-iij8 arm (a)
(35193f5dd, attested 872a94aa3, both verified on trunk) and asked for a ruling
instead of quietly satisfying the criterion — the right call, and the criterion
is mine.
CRITERION 1 AS I WROTE IT WOULD HAVE BUILT A FAIL-OPEN GATE. It says a step
killed at its budget is "tallied as BUDGET, not FAIL". Literally implemented, a
step that ran out of clock stops failing: a spec goes green on steps that never
finished, and a release passes on a machine slow enough that nothing completed.
820-c8q8 — completed, titled
`litmus-timeout-cannot-distinguish-a-regression-from-a-busy-host` — settled
that a timed-out step still FAILS, and the runner's own rc=124 site says so in
as many words, "Reported, never used to change the verdict". I did not look it
up before filing. esme flagged the same reconciliation when they RELEASED the
row; yoga hit it while implementing. Two hosts reached it independently and
neither of them wrote it.
RATIFIED: TESTS_BUDGET_KILLED counts IN ADDITION to TESTS_FAILED, never instead
of it — step fails, spec fails, run exits non-zero, and the summary gains one
line only when non-zero, worded as a SUBSET of the FAIL above rather than a
sibling. That serves what the criterion was FOR (a closure row reading "7 FAIL"
cannot tell seven broken assertions from seven steps that ran out of clock)
without doing what it said. Verified here as a second regime:
scripts/test-litmus-budget-tally.sh -> ok:litmus-budget-tally:7.
THE OTHER ONE WAS THIS MORNING. 1198-7q95's criterion 3 said a row with events
and no status write must never be aged off an event; reading the code showed
that fallback is deliberate under 672-bz7u, and implementing the criterion as
written would have deleted a working guard. So: two criteria, one day, both
filed by the coordinator, both specifying a remedy that silently reversed a
settled decision the filer had not looked up, both caught by whoever went to
implement them.
THE SHAPE, and it is the useful part: A CRITERION THAT NAMES THE OUTPUT THE
CLOSURE NEEDS IS SAFE; A CRITERION THAT NAMES THE MECHANISM IS A DESIGN
DECISION WEARING A TEST'S CLOTHES. "The closure must be able to distinguish a
budget kill from a failed assertion" is checkable and leaves the design open.
"Tally it as BUDGET, not FAIL" is a patch written by someone who has not read
the code, ratified by the act of filing, and handed to someone whose job is
made to look like compliance. The filer is the person LEAST likely to notice,
because the criterion reads as an obvious consequence of the symptom that
prompted it. The remedy is not more care while filing — it is that a criterion
naming a mechanism must cite the decision it is consistent with, or say
explicitly that it has not checked.
BOTH IMPLEMENTERS DID THE RIGHT THING AND IT COST THEM A ROUND TRIP EACH.
That is the tax this shape charges, and it is paid by the wrong person.
ARM (b) IS WITHDRAWN, NOT DEFERRED: pirria 182.6s under a 300s floor budget and
NOT killed, esme killed at 300.6s on the same arm at MINGW, yoga's five
not-contended misses on a fat host. Tier does not predict speed.
FOUR DEFECTS IN YOGA'S OWN FIXTURE, one family, worth the drill as a set:
test data indistinguishable from the thing it describes. No bindings registry
in the throwaway root, so the runner refused at rc=3 and FOUR arms reported
green over a run that executed nothing; the premise arm added to catch that
matched the spec NAME, which appears in the runner's own "selected 1 test(s)
and executed NONE" line, so it passed on the very message saying nothing ran;
an `echo "ok: probe"` interpolated into a double-quoted YAML scalar rendered
`command: "echo "ok: probe""`, which the runner SKIPPED rather than erroring
on, reading as success to an absence assertion; and the gate refused the
fixture under 721-77yu for carrying a bare `litmus:<name>` token no declared
test provides. THAT LAST REFUSAL IS CORRECT AND YOGA DID NOT WORK AROUND IT —
the fixture manufactures the test inside a throwaway root rather than claiming
it, so the name is assembled at runtime, the same remedy 1118-zvai used when a
repo-wide sweep refused its own fixture's test data. 913-27ex caught two of the
four; 721-77yu caught the fourth. Each guard was written by someone bitten the
same way, which is the whole argument for writing them down.

**Pass 33 (2026-09-15T14:11Z) — nothing to relay, and the third near-miss of
the day dissolved by enumerating instead of concluding.** windows-next 0 ahead,
osx-next 0 ahead, main unchanged; no host has filed a report in the thirteen
minutes since pass 32 closed, which is what a fleet mid-slice looks like. Six
rows in_progress, one expiry candidate (1155-jurn, esme's, untouched by
design), audit rows=23 stems=23, stale-ready 88/507.
I ALMOST FILED A DEFECT AGAINST THE LEDGER AND AGAINST A HOST THAT HAD DONE
EVERYTHING RIGHT. macbookair pushed a status flip for 920-pxg6 to in_progress
at 12:33:14Z — alone and first, exactly the discipline this coordinator asked
them for an hour earlier — and the fold still reads `ready` with plan_next
OFFERING the row. Read two ways, that is "the claim did not take", which would
have been a serious instrument finding: the discipline produced no protection.
The enumeration says otherwise. Every status write on that packet_id, in order:
in_progress 09-13T11:51:14Z, ready 09-13T11:55:23Z, in_progress
09-15T12:33:14Z, ready 09-15T12:37:28Z — all host=macos. They claimed it, did
the darwin half, and RELEASED IT BACK four minutes later because only their
half was done. The fold is correct, the flip took, and the row is claimable
because there is claimable work in it.
THAT IS THREE TODAY, AND THEY ARE ONE SHAPE. The 1201 order number shared with
macbookair, which fifteen prior duplicates showed to be the ledger's normal
state; this; and pass 29's pirria hazard, which their shell history dissolved.
Each time the wrong answer was AVAILABLE FROM THE SAME DATA and each time it
accused someone. The discriminator is never care — it is enumerating the
outcomes before comparing, because a two-way read of a three-way world returns
a specific falsehood rather than a shrug, and the specific falsehood is what
gets sent to the host. One `grep` over the status channel cost less than the
message I would have had to retract, as it did the other two times.
STALE-READY, SURFACED NOT CLOSED: 1201-t6ms reads `ready` and a landed commit
cites it (cfa791d41, on trunk via this pass's predecessor). macbookair wrote
that `ready` DELIBERATELY — "release 1201-t6ms as landed" — so the claim was
released correctly and the terminal status was not set, which leaves finished,
landed work sitting in the ledger as unfinished. That is 1155-jurn's shape
mirrored: one is finished work reading in_progress, this is finished work
reading ready. Surfaced to its owner with the evidence, never closed from here;
the row's own verification is theirs to run. 1183-j9dk is the other candidate,
four citing commits, and it is a live blocker under 804-deux rather than an
abandoned row — also surfaced, not judged.
NOTHING ASSIGNABLE TO THE ONE IDLE HOST, AND THAT IS THE HONEST ANSWER. macneo
is free, answered this coordinator's measurement ask within the hour, and is
blocked on provisioning that only the operator can authorise. The floor-tier
work that remains for it is a curl-install smoke, which on macOS is
DESTRUCTIVE of that workstation's app state and VM directories, and macneo
holds NO standing consent (1004-vsh2). So the queue for that host is empty
until the operator answers, and inventing a slice to avoid saying so would be
worse than the idleness.

**Pass 33 addendum (2026-09-15T14:26Z) — the imperative is what gets applied,
and the qualifier underneath it does not travel.** macbookair closed 1201-t6ms
properly (b01f8c8ca, verified on trunk, row now `completed`) and reported the
cause as a rule they had wrong: their lane's instruction says "RELEASE THE
CLAIM AT CYCLE END, unconditionally" and they applied it literally to work that
was finished and landed.
I WENT AND READ THE SHARED TEXT RATHER THAN ACCEPTING THE DIAGNOSIS, and it is
half right in the way that matters. `skills/advance-work-from-plan/SKILL.md`
§4's BODY already made the distinction — "Completed work moves to its terminal
status (§7.2). Work you did NOT finish goes back to `ready`" — so the rule was
never wrong. Its HEADING was "Release on exit, unconditionally", and the
heading is the part a reader executes. One bolded imperative, one qualifier one
line below it, and the imperative won on a careful host. Fixed at the heading:
"Release on exit — a CLAIM is released unconditionally, a ROW is closed", with
the measured instance written into the step so the next reader meets the
distinction where they would otherwise skip it.
THIS IS THE MIRROR OF THE STRANDING THE STEP EXISTS TO PREVENT. 641-e2qa left
21 packets `in_progress` and hid them from ready and from burndown; this leaves
a finished row `ready` and offers it to the whole fleet through plan_next. Both
cost a host a cycle, and the step only warned about one of them, which is
probably why "unconditionally" got written in the first place.
AND A GATE EARNING ITS KEEP, worth recording because gates usually enter this
file as friction: `set-field status completed` REFUSES without `--evidence`
(650-dq6u), and that refusal is precisely why this coordinator could not close
the row from here — no run to cite. The closure came back with the mutation arm
RE-EXECUTED rather than quoted from the landing cycle (deleting the refusal
branch reds the refusal test while the positive control still passes; restored
byte-clean, porcelain 0). macbookair also corrected their own closure wording,
which said `--lib` on a crate that has no lib target: a plain run there reports
"0 passed; 525 filtered out" with rc=0 — success-shaped and measuring nothing.
A closure that sends the next reader to a command that CANNOT FAIL is the same
vacuity as a green arm over a run that executed nothing, one layer out.

**Pass 33 addendum 2 (2026-09-15T14:52Z) — COMPLETING A PARTIAL FIX, and
saying so rather than letting `fixed` mean two things in one file.** The
heading correction landed at 0dbdb7ca3 and was HALF the defect. macbookair
caught the other half while the gate was still running: §4's only code block
showed the `ready` path. Three surfaces — heading, sole example, prose
qualifier — and before the fix two of them were wrong for finished work while
the correct one was the one a tired reader skims past. Fixing the heading alone
would have left the example teaching the wrong ending under a heading that now
reads as authoritative. This land adds the terminal block and the rule above
both; the drill records it as completing a partial, not as a new fix, because a
record that reads as complete when it is half done is the same failure as the
heading.
I GAVE THE RIGHT ORDER FOR A REASON I HAD NOT MEASURED. I said put the terminal
block first because "the finished path is the common one". macbookair counted
their lane: cycle-end writes run `ready` 12 to `completed` 3. I reproduced it
here by a different method before conceding — all 76 fragments carrying
`host: macos` in plan/index.d/, counted by status value, gives the same 12 and
3 — and re-ran it uncapped, because my first pass used `head -400` and a capped
enumeration read as a count is its own trap. My justification was a
plausible-sounding assertion offered in the middle of a day spent catching
exactly that, by both of us, in each other.
THE REPLACEMENT RULE IS BETTER AND REACHES THE SAME ANSWER HARDER, and it is
now written ABOVE the two blocks where a future editor will meet it: PUT FIRST
THE BLOCK WHOSE MIS-COPY FAILS LOUD. Copying `ready` onto finished work is
silent and advertises it fleet-wide — that was the bug, and it survived until a
stale-row sweep. Copying `completed` onto unfinished work is refused by
650-dq6u, which wants a SHA and a named check result and cannot be satisfied by
fabrication. Frequency argues for `ready` first; asymmetry argues for
`completed` first; asymmetry is right and FREQUENCY IS THE TRAP. Without the
rule written down, the next editor finds the 12-to-3 and helpfully reverses the
order, correct about the frequency and wrong about the risk. GENERALISED, and
worth carrying past this step: when two examples sit together and one can be
mis-copied silently while the other refuses, THEIR ORDERING IS A SAFETY
PROPERTY, NOT A STYLE CHOICE.
macbookair's sentence goes into the step verbatim because it is the only part
that explains the original wording: A RULE WRITTEN FROM ONE FAILURE MODE READS
AS ABSOLUTE ABOUT THE OTHER. This step was built from 641-e2qa, saw only the
stranding direction, and stated its remedy without a boundary. What is being
corrected is not carelessness but a structure that defeats care — which is the
only kind of correction worth making to a rule careful people were already
following.
LENOVINHA IS PAUSED, NOT SILENT, AND THE EXPOSURE IS SMALLER THAN THIS
COORDINATOR FIRST SAID. Their keyring has answered blocked:gh-keyring-locked
for three consecutive cycles — the second lock tonight, the first having
produced 1189-2ra5 — and they have cancelled the :51 drain rather than emit
identical no-op reports, on the correct ground that a cadence reporting the
same sentence asserts a freshness it does not have. No gh auth login, no
refresh, no peer push, no --no-verify, no hook edit; the unlock is the
operator's and is queued as such. Verified from here: their salvage ref
refs/heads/salvage/lenovinha/20260915-1199-aw6m is NOT on origin (control: six
salvage refs are, including their own 20260914 one, so the namespace and their
access both work) and none of bbf70a8ba / cc6c5564b / 44b76c169 exist in this
checkout.
BUT THE HAZARD WAS NEVER "UNPUSHED" AND THIS COORDINATOR FRAMED IT WRONG.
872-c9nd's actual hazard is work existing in ONE PLACE SOMETHING MIGHT DELETE.
lenovinha wrote a bundle and a self-contained patch series OUTSIDE the
checkout and sent the bundle off the machine entirely, which closes that
without going near the credential. I had escalated it with deadline urgency it
no longer carries, and the correction is mine: naming a pressure point is not
the same as offering an alternative to it, and they found the alternative I
should have.
THEIR VERIFICATION IS THE DAY'S ONE INVERSE FINDING AND IT BELONGS BESIDE THE
OTHERS FOR ITS POLARITY. Everything else this fleet caught today was a false
GREEN — a vacuous arm over a run that executed nothing, a guard matching the
comment documenting what it forbids, a stub PATH that removed nothing, a
closure citing a command that cannot fail. Theirs is a false RED:
`git bundle verify` PASSES, and the fetch into an EMPTY repo fails on "lacks
these prerequisite commits: b61c1759a" — a prerequisite that is
origin/linux-next's own tip, which every real clone has and only the test
environment lacked. A CORRECT ARTIFACT READ AS BROKEN BECAUSE THE RECOVERY TEST
RAN IN AN ENVIRONMENT THE RECOVERY WILL NEVER HAPPEN IN. Believing it would
have meant rebuilding a working bundle, or concluding the work was
unrecoverable while holding a good copy. The patch series, needing no
prerequisite at all, is the artifact to reach for first precisely because it
has no environment to get wrong.
AND THEIR ARM 2b, WHICH IS THE SHARPEST INSTRUMENT FINDING OF THE DAY. The
1189-2ra5 fixture arm whose stated subject is "a host with no busctl at all"
built its PATH as "$stub:$PATH" — WHICH REMOVES NOTHING. It had been probing
the host's real keyring all along and passed only while that keyring was
unlocked; the re-lock is the only reason anyone found out. In their words, its
passing history was never evidence about its stated subject, which is why they
rebuilt it from nothing rather than patching the PATH. It now passes WITH the
keyring locked — the state it had silently depended on being false. That is
1109-t8kw's class, and today's tally in that class is: yoga's four in the
budget-tally fixture, lenovinha's one, and two of this coordinator's own
(1176-9vqn's hidden PATH candidate, 1198-7q95's if-not pipeline). Seven
instrument failures against zero work failures, in one day, across four hosts.

**Pass 34 (2026-09-15T16:11Z) — a remedy this coordinator broadcast fleet-wide
never ran on half the fleet, and the sweep it triggered found two more
instances than the host that reported it could reach.** osx-next +6 relayed
(macbookair's 1201-t6ms closure, their drill correction, and a 690-w94k claim);
windows-next 0.
MY DETACH RECIPE IS LINUX-ONLY. `setsid` DOES NOT EXIST ON macOS, and
`setsid nohup <script> …` fails outright on both Macs — macneo hit it running
the very suites the operator had just provisioned yq for. This coordinator has
prescribed that line as THE fleet standard for weeks, in two skills and in its
own standing notes, and no Mac had ever executed it. Corrected in both skills
with the platform pair written out, and the two load-bearing details confirmed
unchanged on either platform: a script FILE rather than an inline command, and
a terminal `rc=` marker for the Monitor. This is green-on-one-regime arriving
at the author of that rule: a remedy measured on one regime is a property of
THAT REGIME until a second one executes it, and "it works everywhere" is the
assumption a coordinator is best placed to make and worst placed to check.
THE PROVISIONING PAID FOR ITSELF IN ITS FIRST RUN, which is the argument for it
made by it. With yq 4.53.6 installed and ZERO warn:litmus-degraded-no-yq,
macneo produced the fleet's first undegraded readings of those suites:
forge-environment-discoverability 18/0/7 in 24s, meta-orchestration 21/2/1 in
117s. TWO ARMS THAT PASS DEGRADED FAIL ONCE THEY ACTUALLY EXECUTE, and macneo
checked each rather than handing over a count: both are ARM defects, not
product defects.
THE SWEEP FOUND THREE SITES WHERE macneo COULD ONLY REACH ONE. Their find is
BSD `wc -l` padding to width 8, so a hermetic arm's `[ "$dirt" = "0" ]` fails
on whitespace alone while the gate under test is entirely correct — 1130-i6xj's
class, with a positive control against an unpadded 0 isolating padding as the
whole difference. Before fixing it this coordinator swept the corpus, and the
discriminator is NOT "uses wc -l" (58 do) but "compares wc -l output as a
STRING": `[ "$n" -eq 0 ]` tolerates the padding, `[ "$n" = 0 ]` does not. Three
sites qualified — forge-findings-persistence-shape (macneo's),
forge-experts-teardown-ephemeral, and plan-compaction-format-preservation —
and the last carried TWO occurrences, caught only because the edit asserted its
match count was 1 and refused when it was 2. A fourth candidate my own scan
flagged, build-test-timing-telemetry-shape, was ALREADY detainted; the scan's
negative lookahead had missed a `wc -l < $F | tr -d ' '`, so the scan was wrong
in both directions and printing each site's actual assignment is what settled
it. All three fixed with the project's own `| tr -d ' '` idiom; re-scan clean.
THE OTHER ARM IS HANDED BACK RATHER THAN GUESSED AT. macneo's first failure is
litmus:e2e-eligibility-probe-shape 6/7, which stubs a fake `podman` on PATH and
requires `skip:live-runtime-present`; on macneo the probe answered `eligible`
and the preflight reported services-no-podman. The arm is hermetic BY
CONSTRUCTION — it builds its own stub — so the interesting question is WHY the
stub did not take effect there, and this host cannot answer it: the stub
resolves correctly here, so every fix written from this machine would be a
guess dressed as a remedy. Shipping a `skip:` for a mechanism nobody has
identified would convert an honest red into a silent skip, which is worse than
the red. Handed back as a discriminating probe instead.

**Pass 34 addendum (2026-09-15T17:02Z) — A PEER MEASURED THE COST OF A RULE
THIS COORDINATOR WROTE AND WAS NOT FOLLOWING.** macbookair's macOS land refused
twice on the mandated-merge guard, each refusal costing a full gate, and rather
than calling it bad luck they measured the race: trunk taking a commit every
~6.7 minutes against a gate longer than that. I checked their arithmetic against
trunk before answering and IT IS WORSE THAN THEY REPORTED — 21 commits in three
hours, 9 in the last hour, mean interval 5.5 MINUTES — and the attribution is
the part that matters: EIGHT OF THE 21 ARE MINE. The coordinator is the single
largest source of the churn the slow hosts cannot outrun.
THE RULE ALREADY EXISTS AND IT IS MINE: "the coordinator's cadence is the churn
slow hosts lose to; land once per pass, relay-land work/<order> branches,
quiesce for a critical commit." Pass 33 landed twice. No pass today reached the
third clause. A rule held in a standing note and applied by judgement is applied
when you remember it — which is the same sentence this file already carries
about the 795-imz3 refusal, now recurring at the level of cadence rather than
syntax, and costing a peer two gates instead of one land.
THEIR REASONING FOR TAKING THE RELAY REF IS THE PART TO KEEP. They declined the
same hatch TWICE earlier today because the host could satisfy the guard then,
and what changed their mind was the numbers rather than the inconvenience. A
gate longer than trunk's inter-commit interval is not an unlucky sequence, it is
arithmetic, and "a gate or merge policy your host cannot satisfy" is exactly the
case the refusal text names — so taking the offered path is COMPLIANCE, not
routing around the guard. The distinction is worth preserving because the same
action taken for the wrong reason would be the thing the guard exists to stop.
RELAYED AND QUIESCING. 5b249f35f merged and landing with this record. After it,
NO FURTHER CODE LANDS FROM THIS HOST until the platform hosts have had a clear
window; lenovinha (6 of the 21) is told the same. The window is worth more to
them than to me, which is the whole content of the rule I was not following.
THE REFUSAL WORDING IS FIXED, AND THEIR READING IS SHARPER THAN THE NOTE
ALREADY IN THE FILE. 1064-r8fv fixed the dead-end half by adding a lane hint,
but left "not a lost race, so retrying cannot help" absolute. It is TRUE of
retrying the PUSH and FALSE of re-running the script, whose attempt loop merges
trunk at attempt start and re-gates — the tool declines to use, for this
condition, a remedy it already performs. A tired reader takes the sentence at
face value and hand-merges, which is what that host did twice before measuring.
The message now names which retrying is futile, names the step the tool already
takes, and — the part their report earned — tells the reader to MEASURE the
interval before spending another gate on it, with the command to do so.
AND THEIR FIXTURE CARRIES THE CONTROL THE DAY'S OTHER VACUITY FINDINGS LACKED.
It counts ZOMBIES through /bin/ps filtered to its own pid rather than grepping
for `.wait()`, because a source-level test would have passed on the broken code
THE MOMENT THE MISLEADING COMMENT WAS WRITTEN — and that comment, "Detached —
let it complete in the background", is a specimen worth keeping: its second
clause is true, which is precisely what makes the first sound reasoned rather
than absent. The built-in control spawns raw children and REQUIRES zombies to
appear, so the arm cannot pass vacuously if a platform ever auto-reaps.
