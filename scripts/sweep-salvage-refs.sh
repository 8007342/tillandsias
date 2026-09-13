#!/usr/bin/env bash
# @trace order:874-w2gc, order:1148-3439
#
# sweep-salvage-refs.sh — the CONSUMER the salvage net was missing.
#
# ORDER 874-w2gc. 872-c9nd/874-s8vf made pushing a dirty tree to
# refs/heads/salvage/* work; nothing then LOOKED at those refs. A salvaged
# tree nobody ever notices is prose-with-extra-steps — the rescue happened,
# the recovery never will. This sweep is the coordinator-cycle step that turns
# a salvage ref into a durable record, so rescued work is visible in the plan
# and claimable like any other row.
#
# RE-POINTED BY ORDER 1148-3439. --apply used to append a progress event to
# packet 874-s8vf through tillandsias-plan; once that packet was archived the
# ledger refused every event on it (compaction rule: no events on an archived
# packet) and apply mode filed NOTHING from the day of the archive onward —
# report mode kept counting unseen refs correctly the whole time, which is
# what made the gap invisible: nobody diffs filed= against new= on a verdict
# line that still says ok. There is no packet row to archive out from under
# this fix: the standing per-host files below (plan/salvage-refs.d/, the
# plan/mo-full-attestations.d/ shape) are never archived, are append-only,
# and need no plan binary at all.
#
# What it does, in order:
#   1. `git ls-remote <remote> 'refs/heads/salvage/*'` — the ground truth.
#   2. For each ref, checks whether the ref path is already NAMED (exact
#      string match) anywhere under plan/salvage-refs.d/*.md — the
#      append-only ledger step 3 writes. A ref named there by ANY host's
#      file is "seen" and is never re-filed.
#   3. With --apply, appends one line per UNSEEN ref to THIS host's own
#      plan/salvage-refs.d/<host>.md (created with a short header comment on
#      first use): first-seen UTC timestamp, the ref, its sha, an ancestry
#      verdict (which of linux-next/windows-next/osx-next/main already
#      contain the sha, checked against that branch's origin/* ref, or
#      `none`), and the changed-file count of the salvage commit against its
#      parent (`-` when the parent is unavailable). Without --apply it only
#      reports (report mode never writes anything).
#      scripts/check-salvage-refs-ledger.sh is the gate that keeps this
#      ledger's grammar and reachability honest.
#   4. Reports the local overlap-refusals.jsonl (873-zcim exit criterion 3's
#      durable record, which also had no consumer): total refusals, how many
#      are new since the last consumed cursor, and the newest line. --apply
#      advances the cursor. Refusals are host-local telemetry — they are
#      REPORTED for the coordinator to judge, not written to any ledger.
#
# RETENTION DECISION (recorded here and on 874-w2gc's ledger row): salvage
# refs are kept until a human or coordinator confirms the rescued content is
# merged or consciously abandoned; deletion then requires
# TILLANDSIAS_SALVAGE_DELETE_OK=1 past the pre-push guard. No automatic
# time-based reaping: the refs are tiny, the work they carry was by
# definition unrecoverable from anywhere else, and an expiry policy would
# reintroduce exactly the silent-loss failure the net exists to end. A ref a
# human confirms disposed of gets a trailing ` deleted` marker appended to
# its ledger line BY HAND — this script never removes or rewrites a line, and
# never writes that marker itself (deletion stays a conscious, non-automated
# act; NOT IN SCOPE here per 1148-3439).
#
# Verdict grammar (last stdout line):
#   ok:salvage-sweep:refs=<total>:new=<unseen>:filed=<lines-written>:refusals-new=<n>
#   fail:salvage-sweep:<reason>
#
# Seams (fixture use): TILLANDSIAS_SALVAGE_ROOT (repo root — also honored by
# scripts/check-salvage-refs-ledger.sh, so a fixture can point both scripts at
# the same throwaway ledger), TILLANDSIAS_SALVAGE_REMOTE (default origin),
# TILLANDSIAS_CYCLE_STATE_DIR (shared with cycle-checkout-lock.sh).
set -uo pipefail

ROOT="${TILLANDSIAS_SALVAGE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT" || { echo "fail:salvage-sweep:no-root"; exit 2; }

REMOTE="${TILLANDSIAS_SALVAGE_REMOTE:-origin}"
STATE_DIR="${TILLANDSIAS_CYCLE_STATE_DIR:-$HOME/.cache/tillandsias}"
REFUSALS="$STATE_DIR/overlap-refusals.jsonl"
CURSOR="$STATE_DIR/overlap-refusals.cursor"
LEDGER_DIR="plan/salvage-refs.d"
BRANCHES="linux-next windows-next osx-next main"

apply=0
[ "${1:-}" = "--apply" ] && apply=1

# ── 1. ground truth ──────────────────────────────────────────────────────────
if ! ls_out="$(git ls-remote "$REMOTE" 'refs/heads/salvage/*' 2>&1)"; then
    echo "fail:salvage-sweep:ls-remote:$(printf '%s' "$ls_out" | head -1 | cut -c1-80)"
    exit 1
fi

total=0 new=0 filed=0
new_refs=()
while IFS=$'\t' read -r sha ref; do
    [ -n "${ref:-}" ] || continue
    total=$((total + 1))
    # 2. seen = the ref path is already named in the standing ledger.
    if grep -rqF -- "$ref" "$LEDGER_DIR" 2>/dev/null; then
        continue
    fi
    new=$((new + 1))
    new_refs+=("$ref $sha")
    echo "unseen: $ref $sha"
done <<EOF
$ls_out
EOF

# ── 3. file unseen refs to the standing per-host ledger (apply mode only) ────
if [ "$apply" -eq 1 ] && [ "$new" -gt 0 ]; then
    host="$(hostname -s 2>/dev/null | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9-')"
    [ -n "$host" ] || host="unknown"
    ledger_file="$LEDGER_DIR/$host.md"
    if [ ! -f "$ledger_file" ]; then
        mkdir -p "$LEDGER_DIR" || { echo "fail:salvage-sweep:mkdir:$LEDGER_DIR"; exit 1; }
        {
            printf '# salvage-refs ledger -- %s.md (order 1148-3439)\n' "$host"
            printf '# Append-only: one line per refs/heads/salvage/* ref this ledger has ever\n'
            printf '# recorded. Written by: scripts/sweep-salvage-refs.sh --apply.\n'
            printf '# Grammar: | <utc-first-seen> | <ref> | <sha> | <ancestry> | <files> |\n'
            printf '#   ancestry: on:<branch>[,<branch>...] for every one of linux-next,\n'
            printf '#   windows-next, osx-next, main whose origin/<branch> ref contains the sha,\n'
            printf '#   or none.\n'
            printf '#   files: git diff --name-only <sha>^ <sha> count, or - when no parent exists.\n'
            printf '# A ref confirmed merged or consciously abandoned gets a trailing " deleted"\n'
            printf '# marker appended BY HAND; a line is otherwise immutable, never removed or\n'
            printf '# rewritten.\n'
            printf '# Gate: scripts/check-salvage-refs-ledger.sh (not yet wired into\n'
            printf '# ./build.sh --check — see that script'"'"'s header for where it belongs).\n'
        } >"$ledger_file" || { echo "fail:salvage-sweep:file-create:$ledger_file"; exit 1; }
    fi
    for entry in ${new_refs[@]+"${new_refs[@]}"}; do
        ref="${entry% *}"; sha="${entry##* }"
        # Bring the objects local so ancestry/diff below can see them; this
        # never creates a local ref, same posture as the append-event path it
        # replaces (which also only ever read, never wrote, salvage refs).
        git fetch -q "$REMOTE" "$ref" >/dev/null 2>&1 || true
        ancestry=""
        for b in $BRANCHES; do
            if git rev-parse -q --verify "$REMOTE/$b" >/dev/null 2>&1 \
                && git merge-base --is-ancestor "$sha" "$REMOTE/$b" 2>/dev/null; then
                ancestry="${ancestry:+$ancestry,}$b"
            fi
        done
        if [ -n "$ancestry" ]; then
            ancestry="on:$ancestry"
        else
            ancestry="none"
        fi
        if git rev-parse -q --verify "$sha^" >/dev/null 2>&1; then
            files="$(git diff --name-only "$sha^" "$sha" 2>/dev/null | wc -l | tr -d ' ')"
        else
            files="-"
        fi
        ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        if printf '| %s | %s | %s | %s | %s |\n' "$ts" "$ref" "$sha" "$ancestry" "$files" >>"$ledger_file"; then
            filed=$((filed + 1))
            echo "filed: $ref"
        else
            echo "fail:salvage-sweep:file-ref:$ref"
            exit 1
        fi
    done
fi

# ── 4. overlap-refusals consumer (873-zcim residue) ──────────────────────────
ref_total=0
if [ -f "$REFUSALS" ]; then
    ref_total="$(wc -l < "$REFUSALS" | tr -d ' ')"
fi
consumed=0
if [ -f "$CURSOR" ]; then
    consumed="$(cat "$CURSOR" 2>/dev/null | tr -cd '0-9')"
    [ -n "$consumed" ] || consumed=0
fi
# A truncated/rotated file must not make the delta negative.
[ "$consumed" -gt "$ref_total" ] && consumed=0
ref_new=$((ref_total - consumed))
if [ "$ref_new" -gt 0 ]; then
    echo "overlap-refusals: $ref_new new since last sweep; newest:"
    tail -1 "$REFUSALS"
fi
if [ "$apply" -eq 1 ] && [ "$ref_new" -gt 0 ]; then
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    printf '%s\n' "$ref_total" > "$CURSOR" 2>/dev/null || true
fi

echo "ok:salvage-sweep:refs=$total:new=$new:filed=$filed:refusals-new=$ref_new"
