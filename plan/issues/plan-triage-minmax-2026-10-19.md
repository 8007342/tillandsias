# Plan triage: MinMax work selection, regrouping, due diligence — 2026-10-19

Umbrella order `1800-rbcx`. Written on macuahuitl (linux coordinator) from the
folded ledger at linux-next `4e4fd5925`, by the plan tool (`query --json`,
`forgotten`, `blocking-counts`, `select-work-batch.sh`) and `gh pr list`; two
read-only sub-agents clustered the rows and audited drafts/refs. Counts are
one measurement on that commit.

Operator direction (2026-10-19): triage the order of `./plan`; regroup by
overlapping requirements; add the missing MinMax step to work selection,
with randomization and Due-Diligence Follow-Ups ("no leftover code left
behind because it's unpopular"); we optimised velocity and forgot direction.

The rule that answers it is `methodology/work-selection.yaml` (new component,
registered in `methodology/catalog.yaml` and `methodology.yaml` entrypoints).

## 1. How selection works today (what exists before designing a replacement)

| Surface | Where | Ranks by | Verdict |
|---|---|---|---|
| `plan_next` / `tillandsias-plan next` | `answer.rs` `next_ranking_key` | (priority, release-targeted, order) | priority-first: the exact anti-pattern `convergence.yaml` `minimax_convergence_strategy` names |
| cycle batch | `scripts/select-work-batch.sh`, rule in `distributed-work.yaml` `cycle_batch_triage.selection_rule` | epic score `2*urgency + 1.5*blocking + neglect`, then priority inside the epic | minimax at EPIC level, no value/effort/direction term |
| entropy | `cycle_batch_triage.entropy` | score-weighted, epsilon-mixed top-K epics, printed seed | exists, epic level only |
| forgotten | `forgotten.rs` `forgotten_sort` (718-jqt5) | eventless, oldest, fewest dependents | exists; nothing is obliged to read it |

Measured disagreement, same ledger, same host: `plan_next` offers
`722-w7a2` (windows signing, operator-bound), `776-jcf3` (operator YES
needed), `776-t8hs` (SignPath application, operator), `907-8ypf`, `1118-fqfk`.
`select-work-batch.sh linux` chose epic `stable-milestone-v1` (score 11.334,
pick 3/8) with head `1235-rfub`. Three of `plan_next`'s five are operator
work a host cannot advance; the two surfaces share no row.

Population: 899 open rows (853 ready, 17 in_progress, 29 blocked).
Priority histogram p0 10 / p1 187 / p2 437 / p3 129 / unset 136 — a
histogram, not an ordering. `release_target` coverage 509/899; 390 rows
(43%) ungrouped, versus 116/176 when `cycle_batch_triage` was written
(2026-08-09) — coverage regressed. 209 of the grouped rows sit under one
milestone (`fail-loud-diagnosis-milestone`), which the epic score treats as
ONE residual. `forgotten` returns 829 of 853 ready rows.

"MinMax" in the repo: `minimax_convergence_strategy` (strongest remaining
counterexample first) and `proximity.yaml` `minimax_validation`. The
operator's sense — max value per min effort — had no term anywhere: no
surface reads `size`/`estimated_hours` for ranking.

## 2. Clusters (requirement, not milestone)

Rows per cluster are approximate (keyword bucketing, +-15%). `None` =
ungrouped.

| # | Cluster | Outcome it serves | ~rows (p0/p1) | Representative orders | Milestones carried |
|---|---|---|---|---|---|
| 1 | Fleet rendezvous / VPN / messaging | hosts find each other LAN-first, mesh off-LAN | 40 (0/20) | 1548-5t00, 1548-2ilf, 1505-6w7d, 1506-32k5, 1506-7tq4 | 3 fleet milestones + 13 None |
| 2 | Login UX (CF/GitHub/Codex, QR, device flow) | sign in from phone/terminal without loops | 18 (1/5) | 1757-n45b, 1719-7wd9, 1773-dywf, 1759-3ezn, 1475-uif4 | None 10, FL 6 |
| 3 | Vault & credential lifecycle | credentials rotate/reset, never need an operator | 60 (1/16) | 1461-8tyy, 1118-fqfk, 1400-b7h4, 1402-hfta, 1403-4b5z, 590-* | None 35, FL 14, cred-audit 5 |
| 4 | Windows signing | installer not flagged | 8 (0/6) | 722-w7a2, 776-t8hs, 722-ksnk | windows-authenticode-signing |
| 5 | Lean/Kani convergence models | scorer provably matches model | 25 (0/3) | 1550-32d6, 1550-n4eb, 1550-8528 | convergence-models 12, None |
| 6 | CentiColon grader / evidence pilots | grader cannot over-credit | 11 (0/3) | 1469-vhuk, 1472-5t4b, 1395-64r7 | pilots 3, FL 5 |
| 7 | Shell-to-Lua ports / proc runner | no dialect reds, one runner | 54 (0/13) | 1384-aixy, 1443-6r3q, 1520-z95v, 1135-z8gn | lua-bash 8, None 32 |
| 8 | Litmus budgets / timeouts / orphan fixtures | gate red only for a real reason | 64-88 (1/10-16) | 1233-jqp4, 1236-bmjh, 1799-5kvy, 1063-nraf, 1355-m9xa | FL ~40, None ~25 |
| 9 | Refusal labels (why / what clears) | every refusal is actionable | 26-44 (0/6-9) | 1247-amcu, 1247-lwek, 1797-vsks, 1322-qfxs | FL ~12, None ~15 |
| 10 | Land queue / push gate / peer autonomy | green work lands without the coordinator | 56-78 (0/13-15) | 1731-cshq, 1735-hjeu, 1255-s4im, 1337-sj62 | None ~30, FL ~25 |
| 11 | Plan tool & ledger hygiene | the ledger says what is true | 36-90 (0/6-17) | 1073-xays, 1109-veaf, 1367-emjg, 1239-cges | None ~30, FL ~15 |
| 12 | Release / install / hot upgrade / soft reset | upgrade and reset never lose the user's state | 28-56 (0/7-13) | 1490-gttj, 1490-pguh, 1068-phrh, 1425-8wir, 1561-9f4x | None ~20, FL ~15, SV ~5 |
| 13 | macOS VM / guest / GPU | macOS launches a forge first time | 38-90 (0/14-31) | 1514-rxhw, 1792-48yg, 1794-rf3a, 1795-rtfy, 1654-6me6 | None ~52, FL ~21 |
| 14 | Windows WSL2 builder / tray | Windows launches a forge first time | 27-64 (0/3-7) | 667-kfyn, 1437-3iux, 1295-b4i8, 1713-6urw | FL, SV, None |
| 15 | Local inference / experts / GPU tuning | local experts answer | 30-77 (2/7-11) | 606-bvnp, 722-ecne, 722-uern, 1248-j6vd, 1001-7fd9, 1747-e9d6 | EX ~15, None ~25 |
| 16 | Browser windows / web preview / dev-mode | "serve my web project, open it on a device" | 10-55 (0/4-19) | 1552-238z, 1552-e3wf, 1700-dn8g, 1656-cscv, 1726-3mn6 | 47 of 55 None |
| 17 | Enclave security / workload identity | nothing on the wire is unauthenticated | 29 (2/7) | 1685-kwmr, 1688-ideu, 972-umik, 975-rsgm | None 16, SV 6 |
| 18 | Forge image / container launch / harness lanes | a forge comes up, agents get their context | 32 (0/9) | 1776-ondm, 1637-tpz3, 1448-2vth, 1725-23q0 | None 16, SV 6 |
| 19 | Telemetry / provisioning progress | the user sees what is happening | 19 (2/2) | 682-u3si, 1778-gct2, 1420-* | telemetry 3, None 10 |
| 20 | Methodology / milestones / research | — | 10-22 (1/1) | 700-nz4n, 630-67jk, 1530-7gkz | mixed |

Clusters 13, 16, 3, 15, 10 are the ungrouped hot spots (52, 47, 35, 34, 27
rows with no milestone). Cluster 12's `1490-*` family (10 rows) is a
coherent epic with no milestone at all.

## 3. Duplicates and outgrown rows

Candidate merges (later row into earlier unless noted; a host executes each
as one `merge-into` event after reading both rows — `1800-xagc`):

- 1002-kav4 <- 1747-e9d6 (embed endpoint probed once, never retried, spec_answer dead)
- 1490-pguh <- 1739-ufcj (soft reset removes only Tillandsias podman objects)
- 1182-2vaz / 1557-vhdk (Windows model weights location)
- 1438-pk9j / 1557-exxy (migrate legacy roots into tillandsias-home)
- 1437-av8u / 1437-3iux (vault store persists across reset, macOS/Windows pair — keep both only if exit criteria differ per platform)
- 1561-9f4x umbrella vs 1561-kfgk, 1561-y6f9, 1380-zmpi (installer end-user lines)
- 1570-k4fx / 1578-7s8h (check-cheatsheet-refs needs ripgrep)
- 834-7ut9 / 1410-ugvw (ghost spec cited, never existed)
- 1430-rnpd, 1498-fn96, 1744-jrjw, 1560-73zh (tray quit force-stops the guest)
- 1420-6brx, 1420-ev7i, 1420-v3zt, 1443-bgbs, 594-kgnr, 1571-fl8t (first-launch progress surface)
- 1233-jqp4, 1236-bmjh, 827-uh6t, 1192-xv4n, 1062-v3j4, 1604-8uae (litmus budgets)
- 1262-im9j, 1435-ebcx, 1436-v24f, 1247-omqr (claims-across-branches false positives)
- 1015-mq6d, 1228-4xdp, 1183-2s7a, 1336-k4ih, 889-twhe (plan-only lane refusals)
- 1270-5mz8, 1737-xbh3, 1258-tpkz, 1555-f6wy, 1146-xs6s (stale plan binary)
- 1255-s4im, 1001-i5ux, 1564-frzr, 1429-4y9f (client-side-only push guards)
- 1719-7wd9, 1759-3ezn, 1773-dywf (CF login exchange failure handling)
- 1400-b7h4, 1402-hfta, 1403-4b5z -> 1118-fqfk (unseal share recovery)
- 1656-twhk, 1657-uq5d, 1699-rhy2, 1700-dn8g (dev-mode CDP / device windows)
- 1686-7miz, 1687-ipmx, 692-zjzg (SPIFFE-style workload identity)
- 1637-cnxq / 915-wkm2 (where scratch and worktrees live)

Outgrown (narrow fix superseded by a sibling; disposition `close:superseded-by`
after the host confirms the sibling's exit criteria cover it):
1420-6brx, 1420-v3zt (by 1778-gct2); 1004-qdys, 1086-btjb (by 1490-pguh);
1570-qutp, 1570-mxcg, 1570-k4fx, 1174-jd8n, 964-zgga, 1301-ie39, 833-ecdg
(by the Lua ports); 1040-eniv, 1056-w2yy, 871-4c3u, 1464-v3xq, 1355-m83d (by
1252-znbn / 902-5bf9); 1326-w9t9, 1352-qbrd, 1278-qbia, 1427-r2d2 (by
1255-s4im + mirror pre-receive 1446-87cy); 1452-ihxp, 1630-pz77 (by
664-7qzz / 1384-j3cv); 1193-e6kv (by 1776-ondm); 1237-f9dy, 1122-6sqz
(ci-full installs the launcher already); 1454-y3vw; 888-jfsz; 1001-i5ux.

## 4. Orphans: leftover code nobody is obliged to finish

Draft PRs (12 open; 11 untouched >5 days, every branch's commits unlanded by
patch-id): #196 work/1375-amye (+1161, portable `run` verb), #215
work/1548-cii8 (+3201, per-host X25519 identity + Noise XX; row ready),
#217 work/914-ahsy, #232/#235/#238 work/1553-6b3a|q7f4|3isv (58-61 files,
NO ledger packet for 1553-q7f4/3isv), #241 work/1543-f44v, #242
work/1558-ixih (no packet), #364 work/539 (+545, headless prompting), #367
work/472 (+1452, cert-lifecycle slice 6), #386 work/1637-cnxq (16 commits,
38 files; row worked 17 times). #525 work/667-kfyn is live (10-18).

Unmerged `origin/work/*` refs: 38 of 722, ~31 carrying non-plan files. Ten
have a row already closed (verified/completed/done/implemented) but the ref
never landed: 1069-c9w6, 1087-h2z9, 1342-r4pv, 1331-884p-fixture,
1347-r9g8-arm-a, 1470-dbuw, 1553-a9n6, 1351-y98c, 1338-i23k, 765-xpct,
1324-ujvb — each is either a closure claimed without its code (audit) or a
ref to delete. Refs with no packet at all: tray-ux-linux-order,
437-forge-src-tmpfs-topology (30 files, "mark implemented"),
1367-lua-predicate-shims (36 files), retire-ruby-lua (27 files),
configure-codex-host-20260929. Open rows with code on an unlanded ref:
1506-32k5 (13 code files, ref 10-03), plus the draft set above.

In-progress: all 17 rows carry a null lease (a smell by itself);
1386-iubj has no fragment since 10-03. Blocked: 29 rows, only 9 name a
blocker; two blocks are STALE — 1384-aixy blocked by 1384-bqhy (completed),
689-zwzm blocked by 690-2kwd (verified). Circling (most `worked` events,
still ready): 245 (54), 824-6qxh (33), 1242-4x53 (23), 793-qc6q (20),
1135-z8gn (19), 902-5bf9 (18), 1637-cnxq (17), 996-bcjx (17), 1256-cqsy
(17), 1252-znbn (16), 1235-rfub (15).

## 5. Proposed DIRECTION (for the operator to confirm or reorder)

The `## DIRECTION` block `work-selection.yaml` reads from plan/loop_status.md
does not exist yet; this is the proposal `1800-jybu` files it from:

1. **First launch works on every platform** — stable-milestone-v1, macOS VM
   (13), Windows WSL2 (14), forge image/launch (18), release/reset (12),
   enclave security (17).
2. **Sign-in and credentials never need an operator** — credential-lifecycle
   (3), login UX (2), windows signing (4).
3. **Green work lands without the coordinator** — land queue (10), litmus
   budgets (8), shell-to-lua (7), refusal labels (9), plan tool (11).
4. **Local experts answer** — forge-local-experts (15).
5. **Prompt-to-app: serve and open it on a device** — browser/web preview
   (16), telemetry/progress (19). Needs a milestone minted.
6. **The fleet finds itself** — rendezvous/VPN/messaging (1), v0.6.
7. Convergence models and grader (5, 6).

## 6. Top 15 by MinMax (value / effort, with direction)

Value = direction + urgency + risk + blocking; effort from `size` where the
row carries one, else my estimate (S/M/L). "Why now" is the residual it
removes.

| # | Row | What | Dir | Effort | Why now |
|---|---|---|---|---|---|
| 1 | 1461-8tyy | GitHub token in Vault self-rotates before 8h expiry | 2 | M | p0; every expiry is an operator reseed and a dead push lane fleet-wide |
| 2 | 975-rsgm | enclave CA bundle lives in /tmp; containers cannot restart | 1 | M | p0, blocked with no named blocker — unblock (`1800-4yat`) then fix; a reboot loses the forge |
| 3 | 1118-fqfk (+1400-b7h4, 1402-hfta, 1403-4b5z merged) | unseal share to tmpfs, wiped on reset | 2 | M | the recovery/retry trio collapses into it; security surface |
| 4 | 1776-ondm | one image-ensure seam, failed build remembered by inputs | 1 | M | absorbs 1193-e6kv and the 1788-qlwq forge-defect tail; cold-launch root cause class |
| 5 | 1490-pguh (+1739-ufcj) | label-keyed cleanup replaces `podman system reset` | 1 | M | the 1490-* hot-upgrade epic's gate; retires 1004-qdys, 1086-btjb |
| 6 | 1384-aixy | proc-run/proc-spawn on mlua | 3 | L | STALE BLOCK (blocker completed); root of the shell-to-lua carried obligation |
| 7 | 1233-jqp4 + 1236-bmjh | litmus budgets calibrated; five elevated timeouts come back down | 3 | M | in_progress; every false red costs a relay cycle; six-row dup family folds here |
| 8 | 1731-cshq | land queue gates as one merge train, bisects on red | 3 | L | 17-min per-PR gates are the throughput ceiling; blocking for 1732-1737 |
| 9 | 1548-cii8 / 1506-32k5 (PR #215) | per-host X25519 identity, Noise XX | 6 | S to land, L to rewrite | +3201 lines already written and rotting; land-or-close is the cheapest decision in the ledger |
| 10 | 1637-cnxq (PR #386) | scratch inside the checkout, guard on new sites | 3 | S to land | 16 commits drafted, 17 worked events: circling; slice 1 lands or the row splits |
| 11 | 1235-rfub | relay gate landed a tray tree that does not compile on macOS | 1 | M | selector's urgent slot every day; 15 worked events means it needs decomposition, not another pass |
| 12 | 1002-kav4 (+1747-e9d6) | embed endpoint retried; spec_answer alive after late inference | 4 | S | one retry loop makes the experts tier real for the whole session |
| 13 | 1247-amcu | refusal why/remedy umbrella | 3 | — | cap it: measured top-N landed in #578; close the umbrella on a count, merge leftovers into one row |
| 14 | 1552-238z (+1656/1700 family) | local web preview + device-sized windows | 5 | L | 47 ungrouped rows with no milestone: mint the milestone first (`1800-xagc`), then slice 1 |
| 15 | 606-bvnp / 722-ecne / 722-uern | mirror service identity (three p0s) | 4 | L | blocked on 451 (pending): either 451 moves or the p0s are re-rated — a p0 that cannot move is a ledger lie |

`plan_next`'s current top three (722-w7a2, 776-jcf3, 776-t8hs) are operator
work; they belong in the operator queue as plain asks, not in a host's next.

## 7. The rule, in one paragraph each (full text: `methodology/work-selection.yaml`)

**MinMax score.** `value = direction_weight + urgency + risk + min(blocking,10)`,
`effort = size (S1/M3/L8, untagged 5)`, `score = value/effort`; the epic
score is the MAX of its packets (minimax residual), never the mean; computed
once in the plan tool as `minmax_score` / `tillandsias-plan score`, consumed
by `next`, `select-rows` and the batch selector so the two surfaces agree.
Inputs are ledger fields only; missing inputs score conservatively and are
counted on the triage line.

**Randomization.** Epic entropy unchanged. One packet-level `explore=` slot
per batch of budget >= 3, drawn score-weighted from below the top `budget`
of the chosen epic from the printed seed; a packet explored twice without a
disposition leaves the draw and goes to the sweep.

**Due-diligence follow-up.** `forgotten --diligence` prints six triggers
(stale-in-progress 14d, stale-block, orphan-ref 14d, orphan-draft 14d/7d,
forgotten-leaf 60d, explore-twice); the coordinator dispositions the top
five weekly; dispositions are exactly advance / merge-into / regroup /
close:<superseded-by|obsolete|wont-do> with a stated reason; the sweep set is
a `stale-rows` carried backlog (advisory, then gentle: a change touching a
sweep row's `owned_files` owes it one event or a waiver).

## 8. Rows filed

- `1800-rbcx` umbrella (this note + the methodology component)
- `1800-kbfe` plan tool `score`; `next`/`select-rows`/selector rank by it; explore slot
- `1800-jybu` DIRECTION block folded like ACTIVE RELEASE; direction_weight on the projection
- `1800-qkst` `forgotten --diligence`, `stale-rows` counter, weekly coordinator step
- `1800-xagc` execute the regroup/merge/outgrown list above as events; mint the web-preview milestone; split fail-loud-diagnosis-milestone
- `1800-4yat` disposition the orphans: 11 draft PRs, 38 unmerged refs, 2 stale blocks, 17 lease-less in_progress rows

## 9. Open questions for the operator

1. DIRECTION order: accept the seven outcomes above as listed? (yes / reorder)
2. The `stale-rows` backlog: start at advisory, or straight to gentle? (advisory / gentle)
3. Orphan drafts older than 14 days with a ready row: default disposition land-if-green or close? (land / close)

## 10. Operator rulings (2026-10-19)

1. DIRECTION: approved as listed in section 5, in that order. `1800-jybu` writes it into `plan/loop_status.md` unchanged.
2. `stale-rows` backlog: starts **advisory, warnings only**. Nothing is refused or carried until a later ruling moves it to gentle.
3. Orphan drafts older than 14 days with a ready row: default disposition is **close**. A closed row or spec is a tombstone; if the work is needed again it is revived as a new spec or row per the methodology's tombstone rules, not by reopening the draft.
