#!/usr/bin/env bash
# @trace order:1148-3439, order:874-w2gc
#
# check-salvage-refs-ledger.sh — the local-gate-shaped check for the standing,
# append-only per-host salvage-refs ledger (plan/salvage-refs.d/, written by
# scripts/sweep-salvage-refs.sh --apply). Copies the shape of
# scripts/check-mo-full-attestations.sh (plan/mo-full-attestations.d/): one
# committed markdown file per host, parsed by a script that refuses when the
# grammar breaks or a line no longer describes reality.
#
# WHY THIS EXISTS. sweep-salvage-refs.sh files a line the moment a salvage/*
# ref is first seen; nothing then re-checks that the line still parses or
# still describes something real. A line with the wrong field count is
# silently unparseable by every future sweep (the seen-check is a plain
# string grep, so a malformed line neither matches nor gets fixed) and by a
# human skimming the file; a line naming a ref that has since been deleted
# WITHOUT the trailing ` deleted` marker looks like an outstanding rescue
# forever.
#
# GRAMMAR (per non-comment, non-blank line):
#   | <utc-first-seen> | <ref> | <sha> | <ancestry> | <files> |[ deleted]
# utc-first-seen: an ISO-8601 UTC timestamp. sha: 40 lowercase hex chars.
# ancestry: `on:<branch>[,<branch>...]` or `none`. files: a non-negative
# integer, or `-`. A line MAY end with a literal trailing ` deleted` marker
# (appended by hand once a human or coordinator confirms the ref is merged or
# consciously abandoned) — see scripts/sweep-salvage-refs.sh for the writer
# and the retention decision.
#
# CHECKED, and where:
#   * EVERY file: the five-field grammar above, structurally. Garbage fails
#     on any host that runs this check.
#   * EVERY non-deleted line, in every file (not just the current host's,
#     unlike check-mo-full-attestations.sh's reachability half — a salvage
#     ref lives on the shared remote, not on a per-host local branch, so
#     there is no "owning host" restriction to apply): the ref must still
#     exist on the remote (`git ls-remote --heads origin <ref>`), or the line
#     must carry the trailing ` deleted` marker.
#
# A missing ledger directory passes vacuously (0 lines) — nothing has ever
# been filed yet, which is a legitimate state, not a defect.
#
# Verdict grammar (last stdout line):
#   ok:salvage-refs-ledger:<lines>
#   violation:salvage-refs-ledger:<reason>
# Exit 0 exactly on ok. Per-violation detail goes to stderr (the
# check-mo-full-attestations.sh `refuse()` idiom).
#
# NOT WIRED into ./build.sh --check by this packet (1148-3439) — filing a
# ref is intentionally cheap and the coordinator decides when to activate
# this gate, the same two-step activation check-mo-full-attestations.sh went
# through (742-ye7w / 651-2x5s). When it IS wired, the natural spot is
# build.sh beside the existing step:
#     _step "Checking the durable MO-FULL attestation ledger (614-2gqx)..."
#     if ! _run bash "$SCRIPT_DIR/scripts/check-mo-full-attestations.sh" ...
# — both gates validate an append-only plan/*.d/<host>.md ledger the same
# way, so they belong next to each other in the --check sequence.
#
# Seams (fixture use): TILLANDSIAS_SALVAGE_ROOT (repo root — shared with
# scripts/sweep-salvage-refs.sh, so a fixture can point both scripts at the
# same throwaway ledger without ever touching the real one).
set -uo pipefail

ROOT="${TILLANDSIAS_SALVAGE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT" || { echo "violation:salvage-refs-ledger:no-root"; exit 1; }

LEDGER_DIR="plan/salvage-refs.d"
REMOTE=origin
# ORDER 1173-a5ng. The branch whose copy of the ledger is consulted when the
# LOCAL copy is behind. Named rather than hardcoded so the fixture can point it
# at a throwaway ref, but defaulted to the trunk every host merges from.
TRUNK_REF="${TILLANDSIAS_SALVAGE_TRUNK_REF:-origin/${TILLANDSIAS_TRUNK_BRANCH:-linux-next}}"

TS_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
SHA_RE='^[0-9a-f]{40}$'

violations=0
lines=0
marker_on_trunk=""

refuse() { # refuse <file> <detail...>
    violations=$((violations + 1))
    echo "REFUSED: $1" >&2
    shift
    printf '   %s\n' "$@" >&2
}

# ORDER 1173-a5ng — IS THIS LINE ALREADY MARKED ON TRUNK?
#
# THE RACE, measured on yolanda 2026-09-13: the coordinator marked line 19 at
# 6857ce7f6 (20:29Z) and deleted the ref at 20:31Z; yolanda's land, gating a tree
# merged BEFORE that commit, refused at ~20:35Z with
# violation:salvage-refs-ledger:1 — while trunk carried the marker the whole
# time. Mark-then-land-then-delete protects a gate that merges trunk AFTER the
# marker lands. It does nothing for a gate already running on an older snapshot,
# and on a floor host a gate runs for an hour, so no timing rule closes this.
#
# THE FIX IS ONE READ THE CHECK ALREADY PAYS FOR. It makes a network round trip
# for `git ls-remote` above; trunk's copy of the same ledger file is a local
# `git show` against a ref that fetch already updated.
#
# THREE STATES, NOT TWO, and the third is the one that bites. `git show
# <ref>:<path>` on a missing ref or a path absent there EXITS NON-ZERO AND WRITES
# ZERO BYTES — indistinguishable from "read it, found no marker" if the rc is
# discarded. This function returns 2 for "could not read trunk's copy" so the
# caller refuses (the pre-existing behaviour) rather than silently forgiving.
_marker_on_trunk() { # _marker_on_trunk <ledger-file> <ref> -> 0 marked | 1 not | 2 unreadable
    local _f="$1" _ref="$2" _copy _rc
    _copy="$(git show "$TRUNK_REF:$_f" 2>/dev/null)"; _rc=$?
    [ "$_rc" -eq 0 ] || return 2
    # A marked line names the ref AND ends with the trailing marker. Matching
    # the ref alone would forgive an unmarked line on trunk, which is the very
    # outstanding-rescue case the negative control keeps.
    while IFS= read -r _l || [ -n "$_l" ]; do
        case "$_l" in
            *"$_ref"*' deleted') return 0 ;;
        esac
    done <<EOF
$_copy
EOF
    return 1
}

if [ ! -d "$LEDGER_DIR" ]; then
    echo "ok:salvage-refs-ledger:0"
    exit 0
fi

# ONE remote query for every line, captured — and a named skip when origin is
# unreachable, so an offline gate does not read "no network" as "ref deleted"
# (green-on-one-regime: the check must not red a host for a substrate it
# cannot reach).
remote_heads="$(git ls-remote --heads "$REMOTE" 'refs/heads/salvage/*' 2>/dev/null)" || {
    echo "skip:salvage-refs-ledger:origin-unreachable (reachability half not checked; grammar half only)"
    remote_heads="__ORIGIN_UNREACHABLE__"
}

for f in "$LEDGER_DIR"/*.md; do
    [ -e "$f" ] || continue
    case "$f" in
        */README.md) continue ;;
    esac
    ln=0
    while IFS= read -r raw_line || [ -n "$raw_line" ]; do
        ln=$((ln + 1))
        case "$raw_line" in
            ''|'#'*) continue ;;
        esac
        lines=$((lines + 1))

        # Peel off a trailing " deleted" marker before counting fields — it
        # sits OUTSIDE the five-field grammar, appended by hand.
        body="$raw_line"
        deleted=0
        case "$body" in
            *' deleted') deleted=1; body="${body% deleted}" ;;
        esac

        case "$body" in
            '| '*' |') : ;;
            *)
                refuse "$f" "line $ln is not shaped like '| a | b | c | d | e |': $raw_line"
                continue
                ;;
        esac

        # Field count via pipe count, not via `read` alone: `read` silently
        # leaves missing trailing fields empty, so a four-field line and a
        # five-field line are indistinguishable to it — only counting the
        # delimiters themselves tells a short line from a well-formed one.
        pipes="$(printf '%s' "$body" | tr -cd '|' | wc -c | tr -d ' ')"
        if [ "$pipes" -ne 6 ]; then
            refuse "$f" "line $ln does not have five ' | '-delimited fields (found $((pipes - 1)) field(s)): $raw_line"
            continue
        fi

        IFS='|' read -r _lead f1 f2 f3 f4 f5 _trail <<<"$body"
        ts="$(printf '%s' "$f1" | tr -d '[:space:]')"
        ref="$(printf '%s' "$f2" | tr -d '[:space:]')"
        sha="$(printf '%s' "$f3" | tr -d '[:space:]')"
        ancestry="$(printf '%s' "$f4" | tr -d '[:space:]')"
        files="$(printf '%s' "$f5" | tr -d '[:space:]')"

        if [ -n "${_lead}" ] || [ -n "${_trail}" ]; then
            refuse "$f" "line $ln has content outside the leading/trailing pipe: $raw_line"
            continue
        fi

        ok_line=1
        if ! grep -qE "$TS_RE" <<<"$ts"; then
            refuse "$f" "line $ln has a malformed first-seen timestamp '$ts': $raw_line"
            ok_line=0
        fi
        if [ -z "$ref" ]; then
            refuse "$f" "line $ln names an empty ref: $raw_line"
            ok_line=0
        fi
        if ! grep -qE "$SHA_RE" <<<"$sha"; then
            refuse "$f" "line $ln has a malformed sha '$sha': $raw_line"
            ok_line=0
        fi
        case "$ancestry" in
            none|on:*) ;;
            *)
                refuse "$f" "line $ln has a malformed ancestry verdict '$ancestry' (want 'none' or 'on:<branch>[,<branch>...]'): $raw_line"
                ok_line=0
                ;;
        esac
        case "$files" in
            -) ;;
            *[!0-9]*|'')
                refuse "$f" "line $ln has a malformed files count '$files' (want a non-negative integer or '-'): $raw_line"
                ok_line=0
                ;;
        esac

        [ "$ok_line" -eq 1 ] || continue
        [ "$deleted" -eq 1 ] && continue

        # THE REACHABILITY HALF. Every file, not just the current host's — a
        # salvage ref describes shared remote state, so any host can tell
        # whether it is still there.
        # No pipeline into grep -q here (795-imz3 / 1076-kft9: SIGPIPE under
        # pipefail reports failure on a hit); the remote's salvage heads were
        # captured once, below the loop's start, and are matched in-shell.
        [ "$remote_heads" != "__ORIGIN_UNREACHABLE__" ] || continue
        case "$remote_heads" in
            *"$ref"*) ;;
            *)
                # 1173-a5ng: before refusing, ask TRUNK. A local copy that is
                # merely behind is the commonest reason a line is unmarked here,
                # and it is not an outstanding rescue.
                _marker_on_trunk "$f" "$ref"
                case "$?" in
                    0)  marker_on_trunk="${marker_on_trunk:+$marker_on_trunk,}$ref"
                        echo "   line $ln names $ref, absent from $REMOTE and unmarked in this checkout — but $TRUNK_REF's copy of $f already carries the marker." >&2
                        echo "   MERGE TRUNK: this tree predates the commit that marked it. Nothing is outstanding." >&2
                        ;;
                    2)  refuse "$f" "line $ln names $ref, which no longer exists on $REMOTE and carries no trailing ' deleted' marker" \
                               "(and $TRUNK_REF:$f could not be read, so the behind-tree case could NOT be ruled out — fetch, then re-run)" ;;
                    *)  refuse "$f" "line $ln names $ref, which no longer exists on $REMOTE and carries no trailing ' deleted' marker" ;;
                esac
                ;;
        esac
    done <"$f"
done

if [ "$violations" -gt 0 ]; then
    echo "violation:salvage-refs-ledger:$violations"
    exit 1
fi
if [ -n "${marker_on_trunk:-}" ]; then
    # The row's verdict shape. A reader greps the token; the stderr lines above
    # say what to do about it.
    echo "ok:salvage-refs-ledger:$lines:marker-on-trunk:$marker_on_trunk"
    exit 0
fi
echo "ok:salvage-refs-ledger:$lines"
exit 0
