#!/usr/bin/env bash
# @trace order:721-nyev, spec:ci-release
#
# Every script that RUNS tillandsias-plan must resolve it through the shared
# probe (scripts/plan-binary-probe.sh), never through a hardcoded target/ path.
#
# WHY A GATE RATHER THAN ANOTHER ROUND OF FIXES. 704-zcgi centralised the probe
# on the reasoning that fixing instances is not enough. Four more instances
# appeared afterwards anyway -- check-stranded-in-progress, then
# check-fragment-closure-evidence-added, then select-work-batch, then
# cycle-preflight -- each written by someone who had no reason to know the
# probe existed. A tenth will be written next week. The rule has to be
# enforceable rather than remembered.
#
# THE UNDERLYING FACT: an executable BIT is a claim; RUNNING the binary is
# evidence. On a shared Windows/WSL checkout a WSL build leaves a Linux ELF at
# target/release/tillandsias-plan beside the runnable .exe, and `[ -x ]` is
# true for both. Callers that trusted the bit degraded in three different
# directions -- a silent "binary absent, check skipped", a red gate naming
# violations that did not exist, and a pre-push lane that reported on a
# validation it never ran.
#
# THE INVARIANT, deliberately simple: if a script mentions a target/ plan-binary
# path in code, it must also source the probe. Simple because 727-kmks warns
# against pattern-matchers that need a table of exceptions -- the fix for every
# real site is the same one line, so no exception table should be necessary. If
# a genuine exception ever appears, that is a signal to reconsider the rule, not
# to add an allow-list.
#
# GRAMMAR (exactly one line on stdout)
#   ok:plan-binary-probe-usage:<eligible> eligible of <scanned> scanned
#   violation:plan-binary-probe-usage:<n>
#
# Exit 0 on ok, 1 on violation, 2 on usage error.

set -uo pipefail

ROOT="${PLAN_PROBE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT" || { echo "violation:plan-binary-probe-usage:0"; exit 2; }

SCAN_DIR="${1:-scripts}"
PROBE_REL="plan-binary-probe.sh"

violations=()
checked=0
scanned=0

while IFS= read -r f; do
    # The probe itself defines the candidate paths; it cannot source itself.
    scanned=$((scanned + 1))
    case "$f" in */$PROBE_REL) continue ;; esac

    # Code lines only. A comment or a user-facing message may name the path
    # legitimately -- and a checker that flagged its own explanatory comment
    # would be the "gate that greps its own comment" antipattern 601-462g
    # names, one level up.
    code="$(sed 's/#.*//' "$f")"
    if ! printf '%s' "$code" | grep -qE 'target/(release|debug)/tillandsias-plan'; then
        continue
    fi
    # Messages that merely NAME the path (echo/printf/array notes) are not
    # executions. Strip quoted-string contexts that are obviously output.
    if ! printf '%s' "$code" \
        | grep -vE '(echo|printf|LANE_NOTES|note|fail|say)[[:space:]]' \
        | grep -qE 'target/(release|debug)/tillandsias-plan'; then
        continue
    fi

    checked=$((checked + 1))
    if ! grep -q "$PROBE_REL" "$f"; then
        violations+=("$f")
    fi
done < <(find "$SCAN_DIR" -name '*.sh' -type f 2>/dev/null | sort)

if [ "${#violations[@]}" -gt 0 ]; then
    echo "violation:plan-binary-probe-usage:${#violations[@]}"
    for v in "${violations[@]}"; do
        echo "  $v runs tillandsias-plan from a hardcoded target/ path without sourcing scripts/$PROBE_REL" >&2
    done
    echo "  REMEDY: . \"\$(dirname \"\${BASH_SOURCE[0]}\")/plan-binary-probe.sh\"; PLAN=\"\$(resolve_plan_binary)\"" >&2
    echo "  An executable bit is a claim; running the binary is evidence (704-zcgi, 721-nyev)." >&2
    exit 1
fi

# Say BOTH numbers. "1 checked" reads as "it only looked at one file",
# when it means "one file mentions the path and it is compliant" -- the
# count invites the same misreading this whole class is about.
echo "ok:plan-binary-probe-usage:${checked} eligible of ${scanned} scanned"
exit 0
