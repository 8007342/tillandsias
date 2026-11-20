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
#   scripts/archiver-check-memo.sh record          -> adds the current digest to the memo set
#   TILLANDSIAS_ARCHIVER_MEMO=<path> overrides the memo file (fixtures).
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "miss:not-a-git-repo"; exit 1; }
# ORDER 2118-tnut (operator 2026-11-20, landing-pipeline P10 item d): the memo
# lives in the COMMON git dir, shared by every worktree of this clone, and
# holds a SET of verified digests rather than one. It used to live in the
# per-worktree git dir with a single digest, so every fresh gate worktree
# missed by construction: 31 hits in 424 runs on lenovinha, one miss 316 s
# under load. A digest is CONTENT only (ledger bytes, instrument bytes, plan
# binary bytes), so one worktree vouches for another only when every input is
# byte-identical — never for a different tree that happens to share a path.
GIT_COMMON="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || { echo "miss:no-git-dir"; exit 1; }
MEMO="${TILLANDSIAS_ARCHIVER_MEMO:-$GIT_COMMON/tillandsias-archiver-check.memo}"
MEMO_KEEP=64   # digests kept; the oldest drop first
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
        # 964-9yyp adds native-scratch-dir.sh: it decides WHERE the check's
        # tree churn happens, so a change to it is a change to the instrument
        # even though it cannot change the verdict.
        # ORDER 560 adds the Lua worker, now the default sweep, and the backend
        # selector: a green recorded with one worker says nothing about the other.
        for f in scripts/archive-plan-packets.sh scripts/archive-plan-packets.lua scripts/archive-plan-packets.rb scripts/check-archive-answerability.sh scripts/native-scratch-dir.sh; do
            [ -f "$f" ] && { printf '%s\n' "$f"; "${SHA[@]}" < "$f"; }
        done
        printf 'archiver-backend:%s\n' "${TILLANDSIAS_ARCHIVER_BACKEND:-default}"
        # The plan binary's identity, resolved through the sanctioned probe
        # (746-htj9: never a hardcoded target/ path), by CONTENT (2118-tnut).
        # It used to be path + size + mtime, which made two worktrees' identical
        # builds look different and a same-path rebuild with a copied mtime look
        # the same. Hashing it costs milliseconds against a check of seconds.
        local _plan_bin
        if _plan_bin="$(resolve_plan_binary 2>/dev/null)" && [ -n "$_plan_bin" ] && [ -e "$_plan_bin" ]; then
            printf 'plan-binary:'; "${SHA[@]}" < "$_plan_bin"
        else
            printf 'plan-binary:none\n'
        fi
    } | "${SHA[@]}" | cut -d' ' -f1
}

case "${1:-}" in
    digest) _digest ;;
    check)
        d="$(_digest)"
        if [ -r "$MEMO" ] && grep -qxF -- "$d" "$MEMO"; then
            echo "ok:archiver-check-memoized:${d:0:8}"; exit 0
        fi
        [ -r "$MEMO" ] && echo "miss:ledger-or-instrument-changed" || echo "miss:no-memo"
        exit 1 ;;
    record)
        d="$(_digest)"
        tmp="$MEMO.tmp.$$"
        { [ -r "$MEMO" ] && grep -vxF -- "$d" "$MEMO"; printf '%s\n' "$d"; } | tail -n "$MEMO_KEEP" > "$tmp" \
            && mv -f "$tmp" "$MEMO" && echo "ok:archiver-check-memo-recorded:${d:0:8}" ;;
    *) echo "usage: $0 digest|check|record" >&2; exit 2 ;;
esac
