#!/usr/bin/env bash
# @trace spec:ci-release
#
# check-unrunnable-platform-arms.sh — name the gate arms this change touches
# that THIS HOST'S GATE CANNOT RUN, because they are scoped to another platform.
#
# Order 1194-davi. ADVISORY: it exits 0 on every finding. Only a broken
# checkout (exit 2) is an error.
#
# ── WHY IT EXISTS, with the measurement ─────────────────────────────────────
#
# b3a93780b (order 1189-2ra5) wrapped `gh auth status` in a timeout. The
# `timeout` prover row in check-host-tools.sh is scoped `macos`, so that arm
# runs ONLY on macOS. The change went green through a full ./build.sh --check
# on Linux, landed, and took BOTH macOS hosts' ability to land with it for a
# day. macbookair bisected it in pristine worktrees:
#     b3a93780b^  rc=0, zero FAIL lines
#     b3a93780b   rc=1, host-tools 1/24 red (989-ykks)
# Every Linux and Windows land since was green and correct and would have
# stayed green forever. THERE WAS NO SIGNAL ON THE AUTHORING SIDE AT ALL.
#
# THE SCOPING IS CORRECT AND THIS FILE DOES NOT TOUCH IT. A Linux host
# genuinely cannot prove macOS's `timeout` story, and widening the arm would
# hand it an inventory it cannot derive. The remedy is that the author is TOLD.
#
# ── WHAT THIS CAN AND CANNOT CHECK ──────────────────────────────────────────
#
# CHECKED: a changed path that a prover row NAMES in its `<prover>` field,
# where that row's `<platforms>` field excludes this host.
#
# NOT CHECKED, and this is the honest limit: the inventory is exactly as
# complete as the rows' own `<prover>` column. MEASURED on linux at the time of
# writing — 13 rows, 8 skipped here, and of those 8 exactly ONE names a prover
# (`timeout` -> check-credential-channel.sh, which is precisely the file that
# cost both macOS hosts a day). The other 7 carry `-`, meaning "no cheap prover
# exists"; any file association for them lives in prose in the `why` field and
# is NOT a queryable column.
#
# So a SILENT run is not evidence that a change is safe across platforms. It is
# evidence that no path in this change is named by a prover row scoped away
# from here. Backfilling `<prover>` on rows that have one is a different packet;
# do not read this advisory's silence as coverage it does not have.
#
# DERIVED FROM THE ROWS THEMSELVES (1194-davi's second exit criterion), by
# parsing `required_tools()`'s spec heredoc in check-host-tools.sh. There is no
# second list here to drift out of step with that one. If the heredoc's field
# order changes, this script reports `fail:` rather than guessing.
#
# ── VERDICT GRAMMAR (closed) ────────────────────────────────────────────────
#   ^(ok:unrunnable-platform-arms:0 of [0-9]+ changed paths
#    |advisory:unrunnable-platform-arms:[0-9]+ of [0-9]+ changed paths
#    |skipped:unrunnable-platform-arms:(no-spec-source|no-diff-base|no-rows)
#    |fail:unrunnable-platform-arms:(unparsable-spec|unknown-platform))$
#
# `skipped:` is its own word: a pass that never ran must never report `ok`
# (785-sqe6, 787-f7dh). Every verdict names its denominator, so none can be
# misread as health over an empty set.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

SPEC_SOURCE="scripts/check-host-tools.sh"
PLATFORM=""
BASE_REF="${TILLANDSIAS_UNRUNNABLE_BASE:-origin/linux-next}"

while [ $# -gt 0 ]; do
    case "$1" in
        --platform) PLATFORM="${2:-}"; shift 2 ;;
        --base) BASE_REF="${2:-}"; shift 2 ;;
        --spec-source) SPEC_SOURCE="${2:-}"; shift 2 ;;
        *) shift ;;
    esac
done

if [ -z "$PLATFORM" ]; then
    case "$(uname -s 2>/dev/null)" in
        Darwin) PLATFORM=macos ;;
        Linux) PLATFORM=linux ;;
        MINGW*|MSYS*|CYGWIN*) PLATFORM=windows ;;
        *) echo "fail:unrunnable-platform-arms:unknown-platform"
           echo "  uname -s did not resolve to macos/linux/windows; the inventory cannot be scoped" >&2
           exit 0 ;;
    esac
fi

if [ ! -f "$SPEC_SOURCE" ]; then
    echo "skipped:unrunnable-platform-arms:no-spec-source"
    echo "  note: $SPEC_SOURCE absent — the prover-row inventory has no source, so nothing was examined" >&2
    exit 0
fi

# Parse the spec heredoc. Field order is documented above the heredoc in the
# source as <tool>|<kind>|<scope>|<platforms>|<prover>|<expect>|<why>|<remedy>.
# A row with fewer than 8 fields means that contract moved: report fail: rather
# than silently reading the wrong column, which is how a guard starts asserting
# about a subject nobody named.
rows="$(awk '
    /<<.?SPEC.?$/ { inh=1; next }
    /^SPEC$/      { inh=0 }
    inh && /\|/ && $0 !~ /^[[:space:]]*#/ { print }
' "$SPEC_SOURCE" 2>/dev/null)"

if [ -z "$rows" ]; then
    echo "skipped:unrunnable-platform-arms:no-rows"
    echo "  note: no prover rows parsed from $SPEC_SOURCE — nothing was examined" >&2
    exit 0
fi

malformed="$(printf '%s\n' "$rows" | awk -F'|' 'NF<8 {c++} END {print c+0}')"
if [ "$malformed" -gt 0 ]; then
    echo "fail:unrunnable-platform-arms:unparsable-spec"
    echo "  $malformed row(s) in $SPEC_SOURCE carry fewer than 8 pipe-separated fields." >&2
    echo "  The documented contract is <tool>|<kind>|<scope>|<platforms>|<prover>|<expect>|<why>|<remedy>." >&2
    echo "  Refusing to guess which column is which: a guard reading the wrong field" >&2
    echo "  asserts confidently about a subject nobody named." >&2
    exit 0
fi

if ! git rev-parse --verify "$BASE_REF" >/dev/null 2>&1; then
    echo "skipped:unrunnable-platform-arms:no-diff-base"
    echo "  note: base ref '$BASE_REF' unavailable — set TILLANDSIAS_UNRUNNABLE_BASE to scope the pass" >&2
    exit 0
fi

changed="$(
    {
        git diff --name-only "$BASE_REF" 2>/dev/null
        git diff --name-only --cached 2>/dev/null
        git ls-files --others --exclude-standard 2>/dev/null
    } | sort -u
)"
changed_n="$(printf '%s\n' "$changed" | grep -c . 2>/dev/null || true)"
changed_n="${changed_n:-0}"

# The unrunnable-here inventory: rows whose platforms EXCLUDE this host and
# which name a prover. The platform test mirrors check-host-tools.sh's own
# `case ",$platforms," in *",$PLATFORM,"*)`, so the two agree by construction.
hits=0
notice=""
while IFS='|' read -r tool kind scope platforms prover expect why remedy; do
    [ -n "${tool:-}" ] || continue
    case ",$platforms," in *",$PLATFORM,"*) continue ;; esac
    [ "${prover:--}" != "-" ] || continue
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        case "$path" in
            */"$prover"|"$prover")
                hits=$((hits + 1))
                notice="${notice}  ${path}
      exercised by the '${tool}' prover row, which is scoped to: ${platforms}
      THIS HOST IS '${PLATFORM}', so ./build.sh --check here NEVER RUNS that arm.
      A break in it lands green from this host and stays green until a '${platforms}' host gates.
"
                ;;
        esac
    done <<< "$changed"
done <<< "$rows"

if [ "$hits" -eq 0 ]; then
    echo "ok:unrunnable-platform-arms:0 of ${changed_n} changed paths"
    exit 0
fi

echo "advisory:unrunnable-platform-arms:${hits} of ${changed_n} changed paths"
printf '%s' "$notice" >&2
echo "  This is ADVISORY and does not refuse the push (1194-davi). Refusing a ${PLATFORM} land" >&2
echo "  over an arm this host cannot run would trade a visibility gap for a worse one." >&2
echo "  Hand the change to a host on that platform, or say on the row why you did not." >&2
exit 0
