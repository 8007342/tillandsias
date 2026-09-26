#!/usr/bin/env bash
# @trace order:1388-pfys
#
# test-project-info-grep-code-recall.sh — project-info's grep_code must never
# answer "No matches found" for a string that exists.
#
# WHY THIS EXISTS. Measured from inside a forge on 2026-09-26, grep_code gave a
# confident "No matches found" for six strings that git grep finds (queries
# 24-30 of the level-2 expert survey), and a worker trusting it would have
# filed duplicates of 1191-vrjf and 1375-rn9b. Causes: a `find | head -200` file
# cap, the pattern read as a BASIC regex (a|b literal), errors and empty file
# sets reported as "No matches found", and `result` not reset per call.
#
# ARMS. H1-H5 are hermetic (a temp tree) and each FAILS on the pre-fix server
# deterministically. L1-L8 replay the survey's own queries against this
# checkout and demand PARITY with grep -rIE over the same file set: when the
# truth has hits, the answer carries hits, every file it names is in the truth,
# and truncation is announced when the truth exceeds the 50-line cap; when the
# truth has none, the answer is "No matches found". (The survey's two 0-hit
# controls are no longer 0 on trunk: the 1388-pfys row quotes them. Parity is
# the honest claim, not a hard-coded zero.)

set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER="$ROOT/images/default/config-overlay/mcp/project-info.sh"
[ -f "$SERVER" ] || { echo "fail:grep-code-recall:no-server:$SERVER"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "skip:grep-code-recall:no-jq"; exit 0; }

pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gcrecall.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# gc_session <cwd> <args-json>... — one server session, one grep_code call per
# argument; prints each answer's text separated by a \x1e line.
gc_session() {
    local cwd="$1"; shift
    local id=2 a
    {
        printf '{"jsonrpc":"2.0","id":1,"method":"initialize"}\n'
        for a in "$@"; do
            printf '{"jsonrpc":"2.0","id":%d,"method":"tools/call","params":{"name":"grep_code","arguments":%s}}\n' "$id" "$a"
            id=$((id+1))
        done
    } >"$WORK/req.jsonl"
    (cd "$cwd" && TILLANDSIAS_EXPERT_HEALTH_LOG="$WORK/h.jsonl" TILLANDSIAS_EXPERT_USAGE_LOG="$WORK/u.jsonl" \
        bash "$SERVER" <"$WORK/req.jsonl" 2>/dev/null) \
        | jq -r 'select(.id != 1) | (.result.content[0].text // .error.message // "<no-text>"), "\u001e"'
}
gc() { gc_session "$1" "$2" | sed '/^\x1e$/d'; }
args() { jq -nc --arg p "$1" --arg i "$2" --arg d "$3" '{pattern:$p, include:$i, path:$d}'; }

# ── hermetic tree ────────────────────────────────────────────────────────────
T="$WORK/tree"; mkdir -p "$T/d"
i=1; while [ $i -le 260 ]; do printf 'x\nneedle-%d\n' "$i" >"$T/d/f$i.txt"; i=$((i+1)); done
printf 'only alpha here\n' >"$T/alpha.txt"

# H1: every file is searched; 260 hits exist, so the cap must be ANNOUNCED with
# the true count. Pre-fix: head -200 searched at most 200 files, no notice.
out="$(gc "$T" "$(args 'needle-[0-9]+' '*.txt' 'd')")"
if grep -q 'showing 50 of 260 matches' <<<"$out"; then ok "H1 all 260 files searched, truncation announced"
else bad "H1 file cap: expected 'showing 50 of 260 matches', got: $(printf '%s' "$out" | tail -1)"; fi

# H2: extended regex — alternation matches. Pre-fix: BRE, a|b is literal.
out="$(gc "$T" "$(args 'alpha|beta' '*.txt' '.')")"
if grep -q 'alpha.txt:1:only alpha here' <<<"$out"; then ok "H2 a|b alternation matches (extended regex)"
else bad "H2 alternation: got: $(printf '%s' "$out" | head -1)"; fi

# H3: a zero-hit call after a hit call must not return the previous answer.
# Pre-fix: an include matching no file left result unset -> stale hits.
out="$(gc_session "$T" "$(args 'alpha' '*.txt' '.')" "$(args 'alpha' '*.nomatch' '.')" | awk 'BEGIN{RS="\x1e\n"} NR==2')"
if grep -q 'alpha.txt' <<<"$out"; then bad "H3 stale result: second call returned the first call's hits"
elif grep -q "no file matches include" <<<"$out"; then ok "H3 empty file set named, no stale result"
else bad "H3 empty file set: got: $(printf '%s' "$out" | head -1)"; fi

# H4: an invalid pattern is an error, not an absence.
out="$(gc "$T" "$(args 'foo(' '*.txt' '.')")"
if grep -q 'invalid extended regex' <<<"$out"; then ok "H4 invalid pattern named"
else bad "H4 invalid pattern: got: $(printf '%s' "$out" | head -1)"; fi

# H5: control — a genuinely absent string still says No matches found.
out="$(gc "$T" "$(args 'zzz-absent-zzz' '*.txt' '.')")"
if grep -q '^No matches found' <<<"$out"; then ok "H5 absent string -> No matches found"
else bad "H5 control: got: $(printf '%s' "$out" | head -1)"; fi

# ── live parity: the survey's queries against this checkout ──────────────────
# truth <pattern> <include> <path> — grep -rIE over the same file set grep_code
# searches (find -name include, .git pruned). Prints "file:line:" prefixes.
truth() {
    (cd "$ROOT" && find "$3" -path '*/.git' -prune -o -type f -name "$2" -print0 2>/dev/null \
        | xargs -0 grep -InE -e "$1" -- 2>/dev/null) || true
}
live() { # <label> <pattern> <include> <path>
    local label="$1" want got nwant f bad_f="" want_files
    want="$(truth "$2" "$3" "$4")"
    got="$(gc "$ROOT" "$(args "$2" "$3" "$4")")"
    nwant=$(printf '%s' "$want" | grep -c . || true)
    if [ "$nwant" -eq 0 ]; then
        if grep -q '^No matches found' <<<"$got"; then ok "$label truth=0 -> No matches found"
        else bad "$label truth=0 but answer: $(printf '%s' "$got" | head -1 | cut -c1-120)"; fi
        return
    fi
    if grep -qE '^(No matches found|grep_code:)' <<<"$got"; then
        bad "$label FALSE NEGATIVE: truth has $nwant hit(s) (e.g. $(printf '%s' "$want" | head -1 | cut -d: -f1-2)), answer: $(printf '%s' "$got" | head -1 | cut -c1-100)"
        return
    fi
    want_files="$(cut -d: -f1 <<<"$want")"
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        grep -qxF "$f" <<<"$want_files" || bad_f="$f"
    done <<EOF_FILES
$(printf '%s\n' "$got" | grep -v '^\[truncated' | cut -d: -f1 | sort -u)
EOF_FILES
    if [ -n "$bad_f" ]; then bad "$label answer names $bad_f, which the truth does not"; return; fi
    if [ "$nwant" -gt 50 ] && ! grep -q "showing 50 of $nwant matches" <<<"$got"; then
        bad "$label truth=$nwant > cap but truncation not announced with the true count"; return
    fi
    ok "$label parity with grep (truth=$nwant)"
}
live "L1 q24 GIT_TRACE"      'GIT_TRACE' '*.yaml' 'plan'
live "L2 q25 json-get"       'json-get-absent|json verb' '*' 'plan'
live "L3 q26 analyze-bands"  'analyze-bands' '*' 'plan'
live "L4 q27 dashboard"      'update-convergence-dashboard.*(locale|printf)|pct_display' '*' 'plan'
live "L5 q28 measure-bands"  'measure-bands' '*' 'plan'
live "L6 q30 grammar string" 'does not match the configured branch-creation grammar' '*' '.'
live "L7 q29 control a"      'push-plan-fragments.*untracked|untracked.*push-plan-fragments' '*' 'plan'
live "L8 q29 control b"      'does not match the configured branch-creation grammar|work/\* .*grammar' '*' 'plan'

if [ "$fail" -eq 0 ]; then echo "ok:grep-code-recall:$pass"; exit 0; fi
echo "fail:grep-code-recall:$fail failed, $pass passed"; exit 1
