# Axis B: the gate's filesystem multiplier is per-step, not global

Measured on yolanda (Windows 11 host, WSL2 `tillandsias-build`), 2026-08-31.
Packet 941-trcf. Both arms are the SAME forced, profiled gate on the SAME
commit, differing only in which filesystem the checkout sits on.

    TILLANDSIAS_FORCE_CHECK=1 TILLANDSIAS_GATE_PROFILE=1 ./build.sh --check

| arm | path | filesystem | total | attributed |
|---|---|---|---|---|
| 9P   | `/mnt/c/Users/bullo/claudia/tillandsias` | v9fs (DrvFs) | **767s** | 766s |
| ext4 | `/root/stage`                            | ext2/ext3    | **283s** | 281s |

Staging cost 9s (`git clone --no-hardlinks`, 245M). **Net saving 475s per
forced gate run, 2.71x overall, staging paid.**

## The finding: there is no single multiplier

The story that commissioned this asked whether three named steps were
*equally* filesystem-bound "before assuming the multiplier generalizes — do
not extrapolate". They are not, and the spread is two orders of magnitude:

| step | 9P | ext4 | multiplier |
|---|---|---|---|
| ghost-trace ratchet (584-2qq2) | 67.6s | 1.4s | **48.29x** |
| writing the gate stamp | 59.6s | 1.7s | **35.06x** |
| terminology dictionary (629-t6bx) | 42.2s | 41.9s | **1.01x** |

Same gate, same tree, same run. Applying the earlier-measured 2.96x uniformly
would have predicted the dictionary at 14.3s and booked 28s of savings that do
not exist, while under-predicting the ratchet by a factor of sixteen.

The 2.96x measured earlier on the archiver was never a filesystem constant. It
was one step's coefficient.

## Why: the multiplier tracks file-operation COUNT

Not bytes, not CPU. The extremes make the mechanism plain — 78x for the SIGPIPE
scan and 48x for the ghost ratchet, both of which walk many small files and
compute almost nothing, against 1.01x for the dictionary, which reads its corpus
once and then spends 42s parsing. 9P charges per operation, so a step's exposure
is set by how many times it crosses the boundary.

This also explains the archiver's host split, confirmed independently by
macuahuitl: the same check is 11.2s standalone on a native-ext4 Linux host
(halved from 22.4s by the ledger compaction) against 248.6s here — 22x. It is
parse-dominated there and op-latency-dominated here, so ledger compaction helped
that host and could not help this one.

## Consequences

1. **Axis B is worth doing on 9P hosts**: 475s per run for 9s of staging.
2. **The dictionary is the counterexample that matters.** Its 42s cannot be
   touched by staging on any host. If it must get faster that is parser work —
   and no amount of check-collapsing helps either, since it is one step.
3. **Archiver file-op batching is the best-supported cross-host win**: 5.37x
   and 202s saved here, and unlike staging it helps every host including the
   ones already on native filesystems.

## Note on the retired baseline

An earlier 561s figure circulated as the gate's cost. It was a rolling average
over recent runs, not a single forced run, and was recorded with that caveat.
"767s forced vs 561s aggregate" is not a valid delta and **no regression was
ever established**. The four steps this story tracked in fact IMPROVED in
aggregate, 463.6s -> 418.0s, between the compaction and this measurement.

## Full per-step table

All 75 steps present in both arms, sorted by seconds saved.

| 9P (s) | ext4 (s) | mult | saved (s) | step |
|---|---|---|---|---|
| 248.6 | 46.3 | 5.37x | 202.3 | Checking the plan archiver preserves the ready set (831-ezea) |
| 67.6 | 1.4 | 48.29x | 66.2 | Ratcheting ghost traces for the gate stamp (584-2qq2) |
| 70.0 | 4.3 | 16.28x | 65.7 | Checking groundtruth cases grade the same with inference up or down (928-qm8k) |
| 59.6 | 1.7 | 35.06x | 57.9 | Writing the gate stamp |
| 65.5 | 15.7 | 4.17x | 49.8 | Running plan ledger tests (cargo test -p tillandsias-plan, all targets) |
| 24.0 | 1.4 | 17.14x | 22.6 | Checking for if-not pipeline verdict guards (795-imz3) |
| 20.5 | 3.7 | 5.54x | 16.8 | Checking the durable MO-FULL attestation ledger (614-2gqx) |
| 20.2 | 8.8 | 2.30x | 11.4 | Checking image rebuild keeps the installed binary's launch tag (747-knbp) |
| 13.0 | 2.0 | 6.50x | 11.0 | Checking the pre-push empty-ref-list fixture (877-mynm) |
| 7.8 | 0.1 | 78.00x | 7.7 | Checking for newly-added SIGPIPE-decidable verdict pipelines (792-ksr8) |
| 14.4 | 6.8 | 2.12x | 7.6 | Checking scripts/ bash dialect (761-g36m) |
| 8.2 | 3.8 | 2.16x | 4.4 | Checking plan-binary resolution goes through the shared probe (721-nyev) |
| 4.3 | 0.8 | 5.37x | 3.5 | Checking Rust formatting |
| 10.1 | 6.6 | 1.53x | 3.5 | Checking plan/long-running.md matches the live multi_cycle set (251 LM-04) |
| 3.9 | 1.2 | 3.25x | 2.7 | Checking source-slice bounds still resolve (797-8dzt) |
| 2.9 | 0.4 | 7.25x | 2.5 | Checking skills have exactly one source of truth (631-wpkd) |
| 2.4 | 0.2 | 12.00x | 2.2 | Checking the synchronous podman surface stays bounded (714-4r6w) |
| 2.4 | 0.2 | 12.00x | 2.2 | Checking scripts invoked by path are executable (731-d89b) |
| 3.3 | 1.2 | 2.75x | 2.1 | Reporting litmus line-window pins (925-erjs, advisory) |
| 2.9 | 1.1 | 2.64x | 1.8 | Checking litmus pin claims resolve and execute (721-77yu) |
| 4.0 | 2.3 | 1.74x | 1.7 | Checking groundtruth cases for mutable-status pins (680-zphp) |
| 3.8 | 2.2 | 1.73x | 1.6 | Checking every litmus file is bound, retired, or grandfathered (660-ryhn) |
| 2.1 | 0.5 | 4.20x | 1.6 | Checking every ledger fragment is intact (whole overlay) |
| 2.1 | 0.9 | 2.33x | 1.2 | Checking every litmus definition parses (933-4gm8) |
| 1.6 | 0.4 | 4.00x | 1.2 | Checking the file -> covering-litmus-specs query (748-tkjx) |
| 1.2 | 0.1 | 12.00x | 1.1 | Checking wsl.exe has a single constructor (795-jjw3) |
| 1.2 | 0.1 | 12.00x | 1.1 | Checking that added fragment closures carry evidence (686-7qcm) |
| 1.7 | 0.7 | 2.43x | 1.0 | Checking the append-event archived-refusal fixture (896-f8ti) |
| 1.5 | 0.6 | 2.50x | 0.9 | Checking for fragment status transitions the fold discards |
| 0.8 | 0.1 | 8.00x | 0.7 | Checking the proxy's permissive port agrees with its consumers (245 P6) |
| 0.8 | 0.1 | 8.00x | 0.7 | Checking the enclave membership list matches the code (245 P8) |
| 0.8 | 0.1 | 8.00x | 0.7 | Checking VERSION-bump isolation on outgoing commits (702-eusw) |
| 0.9 | 0.3 | 3.00x | 0.6 | Checking the live MCP server build join (823-u3k9) |
| 0.7 | 0.1 | 7.00x | 0.6 | Checking for newly-added expression-pinned litmus steps (634-39ik) |
| 0.6 | 0.1 | 6.00x | 0.5 | Checking new plan/issues citations name symbols, not lines (881-29me) |
| 1.8 | 1.4 | 1.29x | 0.4 | Checking host-identity derivation |
| 1.3 | 0.9 | 1.44x | 0.4 | Checking the promote-stable evidence gate and dry-run |
| 1.3 | 0.9 | 1.44x | 0.4 | Checking the hardware fingerprint refuses an untrue twin claim (805-r98w) |
| 0.9 | 0.5 | 1.80x | 0.4 | Checking the base ledger for completions the fold hides (751-i9mb, advisory) |
| 0.6 | 0.2 | 3.00x | 0.4 | Checking end-user UX strings against recorded operator approval (626-w3fn) |
| 0.5 | 0.1 | 5.00x | 0.4 | Checking that fragments added by this change parse |
| 42.2 | 41.9 | 1.01x | 0.3 | Checking user-visible terminology against the dictionary (629-t6bx) |
| 0.6 | 0.3 | 2.00x | 0.3 | Checking that open packets carry a next_action (831-ezea, advisory) |
| 0.5 | 0.2 | 2.50x | 0.3 | Checking capability-row truth dimension (889-ewvt) |
| 1.3 | 1.1 | 1.18x | 0.2 | Checking the evidence capture helper (899-6pwv) |
| 0.7 | 0.5 | 1.40x | 0.2 | Checking the sanctioned YAML reader is present here (746-htj9) |
| 0.5 | 0.3 | 1.67x | 0.2 | Checking the test-baseline ratchet's own fixture |
| 0.3 | 0.1 | 3.00x | 0.2 | Reporting macOS-only source verification state (739-6r6n) |
| 0.3 | 0.1 | 3.00x | 0.2 | Checking the plan fragment backlog against the compaction cadence (941-trcf, advisory) |
| 0.2 | 0.0 | 0.00x | 0.2 | Reporting Windows-only source verification state (716-f5kc) |
| 0.8 | 0.7 | 1.14x | 0.1 | Checking the issue-capture fast lane keeps its boundaries (889-twhe) |
| 0.4 | 0.3 | 1.33x | 0.1 | Checking a gate stamp cannot be written unearned (940-f77j) |
| 0.3 | 0.2 | 1.50x | 0.1 | Checking the checkout-lock attested-release fixture (899-q9di) |
| 0.3 | 0.2 | 1.50x | 0.1 | Checking plan fragments use keys the fold reads (944-vim8) |
| 0.3 | 0.2 | 1.50x | 0.1 | Checking capability-row host resolution (859-b2zc) |
| 0.2 | 0.1 | 2.00x | 0.1 | Cross-target workspace check (656-spux) |
| 0.2 | 0.1 | 2.00x | 0.1 | Checking the whole-overlay fragment guard's negative controls |
| 0.2 | 0.1 | 2.00x | 0.1 | Checking set-field emits valid YAML for every value shape |
| 0.2 | 0.1 | 2.00x | 0.1 | Checking point-of-use instrument freshness (851-cduu) |
| 0.2 | 0.1 | 2.00x | 0.1 | Checking litmus step scalars are unescaped consistently (875-v7hv) |
| 0.2 | 0.1 | 2.00x | 0.1 | Checking guest headless unit hardening (309) |
| 0.2 | 0.1 | 2.00x | 0.1 | Checking expire-claims --list-live names what it counts (905-wjfj) |
| 0.2 | 0.1 | 2.00x | 0.1 | Checking compaction deletes only what it folded (843-624y) |
| 0.1 | 0.0 | 0.00x | 0.1 | Checking the release runbook's tag/back-merge order (898-zhf3) |
| 0.9 | 0.9 | 1.00x | 0.0 | Checking the reclaim-stranded-claims fixture (943-unii) |
| 0.2 | 0.2 | 1.00x | 0.0 | Checking the nix-capability probe's evidence survives a noisy shell (917-zkge) |
| 0.2 | 0.2 | 1.00x | 0.0 | Checking the litmus step model (901-jtvi) |
| 0.2 | 0.2 | 1.00x | 0.0 | Checking plan/schema status-vocab divergence (440) |
| 1.2 | 2.0 | 0.60x | -0.8 | Checking plan order uniqueness (tillandsias-policy plan-orders) |
| 2.4 | 10.4 | 0.23x | -8.0 | Running clippy (strict + listen-vsock) |
| 3.1 | 12.4 | 0.25x | -9.3 | Checking plan ledger integrity (tillandsias-plan check) |
| 2.8 | 13.1 | 0.21x | -10.3 | Running clippy (strict; includes the workspace type-check) |
| 0.8 | 11.6 | 0.07x | -10.8 | Checking the new-surface parity railguard fixture (628-r2vk) |
| 0.3 | 23.6 | 0.01x | -23.3 | Staging router sidecar (build artifact — not committed) |
| 1.2 | 38.7 | 0.03x | -37.5 | Checking every fragment event lands on a real packet |

## What is actually realizable — the 475s is NOT the win

**Correction to this document's own headline, added before it was pushed.** The
475s is the filesystem's *theoretical* contribution. Most of it cannot be safely
captured, and an earlier measurement on this host (2026-08-30T21:40:10Z, same
packet) already established why: the two largest wins are the two steps whose
correctness depends on describing *the real worktree being pushed*.

| step | win here | safe to stage? |
|---|---|---|
| ghost-trace ratchet | 66.2s | **NO** — not without proof the stage equals the worktree |
| writing the gate stamp | 57.9s | **NO, by definition** — it must hash the real tree |
| plan archiver | 202.3s | only if the staged ledger is provably current |
| terminology dictionary | 0.3s | yes, and worth nothing |

Not hypothetical here: `pre-push-local-gate.sh` carries a
`stale:tree-changed-since-gate` refusal that exists precisely because a stamp
covering a *different* tree than the one being pushed is worse than no stamp.
Staging the gate-stamp step would institutionalise the failure that refusal was
written to catch. This session hit that refusal twice for real, against a
`git status` that read clean because it compares to HEAD rather than to the last
passing gate.

**Honest bottom line: the archiver alone, under a freshness proof** — 202.3s
gross, 193.3s net of the 9s staging. Better than the earlier ~58s estimate
because the archiver regressed on 9P since then, but it is ONE step, not 2.71x
of the gate.

The design question is the coordinator's: (a) stage only the archiver's work and
accept ~193s with a ledger freshness proof, (b) find a cheaper freshness proof
than a full hash — the interesting option, untried — which would also unlock the
ratchet's 66.2s, or (c) attack the 9P boundary itself.

## A contamination in the tail of the table, stated rather than hidden

Several rows show NEGATIVE savings — steps that ran *faster* on 9P:

| 9P | ext4 | step |
|---|---|---|
| 0.3s | 23.6s | staging router sidecar (build artifact) |
| 1.2s | 38.7s | every fragment event lands on a real packet |
| 0.8s | 11.6s | new-surface parity railguard fixture |

These are NOT filesystem effects. The 9P arm ran in the live checkout with warm
build artifacts and caches; the ext4 arm was a fresh clone that had to do the
work cold. Any step whose cost depends on cache warmth rather than file I/O is
contaminated in this comparison and its multiplier should not be quoted.

This does not weaken the headline — it makes it conservative. The cold-cache
penalty fell on the ext4 arm, so a warm ext4 arm would be FASTER than 283s and
the true filesystem multiplier is somewhat larger, not smaller. The steps the
conclusions rest on (archiver, ghost ratchet, gate stamp, dictionary) are
ledger and corpus I/O rather than build artifacts, and are not affected.
