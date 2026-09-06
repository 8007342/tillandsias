#!/usr/bin/env bash
# @trace order:977-448j, order:976-kk6x
#
# check-scorable-obligation-added.sh — refuse a NEWLY FILED packet that carries
# nothing the centicolon scorer can read, and refuse it as a GATE rather than
# asking politely.
#
# WHY "HARD" IS THE WHOLE POINT. The operator's ruling was "require it hard
# going forward", and the fleet already has the evidence for why a soft version
# is the same as none: the daily-maintenance marker existed only as prose from
# 2026-08-13 to 08-17, so "did the gate run" had no answer at all, and the
# cheapest way to satisfy it was to skip it.
#
# WHAT IS ALREADY ENFORCED, so this does not duplicate it:
# check-declared-closures-added.sh (885-92iu) refuses a new packet whose
# `verifiable_closure` NAMES a litmus test that cannot run — unresolvable or
# unbound. What it never asks is whether a closure exists AT ALL. A new packet
# with no closure, or with a closure that is pure prose, passes that gate
# silently, and is exactly the row rung 4 could not score.
#
# MEASURED (977-3dee, same day): of 563 packets, 112 carry a verifiable_closure
# and only 25 name a litmus test. Retroactive coverage came to 2.6%. That is the
# standing debt this gate must NOT red — a gate that reds the trunk on day one
# gets switched off, which is the failure the sibling packet is about. So the
# scope is NEW rows only.
#
# WHAT COUNTS AS SCORABLE. Any of:
#   * a `verifiable_closure` naming a `litmus:<test>` — the pin rung 4 used;
#   * a closure naming a `scripts/<name>.sh` — a script verdict is as
#     mechanical as a litmus test, and refusing it would push an honest author
#     toward a dishonest `unscoreable:`. ADDED after this gate refused the very
#     first real packet filed through it (994-8r3w), whose closure names a
#     script; the refusal was correct about the letter and wrong about the
#     intent, and a gate that makes the honest path harder than the escape
#     hatch is worse than no gate;
#   * a closure naming a `cargo test` invocation — same argument as the
#     script form, and ADDED for the same reason it was (1033-ev5r). This gate
#     refused a packet whose closure was
#     `cargo test -p tillandsias-headless --test vsock_listener_e2e ... passes`.
#     That verdict is as mechanical as a script's: it is a command with an exit
#     code, runnable by anyone, and a reader can check it without asking the
#     author what they meant. The author's available moves under the old
#     grammar were to invent a `scripts/` wrapper that does nothing but shell
#     out to cargo, or to write `unscoreable:` about a row that is plainly
#     scorable. Both are worse records than the cargo line. This is the
#     994-8r3w lesson recurring in a second dialect, which is itself the
#     argument for stating the PRINCIPLE — a closure is scorable when it names
#     something mechanically checkable — rather than accumulating a list of
#     blessed prefixes;
#   * an explicit `unscoreable: <reason>` — a STATED refusal.
#
# THE SECOND IS NOT A LOOPHOLE, IT IS THE POINT. Some rows genuinely close by
# other means: a measurement, a script verdict, an operator decision. Demanding
# a litmus test of all of them would make the gate unsatisfiable, and an
# unsatisfiable gate is switched off. What this refuses is SILENCE — a row that
# says nothing about how it could ever be scored. A stated reason is auditable
# and greppable; an omission is neither.
#
# THE QUESTION IS ABOUT THE FOLDED PACKET, NOT ONE FRAGMENT'S BYTES (1071-adhj).
#
# This gate used to judge each added fragment alone, and that FORCED the repair
# the ledger convention forbids. Filing a packet without an obligation reds the
# push; the author fixes it by adding a correction fragment; the push now
# carries the declaration AND the correction, and this gate still refused,
# because the declaring fragment's own bytes still lacked the block. The only
# way through was to amend the append-only fragment in place — and two hosts
# doing that to the same file on 2026-09-05 produced duplicate `unscoreable:`
# keys, unparseable fragments, and three events orphaned from their packet:
#
#   blocked:all-fragments-intact:2 damaged
#   blocked:fragment-events-land:3 event(s) attached to no packet
#
# Neither host was careless. Both checked trunk first, and trunk is the view
# 1034-whsp measured as hours stale for a platform host, so an in-place
# amendment by a second party is a race neither party can observe.
#
# THE FOLD NEEDS NO PLAN BINARY, and that is the part worth stating rather than
# assuming. A scorable obligation is MONOTONE under the ledger's G-Set union:
# once any fragment declares one for a packet, the folded packet has one, and
# nothing can take it away. So the fold for THIS predicate is a union scan, not
# a ledger reconstruction. The packet feared this gate would have to shell out
# to `tillandsias-plan` and then either BLOCK every host that has not built or
# pass silently when it could not run — 1024-c3h3 exactly. It does neither.
#
# MEASURED on this repo, 2026-09-05: one awk pass over 585 fragments plus the
# 63,445-line base costs 36ms. The second pass runs ONLY when the first found a
# packet without an obligation in its own bytes, which is the uncommon case.
# This is still a sub-second refusal with no built artifact in its path.
#
# BOTH PASSES USE ONE GRAMMAR, deliberately: the same awk block-splitter and the
# same `_scorable_p` predicate decide "is this scorable" in the declaring
# fragment and in the correction. Two spellings of the rule would let a
# correction satisfy the gate with a closure the declaration could not use.
#
# Grammar (one line on stdout, nothing else):
#   ^(ok:scorable-obligations:[0-9]+ checked|violation:scorable-obligation-missing:[0-9]+|skip:no-new-packets)$
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

BASE="${1:-origin/linux-next}"

# Fragments ADDED versus the base, plus wholly untracked ones — new debt only.
#
# NOT `mapfile` (761-g36m): it is bash-4-only and macOS ships bash 3.2, so a
# shared gate that used it would refuse to run on one host and pass vacuously
# there — a gate that cannot execute is indistinguishable from one that found
# nothing.
changed=""
_collect="$(
    { git diff --name-only --diff-filter=A "$BASE"...HEAD -- plan/index.d/ 2>/dev/null || true
      git ls-files --others --exclude-standard -- plan/index.d/ 2>/dev/null || true
    } | sort -u
)"
while IFS= read -r _f; do
    [ -n "$_f" ] || continue
    changed="$changed$_f
"
done <<EOF
$_collect
EOF

[ -n "$changed" ] || { echo "skip:no-new-packets"; exit 0; }

checked=0
violations=0
corrected=0
regime_broken=0
rdetail=""
cdetail=""
detail=""

# ONE block-splitter, used for the declaring fragment AND for the fold. Two
# copies would drift, and a correction could then satisfy the gate with a
# closure the declaration was refused for.
_BLOCK_AWK='
        function flush() {
            if (pid != "") printf "%s\x1f%s\x1f%s\x1f%s\n", pid, unscoreable, first, buf
        }
        /^  - packet_id:|^    - packet_id:/ {
            flush(); pid = $NF; first = ""; buf = ""; unscoreable = "no"; inclosure = 0; next
        }
        pid == "" { next }
        { buf = buf " " $0 }
        # An `unscoreable:` FIELD is a stated refusal and is scorable by itself.
        /^[ \t]*unscoreable:[ \t]*[^ \t]/ { unscoreable = "yes"; inclosure = 0; next }
        # verifiable_closure, block-scalar or inline.
        /^[ \t]*verifiable_closure:[ \t]*[|>]/ { inclosure = 1; next }
        /^[ \t]*verifiable_closure:[ \t]*[^ \t|>]/ {
            if (first == "") { line = $0; sub(/^[ \t]*verifiable_closure:[ \t]*/, "", line); first = line }
            inclosure = 0; next
        }
        # Any other key at field depth ends the block scalar.
        /^[ \t]*[a-z_]+:([ \t]|$)/ { inclosure = 0; next }
        inclosure == 1 {
            if (first == "") {
                line = $0; sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line)
                if (line != "") first = line
            }
            next
        }
        END { flush() }
    '

# ONE scorability predicate, same reason. See the header for why each form
# counts; the list is a grammar, not a set of blessed prefixes.
_scorable_p() {
    case "$1:$2" in
        yes:*|no:litmus:*|no:scripts/*.sh*|no:bash\ scripts/*.sh*|no:sh\ scripts/*.sh*|no:cargo\ test*|no:cargo\ run*|no:./build.sh*|no:bash\ ./build.sh*)
            return 0 ;;
    esac
    return 1
}

_PENDING="$(mktemp "${TMPDIR:-/tmp}/scorable-pending.XXXXXX")"
_SATISFIED="$(mktemp "${TMPDIR:-/tmp}/scorable-satisfied.XXXXXX")"
trap 'rm -f "$_PENDING" "$_SATISFIED"' EXIT

# ── PASS 1: the fragments this push ADDS ────────────────────────────────────
while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    # Only fragments that DEFINE packets. An events-only fragment adds no
    # obligation and must not be demanded of.
    grep -q '^packets:' "$f" 2>/dev/null || continue

    while IFS= read -r block; do
        [ -n "$block" ] || continue
        checked=$((checked + 1))
        pid="${block%%$'\x1f'*}"
        _rest="${block#*$'\x1f'}"
        unscoreable="${_rest%%$'\x1f'*}"
        _rest2="${_rest#*$'\x1f'}"
        body="${_rest2%%$'\x1f'*}"
        whole="${_rest2#*$'\x1f'}"
        # `body` is the closure's FIRST LINE, not the whole packet, and the
        # patterns are ANCHORED to it. See the header for why (1036-w2kd).
        if _scorable_p "$unscoreable" "$body"; then
            # SCORABLE. Now the SECOND question, which is a different one:
            # is the score it will produce COMPARABLE with the previous run?
            # A row that tombstones an obligation changes the denominator
            # scope, which math-foundations.yaml names as leaving the band
            # where centicolon_function is monotone (rung 3 returns
            # Regime::Broken for exactly this).
            #
            # THIS IS NOT A VIOLATION AND MUST NOT BE ONE. Tombstoning is
            # legitimate — the operator's rule at proximity.yaml:47 requires
            # it when a requirement's meaning changes. What would be wrong is
            # letting the resulting score be read as comparable. So it is
            # NAMED, loudly, and the gate still passes.
            # 1036-jamx: the DECLARATIVE forms only. A bare `tombstone`
            # substring also matches prose REFERRING to this mechanism —
            # "the tombstone/regime scan still needs" tripped it — which is
            # the same defect the scorable patterns above were just anchored
            # to fix, in this script's sibling arm. The signal stays prose
            # because the fixture's contract is prose (`notes: this row will
            # tombstone req-old`), so it is narrowed to verb forms rather
            # than moved to a field, which would change another packet's
            # design unilaterally.
            case "$whole" in
                *tombstones*|*tombstoning*|*will\ tombstone*|*tombstone:*)
                    regime_broken=$((regime_broken + 1))
                    rdetail="${rdetail}  ${f}: packet '${pid}' tombstones an obligation — its score is OUTSIDE the monotone regime and must not be compared with the previous run (977-448j)"$'\n'
                    ;;
            esac
        else
            # NOT in this fragment's bytes. That is not yet a verdict: the
            # obligation may live in a correction fragment (1071-adhj). Defer.
            printf '%s\x1f%s\n' "$pid" "$f" >> "$_PENDING"
        fi
    done < <(awk "$_BLOCK_AWK" "$f")
done <<EOF
$changed
EOF

# ── PASS 2: the FOLD, and only when pass 1 left a question open ─────────────
# A scorable obligation is monotone under the G-Set union, so scanning every
# fragment for one is the fold for this predicate. No plan binary, no built
# artifact, and it runs only in the uncommon case. Measured at 36ms over 585
# fragments plus the base.
# BUILD THE FILE LIST DEFENSIVELY. awk treats a missing operand as FATAL and
# then emits NOTHING AT ALL — not even from the files it read before reaching
# it. Measured: one readable fragment plus a non-existent plan/index.yaml
# produced zero output and rc 2. A `2>/dev/null` on the awk hides that
# completely, and the guard would silently fall back to its old per-fragment
# behaviour on any tree without a base index — refusing packets a correction
# had in fact repaired. That is a FALSE VIOLATION rather than a false pass, so
# it would have been found eventually; it would have been found by an author
# being told to edit an append-only fragment in place, which is the exact
# harm this packet exists to stop.
_fold_files=()
for _ff in plan/index.d/*.yaml plan/index.yaml; do
    [ -f "$_ff" ] && _fold_files+=("$_ff")
done

if [ -s "$_PENDING" ] && [ "${#_fold_files[@]}" -gt 0 ]; then
    while IFS= read -r block; do
        [ -n "$block" ] || continue
        _pid="${block%%$'\x1f'*}"
        _r="${block#*$'\x1f'}"
        _uns="${_r%%$'\x1f'*}"
        _r2="${_r#*$'\x1f'}"
        _bod="${_r2%%$'\x1f'*}"
        if _scorable_p "$_uns" "$_bod"; then
            printf '%s\n' "$_pid" >> "$_SATISFIED"
        fi
    done < <(awk "$_BLOCK_AWK" "${_fold_files[@]}")
fi

# ── ADJUDICATE what pass 1 deferred ─────────────────────────────────────────
while IFS= read -r row; do
    [ -n "$row" ] || continue
    pid="${row%%$'\x1f'*}"
    f="${row#*$'\x1f'}"
    if grep -Fxq "$pid" "$_SATISFIED" 2>/dev/null; then
        corrected=$((corrected + 1))
        cdetail="${cdetail}  ${f}: packet '${pid}' has no obligation in its own bytes; another fragment or the base index supplies one — accepted on the FOLDED packet (1071-adhj)"$'\n'
    else
        violations=$((violations + 1))
        detail="${detail}  ${f}: packet '${pid}' carries no scorable obligation — add a verifiable_closure naming a litmus:<test>, or an explicit 'unscoreable: <reason>' (977-448j)"$'\n'
    fi
done < "$_PENDING"

if [ "$checked" -eq 0 ]; then
    echo "skip:no-new-packets"
    exit 0
fi

if [ "$violations" -gt 0 ]; then
    echo "violation:scorable-obligation-missing:$violations"
    printf '%s' "$detail" >&2
    echo "  A new row that says nothing about how it could be scored is the row" >&2
    echo "  rung 4 could not backfill. State the pin, or state why there is none." >&2
    exit 1
fi

if [ "$corrected" -gt 0 ]; then
    printf %s "$cdetail" >&2
    echo "note:scorable-obligation-by-correction:$corrected" >&2
fi

if [ "$regime_broken" -gt 0 ]; then
    printf %s "$rdetail" >&2
    echo "note:scorable-obligation-regime-broken:$regime_broken" >&2
fi
echo "ok:scorable-obligations:$checked checked"
