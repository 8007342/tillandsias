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
# 2. MATCH THE WHOLE MACHINE SHAPE, NOT AN ANCHOR TOKEN. A handoff that pastes
#    the verbatim block and then DISCUSSES it has two lines starting
#    `skippable: `; `tail -1` takes the prose one. That reported esmeraldinha as
#    not pasting when it was pasting AND interpreting — the instrument
#    penalising the extra work.
#
#    ANCHORING ON `skippable: candidates=` WAS NOT ENOUGH AND THIS SCRIPT SHIPPED
#    WITH THAT BUG. The very entry that DESCRIBED the new anchor, in backticks,
#    satisfied it: `skippable: candidates=` inside prose matched, the value came
#    back empty, and macuahuitl reported as pasting with no top3. A guard that a
#    comment can satisfy is satisfied by the history of the thing rather than the
#    thing (methodology/verification.yaml,
#    quoted_history_lives_in_comments_guards_scan_declarations) — and this is
#    that shape inside the fix for that shape.
#
#    The discriminator is the FULL EMITTED SHAPE: candidates=, floor_ms=,
#    min_runs= and top3= in order. Prose quoting the anchor cannot satisfy it.
#    A LINE ANCHOR (^) would be wrong: lenovinha and yoga indent their pasted
#    block, so `^skippable:` matches on two hosts and misses two others —
#    measured 2026-09-05T19:5xZ before choosing the shape match.
#
# 3. A HOST THAT WRITES TWO ENTRIES PER CYCLE IS NOT A HOST THAT STOPPED
#    PASTING. The newest entry answers "did the last thing this host wrote carry
#    its metrics", which is the right question, but a cycle that ends with a
#    short closing note then reads NOT-PASTING while its own full report sits one
#    entry back. So when the newest entry has no machine line, the row also names
#    the most recent entry that DOES, with its timestamp, and says `last-paste`.
#    Silence and staleness are then distinguishable, which is the whole point.
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
    SHAPE='skippable: candidates=[0-9]+ floor_ms=[0-9]+ min_runs=[0-9]+ top3=[^`|·]*'
    line="$(grep -oE "$SHAPE" "$f" | head -1)"
    if [ -n "$line" ]; then
        echo "$h $line"
        continue
    fi
    # Newest entry carries no machine line. Say whether the host has EVER pasted
    # and when, so a quiet closing note is distinguishable from a silent host.
    prev=""
    for _e in $(printf '%s\n' "$entries" | grep -E "z-([0-9a-f]{8}-)?$h\.md$" | sort -r); do
        if grep -qE "$SHAPE" "$_e"; then prev="$_e"; break; fi
    done
    if [ -n "$prev" ]; then
        _ts="$(basename "$prev" | sed -E 's/^([0-9]{8}t[0-9]{6}z).*/\1/')"
        echo "$h NOT-PASTING (newest: $f) last-paste=$_ts"
    else
        echo "$h NOT-PASTING ($f) last-paste=never"
    fi
done
# The two MUST be equal. A dropped stem under-counts the two-or-more-hosts
# trigger that decides whether a step gets a memoisation packet.
echo "rows=$rows stems=$n_stems"
[ "$rows" = "$n_stems" ] || { echo "violation:dropped-stem:rows=$rows stems=$n_stems" >&2; exit 1; }
