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
# ANSWER ONLY ON A POSITIVE HOST-SIDE ASSERTION (the inversion).
#
# This used to REFUSE when it recognised a container — TOOLBOX_PATH, container=
# oci|podman, marker files — and answer otherwise. That points the failure mode
# at the UNKNOWN case: every dispatch boundary nobody has met yet is a false
# accusation waiting. WSL2 proved enumeration cannot even be completed: measured
# by yolanda inside tillandsias-build, TOOLBOX_PATH empty, container empty, no
# /run/.toolboxenv, no /run/.containerenv, no /.dockerenv — because a WSL distro
# is not inside a dispatch at all, it is a VM the wrapper shells into. There is
# no property to enumerate. Their gate duly accused itself.
#
# Inverted, the failure mode points at the KNOWN case: a caller that does not
# assert host-side gets SILENCE. A new dispatch shape then costs a missing
# answer rather than a wrong one — and missing answers are visible when you go
# looking, while wrong answers are believed (yolanda's phrasing, and the whole
# argument in one line).
#
# THE ASSERTION IS NOT A BARE FLAG. --host-side carries the caller's own PID,
# and this verifies that pid's environ is READABLE and CONTAINS the caller's
# token. Readability alone would let a wrapper pass any pid it liked and re-open
# the hole; containment makes it a POSITIVE CONTROL — it proves this process can
# read the very class of process the verdict depends on. A readable-but-tokenless
# pid is a CALLER BUG (wrong pid, wrong shell, or the export never happened —
# the shape of a test hazard that bit me), and must be loud rather than assumed
# benign.
#
# FOUR OUTCOMES, FOUR CODES, because two of them demand opposite responses:
#   0/1  answered (no competitor / a competitor)
#   2    refused:competing-gate:caller-contract  -> FIX THE CALL SITE
#   3    could-not-run:competing-gate:...        -> this host cannot answer
# A shared code would let a wiring bug read as an unsupported substrate and be
# written off, which is the collapse 1140-i6ct exists to prevent one check over.
#
# NOTHING ON TRUNK READS THESE CODES YET: both call sites are `|| true`. The
# grammar therefore binds a FUTURE consumer, and that consumer must enumerate 2
# apart from 3 with no default that proceeds.
# THREE SILENCES WORE ONE SENTENCE (order 1221-vkbj).
#
# `no-host-side-assertion` is this file's vocabulary for a caller that OMITTED
# something, and its sibling `refused:...:caller-contract` says "FIX THE CALL
# SITE" in so many words. Measured on lenovinha 2026-09-16, build.sh:1898's
# unflagged invocation printed exactly that token on a host where no dispatch
# had happened at all — no host side to assert, no container side to race, and
# nothing whatever to fix. Three situations, one sentence, opposite responses:
#
#   inside a dispatch, cannot see the host side  -> correct silence, nothing to do
#   no dispatch wrapped this gate at all         -> correct silence, nothing to do
#   a wrapper that forgot to assert              -> FIX THE CALL SITE
#
# `--caller-context` lets a caller say which of the first two it is in. It is
# still a POSITIVE ASSERTION by the caller — this file does not go looking, for
# the reason the inversion above states at length.
#
# AND IT DELIBERATELY DOES NOT ANSWER. The tempting move is to let an
# undispatched caller assert --host-side and get a verdict. It cannot: the
# classifier groups by TILLANDSIAS_WRAPPER_TOKEN and needs a host side AND a
# container side to tell LIVE from STRAY. With no dispatch the group is one
# process and the only reachable verdict is `ok:no-competing-gate` — the clean
# run that asserts nothing this header warns about twice, and which
# 1141-vf9w's "promote once it has run clean across hosts" would then eat. A
# green incapable of being red is worse than the silence it replaces.
HOST_SIDE_PID=""
CALLER_CONTEXT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --host-side) HOST_SIDE_PID="${2:-}"; shift 2 ;;
        --host-side=*) HOST_SIDE_PID="${1#*=}"; shift ;;
        --caller-context) CALLER_CONTEXT="${2:-}"; shift 2 ;;
        --caller-context=*) CALLER_CONTEXT="${1#*=}"; shift ;;
        *) shift ;;
    esac
done

case "$CALLER_CONTEXT" in
    ""|dispatched|undispatched) ;;
    *)
        echo "refused:competing-gate:caller-contract (--caller-context '$CALLER_CONTEXT' is not one of dispatched|undispatched; FIX THE CALL SITE, this is not a substrate limit)"
        exit 2 ;;
esac

# A context assertion is about where the CALLER stands, so it is meaningless
# alongside --host-side and must not silently outrank it.
if [ -n "$HOST_SIDE_PID" ] && [ -n "$CALLER_CONTEXT" ]; then
    echo "refused:competing-gate:caller-contract (a caller asserting --host-side must not also assert --caller-context; FIX THE CALL SITE, this is not a substrate limit)"
    exit 2
fi

if [ -z "$HOST_SIDE_PID" ]; then
    case "$CALLER_CONTEXT" in
        undispatched)
            echo "could-not-run:competing-gate:no-dispatch (the caller reports no tillandsias wrapper dispatched this run, so there is no host side to assert and no container side to race — NOTHING TO FIX HERE; a verdict from here could only ever be a vacuous clean)"
            exit 3 ;;
        dispatched)
            echo "could-not-run:competing-gate:inside-dispatch (the caller reports it is INSIDE the dispatch, where the host side is unreadable — the answerable call site is the wrapper's, not this one; NOTHING TO FIX HERE)"
            exit 3 ;;
        *)
            echo "could-not-run:competing-gate:no-host-side-assertion (this caller did not assert --host-side <pid>; only a caller that can see the dispatch's host side may be answered)"
            exit 3 ;;
    esac
fi

if [ ! -d "$PROC_ROOT/1" ]; then
    echo "could-not-run:competing-gate:no-procfs (this host cannot enumerate processes; nothing is asserted about competing gates)"
    exit 3
fi

# THE POSITIVE CONTROL IS OUR OWN ENVIRON, NOT THE CALLER'S PID.
#
# The contract was first written as "the passed pid's environ must contain the
# caller's token". It cannot: `/proc/<pid>/environ` is the environment a process
# was EXEC'D with, and the token is minted and exported at runtime by the very
# shell that asserts. Measured — exporting shell's own environ: 0 matches; a
# child exec'd after the export: 1. So the asserting caller provably cannot show
# its own token, and the first wiring of this check refused its real call site
# with `caller-contract`, correctly, against a contract that was impossible.
#
# THIS process is that child. It was exec'd after the export, so our own environ
# carries the token when the caller really did export it — and unlike a passed
# pid we cannot substitute a convenient one. That makes it a true positive
# control and a stronger one than the original: it proves in a single read that
# environ is READABLE on this substrate AND that the caller's export actually
# happened.
#
# `self` rather than `$$` so the fixture can construct it: real procfs provides
# /proc/self, and a fake tree provides a `self/` directory.
_hs="$PROC_ROOT/self/environ"
if [ ! -e "$_hs" ] || [ ! -r "$_hs" ]; then
    echo "could-not-run:competing-gate:blind (cannot read our own environ at $_hs — this host exposes no readable environ, so nothing can be concluded about competing gates)"
    exit 3
fi
_hs_tok=""
if ! { while IFS= read -r -d '' e; do
           case "$e" in TILLANDSIAS_WRAPPER_TOKEN=*) _hs_tok="${e#*=}"; break ;; esac
       done < "$_hs"; } 2>/dev/null; then
    echo "could-not-run:competing-gate:blind (our own environ at $_hs could not be read through)"
    exit 3
fi
if [ -z "$_hs_tok" ]; then
    echo "refused:competing-gate:caller-contract (caller asserted --host-side $HOST_SIDE_PID but did not export TILLANDSIAS_WRAPPER_TOKEN into this process; FIX THE CALL SITE, this is not a substrate limit)"
    exit 2
fi

self=$$
opaque=0
live_tokens=""   # tokens with a live host-side wrapper
stray_report=""

# Collect token -> (has_host, worker_pids) in one pass.
tokens=""
for d in "$PROC_ROOT"/[0-9]*; do
    pid="${d##*/}"
    [ "$pid" = "$self" ] && continue
    # A DENIED READ IS NOT AN ABSENT TOKEN — but only a read that could have
    # been a WRAPPER is worth suspending an accusation over.
    #
    # ORDER 1141-vf9w, refuted by pirria's measurement. Counting EVERY
    # unreadable environ as opaque put a permanent floor under the suspension
    # and made the detector unable to ever accuse on an ordinary host.
    # `/proc/<pid>/environ` is mode 0400, owner-only; `/proc/<pid>/cmdline` is
    # 0444, world-readable. Measured on yoga: 486 processes, 286 with an
    # unreadable environ, of which exactly ONE was same-uid — `(sd-pam)`, which
    # changes credentials and can never be a gate's wrapper. pirria measured the
    # consequence directly, 30 runs per arm with a genuine stray alive
    # throughout: accused=0 suspended=30 in BOTH the control and the churn arm,
    # opaque 164..171 either way. Churn was never needed; the idle host already
    # suspended. The two regimes where the detector COULD still accuse were
    # exactly the two that had produced false positives.
    #
    # That also made "promote once it has run clean across hosts" satisfiable
    # forever on any unprivileged host, because the detector could not reach its
    # own accusation there — a clean run that asserts nothing, which this file's
    # header warns about twice and which I then built into its promotion gate.
    #
    # THE FILTER IS CMDLINE-SHAPED, and cmdline being world-readable is what
    # makes it always evaluable: a process we cannot read is ambiguous only if
    # it LOOKS like a dispatch wrapper. A root daemon cannot be the wrapper of
    # an unprivileged user's gate. Measured floor after this filter on an idle
    # host: ZERO.
    if [ ! -r "$d/environ" ]; then
        _oc="$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null)"
        case "$_oc" in
            *"toolbox run"*|*with-tillandsias-builder*|*with-wsl2-builder*|*podman*exec*)
                opaque=$((opaque + 1)) ;;
        esac
        continue
    fi
    tok=""
    if ! { while IFS= read -r -d '' e; do
               case "$e" in TILLANDSIAS_WRAPPER_TOKEN=*) tok="${e#*=}"; break ;; esac
           done < "$d/environ"; } 2>/dev/null; then
        opaque=$((opaque + 1)); continue
    fi
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

if [ "$opaque" -gt 0 ]; then
    echo "could-not-run:competing-gate:unreadable-processes:$opaque (a candidate looks headless, but $opaque process(es) could not be read — one of them may be its live wrapper)"
    exit 3
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
