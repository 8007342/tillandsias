# Live-lane sweep rollup — 52 ready-but-landed hits, for per-packet judgement

**Measured:** 2026-09-13 · **Host:** lenovinha (linux) · **Order:** 1080-4deb item 2
**Command:** `LIVE_LANE=1 bash scripts/test-ledger-write-reaches-its-reader.sh --live`
**Scan:** `origin/linux-next`, 10000 subjects · **Denominator:** 397 ready packets

trace: scripts/test-ledger-write-reaches-its-reader.sh (the sweeper)
       scripts/check-fragment-status-loss.sh (why one bucket is empty by construction)

## This list is REPORT ONLY. Do not bulk-close it.

1080-4deb states it as non-negotiable: a hit NAMES an order and the sweep judges
prominence per packet. Wiring this into a gate would red a push on a packet
someone is mid-import on. Three of the 52 are known-good on inspection, and they
are the three the measuring host happened to have direct knowledge of:

| order | why it is legitimately `ready` |
|---|---|
| `900-z3kv` | criterion 2 landed this cycle; criterion 1's (a)/(b) decision is deliberately fenced for the operator |
| `1080-4deb` | this very row — item 1 done, item 2 is the work producing this file |
| `829-dkuc` | set aside deliberately: `multi_cycle`, 12h, its own next_action asks for an operator-paired session |

Three for three, on the only three that could be checked from memory. That is the
calibration to carry into the other 49: **a landed commit naming an order is
evidence that SOME of the work landed, never that the packet is finished.**

## Fresh measurement, not the recorded one

The row carried **46**; the sweep now reports **52**. It was re-run rather than
reused because that number was taken days ago against a different trunk, and
promoting a stale list would hand six hosts work that no longer exists — this
packet's own subject, one level up.

Two of the three channels are now **empty**:

```
ready-but-landed   52
ready-but-claimed   0
blocked-in-prose    0
```

Whoever picks this up should not assume the other two channels are dormant; they
are empty *at this commit*, and re-running is one command.

## A bucket that cannot exist, and why that matters

The obvious triage — split the hits into "has a terminal event, so only the
status move is missing" versus "no closure recorded at all" — returns **52 / 0**.
That is not a property of the corpus. `check-fragment-status-loss` REFUSES a
packet that carries a terminal event while folding non-terminal (that is
1085-g52w's whole subject), so on any green tree the first bucket is empty **by
construction**. The split was attempted, returned 52/0, and is recorded here as a
dead end so the next host does not spend the same minutes on it.

So every hit is the same shape: **a completion-shaped commit landed naming this
order, and no closure was ever recorded.** That is a larger and vaguer class than
"the status move is missing", and it is why this needs judgement rather than a
script.

## The 52

```
702-6jza  722-w7a2  718-jqt5  793-zumy  793-qc6q  795-5itp  814-75yf  814-5avq
823-u5zf  824-6qxh  829-dkuc  830-xsk2  856-s56y  888-miiy  890-27mv  900-z3kv
915-wkm2  917-zkge  917-6iwv  920-pxg6  929-47u8  945-vpg3  956-llei  959-fpc5
964-tzmp  965-rb3v  965-hz3f  966-7umc  967-6ax6  972-umik  997-e4v2  980-krib
982-sguu  989-ykks  992-w7ds  997-pdgf  1001-i5ux 1002-kav4 1021-hf9e 1032-utne
1042-svey 1057-dgij 1061-zd83 1064-5hv2 1063-nraf 1077-vzwq 1080-4deb 1081-gynk
1084-x8ya 1095-vk8r 1109-t8kw 1129-xm5z
```

## Triage recipe, per packet — cheap, and in this order

1. `tillandsias-plan status <order>` — confirm it still folds `ready`. Several
   will have moved since this file was written; that is the expected decay and
   not a defect in the list.
2. Read `next_action`. If it names remaining work, the packet is **legitimately
   ready** and the hit is a true positive about the COMMIT, not about the row.
   Record nothing and move on — re-reporting it next sweep is correct.
3. If `next_action` names nothing outstanding, find the landing commit
   (`git log --grep '<order>' origin/linux-next`) and read what it actually did.
   A `fix(<order>)` subject is a claim about a slice, not a closure.
4. Only then close it, with evidence, through the normal path
   (`append-event ... completed` + `set-field status completed --evidence`).
   `--reopen-evidence` exists if a close turns out to be wrong (650-dq6u), and
   1085-g52w's fixture now pins that a reopen lands.

**Do not** re-status in bulk from this list. Its value is that 52 packets are
worth *looking at*, not that 52 packets are done.

## What this rollup does not do

It does not judge the 49 unexamined packets — that is a host-budget task and the
row asks for exactly that promotion, not for one host to adjudicate 52 rows in a
cycle. It does not change the sweeper, which stays report-only. And it does not
touch the two empty channels beyond recording that they are empty here.
