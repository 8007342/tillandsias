#!/usr/bin/env bash
# ORDER 1924-dobj. Prune loose object files that no linked binary can use.
#
# darwin builds with split-debuginfo=unpacked. A linked binary's debug map
# (its OSO stabs) points at two things: the loose <crate>-<hash>.*.rcgu.o of
# its OWN crate-hash, and rlib members for every dependency (measured with
# nm -ap on a test binary, 2026-10-29). So a loose .o group is only ever
# read when an executable named exactly <crate>-<hash> sits beside it. Every
# other group is a library's objects whose code already lives in its rlib,
# and cargo never collects them: they reached 1.2M files and stalled every
# CoreFoundation test process 3-16 s.
#
# Usage: prune-darwin-stale-objects.sh <target>/debug/deps
# Prints one line: pruned:darwin-stale-objects:files=N groups=M kept=K
# Run it before cargo, never beside a running build of the same target:
# a library mid-compile has loose objects and no rlib yet.
set -euo pipefail

deps="${1:?usage: prune-darwin-stale-objects.sh <deps-dir>}"
[[ -d "$deps" ]] || { echo "pruned:darwin-stale-objects:files=0 groups=0 kept=0 (no $deps)"; exit 0; }

# Fleet hosts share one target dir across worktrees, so another build.sh may
# be compiling into it right now; a library mid-compile has loose objects and
# no rlib yet. Every build.sh holds a SHARED lock on this file while it runs
# cargo; the prune takes it EXCLUSIVE and non-blocking, and skips if any
# build holds it. darwin has no flock(1), so perl's flock() locks the fd this
# shell keeps open (a BSD lock lives on the open file, not the process).
lock="$deps/../../.tillandsias-prune.lock"
exec 8>>"$lock"
lock_rc=0
perl -MFcntl=:flock -e 'open(my $fh, ">>&=", 8) or exit 2; flock($fh, LOCK_EX | LOCK_NB) or exit 1' || lock_rc=$?
if (( lock_rc != 0 )); then
    echo "skipped:darwin-stale-objects:a build holds $lock (shared); pruning next time"
    exit 0
fi

# One listing, one awk pass: names with no dot that end in a 16-hex hash are
# the executables; a .rcgu.o whose prefix is not one of them is stale.
list="$(ls -f "$deps")"
stale="$(awk -v dir="$deps" '
    /^[A-Za-z0-9_]+-[0-9a-f]{16}$/ { exe[$0] = 1; next }
    /\.rcgu\.o$/ { split($0, p, "."); obj[NR] = $0; grp[NR] = p[1]; next }
    END {
        for (i in obj) {
            if (grp[i] in exe) { kept[grp[i]] = 1; continue }
            print dir "/" obj[i]
            gone[grp[i]] = 1
        }
        ng = 0; for (g in gone) ng++
        nk = 0; for (g in kept) nk++
        print "#groups " ng " " nk > "/dev/stderr"
    }' <<<"$list" 2>"$deps/.prune-counts")"
read -r _ groups kept <"$deps/.prune-counts"
rm -f "$deps/.prune-counts"

files=0
if [[ -n "$stale" ]]; then
    files="$(printf '%s\n' "$stale" | wc -l | tr -d ' ')"
    printf '%s\n' "$stale" | tr '\n' '\0' | xargs -0 rm -f
fi
echo "pruned:darwin-stale-objects:files=$files groups=$groups kept=$kept"
