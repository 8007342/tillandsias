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
#   ^(ok:scorable-obligations:[0-9]+ checked|violation:scorable-obligation-missing:[0-9]+|violation:scorable-obligation-parse-failure:[0-9]+|skip:no-new-packets)$
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

BASE="${1:-origin/linux-next}"

# Fragments ADDED versus the base, plus wholly untracked ones — new debt only.
#
# NOT `mapfile` (761-g36m): it is bash-4-only and macOS ships bash 3.2, so a
# shared gate that used it would refuse to run on one host and pass vacuously
# there — a gate that cannot execute is indistinguishable from one that found
# nothing.
# THREE SOURCES, AND THE THIRD IS NOT OPTIONAL (order 1101-b5rc). A fragment
# passes through three git states on its way to a push — untracked, staged,
# committed — and the first two sources cover only the first and third.
# `--diff-filter=A BASE...HEAD` is committed-only, and `ls-files --others`
# excludes the index by definition, so a STAGED path was in neither set and
# this gate could not see it.
#
# THE DANGEROUS VERDICT WAS NOT `skip:`. `skip:no-new-packets` appears only
# when nothing else is new. MEASURED on lenovinha 2026-09-06 with one
# committed valid row and one staged row carrying no obligation at all:
#
#   untracked                          -> refused, correctly
#   staged, same bytes                 -> skip:no-new-packets
#   committed-valid + staged-violating -> ok:scorable-obligations:1 checked
#
# An affirmative pass with a real count, on a tree holding exactly the row this
# gate exists to reject. The discriminator was `git add` and nothing else.
#
# The four sibling guards that share this enumeration
# (check-added-fragments-parse, check-arrival-routing,
# check-declared-closures-added, check-fragment-closure-evidence-added)
# ALREADY carry the --cached source and were measured seeing the staged row;
# this gate was the only one blind. Keep the three sources together.
changed=""
_collect="$(
    { git diff --name-only --diff-filter=A "$BASE"...HEAD -- plan/index.d/ 2>/dev/null || true
      git diff --name-only --cached --diff-filter=A -- plan/index.d/ 2>/dev/null || true
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
parse_failures=0
pdetail=""
corrected=0
regime_broken=0
rdetail=""
cdetail=""
detail=""

# ONE block-splitter, used for the declaring fragment AND for the fold. Two
# copies would drift, and a correction could then satisfy the gate with a
# closure the declaration was refused for.
#
# IT IS CHANNEL-AWARE, and that is order 1093-hzhi. A `- packet_id:` line is
# written at the SAME indent under `packets:` and under `events:`, so splitting
# on the indent alone counted an events entry as a packet row. A fragment
# carrying a new packet AND a note about an existing one — the two-channel
# shape plan/index.d/README.md documents — was therefore refused with a
# violation naming a packet that is not declared in the file. That false
# refusal was not merely noise: its obvious remedy is to add `unscoreable:` to
# the named packet, an in-place edit of a LANDED fragment, which is the exact
# operation the 2026-09-05 collision forbids. It steered authors toward the one
# repair the tree has already learned is destructive, and macuahuitl hit it the
# same night and split a closure fragment instead — which then tripped
# check-fragment-closure-evidence-added, because that guard wants the rung and
# its evidence in ONE file. The workaround for this guard is a violation of
# that one.
#
# THE DECLARING CHANNELS ARE AN ALLOWLIST, and it has two members for a
# reason. Fragments declare under `packets:`; the base index declares under
# `plan_index:` and has NO top-level `packets:` key at all. An allowlist of
# `packets` alone would silently find zero rows in plan/index.yaml and break
# PASS 2 — the monotone fold 1071-adhj added — reintroducing the false refusal
# that packet exists to prevent. An unknown channel is SKIPPED rather than
# assumed to declare: both passes then under-count, and under-counting here
# produces a loud refusal, never a silent pass.
#
# `channel` and `indecl` reset per FILE. awk carries variables across operands,
# and the fold scans every fragment plus the base in one invocation, so without
# the FNR reset a fragment with no top-level key would inherit the previous
# file'"'"'s channel.
_BLOCK_AWK='
        function flush() {
            if (pid != "") printf "%s\x1f%s\x1f%s\x1f%s\n", pid, unscoreable, first, buf
        }
        # A ROW IS A LIST ITEM WHOSE OWN SIBLING KEYS INCLUDE packet_id OR order
        # (1331-884p). It is NOT "any dash at depth 2 or 4", which is what this
        # splitter used to test.
        #
        # WHY THE OLD FORM WAS STRUCTURALLY UNABLE, not merely wrong — and this
        # is the reason to not revert it for simplicity later. Deciding whether
        # a list item begins a packet row requires the item'"'"'s OTHER lines: the
        # id may sit on the marker line (`- packet_id: x`, every fragment) or a
        # line below it (`- order: ...` then `packet_id:`, plan/index.yaml,
        # 1093-hzhi). A single-pass streaming splitter does not have those lines
        # when it must decide, so the dash-and-depth test was the only
        # information available at that point. It equally matched every NESTED
        # sequence entry at those depths — a capability_tags value, an
        # owned_files path, a yaml.safe_dump exit_criteria item written at the
        # parent key'"'"'s indent — and flushed the record mid-row. Everything below
        # it, including verifiable_closure and unscoreable, was then never read:
        # the row went to the deferred path (1071-adhj) and PASSED SILENTLY, and
        # when the id happened to survive, the refusal blamed the file for what
        # the parser failed to see.
        #
        # So the file is read WHOLE, each candidate item is classified by its own
        # keys, and only then is the field grammar replayed. The field grammar
        # below is unchanged; only the boundary decision moved.
        function item_is_row(s, e,   k) {
            for (k = s; k < e; k++) {
                if (L[k] ~ /^[ \t]*-?[ \t]*(packet_id|order):[ \t]*[^ \t]/) return 1
            }
            return 0
        }
        { L[NR] = $0 }
        END {
            n = NR
            for (i = 1; i <= n; i++) {
                if (L[i] !~ /^(  |    )- /) continue
                e = n + 1
                for (j = i + 1; j <= n; j++) {
                    if (L[j] ~ /^(  |    )- / || L[j] ~ /^[A-Za-z_][A-Za-z0-9_]*:[ \t]*$/) { e = j; break }
                }
                if (item_is_row(i, e)) rowstart[i] = 1
            }
            pid = ""; channel = ""; indecl = 0
            unscoreable = "no"; first = ""; buf = ""; inclosure = 0
            for (i = 1; i <= n; i++) {
                line = L[i]
                if (line ~ /^[A-Za-z_][A-Za-z0-9_]*:[ \t]*$/) {
                    flush(); pid = ""
                    channel = line; sub(/:[ \t]*$/, "", channel)
                    indecl = (channel == "packets" || channel == "plan_index")
                    continue
                }
                if (indecl != 1) continue
                if (rowstart[i]) {
                    flush(); pid = ""; first = ""; buf = ""; unscoreable = "no"; inclosure = 0
                }
                if (line ~ /^[ \t]*-?[ \t]*packet_id:[ \t]*[^ \t]/) {
                    if (pid == "") { nf = split(line, F, /[ \t]+/); pid = F[nf] }
                }
                if (pid == "") continue
                buf = buf " " line
                if (line ~ /^[ \t]*unscoreable:[ \t]*[^ \t]/) { unscoreable = "yes"; inclosure = 0; continue }
                if (line ~ /^[ \t]*verifiable_closure:[ \t]*[|>]/) { inclosure = 1; continue }
                if (line ~ /^[ \t]*verifiable_closure:[ \t]*[^ \t|>]/) {
                    if (first == "") {
                        v = line; sub(/^[ \t]*verifiable_closure:[ \t]*/, "", v); sub(/[ \t]+$/, "", v)
                        if (v ~ /^".*"$/ || v ~ /^\047.*\047$/) v = substr(v, 2, length(v) - 2)
                        if (v != "") first = v
                    }
                    inclosure = 0; continue
                }
                if (line ~ /^[ \t]*[a-z_]+:([ \t]|$)/) { inclosure = 0; continue }
                if (inclosure == 1) {
                    if (first == "") {
                        v = line; sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
                        if (v != "") first = v
                    }
                    continue
                }
            }
            flush()
        }
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
            # Carry WHAT THE PARSER CAPTURED (`body`, the closure's first
            # line) into the deferral. The witness below must fire only when
            # the parser captured NOTHING — a row whose closure was read and
            # is merely prose is correctly told it carries no SCORABLE
            # obligation, and calling that a parse failure would be a second
            # message that describes the parser instead of the file.
            printf '%s\x1f%s\x1f%s\n' "$pid" "$f" "$body" >> "$_PENDING"
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

# ── THE WITNESS: does the row's OWN TEXT carry what the parser did not read? ─
# ORDER 1331-884p. The refusal "carries no scorable obligation" describes what
# this script PARSED and asserts it about the FILE. When the two disagree the
# message is confidently wrong, it names an actionable remedy that is already
# present, and the reader spends their repairs on the file instead of the
# parser. Measured cost: five wrong repairs on 1330-j5is (the field's spelling,
# its block-scalar form, the row's indentation, staleness of the staged blob,
# and a known-good control copied verbatim) before anyone instrumented the awk.
#
# So before EITHER verdict — the loud one or the silent deferral — re-read the
# row out of the file with an INDEPENDENT reader. If the field is there and the
# parser did not capture it, that is a PARSE FAILURE of this script, and it is
# reported as one, naming the file and the line it could not parse. It is never
# reported as a property of the row.
_row_obligation_line() { # $1=file $2=packet_id -> "<line>:<field>" or empty
    awk -v want="$2" '
        $0 ~ /^(  |    )- (packet_id|order):/ { inrow = 0; rowstart = NR }
        $0 ~ /^[ \t]*-?[ \t]*packet_id:[ \t]*/ {
            nf = split($0, F, /[ \t]+/)
            if (F[nf] == want) inrow = 1
        }
        # AN EMPTY QUOTED SCALAR IS NOT AN OBLIGATION. `verifiable_closure: ""`
        # unquotes to nothing, which the parser deliberately keeps empty and
        # keeps refused. The parser read it correctly, so this is a silent row
        # and NOT a parse failure — witnessing it would turn a correct refusal
        # into a false accusation against the checker itself.
        inrow && $0 ~ /^[ \t]*(verifiable_closure|unscoreable):[ \t]*("")?[ \t]*$/ { next }
        inrow && $0 ~ /^[ \t]*(verifiable_closure|unscoreable):[ \t]*\047\047[ \t]*$/ { next }
        inrow && $0 ~ /^[ \t]*verifiable_closure:[ \t]*[^ \t]/ { print NR ":verifiable_closure"; exit }
        inrow && $0 ~ /^[ \t]*unscoreable:[ \t]*[^ \t]/        { print NR ":unscoreable";        exit }
    ' "$1" 2>/dev/null | head -1
}

# ── ADJUDICATE what pass 1 deferred ─────────────────────────────────────────
while IFS= read -r row; do
    [ -n "$row" ] || continue
    pid="${row%%$'\x1f'*}"
    _r="${row#*$'\x1f'}"
    f="${_r%%$'\x1f'*}"
    _captured="${_r#*$'\x1f'}"
    if [ -n "$_captured" ]; then
        _witness=""
    else
        _witness="$(_row_obligation_line "$f" "$pid")"
    fi
    if [ -n "$_witness" ]; then
        # The field IS in the row. This script failed to read it. Say THAT.
        parse_failures=$((parse_failures + 1))
        pdetail="${pdetail}  ${f}:${_witness%%:*}: packet '${pid}' carries '${_witness#*:}' at that line and this checker did not parse it — the row was NOT evaluated. This is a defect in check-scorable-obligation-added.sh, not in the fragment: do not edit the fragment to satisfy it (1331-884p)"$'\n'
    elif grep -Fxq "$pid" "$_SATISFIED" 2>/dev/null; then
        corrected=$((corrected + 1))
        cdetail="${cdetail}  ${f}: packet '${pid}' has no obligation in its own bytes; another fragment or the base index supplies one — accepted on the FOLDED packet (1071-adhj)"$'\n'
    else
        violations=$((violations + 1))
        # NAME THE NEW-TEST CASE AND ITS EXIT. A packet whose DELIVERABLE IS
        # THE TEST is refused from BOTH sides and neither message said so: this
        # guard refuses it for naming no litmus, and if the filer then names the
        # one the packet will write, check-declared-closures-added.sh refuses it
        # for naming a test nothing defines (885-92iu) and build.sh exits 1. The
        # attractive wrong turn is to declare the pin and let it dangle, which
        # is 1068-cxmf's standing defect, already four instances deep. Measured
        # 2026-09-12 filing 1130-i6xj: both refusals, in succession, same row.
        # The bind is INTENDED; only the silence about the exit was not
        # (1136-n8sh).
        detail="${detail}  ${f}: packet '${pid}' carries no scorable obligation — add a verifiable_closure naming a litmus:<test>, or an explicit 'unscoreable: <reason>' (977-448j). IF THIS PACKET'S DELIVERABLE IS THE TEST ITSELF, pinning a name nothing defines yet will be refused by 885-92iu — use 'unscoreable: unpinnable-until-the-guard-exists', name the future litmus filename in it, and write that litmus in the same commit as the thing it tests (1136-n8sh)"$'\n'
    fi
done < "$_PENDING"

if [ "$checked" -eq 0 ]; then
    echo "skip:no-new-packets"
    exit 0
fi

if [ "$parse_failures" -gt 0 ]; then
    # MORE SPECIFIC THAN "missing", and reported INSTEAD of it: a row this
    # script could not parse has not been judged, so calling it unscored would
    # be an assertion about a file nobody read.
    echo "violation:scorable-obligation-parse-failure:$parse_failures"
    printf '%s' "$pdetail" >&2
    echo "  The obligation is IN the fragment at the line named above." >&2
    echo "  A row this checker cannot parse must never pass by deferral, and" >&2
    echo "  must never be reported as a row that says nothing (1331-884p)." >&2
    exit 1
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
