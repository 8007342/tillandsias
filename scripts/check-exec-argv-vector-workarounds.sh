#!/usr/bin/env bash
# Order 837-et6t (closure leg of 795-zshi).
#
# The verbatim-argv arm (spec vsock-exec-authz §4) exists so hosts stop
# flattening argv into a shell string. Two host-side escaping workarounds that
# existed ONLY to survive that flattening were deleted with it. A deletion with
# no guard against re-introduction is a deletion that gets undone by whoever
# next hits the quoting problem and does not know why the workaround went away
# — which is how this subsystem accumulated five of them.
#
# THIS SCANS FOR DEFINITIONS, NOT MENTIONS, and that is the whole design.
# `argv_survives_wt_reparse` and `wt_safe_title` are named in comments that
# record why they went away; those comments are the institutional memory and
# must not make the gate red. A `fn <name>` definition is the thing that would
# actually bring the workaround back.
#
# 634-39ik: this asserts the ABSENCE of named symbols — a property that stays
# true however the surrounding code is rewritten — never how today's source
# happens to be spelled. The negative control lives in
# litmus:guest-exec-argv-vector-no-shell and runs this script against a
# hermetic tree that DOES define one, proving the scan refuses.
#
# NOT SCANNED, deliberately: `build_exec_guest_shell_cmd`. Order 838-48ca
# decided on the record to KEEP it, scoped to genuine shell requests
# (`--exec-guest 'a | b'` is a pipeline, which a verbatim vector cannot
# express), and amended 795-zshi's exit criterion 2 to match. Scanning for its
# absence would make this gate enforce a decision the fleet reversed.
#
# @trace spec:vsock-exec-authz
set -uo pipefail

root="${1:-.}"

# Symbols whose DEFINITION must not exist. Add to this list only for a
# workaround that the verbatim-argv arm genuinely retires.
readonly RETIRED_SYMBOLS=(argv_survives_wt_reparse wt_safe_title)

if [ ! -d "$root" ]; then
    echo "blocked:no-such-root:$root"
    exit 2
fi

violations=0
for sym in "${RETIRED_SYMBOLS[@]}"; do
    # `fn <sym>` catches a plain fn, a pub fn, a method and a const fn alike.
    hits="$(grep -rn --include='*.rs' -E "fn[[:space:]]+${sym}\b" "$root" 2>/dev/null || true)"
    if [ -n "$hits" ]; then
        echo "$hits" | while IFS= read -r line; do
            echo "  reintroduced: $line" >&2
        done
        violations=$((violations + 1))
    fi
done

if [ "$violations" -ne 0 ]; then
    echo "violation:exec-argv-workaround-reintroduced:${violations}"
    exit 1
fi

echo "ok:exec-argv-workarounds-absent:${#RETIRED_SYMBOLS[@]} checked"
