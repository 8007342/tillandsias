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
# Every tree needs a readable, TOKENED `self`: the check's positive control
# reads its own environ before it will answer at all. Arms that mean to exercise
# the control's failures overwrite this deliberately.
newroot() {
    local r="$tmp/$1"; mkdir -p "$r/1" "$r/self"
    printf 'x\0' > "$r/1/cmdline"; printf 'PATH=/x\0' > "$r/1/environ"
    printf 'x\0' > "$r/self/cmdline"
    printf 'PATH=/x\0TILLANDSIAS_WRAPPER_TOKEN=self-tok\0' > "$r/self/environ"
    echo "$r"
}

# NEUTRALISE THE CONTAINER MARKERS, or the fixture is not hermetic after all.
# The gate itself runs INSIDE the builder toolbox, where TOOLBOX_PATH is set, so
# an arm that merely inherits the environment gets the inside-container refusal
# no matter what its procfs tree says. Measured the noisy way: every arm passed
# on the host and the whole fixture refused the land from inside the gate. Arms
# that mean to test the container refusal set the marker themselves.
# Arms assert --host-side, because an unflagged caller is silent by design now
# (the inversion). The pid value is immaterial to the scan; what the check
# verifies is its OWN environ, which newroot() supplies.
run_check() { TILLANDSIAS_PROC_ROOT="$1" bash "$CHECK" --host-side 999 2>&1; }

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

# 8. AN UNFLAGGED CALLER IS SILENT — the inversion itself. Before this, the
#    check answered unless it RECOGNISED a container, which pointed its failure
#    mode at every dispatch boundary nobody had met: WSL2 sets no marker at all
#    (measured by yolanda: TOOLBOX_PATH empty, container empty, no marker files)
#    and their gate accused itself. Unflagged now costs a missing answer, never
#    a wrong one.
r="$(newroot unflagged)"
mkproc "$r" 101 tok-a "/usr/bin/conmon --api-version 1 -c abc"
mkproc "$r" 102 tok-a "bash /repo/./build.sh --check"
out="$(TILLANDSIAS_PROC_ROOT="$r" bash "$CHECK" 2>&1)"; rc=$?
check "an unflagged caller is silent, not accusing" 3 "could-not-run:competing-gate:no-host-side-assertion" "$rc" "$out"

# 8b. THE CALLER CONTRACT. A caller that asserts host-side but never exported
#     the token is a CALL SITE BUG, not a substrate limit, and gets its own exit
#     code so a promoting consumer cannot write it off as "this host cannot
#     answer". This is the arm that caught the impossible first version of the
#     contract: it demanded the caller's own pid carry the token, which a
#     runtime export never puts there.
r="$(newroot tokenless)"
printf 'PATH=/x\0' > "$r/self/environ"   # readable, no token
out="$(run_check "$r")"; rc=$?
check "host-side asserted but no token exported is a caller bug (2)" 2 "refused:competing-gate:caller-contract" "$rc" "$out"

# 8c. BLIND: our own environ unreadable. On a substrate with no readable environ
#     at all — MSYS/Cygwin exposes cmdline and status and winpid but no environ;
#     darwin has no /proc — the check must refuse rather than report a clean
#     tree. Constructed so that NEITHER a dangling symlink nor absence is
#     assumed: the precondition is asserted below.
r="$(newroot blindself)"
rm -f "$r/self/environ"
ln -s /nonexistent-so-there-is-nothing-to-read "$r/self/environ" 2>/dev/null || true
if [ -r "$r/self/environ" ]; then
    fail=$((fail+1))
    echo "FAIL: could not construct an unreadable self environ on this substrate — this arm would have asserted nothing"
else
    out="$(run_check "$r")"; rc=$?
    check "an unreadable own-environ is blind (3), never a clean tree" 3 "could-not-run:competing-gate:blind" "$rc" "$out"
fi

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
ln -s /nonexistent-so-there-is-nothing-to-read "$r/103/environ" 2>/dev/null || true
# PROVE THE INJECTED FAILURE ACTUALLY OCCURRED — the rule this arm's own
# history produced, applied to the SETUP rather than only to the assertion.
#
# The arm needs one property: that environ cannot be read. A dangling symlink
# gives it, and so does an absent file; which of the two a substrate allows is
# not the subject. But the arm must not proceed on the ASSUMPTION that either
# worked. Measured by yolanda on WSL: `ln` failed with "No such file or
# directory", the arm passed anyway on the absent file, and the suite printed
# PASS — an arm passing for a reason other than the one it names, which is
# exactly the defect this arm was rewritten to remove one commit earlier.
# `ln`'s stderr went to the log and nothing read it.
#
# So assert the precondition. If NEITHER construction denies the read on this
# substrate, the arm asserts nothing and must say so rather than pass.
if [ -r "$r/103/environ" ]; then
    fail=$((fail+1))
    echo "FAIL: could not construct an unreadable environ on this substrate — neither a dangling symlink nor an absent file denied the read, so this arm would have asserted nothing"
else
    out="$(run_check "$r")"; rc=$?
    check "an unreadable process suspends the accusation" 3 "could-not-run:competing-gate:unreadable-processes" "$rc" "$out"
fi

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then echo "PASS: competing-gate detector $pass/$total (1141-vf9w)"; exit 0; fi
echo "FAIL: competing-gate detector $pass/$total (1141-vf9w)"; exit 1
