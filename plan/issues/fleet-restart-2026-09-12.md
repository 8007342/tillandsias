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
| macbookair-macos | osx-next | (1) `/smoke-curl-install-and-test-e2e` on v56.9.11.1 (Tillandsias.dmg + tar.gz are published), findings to plan/. (2) 1084-x8ya remaining criteria if macneo stays offline (its next_action names what is left). |
| pirria-cachyos | linux-next | (1) salvage FIRST: 1098-q7bk's next_action records a local draft on pirria (an arm plus a PID-1 mutant control) that never pushed. (2) 1098-q7bk is ready and yours by history; 1096-p3tn (timing log written to two paths) is also yours. Floor-tier: no general-queue drain. |
| macneo-macos | osx-next | offline at 01:33Z; 1084-x8ya waits for it or for macbookair. |

Do not run `./build.sh --check` per packet; one land per pass. Do not arm a
cron or reopen a cycle on the coordinator's behalf. Ask before touching a
surface another host's claim names (`tillandsias-plan expire-claims
--list-live` after the merge, not before).
