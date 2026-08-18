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

# ORDER 797-qm4t. The LWW `status:` block, scanned ONLY to ask "does this
# packet_id name anything?". Loss on this channel is not a concern — the comment
# above is right that it works — but a terminal status declared here for a
# packet that does not exist creates nothing and silently records nothing. That
# is how a closure was written against an invented packet_id and collected four
# green signals. Section-scoped, because `  - packet_id:` also appears under
# `packets:` and `events:`.
declared_lww="$(awk '
    /^status:[[:space:]]*$/ { in_s = 1; pid = ""; next }
    /^[a-z_]+:[[:space:]]*$/ { in_s = 0; pid = "" }
    in_s && /^  - packet_id:/ { pid = $3; next }
    in_s && /^    value:/ { if (pid != "") { print pid "\t" $2; pid = "" } }
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
#
# ORDER 787-f7dh — AN UNREADABLE FRAGMENT IS NOT AN EMPTY ONE. This loop used
# to be `"$PLAN" fragment-terminal-events "$f" 2>/dev/null` inside a command
# substitution, which discarded BOTH halves of the only signal available: the
# subcommand's exit status (never inspected, because the pipeline's status is
# `sort`'s) and its stderr. A fragment that failed to parse therefore produced
# exactly what a fragment with no closure events produces — no output, no
# complaint — and the guard printed `ok`. That is this guard's own failure
# class: an unexamined ledger reported as clean, which 785-sqe6 closed for
# "the pass never ran" and this closes for "the pass ran and could not read".
#
# Delegating parse failures to added-fragments-parse (698-7n6q) was an
# ASSUMPTION, not a guarantee: that gate is DIFF-SCOPED, so a malformed
# fragment arriving by merge, by hand edit, from a sibling branch, or already
# present before it landed is never seen by it. Checked at the point of use
# instead. stderr is deliberately NOT redirected now — the parse error names
# the file and line, and it is the operator's fastest path to the fix.
unparseable_fragments=""
# ORDER 797-qm4t, the non-terminal half. The unknown-packet checks on the status
# and terminal-event channels catch a fragment that CLAIMS a closure against a
# packet_id nobody filed. They cannot see a `note` or `progress` event aimed at
# one — that work is dropped in total silence, and the guard reports ok over a
# corpus containing it. Measured: fragment 20260817t184639z carried the whole
# GPU-passthrough measurement set for order 406 as a `note`, addressed to an
# invented packet_id; it is on disk, absent from the fold, and nothing said so.
# Collected in the SAME loop so an unparseable fragment is counted once.
_anyev_capable=no
if plan_binary_has "$PLAN" fragment-event-packets; then _anyev_capable=yes; fi
_anyev_seen=""
_misdef_capable=no
if plan_binary_has "$PLAN" fragment-misplaced-definitions; then _misdef_capable=yes; fi
_misdef_seen=""
if plan_binary_has "$PLAN" fragment-terminal-events; then
    _events_seen=""
    for f in "$FRAG_DIR"/*.yaml; do
        [ -f "$f" ] || continue
        _ev_out="$("$PLAN" fragment-terminal-events "$f")"
        _ev_rc=$?
        if [ "$_ev_rc" -eq 0 ] && [ "$_anyev_capable" = yes ]; then
            # Same file, already known parseable — so this call cannot add a
            # second unparseable count for one fragment.
            _any_out="$("$PLAN" fragment-event-packets "$f" 2>/dev/null)"
            [ -n "$_any_out" ] && _anyev_seen="${_anyev_seen}${_any_out}
"
            # ORDER 812-d45t. A packet DEFINITION written under `events:`
            # instead of `packets:` is accepted by every gate and dropped
            # entirely by the fold — no packet_id is claimed, so the
            # unknown-packet pass above cannot see it either.
            if [ "$_misdef_capable" = yes ]; then
                _mis_out="$("$PLAN" fragment-misplaced-definitions "$f" 2>/dev/null)"
                # Prefix each id with its file HERE rather than joining with a
                # separator and splitting later. The first version used "\t",
                # which inside double quotes is a literal backslash-t, so the
                # reader's tab-IFS split never fired, every line was skipped,
                # and the advisory this block exists to print was silently
                # suppressed — the same shape as the defect being reported.
                if [ -n "$_mis_out" ]; then
                    _misdef_seen="${_misdef_seen}$(printf '%s\n' "$_mis_out" | sed "s|^|${f}: |")
"
                fi
            fi
        fi
        case "$_ev_rc" in
            0) [ -n "$_ev_out" ] && _events_seen="${_events_seen}${_ev_out}
" ;;
            # 3 is the typed unparseable verdict; anything else non-zero (a
            # read error, a killed process) is equally an unread fragment.
            # Both are counted, because the property that matters is "this
            # fragment was not examined", not why.
            *) unparseable_fragments="${unparseable_fragments}  ${f} (exit ${_ev_rc})
" ;;
        esac
    done
    declared_events="$(printf '%s' "$_events_seen" | sort -u)"
    event_packets="$(printf '%s' "$_anyev_seen" | sort -u)"
else
    # ORDER 702-68zj: a binary that predates the rule is STALE HOST STATE, not
    # a ledger defect. The `declared` pass still runs (it only needs the fold);
    # the event pass is skipped LOUDLY rather than approximated with an awk that
    # could again invent completions — a checker that invents completions is
    # worse than no checker, and a half-correct scanner is exactly the next
    # 752. Rebuild to enable the pass.
    declared_events=""
    event_packets=""
    echo "  note: $PLAN predates fragment-terminal-events — closure-event pass SKIPPED (rebuild with 'cargo build --release -p tillandsias-plan')" >&2
fi

# ── AN UNREADABLE FRAGMENT REFUSES (order 787-f7dh) ─────────────────────────
#
# Placed ABOVE the independence check on purpose: an unparseable fragment must
# refuse whether or not anything else in the set declared a status, because
# what it might be hiding is unknowable by construction. The verdict reuses
# the `violation:` grammar rather than inventing a third word — the same
# choice this script already makes when the binary cannot be resolved at all
# (see the `violation:fragment-status-loss:0` exit above): "I could not
# examine the ledger" and "the ledger is wrong" are both refusals, and a
# guard that answers `ok` to the first is the defect.
if [ -n "$unparseable_fragments" ]; then
    n_unparseable="$(printf '%s' "$unparseable_fragments" | grep -c .)"
    echo "violation:fragment-status-loss:${n_unparseable}"
    echo "  UNPARSEABLE fragment(s) — the closure-event pass could not read these," >&2
    echo "  so any terminal event they declare is UNEXAMINED, not absent:" >&2
    printf '%s' "$unparseable_fragments" >&2
    echo "  CAUSE: almost always an unquoted colon-space inside a summary or title." >&2
    echo "         Quote the value, or write it as a block scalar (summary: >)." >&2
    echo "  NOTE: added-fragments-parse (698-7n6q) is diff-scoped, so it does not" >&2
    echo "        see a malformed fragment that arrived by merge or hand edit." >&2
    exit 1
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
               printf '%s\n' "$declared_lww"    | sed 's/^/L\t/'
               printf '%s\n' "$declared_events" | sed 's/^/E\t/'
               printf '%s\n' "$event_packets"   | sed 's/^/A\t/'; } \
    | awk -F'\t' -v q="'" '
        $1 == "M" { if ($2 != "") st[$2] = $3; next }
        $1 == "D" {
            pid = $2; want = $3
            if (pid == "") next
            if (!(pid in seen)) { seen[pid] = 1; checked++ }
            # A `packets:` entry CREATES the packet in the fold, so an
            # unknown pid is unreachable on this path — verified with a control
            # that produced no violation. The unknown-pid checks live on the L
            # and E paths below, which declare without creating.
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
        $1 == "L" {
            pid = $2; want = $3
            if (pid == "") next
            if (!(pid in seen)) { seen[pid] = 1; checked++ }
            # ONLY the unknown-packet question on this channel.
            if (pid in st) next
            if (want == "completed" || want == "verified" || want == "done" || want == "obsoleted")
                dv = dv sprintf("%s: declared %s%s%s in a fragment status block but NO SUCH PACKET is in the fold (typo, or filed against a deleted packet)\n", pid, q, want, q)
            next
        }
        $1 == "A" {
            # ORDER 797-qm4t. Every packet_id an events block addresses, of
            # ANY event type. The only question asked here is whether the
            # fold knows the packet at all: a `note` or `progress` aimed at
            # a packet_id nobody filed is discarded silently, and the
            # terminal-only channel below cannot see it. Deliberately NOT a
            # status comparison — that belongs to D/L/E.
            pid = $2
            if (pid == "") next
            if (!(pid in seen)) { seen[pid] = 1; checked++ }
            if (pid in st) next
            if (pid in unk) next
            unk[pid] = 1
            uv = uv sprintf("__ADVISORY__%s: an events block addresses it but NO SUCH PACKET is in the fold (typo, or filed against a deleted packet) — that event was discarded\n", pid)
            next
        }
        $1 == "E" {
            pid = $2
            if (pid == "") next
            if (!(pid in seen)) { seen[pid] = 1; checked++ }
            if (!(pid in st)) {
                # Same hole from the event side, and here it needs no
                # terminal-status test: a `completed` EVENT for a packet the
                # fold has never heard of is wrong however it got there.
                ev = ev sprintf("%s: has a %scompleted%s EVENT but NO SUCH PACKET is in the fold (typo, or filed against a deleted packet)\n", pid, q, q)
                next
            }
            got = st[pid]
            # A completed EVENT legitimately pairs with ANY closure-ladder
            # terminal: per 650-dq6u the event may set status to completed, or
            # directly to verified/done when the evidence meets that higher
            # rung. obsoleted is accepted too (supersession over a completion).
            if (got == "completed" || got == "verified" || got == "done" || got == "obsoleted") next
            ev = ev sprintf("%s: has a %scompleted%s EVENT but folds as %s%s%s\n", pid, q, q, q, got, q)
            next
        }
        END { printf "%s%s%s__CHECKED__%d\n", dv, ev, uv, checked }
    ')"

checked="$(printf '%s\n' "$join_out" | sed -n 's/^__CHECKED__\([0-9][0-9]*\)$/\1/p' | tail -1)"
[ -n "$checked" ] || checked=0
advisories="$(printf '%s\n' "$join_out" | sed -n 's/^__ADVISORY__//p')"
violations="$(printf '%s\n' "$join_out" | grep -v '^__CHECKED__' | grep -v '^__ADVISORY__' | grep -v '^$')"
# ORDER 797-qm4t. A non-terminal event on an unknown packet_id is REPORTED
# but does not fail the gate. The closure channels (status block, terminal
# event) stay hard violations because a lost closure is lost work with a
# claim attached. This channel sees every `note` and `progress` in the
# corpus, including historical ones in append-only fragments no one may
# rewrite — and 699-dycj is explicit that one host's typo must not become
# every host's red build. Naming it is the fix; the silence was the defect.
if [ -n "$advisories" ]; then
    printf '%s\n' "$advisories" | sed 's/^/  advisory: /' >&2
fi
# ORDER 812-d45t, reported on the same terms as the unknown-packet advisory
# above and for the same reason: historical fragments are append-only, so a
# past mistake must not redden every host's build (699-dycj). The silence was
# the defect.
if [ -n "${_misdef_seen:-}" ]; then
    printf '%s' "$_misdef_seen" | while IFS= read -r _ml; do
        [ -n "$_ml" ] || continue
        echo "  advisory: ${_ml} is a packet DEFINITION under \`events:\` — the fold DROPS it; move it under the top-level \`packets:\` key" >&2
    done
fi
[ -n "$violations" ] && violations="${violations}"$'\n'

if [ -n "$violations" ]; then
    n="$(printf '%s' "$violations" | grep -c .)"
    echo "violation:fragment-status-loss:${n}"
    printf '%s' "$violations" | sed 's/^/  /'
    # Order 696-6byc, exit criteria 2 and 4. This used to print ONE cause and
    # ONE remedy, both describing the declared-under-`packets:` class, whichever
    # class had actually fired. An author whose terminal EVENT disagreed with a
    # non-terminal status was told to "write a NEW fragment with a status:
    # entry" — which would push the packet to completed instead of resolving the
    # contradiction, and forces retracting an immutable fragment. A remedy for
    # the wrong class is worse than no remedy: it is confidently actionable and
    # wrong. Both classes can fire in one run, so these are independent tests,
    # not an if/else.
    #
    # Matched with `case` on the accumulated text rather than `printf | grep -q`.
    # Measured, because the obvious claim here is overstated: with a SHORT
    # `$violations` the grep form is fine — printf finishes writing before
    # grep -q exits, so no SIGPIPE, and the condition is correctly true (checked
    # under `set -uo pipefail`, which line 33 sets). The hazard appears only once
    # the producer outruns the pipe buffer: `yes ... | grep -qF` under the same
    # options returns 141, i.e. FAILURE exactly when the pattern MATCHED
    # (795-imz3). So this is not "the grep version is broken today" — it is a
    # size-dependent failure that would arrive silently on the first run with a
    # few hundred violations, in the code path whose whole job is to explain a
    # failure. `case` is a builtin, needs no subshell or pipe, and cannot have
    # the bug at any size.
    case "$violations" in
        *"in a fragment, folds as"*)
            echo "  CAUSE (declared): \`packets:\` is a G-Set — re-declaring a packet does NOT change its status."
            echo "  REMEDY (declared): write a NEW fragment with a \`status:\` entry (packet_id/field/value/ts/host)."
            ;;
    esac
    case "$violations" in
        *"EVENT but folds as"*)
            echo "  CAUSE (event): a terminal event was recorded without the matching \`status:\` transition. Nothing was discarded, so nothing looks wrong — the packet just stays claimable forever."
            echo "  REMEDY (event): decide which channel is telling the truth. If the closure IS real, add the \`status:\` entry. If it is NOT, the event type must match the rung — \`set-field --evidence\` derives it from the status since 696-6byc, so re-run it rather than hand-writing a terminal event."
            ;;
    esac
    echo "          See plan/index.d/README.md."
    exit 1
fi

echo "ok:no-fragment-status-loss:${checked} checked"
