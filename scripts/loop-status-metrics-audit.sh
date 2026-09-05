#!/usr/bin/env bash
# loop-status-metrics-audit.sh — the cross-host cycle-metrics audit (order
# 1001-q3zf), as a COMMAND rather than as prose in a skill.
#
# WHY THIS IS A FILE. The audit loop lived inside
# skills/coordinate-multihost-work/SKILL.md, and on 2026-09-05 the coordinator
# retyped it from memory instead of running it. The retype dropped two fixes the
# file already carried, and two figures filed into packet 1074-96z9 came out of
# the wrong entry. A corrected instrument that lives in prose gets paraphrased,
# and a paraphrase is a new command with none of the corrections. So the loop
# lives here now and the skill calls it.
#
# WHAT IT PRINTS, one line per row, and NOTHING else on stdout:
#   <host> skippable: candidates=...        a host pasting its metrics
#   <host> NOT-PASTING (<file>)             newest entry carries no machine line
#   unattributed-bucket <name> entries=<n>  a platform label, not a host
#   rows=<n> stems=<n>                      the last line; the two MUST be equal
#
# THE TWO DEFECTS THIS FILE EXISTS TO NOT HAVE:
#
# 1. SORT BY NAME, NEVER BY MTIME. After a merge or a checkout every file's
#    mtime is the checkout time. `ls -t` once read yoga's 09:30Z backfill as
#    newer than its 11:29Z entry (macuahuitl 2026-09-04T12:09Z), and again
#    selected the older entry for four of thirteen stems (macuahuitl
#    2026-09-05T18:52Z). Entry names begin with a UTC stamp, so a reverse
#    lexical sort IS newest-first and needs no clock.
#
# 2. ANCHOR ON THE MACHINE TOKEN AND TAKE THE FIRST MATCH. A handoff that
#    pastes the verbatim block and then DISCUSSES it has two lines starting
#    `skippable: `; `tail -1` takes the prose one. That reported esmeraldinha as
#    not pasting when it was pasting AND interpreting — the instrument
#    penalising the extra work. `skippable: candidates=` matches only the
#    machine line, and `head -1` takes the paste rather than the commentary.
#
# A stem that is a PLATFORM LABEL is a shared bucket, not a host (order
# 1012-hu7d): `loop-status-append` without --host falls back to
# TILLANDSIAS_HOST_KIND, unset in agent shells. Buckets are reported by COUNT.
# Never read one as a host, and never read a host as silent because its entries
# sit in a bucket — ask the host, or read the bucket's newest entry by hand.
#
# The stem is everything after the `<timestamp>z-[<8hex>-]` prefix, NOT the text
# after the last dash: session stems carry dashes of their own
# (lenovinha-tillandsias-forge, macuahuitl-tillandsias-forge), and a last-dash
# split once collapsed three stems into one `forge` row.
set -uo pipefail
cd "$(cd -- "${BASH_SOURCE[0]%/*}/.." && pwd)" || exit 2
DIR="${TILLANDSIAS_LOOP_STATUS_DIR:-plan/loop_status.d}"
[ -d "$DIR" ] || { echo "blocked:no-loop-status-dir:$DIR" >&2; exit 2; }

entries="$(ls "$DIR"/*.md 2>/dev/null | grep -E '/[0-9]{8}t[0-9]{6}z-([0-9a-f]{8}-)?[^/]+\.md$' || true)"
[ -n "$entries" ] || { echo "blocked:no-prefixed-entries:$DIR" >&2; exit 2; }

buckets='^(linux|macos|windows|forge|linux-immutable|linux-mutable)$'
stems="$(printf '%s\n' "$entries" | sed -E 's#.*/[0-9]{8}t[0-9]{6}z-([0-9a-f]{8}-)?##; s/\.md$//' | sort -u)"
n_stems="$(printf '%s\n' "$stems" | grep -c .)"

rows=0
for h in $stems; do
    rows=$((rows + 1))
    if printf '%s' "$h" | grep -qE "$buckets"; then
        n="$(printf '%s\n' "$entries" | grep -cE "z-([0-9a-f]{8}-)?$h\.md$")"
        echo "unattributed-bucket $h entries=$n"
        continue
    fi
    # Reverse LEXICAL sort on a UTC-stamped name: newest first, no clock, no mtime.
    f="$(printf '%s\n' "$entries" | grep -E "z-([0-9a-f]{8}-)?$h\.md$" | sort -r | head -1)"
    [ -n "$f" ] || { echo "$h NO-ENTRY"; continue; }
    line="$(grep -o 'skippable: candidates=[^`|·]*' "$f" | head -1)"
    if [ -n "$line" ]; then echo "$h $line"; else echo "$h NOT-PASTING ($f)"; fi
done
# The two MUST be equal. A dropped stem under-counts the two-or-more-hosts
# trigger that decides whether a step gets a memoisation packet.
echo "rows=$rows stems=$n_stems"
[ "$rows" = "$n_stems" ] || { echo "violation:dropped-stem:rows=$rows stems=$n_stems" >&2; exit 1; }
