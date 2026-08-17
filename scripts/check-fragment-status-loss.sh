#!/usr/bin/env bash
# @trace spec:ci-release
#
# check-fragment-status-loss.sh — catch status transitions that the fold silently
# discards.
#
# Order 635-i6vm.
#
# THE TRAP. `packets:` in a ledger fragment is a G-SET keyed by packet_id: the
# union of declarations, where re-adding an existing packet is a NO-OP. Status is
# a separate LWW-Register with its own `status:` channel keyed by (ts, host).
# Both facts are documented in plan/index.d/README.md and in fragments.rs.
#
# The failure mode is that re-declaring a packet with a new status LOOKS exactly
# like recording a transition. It parses, it validates, `tillandsias-plan check`
# passes, the diff reads correctly in review — and the fold throws the status
# away. Nothing anywhere says so.
#
# Measured 2026-08-09: 11 of 21 packets recorded `completed` in a fragment were
# still folding as `ready`. 52% of fragment-recorded completions had been
# silently discarded, some for two days. Two of them were handed to this host as
# "next work" by the batch selector in the cycle that found this — completed work
# being re-offered for implementation, which is the mechanical root of agents
# "going in circles" on work that is already done.
#
# This is NOT a heuristic or a ranking problem. It is a data-integrity defect
# that every downstream reader inherits, because every reader asks the fold.
#
# GRAMMAR — exactly one line:
#   ^(ok:no-fragment-status-loss:[0-9]+ checked|violation:fragment-status-loss:[0-9]+)$
# Exit 0 when no declared status is being discarded.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

FRAG_DIR="plan/index.d"
[ -d "$FRAG_DIR" ] || { echo "ok:no-fragment-status-loss:0 checked"; exit 0; }

# FAST PATH: no fragment files at all means neither pass below has anything to
# examine, and this guard runs on every `./build.sh --check`. Kept as a literal
# file test rather than deferring to the passes so the freshly-compacted
# checkout — the common case — costs no subprocess at all.
frag_present=0
for _f in "$FRAG_DIR"/*.yaml; do
    [ -f "$_f" ] && { frag_present=1; break; }
done
[ "$frag_present" -eq 1 ] || { echo "ok:no-fragment-status-loss:0 checked"; exit 0; }

# One probe, shared with every script that needs the binary (704-zcgi), and it
# resolves by EXECUTION (721-nyev): an executable BIT is a claim; RUNNING the
# binary is evidence. On a shared Windows/WSL checkout a WSL build leaves a
# Linux ELF at target/release/tillandsias-plan beside the runnable .exe, and a
# first-match-on--x loop selected the ELF. Falls back release, debug, then PATH.
. "$(dirname "${BASH_SOURCE[0]}")/plan-binary-probe.sh"
PLAN="$(resolve_plan_binary)" || PLAN=""
[ -n "$PLAN" ] || { echo "violation:fragment-status-loss:0"; echo "  tillandsias-plan not built; cannot resolve the fold" >&2; exit 2; }

# Every (packet_id, status) pair declared under a `packets:` list in any
# fragment. Deliberately ignores the `status:` LWW channel — that one works.
declared="$(awk '
    /^  - packet_id:/ { pid = $3; st = ""; next }
    /^    status:/    { if (pid != "" && st == "") { st = $2; print pid "\t" st; pid = "" } }
' "$FRAG_DIR"/*.yaml 2>/dev/null | sort -u)"

# NOTE (order 785-sqe6): there is deliberately NO early exit here. See the
# independence guard below the event pass for why an empty `declared` must not
# short-circuit this script.

# SECOND CLASS: a terminal EVENT with no matching status transition.
#
# The `declared` pass catches "declared terminal under `packets:`, discarded by
# the G-Set". It cannot see the other way a completion goes missing: recording
# `type: completed` as an EVENT and never writing the `status:` LWW entry.
# Nothing is discarded there, so nothing looks wrong — the packet simply stays
# claimable forever.
#
# Both classes are compared against the fold in the single join below; this
# block only collects WHICH packets declare a closure event.
#
# Observed on three hosts. The macOS close-out on 2026-08-09 reported 624-q4jj
# ALL-PASS with a full evidence file, wrote `type: completed`, carried no
# `status:` block, and the packet was still being offered as work. Windows filed
# the naming half of the same trap as 642-fedr the same day. Three hosts
# independently is a write-path defect, not three mistakes.
#
# Which packet_ids DECLARE a terminal `completed` event in their events block?
#
# ORDER 752-pst5. This used to be a line-grep with ad-hoc resets, and a grep
# cannot tell an event declaration from PROSE that quotes the marker inside a
# block scalar: packet 751-i9mb's own description quoted `type: completed` and
# the gate invented a completion for it. Attribution is now STRUCTURAL — the
# fragment is parsed as YAML and only `type:` keys under an events list count —
# via `fragment-terminal-events`, the same binary this script already requires
# for the fold. The per-file loop keeps the 598-kibt file-boundary isolation
# by construction: each fragment is read alone, so the last packet of one file
# can never inherit the first closure marker of the next.
if plan_binary_has "$PLAN" fragment-terminal-events; then
    declared_events="$(for f in "$FRAG_DIR"/*.yaml; do
        [ -f "$f" ] || continue
        "$PLAN" fragment-terminal-events "$f" 2>/dev/null
    done | sort -u)"
else
    # ORDER 702-68zj: a binary that predates the rule is STALE HOST STATE, not
    # a ledger defect. The `declared` pass still runs (it only needs the fold);
    # the event pass is skipped LOUDLY rather than approximated with an awk that
    # could again invent completions — a checker that invents completions is
    # worse than no checker, and a half-correct scanner is exactly the next
    # 752. Rebuild to enable the pass.
    declared_events=""
    echo "  note: $PLAN predates fragment-terminal-events — closure-event pass SKIPPED (rebuild with 'cargo build --release -p tillandsias-plan')" >&2
fi

# ── THE TWO PASSES ARE INDEPENDENT (order 785-sqe6) ─────────────────────────
#
# An early exit used to sit above the event pass: "no (packet_id, status) pair
# declared under `packets:`, therefore nothing to check, exit 0". It made the
# closure-event pass UNREACHABLE on exactly the fragment shape most likely to
# carry the defect that pass was written for — a pure `events:` append, which
# is what `append-event` produces and what a set-field/append-event cycle emits
# by default. The verdict printed `ok:no-fragment-status-loss:0 checked` while
# the second pass had never run: this guard's own failure class (an unexamined
# ledger reported as clean), reintroduced by a short-circuit.
#
# Only genuinely-nothing-to-examine exits early now. A fragment set carrying
# events and no declarations reaches the join below, which is the whole point.
if [ -z "$declared" ] && [ -z "$declared_events" ]; then
    echo "ok:no-fragment-status-loss:0 checked"
    exit 0
fi

# ── THE FOLD, READ ONCE (order 783-xyk5) ────────────────────────────────────
#
# Both passes above ask the same question of the same fold: "what status does
# packet X carry?" This used to be `"$PLAN" status "$pid"` inside each loop,
# and every one of those invocations re-read and re-folded the ENTIRE base
# ledger plus all fragments. Measured 2026-08-17 by the 765-dfry per-step gate
# telemetry: ~436ms per spawn, 10.5s warm for this one guard — ~60% of a 17.4s
# `./build.sh --check`, paid 2-5x per cycle on every host, every cycle.
#
# `query --json` is the SAME folded reader (582-26mm) the per-packet `status`
# call goes through, so reading every (packet_id, status) pair in ONE
# invocation is a spawn-count fix, not a semantics change: 974 packets in
# ~129ms, independent of how many packets the fragments declare.
#
# FAIL-SAFE, NOT FAIL-FAST. If the batch cannot be built — a binary predating
# `query`, a jq-less host, a fake harness binary that advertises the
# subcommand without implementing it — the map is rebuilt with exactly the
# per-packet `status` calls this replaced. Slower is acceptable; checking
# NOTHING is not, and an empty map would silently pass every packet. That is
# the same failure this guard exists to catch, so it must never be reachable
# from a performance change.
status_map=""
if plan_binary_has "$PLAN" query && command -v jq >/dev/null 2>&1; then
    status_map="$("$PLAN" query --json --limit 0 2>/dev/null \
        | jq -r '.[] | select((.packet_id // "") != "") | [.packet_id, (.status // "")] | @tsv' 2>/dev/null)"
fi
if [ -z "$status_map" ]; then
    echo "  note: batched fold unavailable ($PLAN query --json); falling back to per-packet status lookups" >&2
    status_map="$( { printf '%s\n' "$declared" | cut -f1
                     printf '%s\n' "$declared_events"; } | sort -u | while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        s="$("$PLAN" status "$pid" 2>/dev/null | awk '{print $2}')"
        [ -n "$s" ] && printf '%s\t%s\n' "$pid" "$s"
    done )"
fi

# One awk pass joins the map against both declaration classes. Rows are tagged
# M/D/E so the map is loaded before either comparison, and a packet absent from
# the map is skipped exactly as an empty `status` result was.
#
# `checked` counts DISTINCT packet_ids examined by EITHER pass (order
# 785-sqe6); it counted pass-one rows only while pass two could not run without
# pass one. Now that an events-only fragment set is examined, a D-only counter
# would report `0 checked` for a run that really did check something — a
# smaller version of the same misreport this packet closes. Distinct-by-pid
# rather than row-summed so a packet carrying both a declaration and a closure
# event counts once: the number answers "how many packets did I examine",
# which is how every loop-status entry has read it. An examination ATTEMPT
# counts whether or not the packet resolves in the fold, exactly as the
# per-packet loop counted before its `status` lookup. Terminal-set
# membership is the resolver's (is_terminal_status, 650-dq6u) — a guard laxer
# OR wider than the resolver is decorative (649-b2e4). Pass-one violations are
# emitted before event violations, preserving the report's original order.
# POSIX awk arrays only: bash stays 3.2-clean (no associative arrays, 761-g36m).
join_out="$( { printf '%s\n' "$status_map"      | sed 's/^/M\t/'
               printf '%s\n' "$declared"        | sed 's/^/D\t/'
               printf '%s\n' "$declared_events" | sed 's/^/E\t/'; } \
    | awk -F'\t' -v q="'" '
        $1 == "M" { if ($2 != "") st[$2] = $3; next }
        $1 == "D" {
            pid = $2; want = $3
            if (pid == "") next
            if (!(pid in seen)) { seen[pid] = 1; checked++ }
            if (!(pid in st)) next
            got = st[pid]
            if (got == want) next
            # A packet legitimately declared `ready` in one fragment and later
            # moved on via the LWW channel is NOT a loss — the fold is ahead of
            # the declaration, which is correct. Only flag a declaration the
            # fold is BEHIND: a terminal status that never took effect.
            if (want == "completed" || want == "verified" || want == "done" || want == "obsoleted")
                dv = dv sprintf("%s: declared %s%s%s in a fragment, folds as %s%s%s\n", pid, q, want, q, q, got, q)
            next
        }
        $1 == "E" {
            pid = $2
            if (pid == "") next
            if (!(pid in seen)) { seen[pid] = 1; checked++ }
            if (!(pid in st)) next
            got = st[pid]
            # A completed EVENT legitimately pairs with ANY closure-ladder
            # terminal: per 650-dq6u the event may set status to completed, or
            # directly to verified/done when the evidence meets that higher
            # rung. obsoleted is accepted too (supersession over a completion).
            if (got == "completed" || got == "verified" || got == "done" || got == "obsoleted") next
            ev = ev sprintf("%s: has a %scompleted%s EVENT but folds as %s%s%s\n", pid, q, q, q, got, q)
            next
        }
        END { printf "%s%s__CHECKED__%d\n", dv, ev, checked }
    ')"

checked="$(printf '%s\n' "$join_out" | sed -n 's/^__CHECKED__\([0-9][0-9]*\)$/\1/p' | tail -1)"
[ -n "$checked" ] || checked=0
violations="$(printf '%s\n' "$join_out" | grep -v '^__CHECKED__' | grep -v '^$')"
[ -n "$violations" ] && violations="${violations}"$'\n'

if [ -n "$violations" ]; then
    n="$(printf '%s' "$violations" | grep -c .)"
    echo "violation:fragment-status-loss:${n}"
    printf '%s' "$violations" | sed 's/^/  /'
    echo "  CAUSE: \`packets:\` is a G-Set — re-declaring a packet does NOT change its status."
    echo "  REMEDY: write a NEW fragment with a \`status:\` entry (packet_id/field/value/ts/host)."
    echo "          See plan/index.d/README.md."
    exit 1
fi

echo "ok:no-fragment-status-loss:${checked} checked"
