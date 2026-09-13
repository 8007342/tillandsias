#!/usr/bin/env bash
# ORDER 1119-6wn6. The loop can say what a cycle spent in tokens, and which
# repeated work keeps costing them.
#
# THE OPERATOR'S DIRECTIVE, 2026-09-11: "we've been burning tokens wildly and
# have been running out of tokens in the worst possible moments, as well as
# having no token awareness ... we need to start monitoring our token cost and
# see if we have expensive repeatable works we could simplify". The loop had
# CPU-time instruments (timing:, recur:, skippable:) and no token instrument, so
# a 42-agent read-only sweep cost 4,480,590 tokens and nobody could see it until
# somebody asked.
#
# ATTESTED, NOT MEASURED. The harness reports token totals TO THE AGENT; nothing
# in this repo can observe them. So the agent states the number and the script
# folds it — the check-mcp-surface shape. These arms therefore pin the LEDGER
# and the VIEWS, which are scriptable, and cannot pin the honesty of the input,
# which is not.
#
# REGIME. Every arm drives the real scripts/cycle-metrics.sh against a scratch
# log in a temp dir via TILLANDSIAS_TOKENS_LOG, so no arm reads or writes this
# host's real metrics. TILLANDSIAS_TIMING_LOG is pinned for the same reason the
# fixture next door pins it: this host carries two timing logs and the reporting
# path refuses until one is named, which would otherwise make these arms
# host-dependent.
#
# Prints one PASS/FAIL summary line and exits 0/1.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

pass=0; fail=0
ok()  { echo "ok:   $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*" >&2; fail=$((fail + 1)); }

CM="scripts/cycle-metrics.sh"
[ -f "$CM" ] || { bad "$CM is missing"; echo "token-instrument: $pass passed, $fail failed"; exit 1; }

W="$(mktemp -d "${TMPDIR:-/tmp}/token-instr.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM
LOG="$W/tokens.jsonl"
# A timing log that exists and is empty: the reporting path only needs it NAMED.
: > "$W/timing.jsonl"

emit() { TILLANDSIAS_TOKENS_LOG="$LOG" bash "$CM" --emit-tokens "$@" 2>/dev/null; }
report() {
    TILLANDSIAS_TOKENS_LOG="$LOG" TILLANDSIAS_TIMING_LOG="$W/timing.jsonl" \
        bash "$CM" 2>/dev/null
}

# ── 1. source=absent BEFORE any record. The row asks for this explicitly: a
#      zeroed line with a path would be a guess dressed as an empty window.
out="$(report | grep -E '^tokens:' || true)"
case "$out" in
    *"source=absent"*) ok "with no log, tokens: reads source=absent" ;;
    "")                bad "no tokens: line is rendered at all" ;;
    *)                 bad "with no log, tokens: did not say absent: $out" ;;
esac

# ── 2. A RECORD IS APPENDED AND RENDERED. ─────────────────────────────────
emit host=h cycle=c1 main_ctx=250000 subagent_tokens=4480590 agents=42 by_model=opus:42 label=recon
[ -s "$LOG" ] && ok "--emit-tokens appends a record" || bad "--emit-tokens wrote nothing"
out="$(report | grep -E '^tokens:' || true)"
case "$out" in
    *"subagent_tokens=4480590"*agents=42*) ok "tokens: renders the attested spend" ;;
    *) bad "tokens: did not render the record: $out" ;;
esac

# ── 3. POISONED NUMERICS COERCE, they never reach the log. One bad row would
#      corrupt the rolling average for every future cycle.
# ASSERT THE POSITIVE FIRST. "abc is absent from the log" is trivially true when
# there is NO log — measured: this arm passed against the pre-fix script, which
# has no --emit-tokens at all. An absence assertion that survives the feature
# being deleted is not a test. Require the coerced ROW to exist, then require the
# poison to be absent from it.
emit host=h cycle=bad subagent_tokens=abc agents=-5 label=x
_bad_row="$(grep '"cycle":"bad"' "$LOG" 2>/dev/null || true)"
if [ -z "$_bad_row" ]; then
    bad "the coerced row was never written, so nothing here is being tested"
elif printf '%s' "$_bad_row" | grep -q '"subagent_tokens":abc'; then
    bad "a non-numeric token count reached the log; the rolling average is now poisoned"
elif printf '%s' "$_bad_row" | grep -q '"subagent_tokens":0,"agents":0'; then
    ok "non-numeric counts coerce to 0 in a row that WAS written"
else
    bad "the coerced row has an unexpected shape: $_bad_row"
fi

# ── 4. REPLACE-ON-RETRY keyed host+cycle. A retried cycle must correct its row,
#      not append a second one that double-counts in the average.
before="$(grep -c . "$LOG")"
emit host=h cycle=c1 main_ctx=260000 subagent_tokens=4500000 agents=43 by_model=opus:43 label=recon
after="$(grep -c . "$LOG")"
if [ "$before" = "$after" ] && grep -q '4500000' "$LOG"; then
    ok "a retried cycle REPLACES its row (no double-count)"
else
    bad "retry appended instead of replacing (${before} -> ${after} rows)"
fi

# ── 5. token_recur RANKS REPEATED LABELS, and ONLY repeated ones. ─────────
rm -f "$LOG"
emit host=h cycle=r1 subagent_tokens=100000 agents=5  label=refuter-fanout
emit host=h cycle=r2 subagent_tokens=100000 agents=5  label=refuter-fanout
emit host=h cycle=r3 subagent_tokens=900000 agents=20 label=commit-review
emit host=h cycle=r4 subagent_tokens=900000 agents=20 label=commit-review
emit host=h cycle=r5 subagent_tokens=4480590 agents=42 label=one-off-sweep
out="$(report | grep -E '^token_recur:' || true)"
case "$out" in
    *commit-review*refuter-fanout*) ok "token_recur ranks repeated labels by total spend" ;;
    *) bad "token_recur did not rank the repeated labels: $out" ;;
esac
# THE DESIGN DECISION, pinned: a one-off is a COST, not a recurrence. Ranking it
# would bury the cheap thing paid fifty times — the one the operator asked to
# find. The 4.48M sweep is the largest number in the log and must NOT appear.
# SAME CORRECTION: "one-off-sweep is absent" is trivially true when NO
# token_recur line exists, and this arm passed against the pre-fix script for
# exactly that reason. Require the line to be ranking something first.
case "$out" in
    "") bad "no token_recur line at all, so the one-off exclusion is untested" ;;
    *"top3=-"*) bad "token_recur ranked nothing, so the one-off exclusion is untested" ;;
    *one-off-sweep*) bad "a single-run label was ranked as a recurrence; the largest one-off will always bury the genuinely repeated work" ;;
    *) ok "a single-run label is NOT ranked while others ARE (a one-off is a cost, not a recurrence)" ;;
esac

# ── 5b. token_max SURFACES WHAT token_recur DELIBERATELY HIDES. ───────────
#      Added on review, and the reasoning is sharper than the original design:
#      the incident that produced this packet WAS a one-off 4.5M sweep, so a
#      view that excludes one-offs by construction would have been silent on the
#      very thing that prompted the operator's directive. Ranking it in
#      token_recur would bury the cheap thing paid fifty times; omitting it
#      everywhere would lose the largest number in the log. Two views, two
#      questions, nothing buried — so both halves are pinned together here.
out_recur="$(report | grep -E '^token_recur:' || true)"
out_max="$(report | grep -E '^token_max:' || true)"
case "$out_max" in
    "") bad "no token_max line at all — the largest single spend is invisible again" ;;
    *"tokens=4480590"*one-off-sweep*) ok "token_max surfaces the one-off with its label" ;;
    *) bad "token_max did not surface the largest record: $out_max" ;;
esac
# The pairing is the point: the SAME record must be in one view and not the
# other. Asserting either alone would let a later 'simplification' collapse them.
case "$out_recur" in
    *one-off-sweep*) bad "the one-off appears in BOTH views; token_recur has stopped excluding single runs" ;;
    *) ok "the same one-off is absent from token_recur (two views, two questions)" ;;
esac

# ── 5c. A ZERO-SPEND LABEL IS NOT "TOKEN-EXPENSIVE". Found by dogfooding: two
#      zero-spend cycles under one label rendered as
#          top3=advance-work-from-plan-drain:tokens=0:runs=2
#      i.e. the top token-EXPENSIVE repeated work was work that spent nothing.
#      An instrument reporting something adjacent to what it claims is the class
#      this packet exists to remove, so it must not commit it.
rm -f "$LOG"
emit host=h cycle=z1 subagent_tokens=0 agents=0 label=free-work
emit host=h cycle=z2 subagent_tokens=0 agents=0 label=free-work
out="$(report | grep -E '^token_recur:' || true)"
case "$out" in
    *free-work*) bad "a label that spent ZERO tokens is ranked as token-expensive recurrence: $out" ;;
    *"top3=-"*)  ok "a zero-spend repeated label is not ranked as token-expensive" ;;
    *)           bad "unexpected token_recur for a zero-spend corpus: $out" ;;
esac
# ...and token_max must still NAME the cycle, because "the largest spend was 0,
# here" and "there is nothing here" are different answers that must not share a
# rendering. This one rendered `label=- cycle=-` before, indistinguishable from
# an empty log.
out="$(report | grep -E '^token_max:' || true)"
case "$out" in
    *"label=free-work"*) ok "token_max names the cycle even when every record spent 0" ;;
    *"label=-"*)         bad "token_max renders label=- on a NON-EMPTY log — indistinguishable from having no data at all: $out" ;;
    *)                   bad "unexpected token_max on a zero-spend corpus: $out" ;;
esac

# ── 6. NEGATIVE CONTROL (the row names it): a cycle that spawned nothing
#      reports zeros and is not flagged.
rm -f "$LOG"
emit host=h cycle=solo main_ctx=120000 subagent_tokens=0 agents=0 label=solo
out="$(report | grep -E '^tokens:' || true)"
case "$out" in
    *"subagent_tokens=0"*"agents=0"*) ok "NEGATIVE CONTROL: a no-sub-agent cycle reports subagent_tokens=0 agents=0" ;;
    *) bad "NEGATIVE CONTROL: a solo cycle did not report zeros: $out" ;;
esac
out="$(report | grep -E '^token_recur:' || true)"
case "$out" in
    *"top3=-"*) ok "NEGATIVE CONTROL: a solo cycle is not flagged by token_recur" ;;
    *)          bad "NEGATIVE CONTROL: a solo cycle was flagged as a token recurrence: $out" ;;
esac

# ── 6b. PER-CYCLE AND CUMULATIVE ARE DIFFERENT FIELDS. ────────────────────
#      Added after the author put a SESSION TOTAL in `main_ctx`, whose contract
#      is per-cycle — the same conflation that kept the 4.5M baseline out of a
#      host log, committed one line later in the author's own record. When only
#      the running total is observable, it goes in main_ctx_cumulative and
#      main_ctx stays 0, so a reader sees WHICH question was answered instead of
#      inferring it from prose.
rm -f "$LOG"
emit host=h cycle=cum main_ctx_cumulative=900000 subagent_tokens=0 agents=0 label=solo
out="$(report | grep -E '^tokens:' || true)"
case "$out" in
    *"main_ctx=0"*"main_ctx_cumulative=900000"*)
        ok "a cumulative attestation renders distinctly from a per-cycle one" ;;
    *) bad "main_ctx and main_ctx_cumulative are not distinguishable in the line: $out" ;;
esac

# ── 7. THE INSTRUMENT CANNOT TAKE DOWN THE CYCLE IT MEASURES. An unwritable
#      log must not make the emit fail: best-effort by contract, like
#      --emit-flow. This is the property that keeps a metrics bug from becoming
#      an outage.
if TILLANDSIAS_TOKENS_LOG=/proc/cannot/exist/tokens.jsonl bash "$CM" --emit-tokens host=h cycle=x subagent_tokens=1 >/dev/null 2>&1; then
    ok "an unwritable log still exits 0 (best-effort; an instrument must not break the cycle)"
else
    bad "--emit-tokens failed on an unwritable log — a metrics path can now take down a cycle"
fi

echo "token-instrument: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
