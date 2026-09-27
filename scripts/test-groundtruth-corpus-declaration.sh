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

# --- 6. the REAL committed sets: the glob invocation is green OR loudly skipped
# ORDER 888-miiy. This step used to require only `fail=0`, and on a host with no
# embedding endpoint the whole invocation died with
# `HARNESS ERROR: spec.answer needs a built index` — no result line at all, so
# `$out` was EMPTY and the step reported "committed glob not green:" with a blank
# verdict. That is the one red out of 2007 that blocked a release cut on
# 2026-08-25, on a host whose only sin was having no ollama running.
#
# The set that drags the index requirement in is spec-rung1.yaml. Its own author
# wrote, when adding it: "NOT wired into the default grade set or build --check:
# the engine needs a built index, and a host without one would get a harness
# ERROR rather than a skip -- making it default would turn a missing host
# artifact into a red build fleet-wide. The gate's own committed-set test names
# one file rather than globbing, so this set cannot affect it." Order 786-kjke
# then added THIS globbing step — correctly, it tests real glob behaviour — and
# swept the set in, which is precisely the condition that warning described.
#
# THE FIX IS NOT "STOP FAILING". A capability gap that merely stopped failing
# would leave the expert-grading tier unexercised on every endpoint-less host
# with nothing saying so — an unexamined thing reported as clean, which is
# strictly worse than the wrong red, because the wrong red at least told the
# truth that something was off. So the assertion is `fail=0` AND that every skip
# is ACCOUNTED FOR: named engines in the summary and a SKIP line per case.
full="$("$PLAN" grade "$ROOT"/openspec/litmus-tests/groundtruth/*.yaml 2>/dev/null)"
out="$(printf '%s' "$full" | grep '^groundtruth-result:' | tail -1)"
if [ -z "$out" ]; then
    bad "the glob produced NO result line at all (the 888-miiy symptom): $(printf '%s' "$full" | tail -1)"
elif ! grep -q 'fail=0' <<<"$out"; then
    bad "committed glob not green: $out"
elif printf '%s' "$out" | grep -q 'skipped=0' && printf '%s' "$out" | grep -q 'stale=0'; then
    ok "the committed groundtruth glob grades fail=0 with nothing skipped or stale ($out)"
elif ! grep -q 'stale=0' <<<"$out"; then
    # ORDER 1229-2862. STALE GETS THE SAME TREATMENT AS A SKIP, and it has to be
    # checked HERE or the field creates a silent green: a run with stale=2
    # skipped=0 still satisfies `skipped=0` and would have reported "nothing
    # skipped" while two cases went uncertified. Same accounting rule as
    # 888-miiy — named engines in the summary and a per-case line — because it
    # is the same failure it was written against.
    if printf '%s' "$out" | grep -q 'stale_engines=' \
       && printf '%s' "$full" | grep -q '^STALE .*NOT VALID in this checkout'; then
        ok "glob is fail=0 and every stale case is named ($out)"
    else
        bad "the glob had STALE cases WITHOUT accounting for them — a silent green: $out"
    fi
else
    # Skips are allowed, but never invisible.
    if printf '%s' "$out" | grep -q 'skipped_engines=' \
       && printf '%s' "$full" | grep -q '^SKIP  .*NOT GRADED on this host'; then
        ok "glob is fail=0 and every skip is named ($out)"
    else
        bad "the glob skipped cases WITHOUT accounting for them — a silent green: $out"
    fi
fi

# --- 7. an ABSENT index SKIPS loudly; it is neither a red nor a silent pass ---
# The positive statement of the fix. Cases that cannot run are skipped, named,
# counted, and the denominator still includes them so a skip cannot quietly
# shrink the bar.
#
# ORDER 1229-2862 CRITERION 4 — WHY THE ARM SELECTION LIVES IN A FUNCTION. The
# discrimination this step has to make is "this host HAS an index and some cases
# FAILED" versus "the skip accounting is wrong", and the two produce the SAME
# result line: both carry skipped=0, and only the exit code and the fail count
# separate them. Before this, a genuine red on an index-bearing host fell through
# every arm into the else — measured on macuahuitl 2026-09-16, total=5 pass=3
# fail=2 rc=1, printing "absent-index skip is not properly accounted" and pointing
# the reader at accounting that was correct, instead of at the two cases that had
# actually failed. One red wearing two names, the second of them aimed at
# innocent code. A forge has no index and takes the skip arm, so the bug is
# invisible on exactly the hosts most likely to re-introduce it; scenario 7b
# below pins the classification with no index at all.
gt_field() { # <result-line> <key>  -> the value, or empty when the key is absent
    printf '%s' "$1" | sed -n "s/.* $2=\([0-9]*\).*/\1/p"
}

# Echoes exactly one verdict for one spec-rung1 run:
#   skipped       an accounted capability gap: every case SKIPped, named, rc=0
#   graded-clean  an index graded it, and nothing is red or uncertified
#   graded-stale  an index graded it, some cases STALE and named, rc=0
#   graded-red    an index graded it and some cases FAILED, rc=1
#   no-result     grade printed no result line at all (a HARNESS ERROR)
#   unaccounted   the line and the exit code disagree, or a gap went unnamed
classify_spec_run() { # <result-line> <rc> [full-output]
    local line="$1" rc="$2" full="${3:-}"
    local total pass fail stale skip
    [ -n "$line" ] || { printf 'no-result'; return; }
    total="$(gt_field "$line" total)"
    pass="$(gt_field "$line" pass)"
    fail="$(gt_field "$line" fail)"
    stale="$(gt_field "$line" stale)"
    skip="$(gt_field "$line" skipped)"
    if [ -z "$total" ] || [ -z "$pass" ] || [ -z "$fail" ] \
       || [ -z "$stale" ] || [ -z "$skip" ]; then
        printf 'unaccounted'
        return
    fi
    # A red is a red whatever else the run did, so this is checked FIRST. A
    # skipped case alongside a real failure must not demote the failure, or the
    # fail-open shape scenario 9 exists to catch walks back in through the door
    # this arm opens. The skips still have to be NAMED, because they shrink what
    # the run certifies.
    if [ "$fail" -gt 0 ]; then
        if [ "$rc" -ne 1 ]; then
            printf 'unaccounted'
            return
        fi
        if [ "$skip" -gt 0 ] \
           && { ! printf '%s' "$line" | grep -q 'skipped_engines=' \
                || ! printf '%s' "$full" | grep -q '^SKIP  .*\['; }; then
            printf 'unaccounted'
            return
        fi
        printf 'graded-red'
        return
    fi
    # A stale case is a case this run did not certify, and 1229-2862 gave STALE
    # the same accounting treatment as a skip for exactly that reason. Without
    # this arm a stale run is announced below as "graded rather than skipped" —
    # true, and silent about the two cases it certified nothing about.
    if [ "$stale" -gt 0 ]; then
        if [ "$rc" -eq 0 ] \
           && printf '%s' "$line" | grep -q 'stale_engines=' \
           && printf '%s' "$full" | grep -q '^STALE .*NOT VALID in this checkout'; then
            printf 'graded-stale'
        else
            printf 'unaccounted'
        fi
        return
    fi
    if [ "$skip" -gt 0 ]; then
        if [ "$rc" -eq 0 ] && [ "$total" -eq "$skip" ] \
           && printf '%s' "$line" | grep -q 'skipped_engines=' \
           && printf '%s' "$full" | grep -q '^SKIP  .*\['; then
            printf 'skipped'
        else
            printf 'unaccounted'
        fi
        return
    fi
    if [ "$rc" -eq 0 ] && [ "$total" -gt 0 ]; then
        printf 'graded-clean'
    else
        printf 'unaccounted'
    fi
}

sp="$("$PLAN" grade --root "$ROOT" "$ROOT/openspec/litmus-tests/groundtruth/spec-rung1.yaml" 2>/dev/null)"
sp_rc=0
TILLANDSIAS_SPEC_INDEX_DIR="" "$PLAN" grade --root "$ROOT" \
    "$ROOT/openspec/litmus-tests/groundtruth/spec-rung1.yaml" >/dev/null 2>&1 || sp_rc=$?
sp_line="$(printf '%s' "$sp" | grep '^groundtruth-result:' | tail -1)"
case "$(classify_spec_run "$sp_line" "$sp_rc" "$sp")" in
    skipped)
        ok "an absent index SKIPS loudly, counted in the denominator (rc=0, $sp_line)"
        ;;
    graded-clean)
        ok "this host HAS an index — spec.answer graded rather than skipped ($sp_line)"
        ;;
    graded-stale)
        ok "this host HAS an index and named every STALE case ($sp_line)"
        ;;
    graded-red)
        # THE ARM THAT WAS MISSING. The accounting is fine and the run is RED:
        # name the cases, because a reader sent to the skip accounting for a
        # real red reads three lines of correct code before finding nothing.
        bad "spec.answer GRADED and FAILED — the skip accounting is fine: $sp_line; first reds: $(printf '%s' "$sp" | grep '^FAIL  ' | head -3 | tr '\n' ' ')"
        ;;
    no-result)
        # ORDER 888-miiy, found from the WITH-ENDPOINT side, which is the only
        # side that reaches this branch. `sp_skip` is sed'd out of the result
        # line, so when grade dies with a HARNESS ERROR and prints no result
        # line at all, sp_skip is EMPTY, ${sp_skip:-0} is 0, and the old
        # condition read that as "0 skipped, therefore graded" — the arm
        # announced "this host HAS an index" while nothing had been graded and
        # nothing had been indexed. `sp_rc` was captured two lines above and
        # never consulted on that path.
        #
        # That is THIS PACKET'S OWN DEFECT, one level in: a harness error
        # rendered as a graded result. The fix for the release gate was written
        # correctly and the arm verifying it carried the same conflation, where
        # no endpoint-less host could ever see it, because every such host takes
        # the skip branch above and returns before reaching here.
        #
        # An absence and a zero are not the same measurement. This branch is the
        # difference.
        bad "grade produced NO result line (rc=$sp_rc) — a HARNESS ERROR, not a graded run with nothing skipped"
        ;;
    *)
        bad "absent-index skip is not properly accounted: rc=$sp_rc line=$sp_line"
        ;;
esac

# --- 7b. the arm selection is PINNED, because no host can observe it ----------
# ORDER 1229-2862 criterion 4. Every input below is a RESULT LINE, never a
# grade run, so this costs no index, no embedding endpoint, and no plan binary
# beyond the one step 7 already needed. That is the point: the defect 7b pins is
# a mis-dispatch that only an index-bearing host can produce, so a regression in
# it would otherwise be invisible to every forge — including the one whose
# checkout would reintroduce it.
#
# The five `unaccounted` rows plus the `no-result` row are the load-bearing half.
# A new arm that accepted anything with a plausible result line would pass the
# first three rows and turn the fixture into the blanket amnesty criterion 4
# exists to prevent.
gt_cases=0
gt_bad=0
gt_pin() { # <result-line> <rc> <full-output> <expected-verdict>
    local got
    got="$(classify_spec_run "$1" "$2" "$3")"
    gt_cases=$((gt_cases + 1))
    if [ "$got" = "$4" ]; then
        ok "arm selection: $1 rc=$2 -> $got"
    else
        bad "arm selection: $1 rc=$2 -> $got (want $4)"
        gt_bad=$((gt_bad + 1))
    fi
}
# The measured macuahuitl shape: an index that graded, two cases genuinely wrong.
gt_pin "groundtruth-result: sets=1 total=5 pass=3 fail=2 stale=0 skipped=0 elapsed_ms=4" 1 "" graded-red
# A red that reports success is not a measurement, and must not read as one.
gt_pin "groundtruth-result: sets=1 total=5 pass=3 fail=2 stale=0 skipped=0 elapsed_ms=4" 0 "" unaccounted
# A real red alongside accounted skips is still a real red (fail-open guard).
gt_pin "groundtruth-result: sets=2 total=7 pass=4 fail=1 stale=0 skipped=2 skipped_engines=spec.answer elapsed_ms=4" 1 \
    "SKIP  c  [spec.answer]  NOT GRADED on this host: no index" graded-red
# ...and the same run with its skips UNNAMED is not a measurement.
gt_pin "groundtruth-result: sets=2 total=7 pass=4 fail=1 stale=0 skipped=2 elapsed_ms=4" 1 "" unaccounted
# The three arms that already existed, pinned so a refactor cannot move them.
gt_pin "groundtruth-result: sets=1 total=5 pass=0 fail=0 stale=0 skipped=5 skipped_engines=spec.answer elapsed_ms=4" 0 \
    "SKIP  c  [spec.answer]  NOT GRADED on this host: no index" skipped
gt_pin "groundtruth-result: sets=1 total=5 pass=5 fail=0 stale=0 skipped=0 elapsed_ms=4" 0 "" graded-clean
gt_pin "groundtruth-result: sets=1 total=5 pass=3 fail=0 stale=2 skipped=0 stale_engines=spec.answer elapsed_ms=4" 0 \
    "STALE c  [spec.answer]  NOT VALID in this checkout: the index is behind the code" graded-stale
# NEGATIVE CONTROLS: an unnamed gap, an uncounted skip, an empty line, and a
# truncated line are all `unaccounted`/`no-result`, never a pass.
gt_pin "groundtruth-result: sets=1 total=5 pass=0 fail=0 stale=0 skipped=5 elapsed_ms=4" 0 \
    "SKIP  c  [spec.answer]  NOT GRADED on this host: no index" unaccounted
gt_pin "groundtruth-result: sets=1 total=5 pass=0 fail=0 stale=0 skipped=2 elapsed_ms=4" 0 \
    "SKIP  c  [spec.answer]  NOT GRADED on this host: no index" unaccounted
gt_pin "groundtruth-result: sets=1 total=5 pass=0 fail=0 stale=0 skipped=0 elapsed_ms=4" 2 "" unaccounted
gt_pin "groundtruth-result: sets=1 total=5 pass=3 fail=2 elapsed_ms=4" 1 "" unaccounted
gt_pin "" 2 "" no-result
if [ "$gt_cases" -eq 12 ] && [ "$gt_bad" -eq 0 ]; then
    ok "arm selection pinned over $gt_cases synthetic runs (no index required)"
fi

# --- 8. NEGATIVE CONTROL: a STALE index is a HARNESS ERROR, never a skip ------
# The whole safety argument for the skip lives here. "This host has no index"
# and "this host's index is wrong" look similar and mean opposite things: the
# first is a capability gap, the second is a defect that a skip would hide.
stale="$(mktemp -d)"; mkdir -p "$stale/idx"; printf '[0.1,0.2]\n' > "$stale/idx/vectors.jsonl"
st_rc=0
TILLANDSIAS_SPEC_INDEX_DIR="$stale/idx" "$PLAN" grade --root "$ROOT" \
    "$ROOT/openspec/litmus-tests/groundtruth/spec-rung1.yaml" \
    >"$stale/out" 2>"$stale/err" || st_rc=$?
rm -rf "$stale"
if [ "$st_rc" -eq 2 ]; then
    ok "a STALE index is still a HARNESS ERROR (rc=2), never skipped"
else
    bad "a stale index did not hard-error: rc=$st_rc — the skip is swallowing a real defect"
fi

# --- 9. NEGATIVE CONTROL: skipping must not make a WRONG answer green ---------
# The fail-open test. Everything above is worthless if the skip path can also
# absorb a genuinely wrong graded answer; a stricter-looking gate that stopped
# failing would be the exact regression this fixture is meant to prevent.
wrong="$(mktemp -d)"
sed 's/LWW-Register/NONEXISTENT-REGISTER-FABRICATION/' \
    "$ROOT/openspec/litmus-tests/groundtruth/expert-groundtruth-rung1.yaml" > "$wrong/w.yaml"
w_rc=0
"$PLAN" grade --root "$ROOT" "$wrong/w.yaml" \
    "$ROOT/openspec/litmus-tests/groundtruth/spec-rung1.yaml" >"$wrong/out" 2>/dev/null || w_rc=$?
w_line="$(grep '^groundtruth-result:' "$wrong/out" | tail -1)"
if [ "$w_rc" -eq 1 ] && printf '%s' "$w_line" | grep -qv 'fail=0' \
   && grep -q '^FAIL  cheatsheet-crdt-primitives' "$wrong/out"; then
    ok "a WRONG answer is still RED even alongside skipped cases (rc=1, $w_line)"
else
    bad "FAIL-OPEN: a wrong answer went green alongside skips: rc=$w_rc line=$w_line"
fi
rm -rf "$wrong"

if [ "$fail" -eq 0 ]; then
    echo "ok:groundtruth-corpus-declaration-fixture:9"
    exit 0
fi
echo "fail: groundtruth-corpus-declaration scenarios failed" >&2
exit 1
