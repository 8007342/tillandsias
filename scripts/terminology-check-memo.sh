#!/usr/bin/env bash
# ORDER 1054-zvq4. The user-visible terminology check (629-t6bx,
# scripts/check-terminology.sh) is LOCALE-BOUND: it parses
# locales/terminology.toml and then scans the VALUES of every other
# locales/*.toml against every dictionary variant — a nested loop over terms x
# strings x files, on EVERY gate. It has never failed on any host.
#
# Measured in the 2026-09-05 cross-host recurrence audit (order 1001-q3zf),
# window=7d, floor_ms=2000, min_runs=5, where the SAME step tops or co-tops
# the skippable list on three hosts with three different regimes:
#   yoga       (silverblue, host-native): runs=150 avg_ms=14275 fail_pct=0
#   lenovinha  (silverblue, toolbox gate): runs=230 avg_ms=33414 fail_pct=0
#   macbookair (macOS, M5):                runs=122 avg_ms=29803 fail_pct=0
# and 25.4s measured on pirria (floor, 4 cores, toolbox gate) while writing
# this. The threefold spread across hosts is why each number carries its
# regime; the step's cost is not a property of the check alone.
#
# Nothing about the check depends on anything but the dictionary, the locale
# files it scans, and the checker itself, so its verdict can be memoised on
# exactly those inputs.
#
# THIS IS A MEMO, NOT A SKIP: a miss RUNS the check; a hit repeats a verdict
# the same bytes earned. Any change to the dictionary, to any scanned locale
# file, or to the checker is a miss. That is the whole safety argument, and it
# is why the digest must name its inputs rather than hash a directory listing:
# a reader has to be able to check that the key covers everything the verdict
# depends on.
#
# WHY THE GATE MEMO (765-tkq2) CANNOT CARRY THIS: that one keys on the whole
# tree, so it never hits during a drain — every cycle writes plan/. The locale
# files, by contrast, are unchanged across nearly every gate, which is exactly
# the condition a narrow memo needs. Same argument the archiver memo (911-m7js)
# makes for the ledger; this file follows its shape deliberately.
#
# THE ENV OVERRIDES ARE PART OF THE KEY, not decoration. check-terminology.sh
# honours TILLANDSIAS_TERMINOLOGY_DICT and TILLANDSIAS_LOCALE_DIR, so a memo
# that ignored them would return a hit earned by a DIFFERENT dictionary or a
# different locale tree. The digest therefore resolves the same two paths the
# checker resolves, from the same variables.
#
# Usage:
#   scripts/terminology-check-memo.sh digest   -> prints the digest
#   scripts/terminology-check-memo.sh check    -> ok:terminology-check-memoized:<d8> (exit 0) | miss:<reason> (exit 1)
#   scripts/terminology-check-memo.sh record   -> writes the memo for the current digest
#   TILLANDSIAS_TERMINOLOGY_MEMO=<path> overrides the memo file (fixtures).
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "miss:not-a-git-repo"; exit 1; }
GIT_DIR="$(git rev-parse --absolute-git-dir 2>/dev/null)" || { echo "miss:no-git-dir"; exit 1; }
MEMO="${TILLANDSIAS_TERMINOLOGY_MEMO:-$GIT_DIR/tillandsias-terminology-check.memo}"
cd "$ROOT" || exit 1
if command -v sha256sum >/dev/null 2>&1; then SHA=(sha256sum); else SHA=(shasum -a 256); fi

# Resolved EXACTLY as scripts/check-terminology.sh resolves them.
DICT="${TILLANDSIAS_TERMINOLOGY_DICT:-$ROOT/locales/terminology.toml}"
LOCALE_DIR="${TILLANDSIAS_LOCALE_DIR:-$ROOT/locales}"

_digest() {
    {
        # The dictionary: its content decides every comparison.
        [ -f "$DICT" ] && { printf 'dict:%s\n' "$DICT"; "${SHA[@]}" < "$DICT"; }
        # The scanned corpus: every locale file except the dictionary itself,
        # by name and content, in sorted order so the digest is stable across
        # shells and glob expansions. A file APPEARING or DISAPPEARING changes
        # the digest through its name, which a content-only hash would miss.
        for f in "$LOCALE_DIR"/*.toml; do
            [ -f "$f" ] || continue
            case "$(basename "$f")" in terminology.toml) continue ;; esac
            printf 'scan:%s\n' "$f"; "${SHA[@]}" < "$f"
        done
        # The instrument: a changed checker must re-run even on unchanged input.
        for f in scripts/check-terminology.sh; do
            [ -f "$f" ] && { printf 'tool:%s\n' "$f"; "${SHA[@]}" < "$f"; }
        done
    } | LC_ALL=C sort | "${SHA[@]}" | cut -d' ' -f1
}

case "${1:-}" in
    digest) _digest ;;
    check)
        d="$(_digest)"
        if [ -r "$MEMO" ] && [ "$(tr -d '[:space:]' < "$MEMO")" = "$d" ]; then
            echo "ok:terminology-check-memoized:${d:0:8}"; exit 0
        fi
        [ -r "$MEMO" ] && echo "miss:dictionary-locales-or-instrument-changed" || echo "miss:no-memo"
        exit 1 ;;
    record) _digest > "$MEMO" && echo "ok:terminology-check-memo-recorded:$(cut -c1-8 < "$MEMO")" ;;
    *) echo "usage: $0 digest|check|record" >&2; exit 2 ;;
esac
