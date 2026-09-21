#!/usr/bin/env bash
# @trace order:1331-884p
#
# test-fragment-status-loss-row-boundary.sh — ORDER 1331-884p, carried from
# 1319-vd5h, which named this script as sharing the row-marker idiom.
#
# Pins the ROW BOUNDARY of the `packets:` pass in
# scripts/check-fragment-status-loss.sh. Two faults lived there and each hid
# the other:
#
#   FLUSH  anchored to a BARE dash at indent 2, so a nested sequence entry
#          written at the parent key's indent flushed the record. A nested list
#          BETWEEN packet_id and status dropped the pair — a status-loss
#          detector losing a status.
#   CAPTURE required indent 2 or 4, so a FLAT fragment (row marker at indent 0,
#          fields at 2) never had its packet_id read at all. Not a lost pair:
#          an unread row, invisible to the pass.
#
# OF 1319-vd5h's THREE NAMED SITES ONLY ONE WAS LIVE — line 88 is a comment
# quoting the old broken code and the `status:` LWW pass is already key-anchored
# to `- packet_id:`. Measuring that before changing anything is why this touches
# one site and not three.
#
# ARMS. Each exists because a weaker version could not fail:
#   0 SELF-CHECK  can this shell MEASURE at all — if the extraction of the
#                 pinned program comes back empty every arm would read nothing
#                 and report it as the subject failing. Says could-not-run.
#   1 NESTED      a nested list between packet_id and status: the pair is LOST
#                 pre-fix and present post-fix.
#   2 FLAT        a row marker at indent 0: the packet is INVISIBLE pre-fix and
#                 read post-fix.
#   3 MUTATION    revert to the pinned program and arms 1-2 must fail — and it
#                 FIRST asserts the reverted program DIFFERS. A no-op mutation
#                 reads exactly like a passing test.
#   4 CORPUS      the five packets the live ledger was not reading must each be
#                 read, BY NAME, and no pair the pinned program read may be lost.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
SUBJECT="scripts/check-fragment-status-loss.sh"
PIN_SHA="${STATUS_LOSS_PIN_SHA:-11e65bc86adfbcf35c21278278d4e37ff785b7cf}"

rc=0
tmp="$(mktemp -d "${TMPDIR:-/tmp}/status-loss-boundary.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT INT TERM
note() { printf '%s\n' "$*"; }
fail() { printf 'FAIL:%s\n' "$*" >&2; rc=1; }

# The `packets:` pass, taken VERBATIM from a source file — never re-implemented,
# so arms 3 and 4 test real behaviour and not a paraphrase of it.
extract_pass() { awk '/^declared="\$\(awk/{f=1;next} f&&/^'"'"' "\$FRAG_DIR"/{exit} f{print}' "$1"; }

if ! git cat-file -e "$PIN_SHA:$SUBJECT" 2>/dev/null; then
    note "skip:status-loss-boundary:pin-unreachable:$PIN_SHA (shallow clone or unfetched history)"
    exit 0
fi
git show "$PIN_SHA:$SUBJECT" > "$tmp/pinned.sh"
extract_pass "$tmp/pinned.sh" > "$tmp/old.awk"
extract_pass "$SUBJECT"       > "$tmp/new.awk"

# ── ARM 0 — CAN THIS RUN MEASURE? ───────────────────────────────────────────
# If either extraction is empty every arm below reads nothing and would report
# the subject as broken. That is a MEASUREMENT failure and must never be
# reported as a verdict on the subject.
if [ ! -s "$tmp/old.awk" ] || [ ! -s "$tmp/new.awk" ]; then
    note "could-not-run:status-loss-boundary:pass-extraction-empty old=$(wc -l < "$tmp/old.awk") new=$(wc -l < "$tmp/new.awk")"
    {
      echo "  The awk pass could not be extracted from the subject, so no arm below"
      echo "  measured anything. This is a MEASUREMENT failure, NOT a verdict on"
      echo "  check-fragment-status-loss.sh — nothing here is an accusation."
      echo "  The extractor anchors on 'declared=\$(awk' ; if that line moved, fix"
      echo "  the extractor rather than the subject."
    } >&2
    exit 2
fi
note "ok:status-loss-boundary:arm0-can-measure:pinned=$(wc -l < "$tmp/old.awk") current=$(wc -l < "$tmp/new.awk") lines"

pairs() { awk -f "$1" "$2" 2>/dev/null; }

# ── ARM 1 — a nested list BETWEEN packet_id and status ──────────────────────
{ printf '%s\n' 'packets:' \
                 '  - packet_id: fixture-nested-list-between-packet-id-and-status' \
                 '    capability_tags:' \
                 '  - plan' \
                 '  - tooling' \
                 '    status: ready'; } > "$tmp/nested.yaml"
pre1="$(pairs "$tmp/old.awk" "$tmp/nested.yaml")"
post1="$(pairs "$tmp/new.awk" "$tmp/nested.yaml")"
[ -z "$pre1" ]  || fail "status-loss-boundary:arm1:the PINNED pass should LOSE this pair (got [$pre1]) — the pin is not the pre-fix code"
case "$post1" in
  *fixture-nested-list-between-packet-id-and-status*ready*) note "ok:status-loss-boundary:arm1-nested-list:pair lost pre-fix, read post-fix" ;;
  *) fail "status-loss-boundary:arm1:pair still lost after the fix (got [$post1])" ;;
esac

# ── ARM 2 — a FLAT fragment, row marker at indent 0 ─────────────────────────
# NOTE printf '%s\n' FOR EVERY LINE: a flat fragment's row marker begins with a
# dash, and `printf '- packet_id: …'` is read as an OPTION, not a format. Caught
# by arm 2 failing loudly rather than by the fixture silently being empty.
{ printf '%s\n' 'packets:' \
                 '- packet_id: fixture-flat-row-marker-at-indent-zero' \
                 '  order: 9999-flat' \
                 '  capability_tags:' \
                 '  - macos' \
                 '  status: ready'; } > "$tmp/flat.yaml"
pre2="$(pairs "$tmp/old.awk" "$tmp/flat.yaml")"
post2="$(pairs "$tmp/new.awk" "$tmp/flat.yaml")"
[ -z "$pre2" ]  || fail "status-loss-boundary:arm2:the PINNED pass should not SEE this packet at all (got [$pre2])"
case "$post2" in
  *fixture-flat-row-marker-at-indent-zero*ready*) note "ok:status-loss-boundary:arm2-flat-row:packet invisible pre-fix, read post-fix" ;;
  *) fail "status-loss-boundary:arm2:flat packet still unread after the fix (got [$post2])" ;;
esac

# ── ARM 3 — MUTATION, proving its own edit landed ───────────────────────────
if cmp -s "$tmp/old.awk" "$tmp/new.awk"; then
    fail "status-loss-boundary:arm3:mutation-is-a-no-op — pinned and current passes are IDENTICAL, so arms 1-2 prove nothing"
else
    note "ok:status-loss-boundary:arm3-mutation-applied:$(diff "$tmp/old.awk" "$tmp/new.awk" | grep -c '^[<>]') differing line(s)"
fi

# ── ARM 4 — THE FIVE, BY NAME, AND NOTHING LOST ─────────────────────────────
# Named rather than counted: a count passes when the fix reads five OTHER rows.
FIVE="1313-w78k 1314-2mdv 1315-d4qd 1323-pc8k 1327-r4zb"
corpus=(); while IFS= read -r f; do corpus+=("$f"); done < <(ls plan/index.d/*.yaml 2>/dev/null)
if [ "${#corpus[@]}" -eq 0 ]; then
    note "could-not-run:status-loss-boundary:arm4:no fragments found under plan/index.d — not a verdict on the subject"
else
    for a in "$tmp/old.awk" "$tmp/new.awk"; do
        out="$a.pairs"; : > "$out"
        for f in "${corpus[@]}"; do awk -f "$a" "$f" 2>/dev/null | sed "s|^|$f\t|"; done | sort > "$out"
    done
    lost=$(comm -23 "$tmp/old.awk.pairs" "$tmp/new.awk.pairs" | wc -l)
    gained=$(comm -13 "$tmp/old.awk.pairs" "$tmp/new.awk.pairs" | wc -l)
    [ "$lost" -eq 0 ] || fail "status-loss-boundary:arm4:pairs LOST under the fix: $lost — a boundary change must never un-read a pair"
    missing=""
    for o in $FIVE; do
        comm -13 "$tmp/old.awk.pairs" "$tmp/new.awk.pairs" | grep -q -- "$o" || missing="$missing $o"
    done
    if [ -n "$missing" ]; then
        fail "status-loss-boundary:arm4:these rows were NOT recovered:$missing (recovered=$gained, lost=$lost)"
    else
        note "ok:status-loss-boundary:arm4-corpus:$gained pair(s) recovered, 0 lost — all five named rows read:$(printf ' %s' $FIVE)"
    fi
fi

if [ $rc -eq 0 ]; then note "ok:fragment-status-loss-row-boundary:5/5 arms"; else note "violation:fragment-status-loss-row-boundary"; fi
exit $rc
