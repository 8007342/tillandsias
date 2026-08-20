#!/usr/bin/env bash
# @trace spec:spec-traceability, plan 786-kjke
#
# test-groundtruth-corpus-declaration.sh — hermetic fixtures for the query
# set's `corpus:` declaration (order 786-kjke).
#
# THE BUG. `tillandsias-plan grade openspec/litmus-tests/groundtruth/*.yaml`
# — the obvious invocation — graded the two FIXTURE-BACKED sets against the
# LIVE ledger and reported `pass=22 fail=6`. All six were false: those sets are
# pinned against committed fixture corpora. The contract lived only in each
# file's header, where no machine could read it, so the tool did the wrong
# thing confidently and blamed the expert. A false red is as corrosive as a
# missed one (741-2izr) — more so here, because this harness is what the
# fleet's `expert_accuracy:` metric rests on.
#
# The load-bearing case is 3: a declared corpus must NOT become a way to make
# red things green. Every scenario builds its own throwaway set + ledger, so
# nothing here depends on the live ledger's contents.
#
# Run: scripts/test-groundtruth-corpus-declaration.sh   (exit 0 = pass)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The SHARED probe, never a hardcoded target/ path: an executable bit is a
# claim, running the binary is evidence (704-zcgi / 721-nyev / 751-vega), and
# build.sh refuses the hardcoded form outright — it caught this file's first
# draft.
# shellcheck source=/dev/null
. "$ROOT/scripts/plan-binary-probe.sh"
TDIR="$(mktemp -d)"
trap 'rm -rf "$TDIR"' EXIT

fail=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1" >&2; fail=1; }

PLAN="$(cd "$ROOT" && resolve_plan_binary)" || PLAN=""
if [ -z "$PLAN" ]; then
    echo "SKIP: no runnable tillandsias-plan (cargo build --release -p tillandsias-plan)" >&2
    exit 0
fi
# The probe answers repo-relative (./target/release/...). Several scenarios
# below `cd` into a throwaway tree, where a relative path resolves to nothing —
# so absolutize once, here, rather than per call site.
case "$PLAN" in
    /*) : ;;
    *) PLAN="$(cd "$ROOT" && cd "$(dirname "$PLAN")" && pwd)/$(basename "$PLAN")" ;;
esac

# A throwaway checkout-shaped tree: a "live" ledger and a fixture corpus that
# disagree, so grading the wrong one is detectable.
mkdir -p "$TDIR/plan" "$TDIR/fixtures/mycorpus/plan" "$TDIR/sets"
cat >"$TDIR/plan/index.yaml" <<'YAML'
plan_index:
  packets:
    - packet_id: live-only-packet
      order: 800-live
      status: ready
      title: Only in the live ledger
YAML
cat >"$TDIR/fixtures/mycorpus/plan/index.yaml" <<'YAML'
plan_index:
  packets:
    - packet_id: fixture-only-packet
      order: 800-fix
      status: ready
      title: Only in the fixture corpus
YAML

# A set that asks about a packet existing ONLY in the fixture corpus.
write_set() { # <path> <corpus-line-or-empty>
    {
        printf 'version: 1\n'
        printf 'name: corpus-declaration-fixture\n'
        [ -n "$2" ] && printf '%s\n' "$2"
        printf 'cases:\n'
        printf '  - id: corpus-fixture-only-packet\n'
        printf '    engine: plan.answer\n'
        printf '    query: "status of fixture-only-packet"\n'
        printf '    why: pins that the declared corpus is the one graded\n'
        printf '    expect:\n'
        printf '      confidence: exact\n'
        printf '      min_citations: 1\n'
    } >"$1"
}

# --- 1. WITHOUT a declaration, grading against the live ledger FAILS ------
# This reproduces the original symptom, and is what makes case 2 meaningful.
write_set "$TDIR/sets/undeclared.yaml" ""
out="$("$PLAN" --index "$TDIR/plan/index.yaml" grade "$TDIR/sets/undeclared.yaml" 2>/dev/null | tail -1)"
case "$out" in
    *"pass=0 fail=1"*) ok "an undeclared set graded against the wrong ledger FAILS (the original symptom)" ;;
    *) bad "undeclared case unexpected: $out" ;;
esac

# --- 2. WITH a declaration, the same case passes against its own corpus ---
write_set "$TDIR/sets/declared.yaml" "corpus: fixtures/mycorpus/plan/index.yaml"
out="$(cd "$TDIR" && "$PLAN" grade --root "$TDIR" --index "$TDIR/plan/index.yaml" "$TDIR/sets/declared.yaml" 2>/dev/null | tail -1)"
case "$out" in
    *"pass=1 fail=0"*) ok "a declared corpus is honoured — the same case now passes" ;;
    *) bad "declared case unexpected: $out" ;;
esac

# --- 3. NEGATIVE CONTROL: a genuinely wrong expectation STILL FAILS -------
# Without this, "always use the declared corpus" could mask real regressions:
# a harness that makes everything green is not a harness.
{
    printf 'version: 1\n'
    printf 'name: corpus-declaration-negative\n'
    printf 'corpus: fixtures/mycorpus/plan/index.yaml\n'
    printf 'cases:\n'
    printf '  - id: corpus-negative-control\n'
    printf '    engine: plan.answer\n'
    printf '    query: "status of fixture-only-packet"\n'
    printf '    why: a real regression must still be caught\n'
    printf '    expect:\n'
    printf '      confidence: exact\n'
    printf '      min_citations: 99\n'
} >"$TDIR/sets/negative.yaml"
out="$(cd "$TDIR" && "$PLAN" grade --root "$TDIR" --index "$TDIR/plan/index.yaml" "$TDIR/sets/negative.yaml" 2>/dev/null | tail -1)"
rc_neg=0
(cd "$TDIR" && "$PLAN" grade --root "$TDIR" --index "$TDIR/plan/index.yaml" "$TDIR/sets/negative.yaml" >/dev/null 2>&1) || rc_neg=$?
case "$out" in
    *"pass=0 fail=1"*)
        if [ "$rc_neg" -eq 1 ]; then
            ok "NEGATIVE CONTROL a wrong expectation still FAILS under a declared corpus (rc=1)"
        else
            bad "negative control failed but rc=$rc_neg (want 1)"
        fi
        ;;
    *) bad "negative control unexpected: $out" ;;
esac

# --- 4. a declared corpus that does not exist is a HARNESS ERROR (rc=2) ---
# Not a FAIL: "the corpus moved" must never read as "the expert is wrong",
# which is the exit-code separation the grade handler documents.
write_set "$TDIR/sets/missing.yaml" "corpus: fixtures/nope/plan/index.yaml"
rc_missing=0
err="$TDIR/missing.err"
(cd "$TDIR" && "$PLAN" grade --root "$TDIR" --index "$TDIR/plan/index.yaml" "$TDIR/sets/missing.yaml" >/dev/null 2>"$err") || rc_missing=$?
if [ "$rc_missing" -eq 2 ] && grep -q 'does not exist' "$err"; then
    ok "a declared corpus that is missing is a HARNESS ERROR (rc=2), not a red case"
else
    bad "missing corpus: rc=$rc_missing err=$(cat "$err")"
fi

# --- 5. the override is ANNOUNCED, never silent --------------------------
err2="$TDIR/announce.err"
(cd "$TDIR" && "$PLAN" grade --root "$TDIR" --index "$TDIR/plan/index.yaml" "$TDIR/sets/declared.yaml" >/dev/null 2>"$err2") || true
if grep -q 'declares corpus' "$err2"; then
    ok "the corpus override announces itself on stderr"
else
    bad "no announcement: $(cat "$err2")"
fi

# --- 6. the REAL committed sets: the glob invocation is fully green -------
out="$("$PLAN" grade "$ROOT"/openspec/litmus-tests/groundtruth/*.yaml 2>/dev/null | tail -1)"
case "$out" in
    *"fail=0"*) ok "the committed groundtruth glob grades fail=0 ($out)" ;;
    *) bad "committed glob not green: $out" ;;
esac

if [ "$fail" -eq 0 ]; then
    echo "ok:groundtruth-corpus-declaration-fixture:6"
    exit 0
fi
echo "fail: groundtruth-corpus-declaration scenarios failed" >&2
exit 1
