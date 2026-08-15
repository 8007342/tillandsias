## Cycle 4 2026-08-15 tlatoani — compacted the ledger, and unstuck a p0 nobody could claim

**Ledger GC.** 78 fragments / 216 KB folded (`plan/index.yaml` 46824 → 49549).
Verified non-lossy before accepting it, because a lossy fold is the regression
compaction refused for months: 2730 added, 5 removed, and ALL FIVE removed lines
are `status:` fields replaced by their folded LWW value (532→in_progress,
647-i98k→done, 690-eug2→done, 722-hthz→implemented, +1). Zero non-status
removals; comment lines 123→128; 873 packets, references sound.

**Split 722-ecne (p0) into six rungs.** `select-work-batch.sh` reported it as
`urgent=` on FOUR consecutive cycles across two seeds and no host claimed it.
Not neglect — its body is design rungs T3-T13 (eleven rungs: git image, host
cert, sshd_config, receive wrapper, repo hardening, agent sidecar, Vault audit
volume, forge wiring, staged migration, spec amendments) against a 3h estimate.
It does not fit a cycle and the selector cannot say so.

Children carry closures the DESIGN already names, not ones invented for the
split: 749-wv4d (T3, the design's own highest-risk rung R1 §5 — sshd under
`--read-only`/`--cap-drop=ALL` as uid 1000:2222, to be verified in-container
before anything builds on it), 749-54pv (T4+T5, closure = the single-principal
host-cert fixture), 749-2fqj (T6+T7, closures = §4a M5 and the design's
EXISTING-volume upgrade fixture), 749-6uby (T8+T10, closures = §4a M0 and D5
re-verified), **749-8iw4 (T9, deliberately NO depends_on** — the parent's own
notes said M6 is blocked on it and it needs none of the sshd rungs, so a small
independent fix had been waiting behind eleven rungs of unrelated work),
749-y8xx (T11+T12). T13 intentionally not a child: it belongs with slice d,
722-uern, which owns the matrix.

**Both split parents set `blocked`, not obsoleted.** `obsoleted` SATISFIES
DEPENDENTS and would have falsely unblocked 722-uern's §4a negative matrix
before a single rung existed. 606-bvnp was the same shape one level up: all four
slices spoken for, yet `next linux` ranked it **#1 claimable** — a host
following the selector would have burned a cycle finding nothing in it.

Falsifiable result: `urgent=` moved from the eleven-rung packet to 749-wv4d
(one rung), and eligible dropped 147 → 146. Filed **750-zrt4** (p2) for the
general defect — a delegated parent stays `ready` because only `ready` is
claimable, and `split_into` is prose the integrity gate already reports as
organic reference debt, so nothing machine-readable links parent to children.

**Not run: destructive e2e.** `e2e-preflight.sh eligibility` →
`skip:live-runtime-present` (it is protecting the live stack this loop validates
with), and the curl-install gate tests a PUBLISHED v0.4 release rather than
draining v0.5. Recorded rather than silently skipped. Also recorded: the plan
expert answers `confidence=unsupported` for "what is the latest tested release?"
— a fact the skill requires a cycle to consult before prioritising e2e.

Suite green. Plan 879 packets. Release: untouched.
