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
