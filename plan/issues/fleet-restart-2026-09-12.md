# Fleet restart 2026-09-12 — recovery drill, assignments, and the stable promotion plan

Coordinator: `macuahuitl-fedora` (message it by that name). The operator's
instruction to every host on 2026-09-12: macuahuitl leads; hosts report for
work and take assignments from it. This file is the durable copy of what the
coordinator says in messages, so a host that fetches origin can read it
without waiting for a reply. Filed by the coordinator; supersedes nothing in
`methodology/`.

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
