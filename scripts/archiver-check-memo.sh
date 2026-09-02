#!/usr/bin/env bash
# ORDER 911-m7js. The plan-archiver ready-set check (831-ezea) is LEDGER-BOUND:
# it copies plan/, archives every completed packet into the copy, diffs the
# ready set, and grades archived rows for answerability — 16-20s on a fast
# host and 105s on a slow one, on EVERY gate, and proportional to the ledger.
# Measured 2026-09-02 (macuahuitl): 16.7-19.6s with 211 fragments over ~620
# packets, 6.8s after a sweep + compaction. Nothing about the check depends on
# anything but the ledger and the tool that reads it, so its verdict can be
# memoised on exactly those inputs.
#
# This is a MEMO, not a skip: a miss runs the check; a hit repeats a verdict
# the same bytes earned. The digest covers the ledger (base, archive, live
# fragments), the archiver and its checker, and the plan binary's identity —
# a change to any of them is a miss. The gate memo (765-tkq2) cannot carry
# this: plan/ changes every cycle by construction, so a tree-level memo never
# hits during a drain, while the ledger itself is unchanged across most gates.
#
# Usage:
#   scripts/archiver-check-memo.sh digest          -> prints the digest
#   scripts/archiver-check-memo.sh check           -> ok:archiver-check-memoized:<d8> (exit 0) | miss:<reason> (exit 1)
#   scripts/archiver-check-memo.sh record          -> writes the memo for the current digest
#   TILLANDSIAS_ARCHIVER_MEMO=<path> overrides the memo file (fixtures).
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "miss:not-a-git-repo"; exit 1; }
GIT_DIR="$(git rev-parse --absolute-git-dir 2>/dev/null)" || { echo "miss:no-git-dir"; exit 1; }
MEMO="${TILLANDSIAS_ARCHIVER_MEMO:-$GIT_DIR/tillandsias-archiver-check.memo}"
cd "$ROOT" || exit 1
. scripts/plan-binary-probe.sh
if command -v sha256sum >/dev/null 2>&1; then SHA=(sha256sum); else SHA=(shasum -a 256); fi

_digest() {
    {
        # Ledger inputs, by name and content. `cat` over a sorted list so the
        # digest is stable across shells; a missing archive dir is fine.
        for f in plan/index.yaml plan/archive/*.yaml plan/index.d/*.yaml; do
            [ -f "$f" ] || continue
            printf '%s\n' "$f"; "${SHA[@]}" < "$f"
        done
        # The instrument: a changed checker must re-run.
        for f in scripts/archive-plan-packets.sh scripts/archive-plan-packets.rb scripts/check-archive-answerability.sh; do
            [ -f "$f" ] && { printf '%s\n' "$f"; "${SHA[@]}" < "$f"; }
        done
        # The plan binary's identity — resolved through the sanctioned probe
        # (746-htj9: never a hardcoded target/ path), by size+mtime: a rebuild
        # changes both, and hashing a 30 MB binary on every gate would cost
        # what this memo saves.
        local _plan_bin
        if _plan_bin="$(resolve_plan_binary 2>/dev/null)" && [ -n "$_plan_bin" ] && [ -e "$_plan_bin" ]; then
            printf '%s\n' "$_plan_bin"
            stat -c '%s %Y' "$_plan_bin" 2>/dev/null || stat -f '%z %m' "$_plan_bin" 2>/dev/null
        fi
    } | "${SHA[@]}" | cut -d' ' -f1
}

case "${1:-}" in
    digest) _digest ;;
    check)
        d="$(_digest)"
        if [ -r "$MEMO" ] && [ "$(tr -d '[:space:]' < "$MEMO")" = "$d" ]; then
            echo "ok:archiver-check-memoized:${d:0:8}"; exit 0
        fi
        [ -r "$MEMO" ] && echo "miss:ledger-or-instrument-changed" || echo "miss:no-memo"
        exit 1 ;;
    record) _digest > "$MEMO" && echo "ok:archiver-check-memo-recorded:$(cut -c1-8 < "$MEMO")" ;;
    *) echo "usage: $0 digest|check|record" >&2; exit 2 ;;
esac
