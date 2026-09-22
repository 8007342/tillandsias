# Block-scalar `key: value` corpus — for the compaction renderer row (macneo)

Produced by yoga 2026-09-21 against origin/linux-next at the commit named below,
at macuahuitl's request, after the `--check` red on
`compaction_on_the_real_ledger_preserves_every_comment_and_item` was excised as
a recorded exception (6c372ed26).

## What this is, and what it is NOT

It is a CANDIDATE POPULATION drawn from real history, not a list of known
breakers. macneo bisected the actual trigger; this list is deliberately wider
and its job is to be a test corpus of spellings nobody would have synthesised.

**It does not identify the culprit and must not be read as if it did.** 254
fragments carry the strict shape and the fixture is green on all but the one
excised, so the trigger is NARROWER than anything measured here. That is also
why no interim writing rule was issued: "no indented `key: value` inside a block
scalar" would forbid 254 fragments' worth of prose to prevent one defect, and
might not even cover it.

## Reading rule, published with the numbers

A block scalar opens with `<key>: |` (or `|-`, `|+`) and its body is the
indented run beneath it. A fragment is listed when some line of some block
scalar body matches:

  LOOSE   `^\s+[A-Za-z_][A-Za-z0-9_.-]*:\s+\S`   436 of 1,444 fragments
  STRICT  `^\s+[a-z_][a-z0-9_]*:\s+\S`           254 of 1,444 fragments

The loose pass matches English prose with a colon — `FIXED: the probe now
checks the fallback` — which is why the strict pass exists and why the strict
one is the corpus below. Neither pass understands YAML; both are text scans,
and a fragment whose block scalar is quoted differently may be missed.

## Reproducing it

The scanner is INLINE below rather than added under `scripts/`, deliberately: a
new script is a code change needing a full gate, and this list is wanted now, on
a night when the fleet's gate has just been red. Save it anywhere, it writes
nothing and reads no git state, and point it at any checkout:

    python3 scan.py strict plan/index.d

```python
#!/usr/bin/env python3
"""List plan fragments whose block scalars contain indented `key: value` lines.

Two passes, because they disagree and the disagreement is the point:
  LOOSE  — any <indent><identifier>: <text>; matches English prose with a colon
  STRICT — lowercase identifier only, i.e. what would parse as a mapping key
Usage: scan.py [loose|strict] [dir]   (default: strict plan/index.d)
"""
import glob, re, sys
mode = sys.argv[1] if len(sys.argv) > 1 else 'strict'
root = sys.argv[2] if len(sys.argv) > 2 else 'plan/index.d'
PAT = (re.compile(r'^\s+[A-Za-z_][A-Za-z0-9_.-]*:\s+\S') if mode == 'loose'
       else re.compile(r'^\s+[a-z_][a-z0-9_]*:\s+\S'))
OPEN = re.compile(r'^(\s*)[A-Za-z_][A-Za-z0-9_-]*:\s*\|[-+]?\s*$')
for p in sorted(glob.glob(f'{root}/*.yaml')):
    lines = open(p, encoding='utf-8', errors='replace').read().split('\n')
    i = 0; first = None
    while i < len(lines):
        m = OPEN.match(lines[i])
        if not m:
            i += 1; continue
        base = len(m.group(1)); i += 1
        while i < len(lines) and (lines[i].strip() == ''
                                  or len(lines[i]) - len(lines[i].lstrip()) > base):
            if lines[i].strip() and PAT.match(lines[i]) and first is None:
                first = (i + 1, lines[i].strip()[:70])
            i += 1
    if first:
        print(f'{p}\t{first[0]}\t{first[1]}')
```

`compact` was NOT run to find the trigger. It writes by default, and invoking a
mutating command to discover behaviour is a mistake this host made once already
on 2026-09-20 with `set-field --value-file /dev/null`.

## The corpus

Commit: 6c372ed26ef213c87d2236c1598257d559602e6a
Fragments scanned: 1448

```
plan/index.d/20260913t040516z-1ce25150-macneo.yaml	21	released: cycle blocked by trunk red 1141-vf9w on darwin; claim never 
plan/index.d/20260913t081134z-22505128-macneo.yaml	18	macneo: VERIFIED LANDED, closing a ready-but-landed row rather than re
plan/index.d/20260913t081442z-2d3e3e69-linux.yaml	78	contract: it pins the LEDGER and the VIEWS, never the honesty of the n
plan/index.d/20260913t081500z-1146-xs6s-stale-binary-remedy-names-a-stale-binary-esme.yaml	30	which: an `_run bash` line in build.sh, or BOTH an
plan/index.d/20260913t085000z-1154-6big-resolve-probe-cannot-see-a-debug-binary-esme.yaml	31	which: an `_run bash` line in build.sh, or BOTH an
plan/index.d/20260913t090042z-33cd1495-linux.yaml	22	token_recur: rank only labels seen MORE THAN ONCE, which is right for 
plan/index.d/20260913t093000z-1155-jurn-exit-status-does-not-survive-wsl-exec-channel-esme.yaml	31	which: an `_run bash` line in build.sh, or BOTH an
plan/index.d/20260913t093456z-1149-vgn2-credential-cold-probe-pirria.yaml	57	filename: credential-cold-probe-sees-the-fallback. With a `fallback_va
plan/index.d/20260913t093508z-1149-e8my-plan-blocked-on-surface-skew-pirria.yaml	47	filename: plan-cli-unknown-name-does-not-blame-staleness. Invoking the
plan/index.d/20260913t094502z-392d6597-linux.yaml	29	would: "an advisory guard whose remedy is load-bearing in the other di
plan/index.d/20260913t094852z-154e6a48-yoga.yaml	70	establishes: a promotion run must show the detector ACCUSING a genuine
plan/index.d/20260913t095511z-052e24dd-yoga.yaml	53	disposition: an event on the row the measurement is about is the truer
plan/index.d/20260913t101336z-1bd94a23-macuahuitl.yaml	22	silent: the sweep reports, the append fails, nothing downstream notice
plan/index.d/20260913t103313z-03f09169-yoga.yaml	42	row: await_marked was exactly such a fix, and because it polled throug
plan/index.d/20260913t104106z-1154-8ywc-expiry-check-skipped-when-live-fold-unavailable-linux.yaml	63	unchanged: it means "a row exists, unverified", and must not be widene
plan/index.d/20260913t104242z-28086533-linux.yaml	34	made: the PRE-fix natural occurrence expires the moment the fix reache
plan/index.d/20260913t113647z-02989f34-linux.yaml	53	explicit: the work is finished and gate-green, not unfinished. Releasi
plan/index.d/20260913t121943z-2482cd40-macos.yaml	21	corrected: one of the 28 is an advisory false positive (rg --version),
plan/index.d/20260913t122059z-19c2ff7b-macuahuitl.yaml	20	fix: judge the capability row on the host's own locus), 1ad2c8693 (arm
plan/index.d/20260913t124534z-1156-eif4-compaction-reads-only-the-status-channel-macuahuitl.yaml	29	fields: fragment. Both functions are correct on their face; only the
plan/index.d/20260913t125456z-0625b89d-macuahuitl.yaml	19	fields: fragments in place and untouched): FAILED before c74a67338, ok
plan/index.d/20260913t133745z-08ea74bd-macuahuitl.yaml	22	account: no meta-arm named the_set_of_fragment_channels_under_test_is_
plan/index.d/20260913t161204z-0f7751f0-macneo.yaml	18	macneo: VERIFIED FIXED AND CLOSED, from an existing green gate log, no
plan/index.d/20260913t162624z-11e24ba6-linux.yaml	66	finding: `next-order` minted 1160 BECAUSE 1158 and 1159 were already i
plan/index.d/20260913t174353z-1c7c4498-yoga.yaml	24	responses: "fix your call site" versus "this host cannot answer". On a
plan/index.d/20260913t190821z-3b167511-linux.yaml	24	was: ok:capability-row-reported:esmeraldinha             rc=0
plan/index.d/20260913t190926z-1165-xkjh-remedy-unavailable-at-the-locus-linux.yaml	57	change: consumers parse that grammar and 1154-8ywc left it alone on
plan/index.d/20260913t191018z-2a06e33e-linux.yaml	28	emit: live_matrix has ALREADY invoked host-capability-probe.sh — the e
plan/index.d/20260913t192133z-03a6e24d-linux.yaml	52	lenovinha: THE LINE FOLLOWS THE LOCUS, NOT THE HOST. Same tree, same b
plan/index.d/20260913t195534z-1d7ce788-macos.yaml	24	stat: illegal option -- c        <- raw BSD usage text on stderr
plan/index.d/20260913t215400z-19aabcaf-macuahuitl.yaml	21	cleared: the closure it deferred now lives in verifiable_closure, boun
plan/index.d/20260913t223018z-096b1160-linux.yaml	71	maker: kind tracks locus. A FIXTURE'S DATA MAKER CAN ENCODE NOT ONLY A
plan/index.d/20260913t234139z-31c84340-macos.yaml	24	sed: 1: "/var/folders/lm/krdnbsm ...": invalid command code f
plan/index.d/20260913t235815z-1175-wuwr-builder-wrapper-dies-at-the-competing-gate-capture-macuahuitl.yaml	23	order: the fixture 10/10 standalone on the host and inside the builder
plan/index.d/20260914t001131z-2c47e830-macneo.yaml	18	macneo: SECOND-HOST CONFIRMATION, plus an interaction this packet pred
plan/index.d/20260914t001137z-1a5731d0-macneo.yaml	21	released: evidence contributed, implementation belongs with a gate-sta
plan/index.d/20260914t001223z-15524c38-macneo.yaml	18	macneo: CONTROLLED MEASUREMENT OF THE DIFFERENTIAL, same host, adjacen
plan/index.d/20260914t003000z-1176-9vqn-a-release-freeze-is-a-rule-with-no-mechanism-yolanda.yaml	30	mitigation: macuahuitl's freeze holds code lands on LINUX-NEXT, the br
plan/index.d/20260914t010839z-326e8de3-linux.yaml	50	authorship: 4e38b5a29 lenovinha "fix(1159-g96c): a fallback locus asks
plan/index.d/20260914t022109z-2b1ac4a0-linux.yaml	66	reopen: 1130-8zxn was a WRONG verdict nobody could clear, this was a R
plan/index.d/20260914t031500z-1179-yshc-envelope-suite-hardcodes-target-debug-esme.yaml	35	ok:   the served document replays the producing run's timestamp verbat
plan/index.d/20260914t034452z-069d569c-yoga.yaml	21	discharged: the arms named in it are landed and green
plan/index.d/20260914t043508z-1f4ed96f-yoga.yaml	21	discharged: scripts/test-gate-memory-refusal.sh is landed and bound
plan/index.d/20260914t050328z-366011a7-macuahuitl.yaml	21	cleared: closure lives in verifiable_closure
plan/index.d/20260914t052419z-2b1482fb-yoga.yaml	21	discharged: scripts/test-salvage-refs-ledger.sh is landed and bound
plan/index.d/20260914t053633z-1aff8af3-yoga.yaml	21	discharged: the arms are landed in the existing fixture and bound
plan/index.d/20260914t073711z-3af4dd4f-yoga.yaml	21	discharged: scripts/test-land-adopts-valid-stamp.sh is landed and boun
plan/index.d/20260914t075425z-35cd2d70-yoga.yaml	21	discharged: the fixture is landed and bound. --replace is required her
plan/index.d/20260914t080827z-14ca3848-macos.yaml	42	mkdir: cannot create directory '/home/ollama/.ollama/models/.tools': P
plan/index.d/20260914t080827z-26b122d8-macos.yaml	21	released: (a) BLOCKED on 1183-j9dk (inference cannot write the macOS m
plan/index.d/20260914t080930z-210b56df-macuahuitl.yaml	21	cleared: the closure lives in verifiable_closure (1136-n8sh discharge;
plan/index.d/20260914t081203z-029b70ed-yoga.yaml	21	discharged: the tests are landed. --replace required by 1151-td46, whi
plan/index.d/20260914t081203z-30fcd520-macneo.yaml	21	released: static assessment contributed; closure needs a live-VM host
plan/index.d/20260914t081246z-24d0b690-macneo.yaml	18	macneo: CRITERIA ASSESSED AGAINST LANDED WORK — two of four look satis
plan/index.d/20260914t081500z-1183-j9dk-inference-cannot-write-model-share-macbookair.yaml	51	mkdir: cannot create directory '/home/ollama/.ollama/models/.tools': P
plan/index.d/20260914t082622z-15737a5e-macuahuitl.yaml	21	cleared: the closure lives in verifiable_closure (1136-n8sh discharge)
plan/index.d/20260914t090000z-1183-2s7a-the-plan-only-lane-skips-the-plan-semantic-checks-yolanda.yaml	78	reading: trunk was not red when I reported it, only the tree my gate
plan/index.d/20260914t124500z-1184-jqqg-a-credential-less-push-hangs-instead-of-failing-yolanda.yaml	31	fatal: could not read Username for 'https://github.com':
plan/index.d/20260914t135930z-06107586-yoga.yaml	23	ok: this host HAS an index — spec.answer graded rather than skipped (s
plan/index.d/20260914t153600z-1184-tj2q-set-field-scalarises-a-list-yoga.yaml	28	then: set-field 9999-tag capability_tags "testing, low-end"
plan/index.d/20260914t153940z-28c1b3da-yoga.yaml	22	write:                 set-field <row> capability_tags "testing, low-e
plan/index.d/20260914t153945z-31daebb8-yoga.yaml	21	discharged: the tests are landed
plan/index.d/20260914t161136z-303de250-macneo.yaml	18	macneo: MEASURED THE TWO CRITERIA THIS HOST CAN SETTLE WITHOUT COMPILI
plan/index.d/20260914t161143z-14a6b670-macneo.yaml	21	released: measurement contributed; remaining work is Rust plus an infe
plan/index.d/20260914t163612z-103e8dd8-macos.yaml	21	guard:   git grep -c 'plan/archive' origin/linux-next -- scripts/push-
plan/index.d/20260914t163707z-25619c50-macos.yaml	21	verdict: ok:fragments-on-trunk:638022bd9e46cecd6c60cee54c7b0cf0efdc539
plan/index.d/20260914t185710z-1188-mm9y-installed-launcher-has-no-provenance-lenovinha.yaml	25	macuahuitl: `tillandsias --version` reported v56.9.12.2 against a VERS
plan/index.d/20260914t194250z-1189-2ra5-locked-keyring-reads-as-no-credential-channel-lenovinha.yaml	56	rule: the probe must be bounded, and a host with no busctl/no secret
plan/index.d/20260914t194553z-0c08505b-macuahuitl.yaml	21	reconciliation: two criteria met, two not; the mechanical caller named
plan/index.d/20260914t194811z-2a4a23c5-macuahuitl.yaml	21	reconciliation: two criteria met by code, two need the slowest host
plan/index.d/20260914t194813z-1d2a1602-macuahuitl.yaml	21	reconciliation: nothing of this row landed; the mechanisms are named
plan/index.d/20260914t194945z-2a5fa882-macuahuitl.yaml	21	reconciliation: two criteria met, the scan itself is still missing
plan/index.d/20260914t201137z-1190-swen-cold-room-smoke-lane-guard-stop-is-the-expected-outcome-macuahuitl.yaml	36	declined: it would test a different machine than the one the smoke
plan/index.d/20260914t220100z-1191-vrjf-dashboard-printf-locale-numeric-yoga.yaml	39	one: the abort is loud, but a host whose percentages happen to parse
plan/index.d/20260915t001101z-175cf8e8-macneo.yaml	18	macneo: THE "SECOND, SMALLER FIX" THIS ROW OFFERS AS AVAILABLE HAS ALR
plan/index.d/20260915t001106z-11811c10-macneo.yaml	21	released: ledger corrected; the ownership remedy needs the macOS build
plan/index.d/20260915t035619z-361cff30-macos.yaml	60	after: 34 iterations for the same 250ms, wall clock 251.7ms
plan/index.d/20260915t041735z-1194-smtb-platform-scoped-gate-arms-macbookair.yaml	22	passes: for every platform-scoped prover row in check-host-tools.sh, S
plan/index.d/20260915t041737z-315c6dc8-macneo.yaml	18	macneo: READING (a) CONFIRMED — THE GUARD REGRESSED, NOT THE PROVER RO
plan/index.d/20260915t042023z-1195-m9vi-macos-plan-lane-wedge-macbookair.yaml	21	vacuously: from a host whose tree cannot satisfy the build stamp, a
plan/index.d/20260915t043634z-1196-5hva-heartbeat-blind-to-ledger-filed-blockers-lenovinha.yaml	47	worse: WEDGED says "adjudicate its worktree", i.e. go look for local d
plan/index.d/20260915t050856z-137ce828-macneo.yaml	18	macneo: THE WEDGE CLEARED WHEN TRUNK WENT GREEN, so this row's central
plan/index.d/20260915t051018z-3737be00-macos.yaml	32	follow: a gate does not have to mention a defect to be disabled by it.
plan/index.d/20260915t051121z-23eeaf48-macneo.yaml	18	macneo: QUANTIFIED THE DETECTOR'S BLIND SPOT, and the number is starke
plan/index.d/20260915t075314z-36391e68-macneo.yaml	18	macneo: RETRACTING MY OWN 2026-09-14 ASSESSMENT OF STEP (a). I wrote t
plan/index.d/20260915t075539z-04dadfc8-macos.yaml	40	miss: a plaintext refusal of REALISTIC LENGTH reaches the AEAD check, 
plan/index.d/20260915t081120z-2d3f1588-macneo.yaml	18	macneo: THE FLOOR-TIER HOST CANNOT PRODUCE SLICE (2)'s LOW-END BANDS, 
plan/index.d/20260915t081121z-0c0c7130-macneo.yaml	21	released: floor tier lacks embedder and a populated index; provisionin
plan/index.d/20260915t081434z-1197-82rm-cache-sweep-removes-the-plan-binary-macuahuitl.yaml	40	everywhere: the rebuild measured 40 s on macuahuitl (20 cores). The fl
plan/index.d/20260915t082721z-1197-y6g6-freeze-fixture-red-on-macos-macbookair.yaml	49	confirming: attempt_plan_only_lane validates the outgoing fragments wi
plan/index.d/20260915t104500z-1200-ih38-validate-share-before-persist-yoga.yaml	30	comment: stored in memory and persisted to the fallback file. Two
plan/index.d/20260915t114310z-1201-hsf9-a-claim-names-a-platform-not-a-workstation-macuahuitl.yaml	30	guarded: 772-4se9 replaced a hardcoded host="linux" — which wrote a
plan/index.d/20260915t141458z-0aab1440-macos.yaml	52	restored: rc=0, worktree byte-clean (git status --porcelain = 0)
plan/index.d/20260915t161341z-18cb1390-macneo.yaml	18	macneo: IT IS (C), AND THE MECHANISM IS DOCUMENTED — the arm's premise
plan/index.d/20260915t173326z-22556ab1-pirria.yaml	28	bash: line 1: /home/lapto/claudia/tillandsias//tmp/tb-target/release/t
plan/index.d/20260915t174723z-1202-fh6y-one-artifact-path-two-incompatible-consumers-macuahuitl.yaml	76	mechanism: the last writer to target/release/tillandsias-plan wins
plan/index.d/20260915t174736z-1203-dzxn-a-platform-host-never-reaches-the-retry-loop-macuahuitl.yaml	37	it: each re-gated, ~900-1100s apiece.
plan/index.d/20260915t180500z-1203-46gj-fixture-assumes-cargo-target-dir-is-relative-pirria.yaml	36	bash: line 1: /home/lapto/claudia/tillandsias//tmp/tb-target/release/t
plan/index.d/20260915t195057z-1207-n96g-eligibility-arm-asserts-a-retired-oracle-macbookair.yaml	45	fails: it is asserting the oracle that was retired for being uninforma
plan/index.d/20260915t201722z-1208-greh-the-citation-guard-skips-the-one-corpus-that-cannot-be-corrected-macuahuitl.yaml	28	trunk: 29 fragments under plan/index.d already carry line-number
plan/index.d/20260915t202046z-3415b998-macos.yaml	54	caveat: the run emits warn:litmus-degraded-no-yq. This step calls no y
plan/index.d/20260915t203000z-1211-34v6-inert-login-remedy-yoga.yaml	34	split: read_host_project_origin_url runs `git config --get
plan/index.d/20260915t211248z-1210-u6xw-git-mirror-observability-implementation-lenovinha.yaml	46	example: a 403 on the mirror's credential was indistinguishable from
plan/index.d/20260915t211651z-1211-q9bm-long-running-view-checked-at-land-not-completion-lenovinha.yaml	28	stale: 330
plan/index.d/20260915t215254z-1213-rbt9-website-found-fourteen-shortcomings-the-ledger-does-not-track-macuahuitl.yaml	63	measured: whether each shortcoming still holds against current trunk. 
plan/index.d/20260916t001145z-15fba3c8-macneo.yaml	18	macneo: NOT MEASURABLE ON THIS HOST, and the reason is a second instan
plan/index.d/20260916t001222z-07ef18f0-macneo.yaml	18	macneo: INVENTORY CONFIRMED, WITH TWO CORRECTIONS TO HOW IT SHOULD BE 
plan/index.d/20260916t003351z-172c6f20-macneo.yaml	18	macneo: THE ARITHMETIC THIS ROW IMPLIES, MEASURED ON THE LOSING SIDE. 
plan/index.d/20260916t005445z-05ef33db-lenovinha.yaml	21	land: attempt 1 — gate ADOPTED, not run. ...
plan/index.d/20260916t011600z-1215-cxgb-yolandas-working-login-rests-on-an-unprovisioned-file-macuahuitl.yaml	37	honest: login failed loudly with an accurate message naming its own ca
plan/index.d/20260916t041500z-1220-zb7q-expire-claims-cannot-see-unlanded-work-macuahuitl.yaml	20	summary: in_progress=6 expired=2 held=0 unknown_age=0 ttl_hours=24
plan/index.d/20260916t080413z-3b8b9760-macos.yaml	38	name: macneo's count of that shape was wrong because the grep matched 
plan/index.d/20260916t081144z-399b73a8-macneo.yaml	18	macneo: HOST-KIND REPORT FOR macos, which is this row's exit criterion
plan/index.d/20260916t083645z-234e9eb8-macneo.yaml	18	macneo: I RAN THE REMEDY AND IT MADE MY HOST'S SIGNAL WORSE, which wid
plan/index.d/20260916t084000z-1222-u8vx-source-absent-reads-as-unsupported-macuahuitl.yaml	30	tokens: cycle=- main_ctx=0 subagent_tokens=0 agents=0 by_model=- avg_s
plan/index.d/20260916t115344z-1224-zpek-live-tray-fails-the-gate-macbookair.yaml	30	stderr: Error: --exec-guest needs to boot the VM, but a running
plan/index.d/20260916t120031z-08c00938-macos.yaml	25	correction: the relay ref is not an escape; two options, not three
plan/index.d/20260916t140000z-1226-jb8y-salvage-audit-needs-three-steps-macuahuitl.yaml	23	row: the check is not one command and every shortcut lies.
plan/index.d/20260916t161143z-278c63c0-macneo.yaml	18	macneo: THE DECISION HALF OF THIS ROW IS DONE; WHAT REMAINS IS PARITY 
plan/index.d/20260916t210000z-1228-xc6c-attestations-outside-the-plan-lane-macuahuitl.yaml	21	answers: "plan-only lane: not applicable — outside plan/index.d/,
plan/index.d/20260916t221500z-1229-2862-grade-calls-the-frame-blind-verifier-macuahuitl.yaml	68	place: "The reader-side audit, not the frame-blind verify". That is
plan/index.d/20260916t232000z-1231-cbie-uninstall-kill-ladder-unguarded-macuahuitl.yaml	133	claimed: nobody should edit an uninstaller's kill ladder at the end of
plan/index.d/20260916t234009z-256e353f-macuahuitl.yaml	46	verifier: rc=0, verify:skip-stale-staging, which is order 447's docume
plan/index.d/20260917t000500z-1232-av4p-forge-session-work-stranded-on-a-salvage-ref-macuahuitl.yaml	55	p1: `build-guest-binaries-prints-error-and-exits-zero-inside-a-green-c
plan/index.d/20260917t004500z-1233-jqp4-litmus-budgets-are-calibrated-against-a-corpus-that-only-grows-macuahuitl.yaml	44	floor: the timing log grows with every gate anyone runs and the ledger
plan/index.d/20260917t010500z-1235-b5sf-env-lock-second-mutex-yoga.yaml	79	p3: production code should take an INJECTED path instead of tests muta
plan/index.d/20260917t013131z-18028179-macuahuitl.yaml	35	invites: "plan-only pushes stay admitted during a freeze" reads as per
plan/index.d/20260917t015000z-1236-bmjh-sequential-removal-of-the-elevated-timeouts-macuahuitl.yaml	47	tree: roughly 1.1 million string comparisons per load on this corpus,
plan/index.d/20260917t033934z-04ca55e3-macuahuitl.yaml	31	implemented: the local stamp must carry today's date in the date field
plan/index.d/20260917t035403z-38a99981-macuahuitl.yaml	29	independently: 56.9.11.x IS 2026-09-11. The launcher's version is exac
plan/index.d/20260917t074001z-39a25256-macuahuitl.yaml	48	omitted: macuahuitl committed mid-gate (violation:...:3) and yoga-silv
plan/index.d/20260917t1210z-1239-cges-epic-head-is-real-work-nothing-can-offer-macos.yaml	58	available: making the selector offer heads would hand out all 13
plan/index.d/20260917t160358z-378b0878-macuahuitl.yaml	30	happened: the block still stops the tray, by a different matcher. The 
plan/index.d/20260917t162538z-1241-8gy4-workspace-test-memoisation-two-host-macuahuitl.yaml	58	purpose: the timing log is live and this host's run count read 180 twe
plan/index.d/20260917t213605z-0ec9ad10-macuahuitl.yaml	40	skipped: not Darwin, or a live tray is present (the matcher was NOT
plan/index.d/20260917t234321z-1247-amcu-every-refusal-carries-an-affordance-macuahuitl.yaml	55	bugs: the checks should not read as checks, they should read as
plan/index.d/20260917t235547z-1355af63-macuahuitl.yaml	47	hosts: scripts/run-litmus-test.sh is 2390 readable lines, `grep -c "st
plan/index.d/20260918t001302z-14af8fdd-macuahuitl.yaml	24	otherwise: gpu/container/ollama, gpu/host-native/ollama, cpu/container
plan/index.d/20260918t013131z-1248-j6vd-cdi-currency-keys-on-driver-not-files-macuahuitl.yaml	23	crun: cannot stat `/usr/lib64/libnvidia-egl-gbm.so.1.1.3`:
plan/index.d/20260918t013150z-1a47ffcd-macuahuitl.yaml	29	crun: cannot stat `/usr/lib64/libnvidia-egl-gbm.so.1.1.3`
plan/index.d/20260918t014513z-07807219-macuahuitl.yaml	47	filed: the spec pinned libnvidia-egl-gbm.so.1.1.3 against a host carry
plan/index.d/20260918t070039z-1252-composition-macuahuitl.yaml	131	intact: Lua DECLARES and DECIDES; Rust (1252-fg9e) SPAWNS, owns fds,
plan/index.d/20260918t201919z-1542306e-pirria-silverblue.yaml	52	live: a fresh `claude -p` in a tree with `.claude/skills -> ../skills`
plan/index.d/20260918t202400z-1253-nmmy-openspec-alias-trees-carry-three-divergent-generated-copies-pirria-silverblue.yaml	79	differently: 1238 is a search that reports success while seeing
plan/index.d/20260918t202800z-1254-pxw6-igpu-classified-discrete-by-bar-floor-pirria-silverblue.yaml	60	lanes: [container]}]`, which `check-capability-row.sh` folds to the to
plan/index.d/20260918t203004z-1253-54zj-npu-usable-derivation-yoga.yaml	90	here: this row can close on the derivation alone, and MUST be able to,
plan/index.d/20260918t204048z-322cc3e1-pirria-silverblue.yaml	37	things: 1253-nmmy (the 44 real openspec files in the other four trees)
plan/index.d/20260918t204100z-1256-f7td-skills-single-source-asserts-the-mechanism-not-the-output-pirria-silverblue.yaml	59	origin: the author could not be refused, and the check that would have
plan/index.d/20260918t204241z-133ab561-pirria-silverblue.yaml	42	them: deleting `.gemini/skills` outright would have made the red tree 
plan/index.d/20260918t211000z-1253-gina-killed-tray-orphans-the-vz-helper-macbookair.yaml	23	passes: after a tray process is SIGKILLed mid-`--exec-guest`, no
plan/index.d/20260918t211500z-1254-fdsu-awk-float-formatting-honours-lc-numeric-macbookair.yaml	26	passes: under an injected comma locale each listed producer emits a DO
plan/index.d/20260918t212116z-1254-47xd-container-lane-false-negative-yoga.yaml	66	version: a verdict derived from one input while a second input, presen
plan/index.d/20260918t212126z-1255-rvr7-skills-guard-population-and-tier-gap-yoga.yaml	35	yoga:      SKILLS_CHECK_RUNTIMES=".claude .opencode .codex .github"
plan/index.d/20260918t212157z-1d810524-pirria-silverblue.yaml	46	repeat: dropping the revert with `git reset --hard <commit>^` also dro
plan/index.d/20260918t212300z-1257-z3cu-a-host-in-a-long-gate-reads-as-idle-pirria-silverblue.yaml	39	side: a host that knows it has entered a long phase says so, with an E
plan/index.d/20260918t212505z-08a8c573-lenovinha-silverblue.yaml	44	retrieves: same model, same vectors, same ranking.
plan/index.d/20260918t212603z-2b2345a6-lenovinha-silverblue.yaml	50	next_action: criterion 3's seam is located and UNTOUCHED. dev-inferenc
plan/index.d/20260918t212610z-220e61e7-lenovinha-silverblue.yaml	54	next_action: nothing is left to BUILD. What is left is the DECISION th
plan/index.d/20260918t212815z-24c68d18-lenovinha-silverblue.yaml	34	ok: <packet>.title <the old title> -> lenovinha-silverblue
plan/index.d/20260918t223000z-1258-99k9-no-fast-pregate-lint-for-file-local-conventions-macbookair.yaml	125	request: macneo is floor tier under a standing instruction not to
plan/index.d/20260918t225148z-0ce32449-yoga-silverblue.yaml	33	yoga:      all four groundtruth/query-vectors/*.json are 768-dimension
plan/index.d/20260918t231640z-34c43590-tlatoanis-macbook-neo.yaml	228	row: cut a FRESH branch at the target ref and copy forward only the fi
plan/index.d/20260918t231728z-0d434768-tlatoanis-macbook-neo.yaml	38	reframe: establish whether the refusal still reproduces before hunting
plan/index.d/20260918t231925z-2819cee0-tlatoanis-macbook-neo.yaml	247	correct: exit 3 could-not-run, tokenised cause, and no substantive rea
plan/index.d/20260918t232046z-33ac39c8-tlatoanis-macbook-neo.yaml	247	correct: exit 3 could-not-run, tokenised cause, and no substantive rea
plan/index.d/20260918t235224z-0f02c4ec-pirria-silverblue.yaml	27	expect: plan-binary-locus-native: 2 passed, 1 failed     rc=1
plan/index.d/20260918t235434z-0c41cf6a-pirria-silverblue.yaml	30	rows: live=9 unclaimed=0 expired=0 held=0 unknown_age=0 total=9
plan/index.d/20260919t001425z-31106e50-esmeraldinha.yaml	21	ok: with both artefacts runnable, the probe resolves the locus-native 
plan/index.d/20260919t002715z-3390ce40-esmeraldinha.yaml	24	enumeration: physical_device_count=1 — llvmpipe only, type=CPU(4) driv
plan/index.d/20260919t002814z-06ab3b79-pirria-silverblue.yaml	21	esme: scripts/test-plan-binary-locus-native.sh -> 3 passed, 0 failed
plan/index.d/20260919t002814z-26f0f579-pirria-silverblue.yaml	24	error: pathspec 'we' did not match any file(s) known to git
plan/index.d/20260919t022500z-1265-8qr6-freeze-absent-for-the-whole-cut-host-landing-pirria-silverblue.yaml	92	construction: the transient state IS the finding, and it is only
plan/index.d/20260919t022953z-1b6bdb44-yoga-silverblue.yaml	26	yoga:      SKILLS_CHECK_RUNTIMES=".claude .opencode .codex .github"
plan/index.d/20260919t040044z-1266-75tr-litmus-pkill-self-match-yoga.yaml	21	command: "pkill -f tillandsias 2>/dev/null && sleep 3 && echo SHUTDOWN
plan/index.d/20260919t045447z-042c5530-yoga-silverblue.yaml	13	command: "pkill -f tillandsias 2>/dev/null && sleep 3 && echo SHUTDOWN
plan/index.d/20260919t050001z-306d0070-pirria-silverblue.yaml	22	land: attempt 1 — gate (~45 min on 4 cores), push, lost the race, retr
plan/index.d/20260919t054930z-06479b67-lenovinha-silverblue.yaml	25	land: attempt 1 — push
plan/index.d/20260919t074000z-1267-fj2z-audit-what-usr-lib-wsl-exposes-in-container-esmeraldinha.yaml	53	substance: "we're not entirely sure what that surface exposes besides
plan/index.d/20260919t093600z-1267-uafx-wsl-gate-leaves-native-plan-binary-stale-yolanda-windows.yaml	42	lands: after ./build.sh --check on a Windows host, the binary the prob
plan/index.d/20260919t162544z-1268-fx87-merged-channel-arms-are-the-executors-acceptance-test-yolanda-windows.yaml	55	warning: function `host_session_bus_path` is never used
plan/index.d/20260919t172254z-1269-6fcn-windows-target-headless-demands-a-linux-musl-artifact-yolanda-windows.yaml	45	error: failed to run custom build command for `tillandsias-headless v5
plan/index.d/20260919t175054z-091fe3e4-yolanda-windows.yaml	23	yq: ABSENT at this locus. By census NO ARM IN THIS SET CALLS IT, direc
plan/index.d/20260919t175118z-1029a904-yolanda-windows.yaml	21	error: writing status 'completed' requires --evidence <ref> (commit SH
plan/index.d/20260919t175123z-1270-wiki-long-path-checkout-fails-on-windows-yolanda-windows.yaml	38	fatal: cannot create directory at 'openspec/changes/archive/
plan/index.d/20260919t175519z-1268-m2ir-metrics-log-fallback-to-tmp-fires-inside-the-checkout-macuahuitl.yaml	29	macuahuitl: four records (litmus:credential-isolation,
plan/index.d/20260919t175520z-1270-5mz8-prebuilt-binary-resolved-by-existence-runs-stale-macuahuitl.yaml	61	once: every resolver that prefers a prebuilt compares it to its source
plan/index.d/20260919t190100z-1273-4mak-smoke-never-verifies-a-signature-macneo.yaml	29	overclaimed: install-macos.sh verifies the asset's SHA256 against the
plan/index.d/20260919t190717z-03e008f0-macneo.yaml	23	resolved: ./target/release/tillandsias-plan
plan/index.d/20260919t190723z-00c84d58-macneo.yaml	22	timeout: failed to run command 'cargo': No such file or directory
plan/index.d/20260919t191651z-20fc61b8-macneo.yaml	49	investigation: an awk that reported `_prepare_ci_full_install_inputs` 
plan/index.d/20260919t193528z-3053e416-yoga.yaml	24	via: validator-surface hash ... newer: Cargo.lock
plan/index.d/20260919t194003z-2275a780-pirria-silverblue.yaml	51	observation: **since a forge only ever regenerates `.opencode`, no amo
plan/index.d/20260919t201258z-1adc82b8-macneo.yaml	32	error: failed to push some refs
plan/index.d/20260919t203010z-10c4c920-macneo.yaml	23	macbookair: tree had taken a PLAN-ONLY merge on top of a stamped tree
plan/index.d/20260919t205431z-254f2c0b-pirria-silverblue.yaml	24	resolved: <scratchpad>/cargo-target/release/tillandsias-plan
plan/index.d/20260919t210842z-09b452d6-yoga.yaml	27	expected_behavior:  "ok: cargo-target-dir-success"
plan/index.d/20260919t213253z-1280-58kq-installer-says-stable-under-a-pinned-base-macneo.yaml	24	channel: stable
plan/index.d/20260919t221613z-2eaef0db-yoga.yaml	47	appeared: a guard's blind spot is the set of inputs its own evidence c
plan/index.d/20260919t232708z-1416a788-macneo.yaml	59	error: refusing to store prose passed through argv that carries a lite
plan/index.d/20260919t233254z-2211a6d6-pirria-silverblue.yaml	28	instrument: polling the agent's own log
plan/index.d/20260919t234418z-1238c317-pirria-silverblue.yaml	26	clearer: removed vault-data/ (via podman unshare — subuid-owned)
plan/index.d/20260920t023722z-371e4e48-macneo.yaml	35	surprising: the gate is the heaviest thing this host runs, and the fai
plan/index.d/20260920t040641z-1286-4437-install-resets-and-reprovisions-on-every-platform-macuahuitl.yaml	56	keep: the reset destroys the vault store, mirrors and images on the
plan/index.d/20260920t041000z-1293-wka4-step-child-shell-does-not-inherit-pipefail-pirria-silverblue.yaml	73	opposite: the runner sets pipefail, the stdlib names it five times,
plan/index.d/20260920t060422z-1289-ggsb-shared-local-experts-over-a-fleet-git-mirror-macuahuitl.yaml	36	work: which host serves it (the operator first named macuahuitl; the
plan/index.d/20260920t065303z-0be96cbc-esmeraldinha.yaml	22	error: read /mnt/c/Users/bullo/claudia/tillandsias/target/plan-scratch
plan/index.d/20260920t065304z-1e30758c-esmeraldinha.yaml	29	remote: No anonymous write access.
plan/index.d/20260920t065400z-1287-h6qn-plan-only-lane-reports-stale-when-the-validator-surface-stamp-is-merely-absent-esmeraldinha.yaml	55	via:      validator-surface hash — validate-yaml/check --strict-fragme
plan/index.d/20260920t071948z-1293-krrp-groundtruth-harness-parses-jsonrpc-by-line-number-macuahuitl.yaml	42	measured: the server answered nothing for that id (then the fix is
plan/index.d/20260920t075000z-1301-ie39-python-policy-is-a-spelling-denylist-macbookair.yaml	46	prefixes: `#!/usr/bin/env python`, `#!/usr/bin/python`, `python `/`pyt
plan/index.d/20260920t075052z-2184e7dd-yoga.yaml	56	could: pushing this slice printed "NOTICE — 4 litmus spec(s) assert on
plan/index.d/20260920t080456z-1295-b4i8-smoke-cache-purge-destroys-the-gate-toolchain-yolanda-windows.yaml	95	itself: the runbook has no fixture that runs a Windows smoke and check
plan/index.d/20260920t080611z-1296-jutd-land-refusals-reach-the-harness-as-exit-zero-yolanda-windows.yaml	53	exit: the refusal it correctly detected leaves as 0.
plan/index.d/20260920t080631z-1297-2htc-litmus-runner-cannot-provision-yq-from-the-toolbox-yolanda-windows.yaml	74	itself: a degraded run must report HOW MANY steps its missing
plan/index.d/20260920t110600z-2673a344-pirria-silverblue.yaml	38	exempt: a cycle saying it did not finish must still be able to say so.
plan/index.d/20260920t112102z-190c1c00-macneo.yaml	51	ok:   ARM 4: the comma locale DOES reform the load (1,81) and LC_ALL=C
plan/index.d/20260920t114241z-22ea1088-tlatoanis-macbook-neo.yaml	21	released: holding it on macneo gates nothing; pickup trigger is a refu
plan/index.d/20260920t114819z-1282-trqp-windows-instance-yolanda.yaml	13	warn: Test timeout after 30s in step: wrapper convergence sequence has
plan/index.d/20260920t122349z-1304-wbb2-litmus-wrong-block-binding-silent-macuahuitl.yaml	38	file: rc=0, ZERO mentions, PASS 0 / FAIL 0 / SKIP 0, `Coverage: 100%`;
plan/index.d/20260920t122833z-05f046c5-yoga.yaml	29	digest: sha256sum (/usr/bin/sha256sum)
plan/index.d/20260920t122849z-0a0ed058-macbookair-macos.yaml	21	ok:   ARM 2: an artifact matching its signature emits cosign:verified:
plan/index.d/20260920t123000z-1303-vt3y-salvage-reports-deletions-as-skipped-macbookair.yaml	22	then: the ref's `git diff --stat <ref>^ <ref>` shows the file removed,
plan/index.d/20260920t124623z-033964c8-macneo.yaml	67	here: a host reset on that promise keeps its Vault share.
plan/index.d/20260920t140000z-1307-kic6-trunk-pushes-hang-while-salvage-pushes-go-yolanda.yaml	55	account: the hangs include PLAN-ONLY fast-lane pushes to trunk,
plan/index.d/20260920t142353z-186fa2f2-yoga.yaml	66	deferral: the fixture's default path shells out only to cp date dirnam
plan/index.d/20260920t143000z-1307-kic6-two-run-experiment-yolanda.yaml	24	error: failed to push some refs to '...'
plan/index.d/20260920t144535z-1309-qc95-ssh-lane-falls-open-lenovinha-silverblue.yaml	41	found: 1288-5qpn, which requires the relay and hooks to FAIL HARD with
plan/index.d/20260920t154452z-23bff0e0-yolanda-windows.yaml	25	working: the working tree carried code changes the last gate had not c
plan/index.d/20260920t160128z-2af12e4c-esmeraldinha.yaml	58	command: not extractable (single-line double-quoted scalar required; f
plan/index.d/20260920t161822z-1f0de8f4-yolanda-windows.yaml	20	yolanda: a push through scripts/push-plan-fragments-to-trunk.sh return
plan/index.d/20260920t174500z-1309-rb3p-tray-pushes-forwarder-target-macbookair.yaml	25	set: with NO file written by hand and NO env var set in the guest, a c
plan/index.d/20260920t180105z-1310-rec6-mirror-integrity-and-refusal-lenovinha-silverblue.yaml	35	lenovinha: "we should have discipline on when we can restart it, but f
plan/index.d/20260920t180536z-1311-kmyk-initialize-bare-metal-host-skill-lenovinha-silverblue.yaml	24	arm: add any token seeding, prompt, or copy to the skill and this arm 
plan/index.d/20260920t181644z-1312-i6da-initialize-bare-metal-host-skill-macuahuitl.yaml	36	checked: the skill carries a `## Repairs` section where every entry
plan/index.d/20260920t182523z-1313-prin-mirror-ssh-lane-wires-lenovinha-silverblue.yaml	37	evidence: (a) a push to linux-next (a plan-lane fragment push or a gat
plan/index.d/20260920t183000z-1309-q4kr-smoke-destroys-builder-toolbox-pirria.yaml	27	ensure_ca_bundle: "Failed to run command: No such file or directory (o
plan/index.d/20260920t184503z-05d1fc9b-pirria.yaml	19	moves: "three sub-second deciders" is TWO sub-second deciders and ONE 
plan/index.d/20260920t185100z-1315-d4qd-destructive-roots-have-silent-defaults-macneo.yaml	61	false: it names /tmp paths, does exactly what it said, exits 0, and th
plan/index.d/20260920t185901z-128833a0-macbookair-macos.yaml	24	forwarder: running
plan/index.d/20260920t190500z-plan-only-lane-refusals-measured-pirria.yaml	70	subject: the remedy is only complete because the checker itself is wha
plan/index.d/20260920t201034z-10822341-pirria.yaml	46	breakage: the pass RATE's VALUE changes on hosts where a skip previous
plan/index.d/20260920t211517z-14e304b8-yolanda-windows.yaml	57	file: subject AND control both read 0, so the instrument's silence loo
plan/index.d/20260920t214440z-0e06c83c-yolanda-windows.yaml	37	incidental: the vsock vocabulary is linked into both binaries, and the
plan/index.d/20260920t214500z-1287-h6qn-retraction-and-mtime-mechanism-pirria.yaml	18	step: attempt 1 refused, attempt 2 pushed, with only a fetch and a reb
plan/index.d/20260920t225715z-2bdcf840-yoga.yaml	24	selector: scripts/change-class.sh plus a selector matrix in build.sh. 
plan/index.d/20260920t230000z-1323-5taw-capability-probe-reads-help-which-a-lying-help-defeats-yolanda.yaml	55	binaries: probe a refusal by asking for the refusal. A version check, 
plan/index.d/20260921t000345z-1321-2ixp-salvage-snapshot-loses-exec-bits-macuahuitl.yaml	34	shape: a gate step wired from one regime), so a mode lost on a Windows
plan/index.d/20260921t001449z-274bf874-yoga.yaml	42	test: unknown path -> FULL; missing or unfetchable base ref -> FULL;
plan/index.d/20260921t004052z-09c0847b-yoga.yaml	42	style: LIGHT = {plan-ledger, docs}; SCOPED adds {specs, methodology,
plan/index.d/20260921t004436z-0a4d59dc-yoga.yaml	47	producer:        NO MATCH — UNBOUNDED_PRODUCER_RE lists cat, find, jou
plan/index.d/20260921t013000z-1324-emdf-smoke-consent-gate-sits-after-the-destruction-yolanda.yaml	49	point: after the unregister.
plan/index.d/20260921t025926z-174d7320-pirria.yaml	33	ruling: fix forward, never a repaired tag), and its README row carries
plan/index.d/20260921t033000z-1327-r4bx-push-script-reselects-fragments-mid-flight-esmeraldinha.yaml	30	those: a reader who saw only the launch line and the final line can sa
plan/index.d/20260921t042804z-01f22b4f-yoga.yaml	34	plausible: 5/5 is a passing line and would have been reported as a pas
```
