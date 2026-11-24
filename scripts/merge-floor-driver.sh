#!/usr/bin/env bash
# @trace order:2118-asur
# The git side of merge driver `tillandsias-floor` (scripts/ensure-hooks.sh sets
# it): runs scripts/lua/merge-floor-min.lua. When that cannot run, falls back to
# git merge-file. A driver that merely exits non-zero leaves OURS in the file
# with no conflict markers, which a hurried `git add` takes as resolved.
# Usage: merge-floor-driver.sh %O %A %B %P %X %Y
set -u
tmp="$2.floor-in"
cp -- "$2" "$tmp" || exit 2
P="$(. scripts/plan-binary-probe.sh 2>/dev/null && resolve_plan_binary 2>/dev/null)" || P=""
rc=99
if [ -n "$P" ]; then
    out="$(TILLANDSIAS_MERGE_OURS="${5:-}" TILLANDSIAS_MERGE_THEIRS="${6:-}" \
        "$P" script run scripts/lua/merge-floor-min.lua -- "$1" "$2" "$3" "$4")"; rc=$?
fi
case "$rc:${out:-}" in
    0:ok:merge-floor:*) rm -f -- "$tmp"; exit 0 ;;
    1:violation:merge-floor:conflict:*) rm -f -- "$tmp"; exit 1 ;;
esac
echo "note:merge-floor:driver-did-not-run:$4 — git's textual merge instead" >&2
cp -- "$tmp" "$2" && rm -f -- "$tmp"
git merge-file "$2" "$1" "$3" && exit 0
exit 1
