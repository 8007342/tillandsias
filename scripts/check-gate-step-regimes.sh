#!/usr/bin/env bash
# @trace order:1302-7j8p, spec:ci-release
#
# A GATE STEP MUST CARRY A RECORDED SECOND-REGIME RUN BEFORE IT ENTERS --check.
#
# WHY THIS EXISTS, measured rather than supposed. On 2026-09-20 two steps
# entered the gate with a Linux-only measurement and reddened both macOS gates
# within hours:
#   414 (1269-gfdi) — the subject skips its toolbox arms on a Mac, and ARM 0
#       demanded a line that cannot print there (1300-q7eq).
#   416 (1273-4mak) — the stub digests with sha256sum under a PATH pinned to
#       /usr/bin:/bin, unreachable on macbookair, so ARM 2 refused a genuine
#       artifact while ARM 3 passed vacuously.
# Both were green on the author's regime. The author's host is not the
# measurement that matters for a step that runs on every host.
#
# THE RECORD LIVES IN THE .step FILE, as a STEP_SECOND_REGIME variable beside
# the step's other STEP_* data. A sidecar would be more greppable and was
# rejected for one reason: a record that lives apart from its subject can drift
# from it, and a checker reading a field nothing writes is this packet's own
# defect in miniature. In the step file the record cannot outlive the step.
#
# FORM:  STEP_SECOND_REGIME="<host> <YYYY-MM-DD> <regime> <verdict>"
#   host     the machine that ran it
#   date     when
#   regime   darwin | msys   — a CLOSED SET, deliberately. Linux is not a
#            second regime for a fleet whose gates already run on Linux, and
#            naming a Linux host here must not satisfy the check.
#   verdict  what was seen: a verdict line, or a NAMED SKIP. A step that
#            genuinely cannot run off Linux records `skip:<reason>` and that
#            COUNTS — the point is a recorded observation from the other
#            regime, not a green one (965-sxec).
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "refused:gate-step-regimes:not-bash"; exit 2; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="${1:-$ROOT/scripts/gate-steps.d}"

[ -d "$DIR" ] || { echo "skip:gate-step-regimes:no-step-dir:$DIR"; exit 0; }

# The regimes that COUNT as a second one. Closed by design: adding a token here
# is a decision about what the fleet considers a distinct regime, and it should
# be made deliberately rather than by a host writing a new word into a step.
_is_second_regime() {
    case "$1" in
        darwin|msys) return 0 ;;
        *) return 1 ;;
    esac
}

missing=0
malformed=0
linuxonly=0
ok=0
detail=""

for step in "$DIR"/*.step; do
    [ -e "$step" ] || continue
    name="$(basename "$step")"
    # Read the value without sourcing: a .step is data, and sourcing it would
    # execute whatever a future step happens to contain.
    line="$(grep -E '^[[:space:]]*STEP_SECOND_REGIME=' "$step" 2>/dev/null | head -1)"
    if [ -z "$line" ]; then
        missing=$((missing + 1))
        detail="${detail}violation:gate-step-single-regime:${name}"$'\n'
        continue
    fi
    value="${line#*=}"
    value="${value%\"}"; value="${value#\"}"
    # shellcheck disable=SC2086
    set -- $value
    host="${1:-}"; date_="${2:-}"; regime="${3:-}"
    if [ -z "$host" ] || [ -z "$date_" ] || [ -z "$regime" ]; then
        malformed=$((malformed + 1))
        detail="${detail}violation:gate-step-single-regime:${name}:malformed-record"$'\n'
        continue
    fi
    case "$date_" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;;
        *)
            malformed=$((malformed + 1))
            detail="${detail}violation:gate-step-single-regime:${name}:date-not-yyyy-mm-dd"$'\n'
            continue ;;
    esac
    if ! _is_second_regime "$regime"; then
        linuxonly=$((linuxonly + 1))
        detail="${detail}violation:gate-step-single-regime:${name}:regime-${regime}-is-not-a-second-regime"$'\n'
        continue
    fi
    ok=$((ok + 1))
done

bad=$((missing + malformed + linuxonly))
if [ "$bad" -gt 0 ]; then
    printf '%s' "$detail" >&2
    echo "violation:gate-step-single-regime:$bad"
    {
        echo "  $bad of $((bad + ok)) gate steps carry no usable second-regime record."
        echo "  A step green only on its author's regime is the failure this refuses:"
        echo "  two such steps reddened both macOS gates within hours on 2026-09-20."
        echo "  Add to the .step file:"
        echo '    STEP_SECOND_REGIME="<host> <YYYY-MM-DD> <darwin|msys> <verdict>"'
        echo "  A step that genuinely cannot run off Linux records skip:<reason> as"
        echo "  its verdict, and that COUNTS — the record is an observation from the"
        echo "  other regime, not necessarily a green one."
    } >&2
    exit 1
fi

echo "ok:gate-step-regimes:$ok"
