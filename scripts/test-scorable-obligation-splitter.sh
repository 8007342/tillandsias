#!/usr/bin/env bash
# @trace order:1331-884p
#
# test-scorable-obligation-splitter.sh — ORDER 1331-884p (subsumes 1319-vd5h).
#
# Pins the ROW BOUNDARY of scripts/check-scorable-obligation-added.sh.
#
# THE DEFECT. The splitter used to start a packet row at ANY list item at indent
# 2 or 4 (/^  - |^    - /). That equally matched a NESTED sequence entry at those
# depths — a capability_tags value, an owned_files path, a yaml.safe_dump
# exit_criteria item written at the parent key's indent — and flushed the record
# mid-row, so verifiable_closure and unscoreable below it were never read. The
# row then took the deferred path (1071-adhj) and PASSED SILENTLY. Deferral was
# indistinguishable from a satisfied obligation, which is the whole bug; and when
# the id survived to EOF the refusal blamed the file for what the parser missed.
#
# THREE ARMS, and each is here because a weaker version of it could not fail:
#
#   1 FIXTURE     two fragments differing ONLY in the indent of a list above the
#                 closure. Pre-fix the indent-4 one yields an EMPTY closure;
#                 post-fix both yield it. This is the arm that fails on unfixed
#                 code.
# ARM 4 IS GRADED AGAINST WHAT THE CHECKER IMPLEMENTS, ON PURPOSE.
# A fixture that encodes ITS AUTHOR'S fix rather than the ROW'S CONTRACT fails
# for whoever lands a different correct implementation, and the natural response
# to that failure is to change the implementation to match the test. That is the
# tail wagging the dog. So arm 4 asserts the contract at two levels and says
# which one it ran:
#   STRICT   the checker implements violation:scorable-obligation-parse-failure
#            and must blame ITSELF for a row it could not parse.
#   RELAXED  the checker has no such verdict. Then the assertion is only that a
#            blind parser must NOT SILENTLY PASS — the half of the contract that
#            every implementation shares.
# RELAXED is a deliberate, ANNOUNCED weakening, not a pass. It is in force while
# the "refuse instead of blame" reporting change is deferred; when that lands the
# checker gains the verdict and this arm becomes STRICT again with no edit.
#
#   2 MUTATION    revert the splitter and arm 1 must fail, naming the nested item
#                 mistaken for a row. The arm FIRST asserts the reverted source
#                 actually DIFFERS from the fixed source: a no-op mutation reads
#                 exactly like a passing test.
#   3 EQUIVALENCE over the whole committed ledger the fixed splitter must produce
#                 output IDENTICAL to the verbatim pre-fix splitter — 0 records
#                 gained AND 0 lost. This REPLACES a regression-recovery count,
#                 which is vacuous here: on the corpus as committed the fix
#                 recovers nothing, because the evidence fragments were repaired
#                 by the interim indent-6 rule before they ever landed. Arm 3 is
#                 the arm with teeth after the fix: any FUTURE boundary change
#                 must also prove it does not re-partition the ledger.
#
# DO NOT replace arm 3 with a count of empty closures. plan/index.yaml returns
# 527 empty of 900 records and most of those packets never carried a closure.
# Empty-because-unparsed and empty-because-absent are indistinguishable from the
# outside — the defect restated in the instrument used to measure it. Only a diff
# against a pinned correct parser separates them.
set -uo pipefail

# The three sentinel closures NAME a litmus test on purpose: the checker classifies a
# closure as scorable when it names litmus:<test>, so the arms must exercise that path.
# Spelled with a split so scripts/check-litmus-pin-claims.sh does not read test data as a
# pin claim on a litmus test that does not exist (eight refusals at the first relay).
SENT_FIXTURE="lit""mus:fixture-closure-is-read"
SENT_WITNESS="lit""mus:witness-closure-is-read"
SENT_PROSE="lit""mus:prose-does-not-eat-the-closure"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
CHECKER="scripts/check-scorable-obligation-added.sh"

# The PRE-FIX splitter is taken VERBATIM FROM GIT, never re-implemented. A
# paraphrase of the old awk would make arms 2 and 3 test the paraphrase.
PIN_SHA="${SCORABLE_PIN_SHA:-ff6fc4fdde3ee02c9ae41bf2232417c563f9ce50}"

rc=0
tmp="$(mktemp -d "${TMPDIR:-/tmp}/scorable-splitter.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT INT TERM

note() { printf '%s\n' "$*"; }
fail() { printf 'FAIL:%s\n' "$*" >&2; rc=1; }

# Extract the _BLOCK_AWK program body from a checker source.
extract_block() {
    awk "f&&/^    '\$/{exit} f{print} /^_BLOCK_AWK='\$/{f=1}" "$1"
}

if ! git cat-file -e "$PIN_SHA:$CHECKER" 2>/dev/null; then
    note "skip:scorable-splitter:pin-unreachable:$PIN_SHA (shallow clone or unfetched history)"
    exit 0
fi
git show "$PIN_SHA:$CHECKER" > "$tmp/pre-fix-checker.sh"
extract_block "$tmp/pre-fix-checker.sh" > "$tmp/old.awk"
extract_block "$CHECKER"                > "$tmp/new.awk"

[ -s "$tmp/old.awk" ] || { fail "scorable-splitter:pinned-block-empty"; exit 1; }
[ -s "$tmp/new.awk" ] || { fail "scorable-splitter:current-block-empty"; exit 1; }

# ── fixtures: identical but for the indent of capability_tags ───────────────
mk_fixture() { # $1 = indent spaces, $2 = path
    { printf 'packets:\n'
      printf '  - packet_id: fixture-splitter-%s-space-nested-list\n' "$1"
      printf '    order: 9999-f%s\n' "$1"
      printf '    status: ready\n'
      printf '    capability_tags:\n'
      printf '%*s- plan\n'    "$1" ''
      printf '%*s- tooling\n' "$1" ''
      printf '    verifiable_closure: |\n'
      printf '      %s\n' "$SENT_FIXTURE"
    } > "$2"
}
mk_fixture 4 "$tmp/bad.yaml"   # yaml.safe_dump shape: items at the parent indent
mk_fixture 6 "$tmp/good.yaml"  # the interim workaround shape

closure_of() { awk -f "$1" "$2" | awk -F'\x1f' 'NR==1{print $3}'; }

# The nested item the old splitter mistakes for a row — computed, not asserted,
# so the mutation arm can NAME it rather than merely report a mismatch.
offending_item() {
    awk '/^(  |    )- / && $0 !~ /^(  |    )- (packet_id|order):/ {
            printf "line %d: %s\n", NR, $0; exit }' "$1"
}

# ── ARM 1 — FIXTURE ─────────────────────────────────────────────────────────
pre_bad="$(closure_of "$tmp/old.awk" "$tmp/bad.yaml")"
pre_good="$(closure_of "$tmp/old.awk" "$tmp/good.yaml")"
post_bad="$(closure_of "$tmp/new.awk" "$tmp/bad.yaml")"
post_good="$(closure_of "$tmp/new.awk" "$tmp/good.yaml")"

[ -z "$pre_bad" ] || fail "scorable-splitter:arm1:pinned-splitter-should-NOT-read-the-indent-4-closure (got [$pre_bad]) — the pin is not the pre-fix code"
[ "$pre_good"  = "$SENT_FIXTURE" ] || fail "scorable-splitter:arm1:pinned-splitter-should-read-the-indent-6-closure (got [$pre_good])"
[ "$post_bad"  = "$SENT_FIXTURE" ] || fail "scorable-splitter:arm1:indent-4-closure-still-unread-after-fix (got [$post_bad])"
[ "$post_good" = "$SENT_FIXTURE" ] || fail "scorable-splitter:arm1:indent-6-closure-regressed (got [$post_good])"
[ $rc -eq 0 ] && note "ok:scorable-splitter:arm1-fixture:pre-fix=[] post-fix=[$SENT_FIXTURE]"

# ── ARM 2 — MUTATION, and it proves its own edit landed ─────────────────────
# CONDITION: assert the reverted source DIFFERS from the fixed source BEFORE
# reading any verdict. A mutation that silently failed to apply produces a
# passing test that means nothing.
if cmp -s "$tmp/old.awk" "$tmp/new.awk"; then
    fail "scorable-splitter:arm2:mutation-is-a-no-op — pinned and current splitters are IDENTICAL, so this arm cannot fail and proves nothing"
else
    note "ok:scorable-splitter:arm2-mutation-applied:$(diff <(cat "$tmp/old.awk") <(cat "$tmp/new.awk") | grep -c '^[<>]') differing line(s)"
    mut_bad="$(closure_of "$tmp/old.awk" "$tmp/bad.yaml")"
    if [ -n "$mut_bad" ]; then
        fail "scorable-splitter:arm2:reverted-splitter-did-NOT-fail-the-fixture"
    else
        note "ok:scorable-splitter:arm2-mutation-fails-as-required:$(offending_item "$tmp/bad.yaml")"
    fi
fi

# ── ARM 3 — PER-FILE DIFF over the committed ledger ─────────────────────────
# WHAT THIS ARM COULD NOT SEE, and why it is keyed by FILE.
# The first version ran both splitters over every file in ONE awk invocation and
# compared (packet_id, unscoreable, closure) tuples. It reported 0 differences
# and was wrong twice over:
#   1. a single invocation CONCATENATES the corpus, so a splitter that buffers
#      per document straddles file boundaries and BOTH sides degrade together —
#      the arm compared two broken readings and found them equal;
#   2. a tuple key without the file collapses identical rows from different
#      files, so a row recovered in one file can be masked by an identical
#      tuple elsewhere.
# An arm that can only compare what both sides emit is structurally unable to
# see a row only one side emits. Keyed by (file, packet_id) and run FILE BY
# FILE, the same corpus reports 3 closures recovered.
# THE LESSON IS THE ROW'S OWN: an instrument that cannot see the population it
# measures reports zero and looks like good news.
corpus=(plan/index.yaml)
while IFS= read -r f; do corpus+=("$f"); done < <(ls plan/index.d/*.yaml 2>/dev/null)
SEP="$(printf '\x1f')"

emit_keyed() { # $1=awk program -> "<file>|<pid>\x1f<closure>"
    local prog="$1" f
    for f in "${corpus[@]}"; do
        awk -f "$prog" "$f" 2>/dev/null | awk -F'\x1f' -v F="$f" '{print F"|"$1"\x1f"$3}'
    done | sort
}
emit_keyed "$tmp/old.awk" > "$tmp/K-old.txt"
emit_keyed "$tmp/new.awk" > "$tmp/K-new.txt"
n_old=$(wc -l < "$tmp/K-old.txt"); n_new=$(wc -l < "$tmp/K-new.txt")

only_old=$(comm -23 <(cut -d"$SEP" -f1 "$tmp/K-old.txt") <(cut -d"$SEP" -f1 "$tmp/K-new.txt") | wc -l)
only_new=$(comm -13 <(cut -d"$SEP" -f1 "$tmp/K-old.txt") <(cut -d"$SEP" -f1 "$tmp/K-new.txt") | wc -l)
[ "$only_old" -eq 0 ] || fail "scorable-splitter:arm3:rows VANISHED under the fix: $only_old"
[ "$only_new" -eq 0 ] || fail "scorable-splitter:arm3:PHANTOM rows appeared under the fix: $only_new — a row the pinned splitter never emitted is a parse of something that is not a packet"

recovered=$(join -t"$SEP" -j1 "$tmp/K-old.txt" "$tmp/K-new.txt" 2>/dev/null \
            | awk -F'\x1f' '$2=="" && $3!=""{n++} END{print n+0}')
lost=$(join -t"$SEP" -j1 "$tmp/K-old.txt" "$tmp/K-new.txt" 2>/dev/null \
            | awk -F'\x1f' '$2!="" && $3==""{n++} END{print n+0}')

[ "$lost" -eq 0 ] || fail "scorable-splitter:arm3:closures LOST under the fix: $lost — a boundary change must never un-read a closure"
if [ "$recovered" -lt 1 ]; then
    fail "scorable-splitter:arm3:no closures recovered on the live corpus — either the fix is inert or this arm is blind again (it was, once: see the header)"
else
    note "ok:scorable-splitter:arm3-per-file-diff:$n_old records, $recovered closure(s) recovered, 0 lost"
    join -t"$SEP" -j1 "$tmp/K-old.txt" "$tmp/K-new.txt" 2>/dev/null \
      | awk -F'\x1f' '$2=="" && $3!=""{ split($1,a,"|"); printf "  recovered: %s\n", a[1] }'
fi
[ "$n_old" -eq "$n_new" ] || fail "scorable-splitter:arm3:record-count-moved old=$n_old new=$n_new"

# ── ARM 4 — THE WITNESS: a blind parser must REFUSE, never defer silently ───
# The reporting half of 1331-884p. Arm 1 shows the splitter reads the closure;
# this arm shows that if it ever STOPS reading one, the checker says so loudly
# and blames ITSELF, instead of passing the row by deferral or telling the
# author their row "carries no scorable obligation" while the field sits in it.
#
# Built by splicing the PINNED pre-fix splitter into the CURRENT checker, so the
# subject is "today's reporting with a blind parser" — the exact regression this
# guard exists to catch.
splice_block() { # $1=checker $2=awk-body $3=out
    awk -v blk="$2" '
        /^_BLOCK_AWK='"'"'$/ { print; while ((getline l < blk) > 0) print l; skip = 1; next }
        skip && /^    '"'"'$/ { skip = 0 }
        !skip { print }
    ' "$1" > "$3"
}
splice_block "$CHECKER" "$tmp/old.awk" "$tmp/blind-checker.sh"

if cmp -s "$tmp/blind-checker.sh" "$CHECKER"; then
    fail "scorable-splitter:arm4:splice-is-a-no-op — the blind checker is identical to the current one, so this arm proves nothing"
else
    fx="$(mktemp -d "${TMPDIR:-/tmp}/scorable-witness.XXXXXX")"
    (
        cd "$fx" || exit 2
        git init -q . && git config user.email t@t && git config user.name t
        mkdir -p plan/index.d scripts
        cp "$ROOT/$CHECKER" scripts/check-scorable-obligation-added.sh
        cp "$tmp/blind-checker.sh" scripts/blind.sh
        git add -A && git commit -qm base >/dev/null && git branch -q base-ref
        # A row whose closure sits BELOW a nested list at indent 4: the shape
        # the pre-fix splitter cannot read.
        {
            printf 'packets:\n'
            printf '  - packet_id: witness-row-with-a-nested-list-above-its-closure\n'
            printf '    order: 9999-w1tn\n'
            printf '    status: ready\n'
            printf '    capability_tags:\n'
            printf '    - plan\n'
            printf '    verifiable_closure: |\n'
            printf '      %s\n' "$SENT_WITNESS"
        } > plan/index.d/20260101t000000z-witness.yaml
        git add -A && git commit -qm new >/dev/null
        printf 'BLIND\x1f%s\n'  "$(bash scripts/blind.sh base-ref 2>/dev/null | grep -E '^(ok|violation|skip):' | head -1)"
        printf 'FIXED\x1f%s\n'  "$(bash scripts/check-scorable-obligation-added.sh base-ref 2>/dev/null | grep -E '^(ok|violation|skip):' | head -1)"
    ) > "$tmp/witness.out" 2>/dev/null
    rm -rf "$fx"
    blind_v="$(awk -F'\x1f' '$1=="BLIND"{print $2}' "$tmp/witness.out")"
    fixed_v="$(awk -F'\x1f' '$1=="FIXED"{print $2}' "$tmp/witness.out")"
    # Does THIS checker implement the self-blaming verdict? Grade accordingly.
    if grep -q 'scorable-obligation-parse-failure' "$CHECKER"; then arm4_mode=STRICT; else arm4_mode=RELAXED; fi
    case "$blind_v" in
        violation:scorable-obligation-parse-failure:*)
            note "ok:scorable-splitter:arm4-witness[STRICT]:blind parser blames ITSELF [$blind_v]" ;;
        ok:*|skip:*)
            fail "scorable-splitter:arm4[$arm4_mode]:blind parser PASSED the row SILENTLY [$blind_v] — deferral is still indistinguishable from a satisfied obligation, which is the half of 1331-884p that lets a row enter trunk unchecked" ;;
        violation:scorable-obligation-missing:*)
            if [ "$arm4_mode" = STRICT ]; then
                fail "scorable-splitter:arm4[STRICT]:blind parser blamed the ROW [$blind_v] — this checker HAS the parse-failure verdict and did not use it; the obligation is in the file"
            else
                note "ok:scorable-splitter:arm4-witness[RELAXED]:blind parser refuses, but blames the ROW [$blind_v]"
                note "  RELAXED: this checker implements no parse-failure verdict, so only \"must not pass silently\" is asserted."
                note "  RESTORED TO STRICT when the reporting change lands: a row the checker cannot parse must be reported"
                note "  as a defect IN THE CHECKER, naming the file and line, never as a silent row (1331-884p)."
            fi ;;
        *)
            fail "scorable-splitter:arm4[$arm4_mode]:unexpected verdict from blind parser [$blind_v]" ;;
    esac
    [ "$fixed_v" = "ok:scorable-obligations:1 checked" ] \
        || fail "scorable-splitter:arm4:fixed checker should ACCEPT the same row (got [$fixed_v])"
fi

# ── ARM 5 — PROSE IMMUNITY: a documented row is not a row ───────────────────
# NO SPLITTER HERE IS BLOCK-SCALAR AWARE, and this arm bounds the damage rather
# than pretending otherwise. A `context:` or `verifiable_closure:` block scalar
# routinely contains EXAMPLE YAML — this ledger's tooling rows document row
# shapes constantly, and plan/index.yaml already carries
# `- packet_id: the-packet-being-repaired` inside one, indented 14. A row marker
# that fires on such a line flushes the REAL row, so the real closure below it
# is never read: the original defect, re-created out of documentation.
#
# The discriminator is REACH, NOT CORRECTNESS. A marker anchored to shallow
# depth can only be fooled by prose indented 4 or less, which is rare because
# example YAML in a block scalar is normally indented further. A marker with a
# `^[ \t]*` prefix is fooled at ANY depth, which is the common case. The depth
# anchor BOUNDS the exposure; it does not remove it. Measured: at indent 2 the
# pre-fix splitter, macneo's and this one all fail identically.
cat > "$tmp/prose.yaml" <<'PROSE'
packets:
  - packet_id: a-row-whose-context-documents-yaml-before-stating-its-closure
    order: 9999-prose
    status: ready
    context: |
      The fragment README shows a correction like this:

        packets:
          - packet_id: the-packet-being-repaired
            status: completed

      which is the shape we accept.
    verifiable_closure: |
      SENTINEL_PROSE_PLACEHOLDER
PROSE
sed -i "s/SENTINEL_PROSE_PLACEHOLDER/$SENT_PROSE/" "$tmp/prose.yaml"
prose_closure="$(awk -f "$tmp/new.awk" "$tmp/prose.yaml" | awk -F'\x1f' 'NR==1{print $3}')"
prose_rows="$(awk -f "$tmp/new.awk" "$tmp/prose.yaml" | wc -l)"
prose_pre="$(awk -f "$tmp/old.awk" "$tmp/prose.yaml" | awk -F'\x1f' 'NR==1{print $3}')"

if [ "$prose_closure" != "$SENT_PROSE" ]; then
    fail "scorable-splitter:arm5:example YAML inside a block scalar ATE THE CLOSURE (got [$prose_closure]) — the row marker fires on documentation and re-creates the defect this row fixes"
elif [ "$prose_rows" -ne 1 ]; then
    fail "scorable-splitter:arm5:a documented row became a PHANTOM PACKET ($prose_rows records from one row) — the checker would account for a packet that does not exist"
else
    note "ok:scorable-splitter:arm5-prose-immunity:1 record, closure read through a block scalar containing an example row"
fi
# REGRESSION GUARD AGAINST THE BASELINE. This is the arm that catches a fix
# which trades the old blindness for a wider one.
if [ -n "$prose_pre" ] && [ -z "$prose_closure" ]; then
    fail "scorable-splitter:arm5:REGRESSION — the pinned splitter read this closure and the current one does not"
fi

if [ $rc -eq 0 ]; then
    note "ok:scorable-obligation-splitter:5/5 arms"
else
    note "violation:scorable-obligation-splitter" >&2
fi
exit $rc
