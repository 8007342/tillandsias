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
  land in the /tmp fallback — checkout detection fails there, which is a
  separate 1096-p3tn finding. Moved aside with a dated suffix, never deleted. Each instance was caught by someone else's control or an
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
  packet cites. Two hosts checked, two real ledgers: on Windows every record
  lands in the /tmp fallback because checkout detection fails from the build
  distro. Nobody deletes; the only remedy is mv-aside, and only when the
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
