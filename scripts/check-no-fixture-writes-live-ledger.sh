#!/usr/bin/env bash
# @trace order:1320-44rs
#
# check-no-fixture-writes-live-ledger.sh — no fixture writes a probe into the
# checkout's OWN plan/index.d/ or plan/loop_status.d/.
#
# WHY. A probe fragment written into the live ledger is invisible to every host
# but the one running the fixture, survives the fixture's death, and is read by
# the fold as real. On 2026-09-20 one (plan/index.d/20990101t000002z-1128-probe-
# noid.yaml) sat there after the preflight door SIGKILLed its fixture mid-arm,
# and the v56.9.20.1 release gate refused `blocked:plan-ledger-incomplete`,
# twice. An exit trap is not a guarantee: a fixture that can be killed at any
# instruction must never have written the live tree at that instruction.
#
# WHAT COUNTS AS A LIVE WRITE (a source scan, line by line, cwd-aware):
#   - a write (`>`, `>>`, `tee`, `touch`) whose target starts with $ROOT,
#     $REPO_ROOT or $PROJECT_ROOT (braced or quoted) followed by plan/index.d/ or
#     plan/loop_status.d/, or by a variable that holds such a RELATIVE path
#     (`PEND="plan/index.d/..."` ... `> "$ROOT/$PEND"`);
#   - a RELATIVE write to plan/index.d/ or plan/loop_status.d/ (directly or via
#     such a variable) while the script's cwd is the checkout: after a top-level
#     `cd "$ROOT"` / `cd "$(dirname ...)/.."` and before any other top-level cd.
# THE SCAFFOLD IDIOM IT ACCEPTS: the target starts with any OTHER variable
# (`"$W/plan/index.d/x.yaml"`, `"$S/..."`, `"$1/..."`), or the script has cd'd
# into a scaffold (`cd "$W/wc"`, `cd "$wt"`), or the write sits in a subshell
# that cds elsewhere on the same line. Writes through set-field / push-plan-
# fragments-to-trunk run in the directory the fixture chose, and are judged by
# that cd like any other write.
#
# NOT SEEN, by name: a path assembled across lines by other means (string
# concatenation of pieces, arrays), and writes inside functions called from a
# different cwd than the one they are defined under. The ledger fold still
# reads such a probe; this scan is the cheap first line, the fold the last.
#
# OUTPUT: violation:fixture-writes-live-ledger:<file>:<line> per hit, then
# ok:fixtures-write-scaffolds-only:<n> checked (exit 0) or
# refused:fixtures-write-live-ledger:<k> (exit 1).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

files=()
if [ "$#" -gt 0 ]; then
    files=("$@")
else
    for f in "$ROOT"/scripts/test-*.sh; do files+=("$f"); done
fi

hits=0
n=0
for f in ${files[@]+"${files[@]}"}; do
    [ -f "$f" ] || continue
    n=$((n + 1))
    rel="${f#"$ROOT"/}"
    out="$(awk -v file="$rel" '
        function ledger(p) { return p ~ /^plan\/(index\.d|loop_status\.d)\// }
        # the bare target path of a word: quotes and a leading ./ dropped
        function clean(t) { gsub(/["\047]/, "", t); sub(/^\.\//, "", t); return t }
        function rootvar(t) { return t ~ /^\$\{?(ROOT|REPO_ROOT|PROJECT_ROOT)\}?\// }
        function live_target(t, rest, v) {
            t = clean(t)
            if (rootvar(t)) {
                rest = t; sub(/^\$\{?(ROOT|REPO_ROOT|PROJECT_ROOT)\}?\//, "", rest)
                if (ledger(rest)) return 1
                if (rest ~ /^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/) {
                    v = rest; sub(/^\$\{?/, "", v); sub(/[^A-Za-z0-9_].*$/, "", v)
                    if (v in relvar) return 1
                }
                return 0
            }
            if (!livecwd || localcd) return 0
            if (ledger(t)) return 1
            if (t ~ /^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?(\/|$)/) {
                v = t; sub(/^\$\{?/, "", v); sub(/[^A-Za-z0-9_].*$/, "", v)
                if ((v in relvar) && t !~ /\//) return 1
            }
            return 0
        }
        BEGIN { livecwd = 0 }
        {
            line = $0
            if (line ~ /^[[:space:]]*#/) next
            # variables holding a RELATIVE ledger path
            if (match(line, /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=["\047]?plan\/(index\.d|loop_status\.d)\//)) {
                v = line; sub(/^[[:space:]]*/, "", v); sub(/=.*/, "", v); relvar[v] = 1
            }
            # top-level cd (not inside a subshell on this line)
            localcd = (line ~ /(^|[^$])\([[:space:]]*cd[[:space:]]/)
            if (!localcd && line ~ /(^|[;&[:space:]])cd[[:space:]]+/) {
                if (line ~ /cd[[:space:]]+"?\$\{?(ROOT|REPO_ROOT|PROJECT_ROOT)\}?"?([[:space:];|&)]|$)/ || line ~ /cd[[:space:]]+"?\$\(dirname[^)]*\)\/\.\."?/)
                    livecwd = 1
                else
                    livecwd = 0
            }
            # write targets on this line
            s = line
            while (match(s, /(>>?|tee([[:space:]]+-a)?|touch)[[:space:]]*["\047]?[^[:space:];|&)<>]+/)) {
                w = substr(s, RSTART, RLENGTH)
                sub(/^(>>?|tee([[:space:]]+-a)?|touch)[[:space:]]*/, "", w)
                if (w !~ /^&/ && w != "/dev/null" && live_target(w)) {
                    printf "violation:fixture-writes-live-ledger:%s:%d\n", file, NR
                    break
                }
                s = substr(s, RSTART + RLENGTH)
            }
        }
    ' "$f")"
    if [ -n "$out" ]; then
        printf '%s\n' "$out"
        hits=$((hits + $(grep -c . <<<"$out")))
    fi
done

if [ "$hits" -eq 0 ]; then
    echo "ok:fixtures-write-scaffolds-only:$n checked"
    exit 0
fi
echo "refused:fixtures-write-live-ledger:$hits"
echo "  remedy: plant the probe in a scaffold (a copied plan tree under mktemp or target/, as scripts/test-pending-capability-row-does-not-wedge.sh does) and assert the live plan/ unchanged" >&2
exit 1
