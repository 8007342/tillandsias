#!/usr/bin/env bash
# @trace order:1087-h2z9, spec:ci-release
#
# EVERY DIFFERENCE BETWEEN THE LANDING GATE AND THE RELEASE GATE MUST BE DECLARED.
#
# ./build.sh --check is the gate every host lands through. ./build.sh --ci-full
# drives scripts/local-ci.sh and runs about once a day. On 2026-09-06 --ci-full
# was RED on nine counts while --check was GREEN on all nine, and three of the
# non-litmus reds had arrived in the preceding eleven hours. Every host that
# landed that day landed through a gate blind to all of them, and each was
# correct in believing its own gate was green.
#
# The two are not the same instrument at different depths. Measured:
#     litmus invocations inside the --check block      0
#     local-ci invocations inside the --check block    0
# So the difference is not a depth setting, it is a SET DIFFERENCE, and until
# this fixture there was no list of it anywhere — it was discoverable only by
# running the slow gate and diffing by hand, which is how it was found, a full
# day late.
#
# WHAT THIS ENFORCES, and what it deliberately does not:
#   * every script local-ci invokes and --check does not MUST appear in
#     scripts/gate-divergence-declared.txt. A new one reds this.
#   * a declaration for something no longer in the gap also reds, so the file
#     cannot rot into a list of things that used to be true.
#   * the `untriaged` count RATCHETS: it may fall, never rise.
#
# WHY A RATCHET AND NOT A HARD RED ON UNTRIAGED: there were 22 on the day this
# was written. A gate that reds trunk on day one gets switched off — the failure
# check-scorable-obligation-added.sh's own header names, and the reason its scope
# is new rows only. The ratchet makes the debt bounded and visible without making
# the gate unsatisfiable, which is the same bargain the ghost-trace ratchet makes.
#
# THIS DOES NOT PROPOSE RUNNING LITMUS IN --check. build.sh:2252 (order 748-tkjx)
# excludes the suite deliberately because it is minutes long and a gate that slow
# gets bypassed with --no-verify. That reasoning is sound. The litmus entries are
# classed `excluded` with that reason, and a remedy that made --check slow enough
# to route around would replace this defect with a worse one.
#
# Grammar (one line on stdout):
#   ^(ok:gate-divergence-declared:[0-9]+|violation:gate-divergence-undeclared:[0-9]+|violation:gate-divergence-ratchet:[0-9]+)$
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

DECL="scripts/gate-divergence-declared.txt"
BASELINE_UNTRIAGED=22   # 2026-09-06. May fall, never rise.

[ -f "$DECL" ] || { echo "violation:gate-divergence-undeclared:0"; echo "  $DECL is missing — the declaration IS the mechanism" >&2; exit 1; }
[ -f build.sh ] && [ -f scripts/local-ci.sh ] || { echo "violation:gate-divergence-undeclared:0"; echo "  build.sh or scripts/local-ci.sh missing" >&2; exit 1; }

# Comments are stripped BEFORE scanning, in both gates. Both files discuss other
# scripts in prose at length, and a mention is not an invocation (1055-6yp8).
_invoked_by_local_ci() {
    sed 's/[[:space:]]*#.*//' scripts/local-ci.sh \
        | grep -oE 'scripts/[a-zA-Z0-9_./-]+\.sh' | sort -u
}
_invoked_by_check() {
    {
        awk '/^if \[\[ "\$FLAG_CHECK" == true \]\]/,0' build.sh \
            | sed 's/[[:space:]]*#.*//' | grep -oE 'scripts/[a-zA-Z0-9_./-]+\.sh'
        # The gate-steps.d files are data; STEP_SCRIPT is a literal path by
        # contract (1072-b7eq), which is what makes this scan possible at all.
        for _f in scripts/gate-steps.d/*.step; do
            [ -e "$_f" ] || continue
            ( STEP_SCRIPT=""; . "$_f" 2>/dev/null; [ -n "$STEP_SCRIPT" ] && printf '%s\n' "$STEP_SCRIPT" )
        done
    } | sort -u
}

_W="$(mktemp -d "${TMPDIR:-/tmp}/gate-divergence.XXXXXX")"
trap 'rm -rf "$_W"' EXIT

_invoked_by_local_ci > "$_W/ci"
_invoked_by_check    > "$_W/check"
comm -13 "$_W/check" "$_W/ci" > "$_W/gap"

# Declared paths, comments and blank lines removed.
awk '!/^[[:space:]]*(#|$)/ { print $1 }' "$DECL" | sort -u > "$_W/declared"

undeclared=0; detail=""
while IFS= read -r p; do
    [ -n "$p" ] || continue
    if ! grep -Fxq "$p" "$_W/declared"; then
        undeclared=$((undeclared + 1))
        detail="${detail}  $p runs in --ci-full and not in --check, and is not declared in $DECL"$'\n'
    fi
done < "$_W/gap"

# A declaration for something no longer in the gap is stale. Without this the
# file becomes a list of things that used to be true, which is the shape of every
# stale allowlist this project has had to unpick.
stale=0
while IFS= read -r p; do
    [ -n "$p" ] || continue
    if ! grep -Fxq "$p" "$_W/gap"; then
        stale=$((stale + 1))
        detail="${detail}  $p is declared in $DECL but is NOT in the gap — wired into --check, or gone; remove the line"$'\n'
    fi
done < "$_W/declared"

if [ "$((undeclared + stale))" -gt 0 ]; then
    echo "violation:gate-divergence-undeclared:$((undeclared + stale))"
    printf '%s' "$detail" >&2
    echo "  The landing gate and the release gate must not differ by anything nobody wrote down." >&2
    echo "  Wire it into --check, or add a line to $DECL saying why it stays out." >&2
    exit 1
fi

untriaged="$(awk '!/^[[:space:]]*(#|$)/ && $2=="untriaged" {n++} END{print n+0}' "$DECL")"
if [ "$untriaged" -gt "$BASELINE_UNTRIAGED" ]; then
    echo "violation:gate-divergence-ratchet:$untriaged"
    echo "  untriaged is $untriaged, baseline $BASELINE_UNTRIAGED — the ratchet only turns one way." >&2
    echo "  A new difference must be wired into --check or given a reason, not parked as untriaged." >&2
    exit 1
fi

echo "ok:gate-divergence-declared:$(wc -l < "$_W/gap" | tr -d '[:space:]')"
[ "$untriaged" -gt 0 ] && echo "note:gate-divergence-untriaged:$untriaged (baseline $BASELINE_UNTRIAGED) — checks no landing host runs and nobody decided to exclude" >&2
exit 0
