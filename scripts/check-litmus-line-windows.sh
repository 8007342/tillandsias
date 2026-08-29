#!/usr/bin/env bash
# freshness: added 2026-08-29 linux-yoga (order 925-erjs)
# @trace order:925-erjs, order:748-tkjx, order:634-39ik, order:624-cf9f
#
# check-litmus-line-windows.sh — does any litmus ASSERTION depend on a
# line-count window against a source file?
#
# ── WHY (order 925-erjs, from 748-tkjx's audit) ──────────────────────────────
#
# `grep -A<N> 'anchor' file | grep -q 'target'` measures FORMATTING. Insert a
# comment above the anchor and the target slides out of the window: the test
# fails on CORRECT code, and its message names the pinned behaviour, so the
# reader investigates working code. 748-tkjx records two such false failures in
# one hour on 2026-08-15.
#
# It fails the other way too, which is worse. MEASURED 2026-08-29:
#   * litmus:podman-idiomatic-error-classification asserted only the type NAME
#     inside a 30-line window, so it passed whether the arm mapped to true or
#     false — it could not fail if the classification INVERTED;
#   * litmus:host-browser-mcp-lane-socket-shape matched `ErrorCode::Unsupported` in
#     the arm's own COMMENT, so the code beneath could have changed freely;
#   * litmus:terminal-status-vocabulary-shape read the status list through `-A3` and
#     COMPARES it to another list — reflowing the `matches!` across five lines
#     (ordinary rustfmt output) makes it see ONE status where there are four,
#     and the step then accuses a correct guard script of drift.
#
# 25 windows across 15 tests were converted to structural ranges under
# 925-erjs. This check exists so the count cannot silently grow back — it grew
# from 21 to 23 in the single day between filing the packet and starting it.
#
# ── WHAT IS AND IS NOT A FINDING ─────────────────────────────────────────────
#
# ONLY `critical_path` commands, because only they decide a verdict. A window
# in `rollback.command` prints context for a human after a failure and is doing
# exactly its job. YAML COMMENTS are skipped — every conversion quotes the form
# it replaced, and a check that flagged its own audit trail would be unusable.
#
# Everything still standing needs a RECORDED DISPOSITION in the sidecar file
# (openspec/litmus-tests/LINE-WINDOW-DISPOSITIONS.txt): `<test>:<step-anchor>`
# plus the reason the window is the right scope. An unrecorded window is a
# violation. Not all windows are wrong — `-A2` gathering a call's arguments, or
# a window over a fixture the test just wrote, is the clearest available
# assertion — but each has to be argued once, in writing.
#
# ADVISORY BY DEFAULT (634-39ik's recorded scope: enforcement never halts the
# line; non-compliant state is accepted and filed). `--strict` exits 1 for the
# gate that wants to refuse new debt.
#
# Grammar (exactly one line):
#   ok:litmus-line-windows:<n>-recorded
#   violation:litmus-line-windows-unrecorded:<n>
#   unavailable:<reason>
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="${TILLANDSIAS_LITMUS_TESTS_DIR:-$ROOT/openspec/litmus-tests}"
DISPO="${TILLANDSIAS_LINE_WINDOW_DISPOSITIONS:-$DIR/LINE-WINDOW-DISPOSITIONS.txt}"
STRICT=0
[ "${1:-}" = "--strict" ] && STRICT=1

[ -d "$DIR" ] || { echo "unavailable:litmus-corpus-unreadable"; exit 2; }
[ -r "$DISPO" ] || { echo "unavailable:dispositions-file-unreadable"; exit 2; }

scan() {
    for f in "$DIR"/*.yaml; do
        [ -e "$f" ] || continue
        awk -v name="$(basename "$f")" '
            # Track the top-level section. Only critical_path decides verdicts.
            /^[a-z_]+:/ && $0 !~ /^  / { sect = $0; sub(/:.*/, "", sect) }
            {
                line = $0
                # A YAML comment is documentation, including the audit trail
                # every 925-erjs conversion carries.
                stripped = line
                sub(/^[ \t]+/, "", stripped)
                if (substr(stripped, 1, 1) == "#") next
                if (sect != "critical_path") next
                if (line ~ /grep[^|;)]*-[ABC][ ]*[0-9]/ &&
                    line ~ /(\.sh|\.rs|\.md|\.yaml|\.toml|\.json|\.py|\.nix)/) {
                    printf "%s:%d\n", name, FNR
                }
            }' "$f"
    done
}

recorded=0
unrecorded=0
unrecorded_list=""
while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    test_name="${hit%%:*}"
    # A disposition is keyed by TEST, not by line: line numbers move whenever
    # anything above them is edited, and a key that moves is a key that rots.
    if grep -q "^${test_name}[[:space:]|]" "$DISPO" 2>/dev/null; then
        recorded=$((recorded + 1))
    else
        unrecorded=$((unrecorded + 1))
        unrecorded_list="${unrecorded_list}  $hit
"
    fi
done <<EOF
$(scan)
EOF

if [ "$unrecorded" -gt 0 ]; then
    printf '%s' "$unrecorded_list" >&2
    echo "  Each needs a line in $DISPO naming the test and why the window is the right scope," >&2
    echo "  or a conversion to a structural range (see order 925-erjs for the idiom)." >&2
    echo "violation:litmus-line-windows-unrecorded:$unrecorded"
    [ "$STRICT" = 1 ] && exit 1
    exit 0
fi
echo "ok:litmus-line-windows:${recorded}-recorded"
exit 0
