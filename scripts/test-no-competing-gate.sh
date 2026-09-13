#!/usr/bin/env bash
# @trace order:1141-vf9w, spec:ci-release
#
# Fixture for check-no-competing-gate.sh (1141-vf9w).
#
# REGIME: hermetic and deterministic. Every arm builds a procfs-SHAPED tree of
# plain files and points the check at it through TILLANDSIAS_PROC_ROOT. No
# process is spawned, no signal is sent, nothing is timed, and nothing about
# THIS host is asserted — so it is honest on every host including the ones that
# have no /proc at all. No absolute moment is encoded (1130-i6xj).
#
# WHY NOT REAL PROCESSES. The state this classifier must get right is "the
# host-side wrapper has just died while its container-side child has not", and
# holding that still with real `sleep`s tests the scheduler as much as the
# classifier. The earlier reap fixture had to learn this the noisy way — a
# backgrounded child inheriting a command-substitution pipe hung it for its
# whole timeout.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/check-no-competing-gate.sh"
pass=0; fail=0
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# mkproc <root> <pid> <token|-> <cmdline>
mkproc() {
    local r="$1" pid="$2" tok="$3" cmd="$4"
    mkdir -p "$r/$pid"
    if [ "$tok" = "-" ]; then
        printf 'PATH=/usr/bin\0' > "$r/$pid/environ"
    else
        printf 'PATH=/usr/bin\0TILLANDSIAS_WRAPPER_TOKEN=%s\0' "$tok" > "$r/$pid/environ"
    fi
    printf '%s\0' "$cmd" > "$r/$pid/cmdline"
}
newroot() { local r="$tmp/$1"; mkdir -p "$r/1"; printf 'x\0' > "$r/1/cmdline"; printf 'PATH=/x\0' > "$r/1/environ"; echo "$r"; }

# NEUTRALISE THE CONTAINER MARKERS, or the fixture is not hermetic after all.
# The gate itself runs INSIDE the builder toolbox, where TOOLBOX_PATH is set, so
# an arm that merely inherits the environment gets the inside-container refusal
# no matter what its procfs tree says. Measured the noisy way: every arm passed
# on the host and the whole fixture refused the land from inside the gate. Arms
# that mean to test the container refusal set the marker themselves.
run_check() { TOOLBOX_PATH="" container="" TILLANDSIAS_PROC_ROOT="$1" bash "$CHECK" 2>&1; }

# The container arms need the marker SET, and run_check deliberately clears it,
# so they get their own entry point rather than relying on assignment order.
run_check_in_container() { # <procroot> <marker-var> <value>
    env "$2=$3" TILLANDSIAS_PROC_ROOT="$1" bash "$CHECK" 2>&1
}

check() { # <label> <expected-rc> <expected-token> <rc> <out>
    if [ "$4" -eq "$2" ] && printf '%s' "$5" | grep -q "$3"; then
        pass=$((pass+1))
    else
        fail=$((fail+1)); echo "FAIL: $1 — wanted rc=$2 and '$3', got rc=$4"
        printf '%s\n' "$5" | sed 's/^/    /'
    fi
}

# 1. A HEALTHY GATE: build.sh plus a live host-side wrapper in the same group.
r="$(newroot healthy)"
mkproc "$r" 100 tok-a "toolbox run --container tillandsias-builder bash -l -c x"
mkproc "$r" 101 tok-a "/usr/bin/conmon --api-version 1 -c abc"
mkproc "$r" 102 tok-a "bash /repo/./build.sh --check"
out="$(run_check "$r")"; rc=$?
check "a live wrapper means a healthy gate, not a competitor" 0 "ok:no-competing-gate" "$rc" "$out"

# 2. THE DEFECT: same group, wrapper gone.
r="$(newroot stray)"
mkproc "$r" 101 tok-a "/usr/bin/conmon --api-version 1 -c abc"
mkproc "$r" 102 tok-a "bash /repo/./build.sh --check"
out="$(run_check "$r")"; rc=$?
check "a build.sh with no live wrapper is reported" 0 "competing-gate:" "$rc" "$out"

# 3. THE idle CLASS, and the arm that stops this refusing on an idle host. A
#    finished exec session leaves a conmon behind carrying the token; seven such
#    groups existed on yoga at the time this was written, on a host doing
#    nothing. Folding idle into the defect would have refused all seven.
r="$(newroot idle)"
for p in 201 202 203 204 205 206 207; do mkproc "$r" "$p" "tok-$p" "/usr/bin/conmon --api-version 1 -c abc"; done
out="$(run_check "$r")"; rc=$?
check "conmon-only groups are residue, not competitors" 0 "ok:no-competing-gate" "$rc" "$out"

# 4. DEBRIS IS NOT CONTENTION, and this arm catches the seductive wrong widening.
#    The one group with live workers in the founding measurement was two
#    `sleep 600` children of a cargo test, left by a gate that had FINISHED.
#    Counting any live worker refuses on that for ten minutes after every gate.
r="$(newroot debris)"
mkproc "$r" 301 tok-d "/usr/bin/conmon --api-version 1 -c abc"
mkproc "$r" 302 tok-d "sleep 600"
mkproc "$r" 303 tok-d "sleep 600"
out="$(run_check "$r")"; rc=$?
check "leaked non-build.sh children are not a competing gate" 0 "ok:no-competing-gate" "$rc" "$out"

# 5. NO PROCFS IS COULD-NOT-RUN, never "none found" (965-sxec). This is the arm
#    whose absence made lib-dispatch-reap.sh fail OPEN on darwin: a scan that
#    cannot see is not a scan that saw nothing.
out="$(run_check "$tmp/absent-root")"; rc=$?
check "an unreadable procfs is could-not-run, not a clean answer" 3 "could-not-run:competing-gate:no-procfs" "$rc" "$out"

# 6. ADVISORY vs REFUSING: the same detection, two exit codes, so the promotion
#    is a flag flip rather than a rewrite — and so the refusing mode is proven
#    to work before anyone turns it on fleet-wide.
r="$(newroot refusing)"
mkproc "$r" 101 tok-a "/usr/bin/conmon --api-version 1 -c abc"
mkproc "$r" 102 tok-a "bash /repo/./build.sh --check"
out="$(TILLANDSIAS_COMPETING_GATE_ADVISORY=0 run_check "$r")"; rc=$?
check "refusing mode exits non-zero on the same detection" 1 "competing-gate:" "$rc" "$out"
out="$(run_check "$r")"; rc=$?
check "advisory mode says so and does not block" 0 "advisory:competing-gate:1" "$rc" "$out"

# 7. A process with NO token is invisible: an unrelated build.sh on this host
#    (a sibling checkout, an operator's shell) must never be called a competitor
#    here. Widening to all build.sh processes would refuse across checkouts.
r="$(newroot untokened)"
mkproc "$r" 401 - "bash /other-repo/./build.sh --check"
out="$(run_check "$r")"; rc=$?
check "an untokened build.sh elsewhere is not this checkout's competitor" 0 "ok:no-competing-gate" "$rc" "$out"

# 8. INSIDE A CONTAINER THE CHECK REFUSES TO ANSWER. This is the arm the
#    hermetic fixture could not have predicted and the first in-situ run
#    produced: build.sh re-execs into the toolbox BEFORE its fast refusals, and
#    from inside, a host-side wrapper's environ is unreadable — `[ -r ]` answers
#    TRUE and the read is then DENIED, so every wrapper vanished and every gate
#    reported ITSELF as a competing gate. A fake procfs of plain files is always
#    readable, which is exactly why 8/8 passed over a detector that was wrong in
#    production.
r="$(newroot incontainer)"
mkproc "$r" 101 tok-a "/usr/bin/conmon --api-version 1 -c abc"
mkproc "$r" 102 tok-a "bash /repo/./build.sh --check"
out="$(run_check_in_container "$r" TOOLBOX_PATH /)"; rc=$?
check "inside a container it refuses to answer rather than accusing" 3 "could-not-run:competing-gate:inside-container" "$rc" "$out"
out="$(run_check_in_container "$r" container oci)"; rc=$?
check "an oci container is refused the same way" 3 "could-not-run:competing-gate:inside-container" "$rc" "$out"

# 9. AN UNREADABLE PROCESS SUSPENDS THE ACCUSATION. A denied read is not an
#    absent token: one of the processes it could not read may be the live
#    wrapper of the group that looks headless. Accusing anyway is how a
#    permission boundary becomes a false positive.
r="$(newroot opaque)"
mkproc "$r" 101 tok-a "/usr/bin/conmon --api-version 1 -c abc"
mkproc "$r" 102 tok-a "bash /repo/./build.sh --check"
mkproc "$r" 103 tok-b "bash /repo/./build.sh --check"
# UNREADABLE BY STRUCTURE, NOT BY PERMISSION. This arm used to `chmod 000` the
# environ, which assumes chmod denies the READER — false for root, which has
# DAC_OVERRIDE, and a WSL distro runs as root by default. Measured under
# `podman unshare`: uid 0 gets `[ -r <chmod-000> ]` = TRUE while uid 1000 gets
# FALSE, so the arm passed on Linux hosts and RED yolanda's windows-next gate,
# where the file was readable, the group looked headless and the classifier
# accused — correctly, for the tree the fixture actually built. A dangling
# symlink has nothing to read rather than permission to deny, so `[ -r ]` is
# FALSE for uid 0 and uid 1000 alike and the arm means the same thing
# everywhere. Second time this fixture claimed a regime it did not have; the
# first was inheriting TOOLBOX_PATH from the gate's own container.
rm -f "$r/103/environ"
ln -s /nonexistent-so-there-is-nothing-to-read "$r/103/environ"
out="$(run_check "$r")"; rc=$?
check "an unreadable process suspends the accusation" 3 "could-not-run:competing-gate:unreadable-processes" "$rc" "$out"

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then echo "PASS: competing-gate detector $pass/$total (1141-vf9w)"; exit 0; fi
echo "FAIL: competing-gate detector $pass/$total (1141-vf9w)"; exit 1
