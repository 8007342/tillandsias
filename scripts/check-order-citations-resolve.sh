#!/usr/bin/env bash
# @trace order:1234-zade, spec:spec-traceability
#
# check-order-citations-resolve.sh — every `@trace order:<id>` must name a
# packet that exists.
#
# WHY THIS EXISTS. validate-traces.sh detects GHOST TRACES for `spec:` and does
# not look at `order:` at all — `grep -c order scripts/validate-traces.sh` is
# ZERO — although the documented annotation carries both
# (`# @trace order:859-4jny, spec:ci-release`). Order UNIQUENESS is gated among
# filed packets; order EXISTENCE is not. So a citation into the ledger, which is
# how a reader gets from code to the reasoning behind it, is the one citation
# kind with no resolver.
#
# MEASURED when this landed (2026-09-17): 264 distinct orders cited by @trace,
# 1360 known in the ledger including the archive, and TWO that resolve to
# nothing. Both are the dangerous form rather than the obvious one:
#   1184-u5mg  in scripts/test-gate-stamp-memoization.sh      (real: 1184-jqqg, 1184-tj2q)
#   723-b9cn   in scripts/test-version-bump-isolation-scope.sh (real: ten 723-* ids, none -b9cn)
# A bare number reads as malformed and gets questioned. An INVENTED SUFFIX on a
# real order reads as a legitimate sub-designation, so a reader follows it,
# lands on nothing — or worse, on the wrong packet — and has no reason to doubt
# the citation. Ten such citations landed in one night on 2026-09-16 and every
# gate in the tree passed them.
#
# ARCHIVED PACKETS RESOLVE, deliberately. An order does not stop existing when
# its row is archived; treating that as a ghost would make this guard wrong on
# the oldest and best-traced code in the repo.
#
# RATCHET, not a sweep. The two above are DECLARED below and reported without
# refusing, so this can land without a fixing sweep. Anything else is a
# violation. Removing a declared id after fixing it is the intended direction;
# adding to the list is not, and the count is small enough that growth is
# visible in review.
#
# VERDICTS (one line, stdout):
#   ok:order-citations-resolve:<cited> checked, <declared> declared
#   violation:order-citations-unresolvable:<n>
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

# Known-unresolvable, declared 2026-09-17. Remove an entry when it is fixed.
DECLARED="1184-u5mg 723-b9cn"

# `/usr/bin/grep` deliberately, matching validate-traces.sh: the shell `grep`
# is a wrapper and this guard must not depend on which one a host has. The
# roots below are REAL directories, so recursion is safe here — see 1238-u84w
# for why that sentence has to be said out loud.
_known="$(mktemp)"; _cited="$(mktemp)"
trap 'rm -f "$_known" "$_cited"' EXIT INT TERM

{
    # ORDER 1274-cbk7. The value may be a QUOTED scalar. `order: 1274-cbk7` and
    # `order: "1274-cbk7"` are the same value to YAML, and the plan CLI resolves
    # both, but this guard reads the ledger with grep and keyed on the unquoted
    # SPELLING only. Nine filed packets (1254-47xd, 1255-rvr7, 1256-t3w8,
    # 1257-jxu9, 1258-8wfb, 1258-u8re, 1259-dgaq, 1266-75tr, 1274-cbk7) declare
    # a quoted order and were therefore INVISIBLE here — any @trace citing one
    # failed the gate as "unresolvable" while `tillandsias-plan answer` returned
    # the packet. Found by that exact contradiction on 1274-cbk7.
    /usr/bin/grep -rhoE '^[[:space:]]*-?[[:space:]]*order: "?[0-9]{3,4}-[a-z0-9]{4}"?' \
        plan/index.yaml plan/index.d/ 2>/dev/null
    /usr/bin/grep -rhoE '^[[:space:]]*-?[[:space:]]*order: "?[0-9]{3,4}-[a-z0-9]{4}"?' \
        plan/archive/ 2>/dev/null
} | sed -E 's/.*order: //; s/"//g' | sort -u > "$_known"

if [ ! -s "$_known" ]; then
    echo "blocked:order-citations-resolve:no-ledger-orders-found — the ledger read produced nothing, which is a broken instrument rather than a clean tree"
    exit 2
fi

/usr/bin/grep -rhoE '@trace[^"]{0,60}order:[0-9]{3,4}-[a-z0-9]{4}' \
    scripts/ crates/ images/ methodology/ ./*.sh 2>/dev/null \
    | grep -oE 'order:[0-9]{3,4}-[a-z0-9]{4}' | sed 's/order://' | sort -u > "$_cited"

cited_n="$(grep -c . "$_cited" || true)"
declared_n=0
violations=0

while IFS= read -r id; do
    [ -n "$id" ] || continue
    case " $DECLARED " in
        *" $id "*) declared_n=$((declared_n + 1)); continue ;;
    esac
    violations=$((violations + 1))
    {
        echo "  unresolvable order citation: $id"
        /usr/bin/grep -rln "order:$id" scripts/ crates/ images/ methodology/ ./*.sh 2>/dev/null \
            | sed 's/^/    cited in: /'
        echo "    No packet carries that order. If the suffix was invented on a real"
        echo "    order number, a reader following it lands on nothing or on the wrong"
        echo "    packet — mint a real id with \`tillandsias-plan next-order\` and file it,"
        echo "    or cite the order that actually exists."
    } >&2
done < <(comm -23 "$_cited" "$_known")

if [ "$violations" -gt 0 ]; then
    echo "violation:order-citations-unresolvable:$violations"
    exit 1
fi
echo "ok:order-citations-resolve:${cited_n:-0} checked, ${declared_n} declared"
