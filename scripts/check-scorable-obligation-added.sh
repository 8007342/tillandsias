#!/usr/bin/env bash
# @trace order:977-448j, order:976-kk6x
#
# check-scorable-obligation-added.sh — refuse a NEWLY FILED packet that carries
# nothing the centicolon scorer can read, and refuse it as a GATE rather than
# asking politely.
#
# WHY "HARD" IS THE WHOLE POINT. The operator's ruling was "require it hard
# going forward", and the fleet already has the evidence for why a soft version
# is the same as none: the daily-maintenance marker existed only as prose from
# 2026-08-13 to 08-17, so "did the gate run" had no answer at all, and the
# cheapest way to satisfy it was to skip it.
#
# WHAT IS ALREADY ENFORCED, so this does not duplicate it:
# check-declared-closures-added.sh (885-92iu) refuses a new packet whose
# `verifiable_closure` NAMES a litmus test that cannot run — unresolvable or
# unbound. What it never asks is whether a closure exists AT ALL. A new packet
# with no closure, or with a closure that is pure prose, passes that gate
# silently, and is exactly the row rung 4 could not score.
#
# MEASURED (977-3dee, same day): of 563 packets, 112 carry a verifiable_closure
# and only 25 name a litmus test. Retroactive coverage came to 2.6%. That is the
# standing debt this gate must NOT red — a gate that reds the trunk on day one
# gets switched off, which is the failure the sibling packet is about. So the
# scope is NEW rows only.
#
# WHAT COUNTS AS SCORABLE. Either:
#   * a `verifiable_closure` naming a `litmus:<test>` — the pin rung 4 used; or
#   * an explicit `unscoreable: <reason>` — a STATED refusal.
#
# THE SECOND IS NOT A LOOPHOLE, IT IS THE POINT. Some rows genuinely close by
# other means: a measurement, a script verdict, an operator decision. Demanding
# a litmus test of all of them would make the gate unsatisfiable, and an
# unsatisfiable gate is switched off. What this refuses is SILENCE — a row that
# says nothing about how it could ever be scored. A stated reason is auditable
# and greppable; an omission is neither.
#
# Grammar (one line on stdout, nothing else):
#   ^(ok:scorable-obligations:[0-9]+ checked|violation:scorable-obligation-missing:[0-9]+|skip:no-new-packets)$
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

BASE="${1:-origin/linux-next}"

# Fragments ADDED versus the base, plus wholly untracked ones — new debt only.
#
# NOT `mapfile` (761-g36m): it is bash-4-only and macOS ships bash 3.2, so a
# shared gate that used it would refuse to run on one host and pass vacuously
# there — a gate that cannot execute is indistinguishable from one that found
# nothing.
changed=""
_collect="$(
    { git diff --name-only --diff-filter=A "$BASE"...HEAD -- plan/index.d/ 2>/dev/null || true
      git ls-files --others --exclude-standard -- plan/index.d/ 2>/dev/null || true
    } | sort -u
)"
while IFS= read -r _f; do
    [ -n "$_f" ] || continue
    changed="$changed$_f
"
done <<EOF
$_collect
EOF

[ -n "$changed" ] || { echo "skip:no-new-packets"; exit 0; }

checked=0
violations=0
regime_broken=0
rdetail=""
detail=""

while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    # Only fragments that DEFINE packets. An events-only fragment adds no
    # obligation and must not be demanded of.
    grep -q '^packets:' "$f" 2>/dev/null || continue

    # Split into per-packet blocks and inspect each. awk rather than a YAML
    # round-trip: this runs in the gate and must not need the plan binary.
    while IFS= read -r block; do
        [ -n "$block" ] || continue
        checked=$((checked + 1))
        pid="${block%%$'\x1f'*}"
        body="${block#*$'\x1f'}"
        case "$body" in
            *litmus:*|*unscoreable:*)
                # SCORABLE. Now the SECOND question, which is a different one:
                # is the score it will produce COMPARABLE with the previous run?
                # A row that tombstones an obligation changes the denominator
                # scope, which math-foundations.yaml names as leaving the band
                # where centicolon_function is monotone (rung 3 returns
                # Regime::Broken for exactly this).
                #
                # THIS IS NOT A VIOLATION AND MUST NOT BE ONE. Tombstoning is
                # legitimate — the operator's rule at proximity.yaml:47 requires
                # it when a requirement's meaning changes. What would be wrong is
                # letting the resulting score be read as comparable. So it is
                # NAMED, loudly, and the gate still passes.
                case "$body" in
                    *tombstone*)
                        regime_broken=$((regime_broken + 1))
                        rdetail="${rdetail}  ${f}: packet '${pid}' tombstones an obligation — its score is OUTSIDE the monotone regime and must not be compared with the previous run (977-448j)"$'\n'
                        ;;
                esac
                ;;
            *)
                violations=$((violations + 1))
                detail="${detail}  ${f}: packet '${pid}' carries no scorable obligation — add a verifiable_closure naming a litmus:<test>, or an explicit 'unscoreable: <reason>' (977-448j)"$'\n'
                ;;
        esac
    done < <(awk '
        /^  - packet_id:|^    - packet_id:/ {
            if (pid != "") { printf "%s\x1f%s\n", pid, buf }
            pid = $NF; buf = ""; next
        }
        pid != "" { buf = buf " " $0 }
        END { if (pid != "") printf "%s\x1f%s\n", pid, buf }
    ' "$f")
done <<EOF
$changed
EOF

if [ "$checked" -eq 0 ]; then
    echo "skip:no-new-packets"
    exit 0
fi

if [ "$violations" -gt 0 ]; then
    echo "violation:scorable-obligation-missing:$violations"
    printf '%s' "$detail" >&2
    echo "  A new row that says nothing about how it could be scored is the row" >&2
    echo "  rung 4 could not backfill. State the pin, or state why there is none." >&2
    exit 1
fi

if [ "$regime_broken" -gt 0 ]; then
    printf %s "$rdetail" >&2
    echo "note:scorable-obligation-regime-broken:$regime_broken" >&2
fi
echo "ok:scorable-obligations:$checked checked"
