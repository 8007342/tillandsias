#!/usr/bin/env bash
# @trace order:1141-vf9w, spec:ci-release
#
# check-no-competing-gate.sh — is another gate already running in THIS checkout?
#
# A cancelled gate used to survive its launcher (1141-vf9w): `toolbox run` is a
# thin client of `podman exec` and the container-side build.sh is parented by
# conmon, so killing the host side left the gate running against the same tree.
# The wrapper now propagates termination, but a survivor from before that fix,
# from a host where propagation could not run, or from a kill -9, still holds
# the checkout — and a second gate against a tree a first gate is using is how
# 1132-r4mt's arm 4 raced and how 1141-5pgh's debris appeared.
#
# THREE STATES, NOT TWO. This is the whole design and it was measured rather
# than reasoned (yoga, 2026-09-13). Every process of a dispatch carries
# TILLANDSIAS_WRAPPER_TOKEN. Grouped by that token, live processes fall into:
#
#   LIVE   a live host-side `toolbox run` in the group      -> a healthy gate
#   idle   host side gone, ONLY conmon left                 -> normal residue
#   STRAY  host side gone AND a live build.sh worker        -> the defect
#
# Measured on an IDLE host at the time: one LIVE, SEVEN idle, one false stray.
# A check refusing on "host side gone" would have refused seven times over on a
# host doing nothing — which is why the idle class exists here rather than being
# folded into the defect.
#
# AND THE WORKER TEST IS NARROW ON PURPOSE. The one group with live workers in
# that measurement was NOT a gate: two `sleep 600` children of a cargo test in
# crates/tillandsias-podman, left behind by the land gate that had just
# finished. Counting any live worker would refuse on a test's leaked debris for
# ten minutes after every gate. Debris is not contention; only a live build.sh
# contends for the checkout.
#
# ADVISORY TODAY, REFUSING LATER, and that is a deliberate staging rather than
# a half-measure. This discriminator has been wrong three times in two cycles —
# "ppid is conmon" (a legitimate gate is conmon-parented too), then a
# conmon-session walk (workable but needless), now this — and twice only a
# measurement caught it. A refusing check on the path every Linux build takes
# stops the FLEET when it is wrong, not one host. So it reports, is exercised
# every gate, and is promoted to refusing once it has run clean across hosts.
# Same argument check-portability-idioms.sh makes for staying advisory, and the
# same evidence standard: promote on measurements, not on confidence.
#
# Exit: 0 no competing gate  |  1 a surviving gate is holding this checkout
#       3 could-not-run — this host cannot enumerate processes (965-sxec)
set -uo pipefail

ADVISORY="${TILLANDSIAS_COMPETING_GATE_ADVISORY:-1}"

# PROC ROOT IS A TEST SEAM, and a narrow one: production never passes it, and
# the fixture builds a procfs-shaped tree instead of spawning real processes.
# That is deliberate — arms that race real `sleep`s test the scheduler as much
# as the classifier, and the state this check must get right (a host-side
# wrapper that has just died) is precisely the one that is hard to hold still.
# It also makes the no-procfs arm reachable on a Linux host, which is the arm
# that exists because the same absence silently failed open on darwin.
PROC_ROOT="${TILLANDSIAS_PROC_ROOT:-/proc}"

# NO /proc, NO ANSWER — and say so rather than returning "none found".
# lib-dispatch-reap.sh's header promised exactly this distinction and its code
# returned a silent success instead; on darwin, where /proc does not exist, that
# reported a clean reap having killed nothing. A scan that cannot see is not a
# scan that saw nothing.
if [ ! -d "$PROC_ROOT/1" ]; then
    echo "could-not-run:competing-gate:no-procfs (this host cannot enumerate processes; nothing is asserted about competing gates)"
    exit 3
fi

self=$$
live_tokens=""   # tokens with a live host-side wrapper
stray_report=""

# Collect token -> (has_host, worker_pids) in one pass.
tokens=""
for d in "$PROC_ROOT"/[0-9]*; do
    pid="${d##*/}"
    [ "$pid" = "$self" ] && continue
    [ -r "$d/environ" ] || continue
    tok=""
    {
        while IFS= read -r -d '' e; do
            case "$e" in TILLANDSIAS_WRAPPER_TOKEN=*) tok="${e#*=}"; break ;; esac
        done < "$d/environ"
    } 2>/dev/null
    [ -n "$tok" ] || continue
    cmd="$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null)"
    case "$cmd" in
        *"toolbox run"*)   live_tokens="$live_tokens $tok" ;;
        *conmon*)          : ;;
        *build.sh*)        tokens="$tokens $tok:$pid" ;;
        *)                 : ;;   # debris: a test's leaked child is not contention
    esac
done

for entry in $tokens; do
    tok="${entry%%:*}"; pid="${entry##*:}"
    case " $live_tokens " in
        *" $tok "*) continue ;;   # its wrapper is alive: a healthy concurrent gate
    esac
    stray_report="$stray_report  pid=$pid token=$tok"$'\n'
done

if [ -z "$stray_report" ]; then
    echo "ok:no-competing-gate"
    exit 0
fi

echo "competing-gate: a build.sh is running in this checkout with NO live wrapper (1141-vf9w)"
printf '%s' "$stray_report"
echo "  Its wrapper is gone, so nothing will reap it and it is using this tree."
echo "  SIGTERM has been measured INERT on a survivor; SIGKILL the pid and its children."
if [ "$ADVISORY" = "1" ]; then
    echo "advisory:competing-gate:1 (not blocking; set TILLANDSIAS_COMPETING_GATE_ADVISORY=0 to refuse)"
    exit 0
fi
exit 1
