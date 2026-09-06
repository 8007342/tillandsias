#!/usr/bin/env bash
# @trace order:1049-s35z
#
# check-jq-multiline-capture-strips-cr.sh — a jq capture that can yield MORE
# THAN ONE LINE must strip carriage returns.
#
# WHY ONLY MULTI-LINE, measured on yolanda 2026-09-05 with `od -c` on the value
# rather than grep, because MSYS grep treats CR as part of the line ending and
# hides it:
#
#   v="$(echo '{"a":"x"}' | jq -r .a)"          -> len 1, no CR. SAFE.
#   while read l; do ...; done < <(jq -r '.a[]') -> "one" arrives len 4: o n e \r
#
# jq.exe writes CRLF, and command substitution strips the trailing line ending
# including the CR — so ONLY THE FINAL LINE loses it and every preceding line
# keeps it. Exposure is therefore a property of whether a capture can yield
# multiple lines, NOT of using jq. That is why the litmus runner broke while
# 62 sibling call sites were fine, and why the original packet's "26 scripts,
# all exposed" was wrong by more than an order of magnitude.
#
# `| head -1` IS A GUARD, and I had this backwards until the fixture refuted
# me. The reasoning that it selects the FIRST line — the one that keeps its CR —
# is true about the LINE and wrong about the VALUE: head reduces the stream to
# ONE line before capture, and command substitution then strips that line's
# ending, CR included. Measured: `jq -r '.a[]' | head -1` captures len 3, not 4.
# So a pipeline that reduces before capture is exempt, and two sites in
# bench-inference-floor.sh that I had "fixed" needed no fix at all.
#
# WHAT COUNTS AS MULTI-LINE-CAPABLE: a filter containing `[]` iteration, or a
# top-level comma. A filter that reduces to one line by construction — it ends
# in `| max`, `| join(...)`, `| add`, `| length`, `| first`, or is reduced by a
# following `| head`/`| tail`, or wraps the whole thing in `[...]` without
# re-iterating — is single-line and exempt.
#
# GRAMMAR — exactly one line:
#   ok:jq-multiline-capture-strips-cr:<n> multi-line site(s), all stripped
#   violation:jq-multiline-capture-unstripped:<n> site(s)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

SCAN_DIR="${1:-scripts}"

violations=""
multiline=0

while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    file="${hit%%:*}"
    rest="${hit#*:}"
    line="${rest%%:*}"
    text="${rest#*:}"

    # Skip our own prose and this checker.
    case "$file" in
        */check-jq-multiline-capture-strips-cr.sh|*/test-jq-multiline-capture.sh) continue ;;
    esac
    # A comment is not a call site.
    case "$(printf '%s' "$text" | sed 's/[^#]*#//')" in
        "$text") ;;
    esac
    trimmed="$(printf '%s' "$text" | sed 's/^[[:space:]]*//')"
    case "$trimmed" in \#*) continue ;; esac

    # Reducers collapse to a single line, so the CR lands only on that line and
    # command substitution removes it.
    case "$text" in
        *"| max"*|*"| join("*|*"| add"*|*"| length"*|*"| first"*|*"| any"*|*"| all"*) continue ;;
        *"| head "*|*"| head -"*|*"| tail "*|*"| tail -"*) continue ;;
    esac

    multiline=$((multiline + 1))
    case "$text" in
        *"tr -d"*) ;;   # stripped
        *) violations="${violations}${file}:${line}: multi-line jq capture with no CR strip"$'\n' ;;
    esac
done < <(grep -rnE "jq -r[^|]*\[\]" "$SCAN_DIR" --include=*.sh 2>/dev/null)

if [ -n "$violations" ]; then
    n="$(printf '%s' "$violations" | grep -c .)"
    echo "violation:jq-multiline-capture-unstripped:$n site(s)"
    printf '%s' "$violations" | sed 's/^/  /' >&2
    {
        echo "  jq.exe writes CRLF. Command substitution strips only the FINAL"
        echo "  line ending, so every line but the last arrives with a trailing"
        echo "  carriage return. A value compared, indexed, or used to build a"
        echo "  path is then silently wrong on Windows — and MSYS grep will not"
        echo "  show you the CR, only od -c will."
        echo "  Fix: pipe the jq output through \`tr -d '\\r'\`."
        echo "  Note a pipeline that reduces to ONE line before capture is safe:"
        echo "  \`| head -1\`, \`| max\`, \`| join(...)\` all leave a single line,"
        echo "  whose ending command substitution strips, CR included (1049-s35z)."
    } >&2
    exit 1
fi

echo "ok:jq-multiline-capture-strips-cr:$multiline multi-line site(s), all stripped"
