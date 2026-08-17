## Cycle 2026-08-17T01:24Z (linux-immutable yoga — cycle 7, hourly fleet loop)

783-jdeh COMPLETED (7a30ff140) — and it corrected my own diagnosis from last
cycle, which is the part worth recording.

I filed it as an async-launch-build RACE. The race is real but secondary. The
primary defect is a PATH ASSUMPTION: every forge exports
CARGO_TARGET_DIR=$PROJECT_CACHE/cargo/target (lib-common.sh:1512), so the
mounted checkout has no ./target at all. cycle-preflight.sh runs `cargo build
--release -p tillandsias-plan`, it SUCCEEDS, and then resolve_plan_binary —
searching only ./target and PATH — cannot see the artifact it just built. It
reports blocked:preflight:plan:capabilities-refused, blaming the instrument
for a path assumption, and the forge cycle does zero work. That matches the
lane evidence exactly: capabilities-refused, no ./target directory, no build
error.

The sharp part: resolve_target_binary (order 770-ifeg) fifty lines DOWN IN THE
SAME FILE already honoured CARGO_TARGET_DIR, absolute or relative. The newer
generic probe had learned the lesson the older plan-specific one still had —
the fifth instance of the path-assumption class that 704-zcgi centralised this
file to end. Fixed by giving resolve_plan_binary the same precedence. With the
path fixed the race largely evaporates: preflight now finds what it built
rather than waiting for the launch build to install into ~/.local/bin.

New scripts/test-plan-binary-probe.sh, 5/5, hermetic (a stub answering
`capabilities` is the whole contract — no cargo, podman or network): forge
layout resolves; NEGATIVE CONTROL with the var unset REFUSES, without which
case 1 would prove nothing; ./target/release unregressed; relative
CARGO_TARGET_DIR honoured as its sibling does; a binary failing `capabilities`
still refused so callers keep the stale-vs-absent distinction. Writing the
fixture caught a bug in the FIXTURE — PATH=/nonexistent broke the stub's own
env-shebang and failed three cases against a correct probe; isolation only
needs tillandsias-plan off PATH. All eight probe callers re-verified.

LEDGER COMPACTION (dac3c108f): 49 fragments folded, 0 malformed, packets
unchanged at 978. Diff was +1798/-10, and the 10 removals deserve a note: all
are LWW field replacements (9 status: flips, 1 updated deliverable), which is
what the status channel does by design (642-fedr corrects ANY field). The
meta-orchestration skill states the property to protect as "1021 added lines
and ZERO removed lines". That held for the pure G-Set packet-append fold, but
a correct fold of the LWW channel MUST remove the superseded line — a gate
written to the letter of that sentence would read a legitimate status
correction as corruption. Flagging rather than editing the skill mid-cycle.

Metrics (verbatim): experts: calls=1724 answered=1723 unsupported=1 degraded=0
errors=0 answer_rate=99% | expert_accuracy: pass=21 total=21 rate=100% |
mcp: servers=3 per_server=cli=1714;forge-plan=10;project-info=6 health=ok |
flow: cycles=6 avg_completed_per_cycle=1.67 avg_commits_per_cycle=5
overhead_ratio=3 | timing: steps=62 build_check_ms_avg=17303
litmus_ms_avg=2591 slowest=build-check:25069 | plan: packets=978 ready=348 |
experts_substitution: unknown. flow: overhead_ratio 4.5 -> 4.2 -> 3.43 -> 3.13
-> 3.11 -> 3.00 across six cycles, monotone. Advisories: stranded=0,
compaction now not eligible (fragments=0), cheatsheet derived tree in sync.
Forge e2e not run: rate-limited until ~04:24Z. 626-p4xd and 760-hzi4 scoped
this cycle for the next one.
