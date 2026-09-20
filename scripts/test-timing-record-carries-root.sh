#!/usr/bin/env bash
# @trace order:1299-s2sv, spec:methodology-accountability
#
# WHY THIS FIELD EXISTS. On 2026-09-18 four timing records landed in /tmp while
# a gate ran, the metrics-log-split guard correctly refused to publish, and the
# next release gate reddened two hours later on a symptom several steps from its
# cause. Establishing WHICH checkout had written them was then impossible from
# the records: they carry ts, host, step, phase, duration_ms and exit, and
# nothing about where they came from. The answer existed only in one host's
# session transcript, and 1268-m2ir came within that transcript of closing on an
# unconfirmed mechanism.
#
# THE READER SURVEY CAME FIRST, and it is why this field could be added at all.
# 28 files mention the timing log; only FOUR parse a record field
# (cycle-metrics.sh, build.sh, test-build-step-timing-attribution.sh,
# test-cycle-metrics-recurrence.sh). None does a whole-object comparison, a
# key-set check, to_entries, has() or a field count — measured, not assumed — so
# a new key is inert for every one of them, and the split guard compares wc -l
# and reads no fields at all.
#
# THE ABSENT-CASE RULE, decided from that survey:
#   1. no reader may dereference .root bare — jq yields null for a missing key
#      and null interpolates as the string "null", which is absent-read-as-value
#   2. the canonical read is `.root // .root_unusable // "unknown"`, which is WHY
#      the fallback path must emit root_unusable: without it the chain has a hole
#      exactly where the diagnosis is needed
#   3. ABSENT MEANS PRE-FIELD, NEVER /tmp — ~124k records predate the field and
#      are not evidence about where they were written
#   4. a reader that cannot express "absent" must not consume the field
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
ROOT="$PWD"

pass=0; fail=0; skipped=0
ok()      { printf 'ok:   %s\n' "$1"; pass=$((pass + 1)); }
bad()     { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }
skiparm() { printf 'skip: %s\n' "$1"; skipped=$((skipped + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

JQ="$(command -v jq 2>/dev/null || true)"
if [ -z "$JQ" ]; then
    printf 'skip:timing-record-root:no-jq — every arm reads records with it\n'
    exit 0
fi

# emit_into <log> <project_root> <step>  — one record through the real emitter
emit_into() {
    env TILLANDSIAS_TIMING_LOG="$1" PROJECT_ROOT="$2" \
        bash "$ROOT/scripts/cycle-metrics.sh" --emit-timing \
        step="$3" phase=test duration_ms=5 exit=0 >/dev/null 2>&1
}

# ---------------------------------------------------------------- ARM 1
# A RECORD FROM A .git-DIRECTORY CHECKOUT ANSWERS .root WITH THAT CHECKOUT.
CO="$TMP/checkout"; mkdir -p "$CO/.git"
emit_into "$TMP/a1.jsonl" "$CO" arm1
r1="$("$JQ" -r '.root // .root_unusable // "ABSENT"' < "$TMP/a1.jsonl" 2>/dev/null | tail -1)"
if [ "$r1" = "$CO" ]; then
    ok "ARM 1: a record from a .git-directory checkout answers .root with the checkout path"
else
    bad "ARM 1: expected .root=$CO, got '$r1'"
fi

# ---------------------------------------------------------------- ARM 2
# A LINKED WORKTREE ANSWERS WITH ITS OWN PATH — never /tmp, never absent.
#
# The worktree is constructed as a directory whose .git is a FILE, which is what
# `git worktree add` produces and is the exact condition that broke the resolver
# in 1268-m2ir (`-d "$root/.git"` said "not a checkout" about a tree that is
# one). A real `git worktree add` would prove the same property while mutating
# the repository from inside a gate step, which is not worth it.
WT="$TMP/worktree"; mkdir -p "$WT"
printf 'gitdir: %s/.git/worktrees/probe\n' "$ROOT" > "$WT/.git"
emit_into "$TMP/a2.jsonl" "$WT" arm2
r2="$("$JQ" -r '.root // .root_unusable // "ABSENT"' < "$TMP/a2.jsonl" 2>/dev/null | tail -1)"
case "$r2" in
    "$WT")   ok "ARM 2: a linked worktree answers .root with the WORKTREE's own path, not the main checkout" ;;
    ABSENT)  bad "ARM 2: a worktree record carries no root at all — absent means pre-field, so this record lies about its own age" ;;
    /tmp/*)  bad "ARM 2: a worktree record answered '$r2' — the -d/-e regression is back" ;;
    *)       bad "ARM 2: expected .root=$WT, got '$r2'" ;;
esac

# ---------------------------------------------------------------- ARM 3
# A FALLBACK RECORD CARRIES root_unusable AND fallback_reason, so the canonical
# read `.root // .root_unusable` is NEVER empty.
#
# Driven by pointing the resolver at a root that is not a checkout, with the
# library copied somewhere with no checkout above it so no candidate can win.
OUT="$TMP/outside/nested"; mkdir -p "$OUT"
cp "$ROOT/scripts/metrics-log-path.sh" "$OUT/"
frag="$(cd "$OUT" && env -u PROJECT_ROOT bash -c '
    . ./metrics-log-path.sh
    p="$(metrics_default_log tillandsias-timing.jsonl "" 2>/dev/null)"
    metrics_root_fields "$p"')"
rec="{\"ts\":\"x\",\"step\":\"arm3\",\"duration_ms\":1,\"exit\":0${frag}}"
r3="$(printf '%s' "$rec" | "$JQ" -r '.root // .root_unusable // ""' 2>/dev/null)"
why="$(printf '%s' "$rec" | "$JQ" -r '.fallback_reason // ""' 2>/dev/null)"
if [ -n "$r3" ] && [ -n "$why" ]; then
    ok "ARM 3: a fallback record carries root_unusable and fallback_reason ($why), so .root // .root_unusable is never empty"
elif [ -n "$r3" ]; then
    bad "ARM 3: root_unusable is present but fallback_reason is empty — the record says WHERE it could not write and not WHY"
else
    bad "ARM 3: a fallback record has neither root nor root_unusable; the canonical read yields empty and a reader learns nothing"
fi

# ---------------------------------------------------------------- ARM 4
# EVERY READER PRINTS THE SAME VERDICT OVER A CORPUS WITHOUT THE FIELD AND OVER
# THE SAME CORPUS WITH IT, AND ABSENT IS REPORTED AS ABSENT, NEVER AS A VALUE.
#
# The without-field corpus is the REAL one: the four records preserved from the
# 2026-09-18 incident, verbatim, keys ts,host,step,phase,duration_ms,exit and no
# root of any kind. Synthesising a field-less record would test this author's
# idea of one rather than what the fleet actually wrote.
cat > "$TMP/without.jsonl" <<'CORPUS'
{"ts":"2026-09-18T21:17:42Z","host":"macuahuitl.ayahuitlcalpan.com","step":"litmus:credential-isolation","phase":"all","duration_ms":88,"exit":0}
{"ts":"2026-09-18T21:17:42Z","host":"macuahuitl.ayahuitlcalpan.com","step":"litmus:opencode-web-session-otp-shape","phase":"all","duration_ms":90,"exit":0}
{"ts":"2026-09-18T21:17:42Z","host":"macuahuitl.ayahuitlcalpan.com","step":"litmus-suite","phase":"all","duration_ms":210,"exit":0}
{"ts":"2026-09-18T21:21:53Z","host":"macuahuitl.ayahuitlcalpan.com","step":"litmus-suite","phase":"pre-build","duration_ms":286740,"exit":0}
CORPUS
"$JQ" -c '. + {root:"/some/checkout"}' < "$TMP/without.jsonl" > "$TMP/with.jsonl" 2>/dev/null

# absent must read as absent, not as the string "null"
absent="$("$JQ" -r '.root // .root_unusable // "ABSENT"' < "$TMP/without.jsonl" | sort -u | tr '\n' ',')"
if [ "$absent" = "ABSENT," ]; then
    ok "ARM 4a: over the preserved corpus every record reports root ABSENT — not the string \"null\", not a location"
else
    bad "ARM 4a: the absent case reads as '$absent'; clause 3 says absent means PRE-FIELD and must never become a value"
fi

# the reader's verdict must not move
# The METRICS, not the whole line: `source=<path>` necessarily differs because
# the two corpora are different files, and comparing it would fail for a reason
# that has nothing to do with the field. The first version of this arm did
# exactly that and reported the reader as changed when every number was equal —
# asserting the mechanism instead of the property.
read_verdict() {
    # --no-experts --no-repo-scan because this arm reads ONE line: the full run
    # computes every metric and costs ~16s a side, 32s for the fixture, which is
    # more than gate step 414 cost when that was judged too expensive. Same flags
    # both sides, so the comparison is unchanged; measured 0.57s a side.
    env TILLANDSIAS_TIMING_LOG="$1" bash "$ROOT/scripts/cycle-metrics.sh" \
        --no-experts --no-repo-scan 2>/dev/null \
        | grep -E '^timing:' | head -1 | sed 's/ source=[^ ]*//'
}
v_without="$(read_verdict "$TMP/without.jsonl")"
v_with="$(read_verdict "$TMP/with.jsonl")"
if [ -z "$v_without" ]; then
    skiparm "ARM 4b: the timing reader printed no verdict here, so the comparison would prove nothing"
elif [ "$v_without" = "$v_with" ]; then
    ok "ARM 4b: the timing reader's verdict is IDENTICAL with and without the field — it is inert for existing readers"
else
    bad "ARM 4b: the reader's verdict CHANGED when the field was added:
       without: $v_without
       with:    $v_with"
fi

printf '\n'
if [ "$fail" -eq 0 ]; then
    if [ "$skipped" -gt 0 ]; then
        printf 'ok:timing-record-root:%d/%d (%d skipped)\n' "$pass" "$((pass + fail))" "$skipped"
    else
        printf 'ok:timing-record-root:%d/%d\n' "$pass" "$((pass + fail))"
    fi
    exit 0
fi
printf 'blocked:timing-record-root:%d-failed-of-%d\n' "$fail" "$((pass + fail))"
exit 1
