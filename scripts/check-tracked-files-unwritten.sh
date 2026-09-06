#!/usr/bin/env bash
# @trace order:1063-363b
#
# The gate must not write into the checkout it is measuring.
#
# WHAT HAPPENED. On lenovinha 2026-09-05T01:35:03Z, during the 1036-e5w9 gates
# and litmus, scripts/plan-binary-probe.sh in the WORKING TREE was overwritten
# with the contents of scripts/check-fragment-status-loss.sh. Trunk was intact
# and no commit touched the path, so something in the run escaped its temp dir
# and landed on a tracked file.
#
# WHY IT OUTRANKS AN ORDINARY BUG. plan-binary-probe.sh is an INSTRUMENT: half
# the gate resolves the plan binary through it. Corrupt it mid-run and every
# later step measures something else, and reports confidently. The damage is not
# the overwritten file, it is every verdict taken after it — which is exactly
# the class this fleet has spent the night on, arriving through the filesystem
# instead of through a wrong predicate.
#
# THIS DOES NOT NAME THE WRITER, and I could not find it. Probed on yoga:
# a pristine clone, the instant pre-build litmus corpus (full run to verdict),
# then ./build.sh --check on the working checkout, each with a sha256 baseline
# over all 5,502 tracked files. NOTHING diverged in either half, and no
# untracked leftovers. So the writer is not reproducible from this host with
# this corpus — it may be host-specific, order-specific, or in a phase yoga does
# not run. A guard that detects the class is worth more than a hunt that found
# nothing: this makes the next occurrence name itself on whichever host it
# happens, instead of being noticed hours later by someone reading a diff.
#
# CONTENT, NOT `git status`. A modify-then-restore leaves git clean while every
# measurement taken in between was against different bytes. sha256 over the
# tracked set costs 61ms here against a 254s gate — 0.05% — so there is no
# reason to take the weaker signal.
#
# Usage:
#   scripts/check-tracked-files-unwritten.sh snapshot <state-file>
#   scripts/check-tracked-files-unwritten.sh verify   <state-file>
#
# Grammar (one line on stdout):
#   ok:tracked-files-unwritten:<n> files
#   violation:gate-wrote-tracked-files:<n>
#   blocked:tracked-files-unwritten:<reason>
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

mode="${1:-}"
state="${2:-}"
[ -n "$mode" ] && [ -n "$state" ] || { echo "blocked:tracked-files-unwritten:usage"; exit 2; }

_hash_tracked() {
    # NUL-delimited: a path with a space or a newline must not split, and this
    # runs over the whole tracked set where one such path is enough to corrupt
    # the comparison silently.
    git ls-files -z | xargs -0 -r sha256sum 2>/dev/null | LC_ALL=C sort
}

case "$mode" in
    snapshot)
        if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            echo "blocked:tracked-files-unwritten:not-a-git-repo"
            exit 2
        fi
        # NOT `cmd || fail`: this is a pipeline under `pipefail`, and xargs
        # returns non-zero for reasons that are not a failed snapshot (a file
        # vanishing mid-walk, for one). Judge the ARTEFACT — did we get a
        # plausible list — rather than the exit status of a three-stage pipe.
        # The first draft failed here while writing a perfectly good baseline.
        _hash_tracked > "$state" 2>/dev/null
        _n="$(grep -c . "$state" 2>/dev/null || echo 0)"
        if [ "${_n:-0}" -lt 1 ]; then
            echo "blocked:tracked-files-unwritten:snapshot-empty"
            exit 2
        fi
        echo "ok:tracked-files-unwritten:${_n} files"
        ;;
    verify)
        if [ ! -s "$state" ]; then
            # A missing baseline must not read as a clean tree — that is the
            # fail-open shape this file exists to refuse.
            echo "blocked:tracked-files-unwritten:no-snapshot-at:$state"
            exit 2
        fi
        now="$(mktemp)" || { echo "blocked:tracked-files-unwritten:mktemp-failed"; exit 2; }
        trap 'rm -f "$now"' EXIT
        _hash_tracked > "$now"
        # SAME PATH, DIFFERENT HASH. Keyed by path in awk rather than joined on
        # whitespace: sha256sum emits "<hash>  <path>", and a path may contain
        # spaces. A join/cut approach silently mangles those, and a comparison
        # that drops the awkward paths is exactly the kind of near-miss this
        # guard exists to catch.
        changed="$(awk '
            { h = substr($0, 1, 64); p = substr($0, 67) }
            FNR == NR { before[p] = h; next }
            (p in before) && before[p] != h { print p }
        ' "$state" "$now")"
        n="$(printf '%s' "$changed" | grep -c . || true)"
        if [ "${n:-0}" -gt 0 ]; then
            echo "violation:gate-wrote-tracked-files:$n"
            {
                echo "  The gate modified files in the checkout it was measuring."
                echo "  Every verdict taken after the write measured different bytes"
                echo "  than the tree under test (1063-363b)."
                printf '%s\n' "$changed" | head -20 | sed 's/^/    /'
                echo "  Restore with: git checkout --"
                echo "  Then find the writer: it is a fixture or gate step that"
                echo "  escaped its temp dir. Check three-argument cp, a \$TMPDIR"
                echo "  that was empty so a relative path resolved into the repo,"
                echo "  and any 'cp \$src \$dst' where \$dst was unset."
            } >&2
            exit 1
        fi
        echo "ok:tracked-files-unwritten:$(grep -c . "$now" || echo 0) files"
        ;;
    *)
        echo "blocked:tracked-files-unwritten:unknown-mode:$mode"
        exit 2
        ;;
esac
