#!/usr/bin/env bash
# @trace order:1251-54p3
#
# check-seam-writers-canonical.sh — ORDER 1251-54p3.
#
# Assert that every file which WRITES a process-global "seam" env var also
# references the CANONICAL lock that serialises writers of it.
#
# WHY THIS GATE EXISTS. TILLANDSIAS_PODMAN_BIN is one process-global string and
# three test modules wrote it -- main.rs's fake-podman fixtures, accel_probe
# (/bin/false) and remote_projects (a mock) -- each guarding it with a mutex OF
# ITS OWN. Two independent mutexes serialise nothing, so a module holding what
# it believed was "the" seam lock could still have the var changed underneath it
# by another module holding a different lock.
#
# The invariant in main.rs read "EVERY writer of TILLANDSIAS_PODMAN_BIN in this
# tests mod serializes on THIS mutex". It was TRUE AS WRITTEN and it did not
# cover the crate. THE SCOPE OF THE GUARANTEE WAS THE GAP, NOT ITS WORDING --
# and note that the comment's PRECISION is what made the defect findable at all;
# a vaguer comment would have concealed the same bug while offering nothing to
# check. What was missing is a prompt to RE-READ the scope when a second writer
# appears, which is a judgement no comment performs. This script is that prompt,
# made mechanical.
#
# It is not hypothetical. Run against e1256ec24^ this check names accel_probe.rs
# -- the actual culprit -- before a single test executes. That defect cost two
# full ~70-minute gates and a night of diagnosis across two hosts, and presented
# as a test that passed 3/3 in isolation, failed 3/3 in the full suite on a
# 16-core host, and was NOT REPRODUCIBLE AT ALL on a 20-core host.
#
# KNOWN LIMITATION -- READ THIS BEFORE TRUSTING A GREEN.
# This check is FILE-GRANULAR, NOT FUNCTION-GRANULAR. A file that references the
# canonical lock in one test and writes the seam var WITHOUT it in a DIFFERENT
# test passes. Do not read ok: as "every writer in this file is serialised"; it
# means "this file knows the canonical lock exists". The cross-MODULE case is
# the one that actually bit us, and a new writer almost always arrives as a new
# file, which is why the file-granular form is worth having now. A later
# INTRA-FILE instance is evidence for building the function-granular version
# (which needs real parsing, not grep) -- it is not a failure of this guard.
#
# Comments are STRIPPED before matching, so a canonical-lock name appearing only
# in a doc comment does NOT satisfy the check. The fixture's ARM 3b pins that.
#
# Verdicts, one line on stdout:
#   ok:seam-writers-canonical:<n>            every writing file references it
#   refused:seam-writer-uncanonical:<file>   a writer that does not
#   refused:seam-var-has-no-writers:<var>    POSITIVE CONTROL: the var has no
#                                            writers at all, so a green would be
#                                            vacuous. A check that passes when
#                                            its target disappears is the shape
#                                            that rots silently -- 1248-j6vd's
#                                            currency check reported `current`
#                                            for a month that way.
#
# Usage:
#   ./scripts/check-seam-writers-canonical.sh [crate-src-dir] [VAR] [lock-symbol]
# Defaults target the podman seam. The parameters exist so a second seam var can
# be adopted without a second copy of this logic.
set -u

CRATE="${1:-crates/tillandsias-headless/src}"
VAR="${2:-TILLANDSIAS_PODMAN_BIN}"
CANON="${3:-podman_seam_lock}"

writers=$(grep -rln --include=*.rs -E "(set_var|remove_var)\(\"$VAR\"" "$CRATE" 2>/dev/null \
  | while read -r f; do
      # Strip // comments before confirming: a doc comment naming the var is
      # not a writer of it.
      # CAPTURE THEN MATCH (795-imz3). `producer | grep -q` lets grep exit on
      # the first hit, SIGPIPE the producer, and under `set -o pipefail` report
      # FAILURE ON A MATCH — which inverts the test. This script sets only
      # `set -u` today, so the pipeline form worked by the ABSENCE of pipefail;
      # adding it later, or sourcing this from a caller that has it, would have
      # silently made every writer invisible. Counting into a variable first
      # removes the dependency on that ambient option entirely.
      _hits="$(sed 's://.*::' "$f" | grep -cE "(set_var|remove_var)\(\"$VAR\"" || true)"
      [ "${_hits:-0}" -gt 0 ] && echo "$f"
    done)

if [ -z "$writers" ]; then
    echo "refused:seam-var-has-no-writers:$VAR"
    exit 1
fi

rc=0
n=0
for f in $writers; do
    n=$((n + 1))
    # Same capture-then-match as above, and here the inversion would be worse:
    # under pipefail a file that DOES reference the canonical lock would report
    # failure on the match and be refused as uncanonical — the guard accusing
    # exactly the files that are correct.
    _canon="$(sed 's://.*::' "$f" | grep -c "$CANON" || true)"
    if [ "${_canon:-0}" -eq 0 ]; then
        echo "refused:seam-writer-uncanonical:$f"
        rc=1
    fi
done

[ "$rc" -eq 0 ] && echo "ok:seam-writers-canonical:$n"
exit "$rc"
