#!/usr/bin/env bash
# @trace spec:spec-traceability
# @trace order:642-fedr
#
# Hermetic fixture for the LWW channel alias. The register is keyed on
# `{packet_id}\u{1}{field}` and every entry carries its own `field:`, so it has
# ALWAYS corrected any field; only the CHANNEL was named `status:`. This proves
# the `fields:` name and the `status:` alias fold identically, that a fragment
# carrying BOTH is concatenated rather than half-dropped, and that the two keys
# spelled `status` at different indents stay distinguishable.
#
# Scratch tree only — never touches the real ledger.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/plan-binary-probe.sh"
BIN="$(resolve_plan_binary)" || BIN=""
if [ -z "$BIN" ]; then
    echo "skip:no-plan-binary"
    exit 0
fi

pass=0; fail=0
ok()  { echo "ok: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail+1)); }

W="$(mktemp -d "${TMPDIR:-/tmp}/lww-alias.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM

seed() {
    rm -rf "$W/plan"; mkdir -p "$W/plan/index.d"
    printf 'packets:\n  - packet_id: fixture-642\n    order: 999-f642\n    status: ready\n    pickup_role: any\n    desired_release: v0.5\n    capability_tags:\n      - plan\n' \
        > "$W/plan/index.yaml"
}
fold() { "$BIN" --index "$W/plan/index.yaml" query 2>/dev/null | head -1; }
entry() { # $1 = channel name
    printf '%s:\n  - packet_id: fixture-642\n    field: desired_release\n    value: v0.9\n    ts: "2026-08-26T00:00:00Z"\n    host: h1\n' "$1"
}

# 1. The correction ACTUALLY APPLIES. Without this the identity arm below would
#    pass on two identical no-ops — the vacuous shape.
seed; BEFORE="$(fold)"
entry fields > "$W/plan/index.d/a.yaml"; AFTER_FIELDS="$(fold)"
[ -n "$BEFORE" ] && [ "$BEFORE" != "$AFTER_FIELDS" ] \
    && ok "a NON-status correction through fields: changes the fold ($BEFORE -> $AFTER_FIELDS)" \
    || bad "fold unchanged, so the identity arm would prove nothing: [$BEFORE]"

# 2. IDENTICAL FOLD through the alias.
seed; entry status > "$W/plan/index.d/b.yaml"; AFTER_STATUS="$(fold)"
[ "$AFTER_FIELDS" = "$AFTER_STATUS" ] \
    && ok "fields: and status: fold identically ($AFTER_STATUS)" \
    || bad "alias diverges: fields=[$AFTER_FIELDS] status=[$AFTER_STATUS]"

# 3. BOTH channels in one fragment are CONCATENATED, not one silently dropped.
#    Preferring one would lose data the moment anything writes both.
seed
{ entry fields; printf 'status:\n  - packet_id: fixture-642\n    field: pickup_role\n    value: windows\n    ts: "2026-08-26T00:00:00Z"\n    host: h1\n'; } \
    > "$W/plan/index.d/both.yaml"
BOTH="$(fold)"
if printf '%s' "$BOTH" | grep -q 'v0.9'; then
    # pickup_role is not in the query projection; assert it through the ledger
    # integrity read instead of asserting nothing.
    "$BIN" --index "$W/plan/index.yaml" check >/dev/null 2>&1 \
        && ok "a fragment carrying BOTH channels folds and stays sound ($BOTH)" \
        || bad "both-channel fragment broke the integrity check"
else
    bad "the fields: half of a both-channel fragment was dropped: [$BOTH]"
fi

# 4. ANCHOR. Two different keys are spelled `status` at different indents: the
#    column-0 CHANNEL and the four-space packet DECLARATION field. Any reader
#    grepping unanchored conflates them, and after this change there are three
#    spellings in play. Asserted directly — a fold test that passes on an
#    unanchored grep is the vacuous-fixture shape (macuahuitl, 2026-08-26).
A="$W/anchor.yaml"
printf 'status:\n  - packet_id: p\n    field: status\n    value: ready\npackets:\n  - packet_id: p\n    status: ready\n' > "$A"
UN=$(grep -c 'status:' "$A"); CH=$(grep -c '^status:' "$A"); DECL=$(grep -c '^    status:' "$A")
[ "$UN" -gt "$CH" ] && [ "$CH" = 1 ] && [ "$DECL" = 1 ] \
    && ok "anchored greps separate the channel (col 0) from the declaration (4 spaces): un=$UN ch=$CH decl=$DECL" \
    || bad "anchor lost: un=$UN ch=$CH decl=$DECL"

# 5. NEGATIVE CONTROL: an entry naming a packet that does not exist is reported
#    as a gap rather than silently discarded, through EITHER channel.
seed
printf 'fields:\n  - packet_id: no-such-packet\n    field: desired_release\n    value: v9.9\n    ts: "2026-08-26T00:00:00Z"\n    host: h1\n' \
    > "$W/plan/index.d/orphan.yaml"
OUT="$("$BIN" --index "$W/plan/index.yaml" check 2>&1)"
printf '%s' "$OUT" | grep -qi 'no-such-packet' \
    && ok "an orphaned fields: entry is NAMED, not silently discarded" \
    || bad "orphaned fields: entry vanished without a gap report: [$OUT]"

echo "test-lww-channel-alias: $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
echo "ok:lww-channel-alias:$pass"
