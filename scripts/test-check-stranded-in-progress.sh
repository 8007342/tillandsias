#!/usr/bin/env bash
# @trace order:882-vqe4, order:641-e2qa
#
# test-check-stranded-in-progress.sh — pin that a packet's stranded verdict does
# not depend on WHERE its history is stored.
#
# THE DEFECT THIS EXISTS TO PREVENT. The detector counted activity with a grep
# over plan/index.d/*.yaml only. Compaction folds fragments into plan/index.yaml
# as routine garbage collection, so after a fold that grep returned zero for a
# packet whose history was fully intact. Measured on the live ledger
# 2026-08-25: 865-n8vq carried 35 events in the base, the detector saw 0, and
# reported a p0 the coordinator had touched 106 minutes earlier as STRANDED.
# 641-e2qa built this check to make neglected work visible; pointing it at the
# best-tended packet in the ledger inverts it.
#
# Arm 3 is the one that keeps the fix honest: a claim with no events ANYWHERE
# must still report stranded. A check that stopped reporting anything would
# "fix" the false positive by deleting the feature.
#
# Hermetic: a scratch tree with its own plan/index.yaml and plan/index.d/,
# the real script and the real folder binary. No network, no repo ledger.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0; pass=0
ok()  { echo "ok: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail+1)); }

# shellcheck source=scripts/plan-binary-probe.sh
. "$ROOT/scripts/plan-binary-probe.sh"
PLAN="$(resolve_plan_binary)" || { echo "SKIP: no runnable plan binary"; exit 0; }
case "$PLAN" in /*) ;; *) PLAN="$ROOT/${PLAN#./}" ;; esac

W="$(mktemp -d "${TMPDIR:-/tmp}/stranded-test.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM
mkdir -p "$W/scripts" "$W/plan/index.d" "$W/target/release"
for s in check-stranded-in-progress.sh plan-binary-probe.sh agent-identity.sh; do
    [ -f "$ROOT/scripts/$s" ] && cp "$ROOT/scripts/$s" "$W/scripts/"
done
cp "$PLAN" "$W/target/release/tillandsias-plan"

# BASE: three in_progress packets.
#   base-evented   — its only events are in the BASE (the folded case)
#   frag-evented   — its only events arrive in a FRAGMENT (the overlay case)
#   never-touched  — claimed, no events anywhere (the TRUE POSITIVE)
cat > "$W/plan/index.yaml" <<'YAML'
packets:
    - order: 900-aaaa
      packet_id: base-evented
      status: in_progress
      kind: defect
      pickup_role: any
      priority: p2
      events:
        - type: claim
          ts: "2026-08-25T01:00:00Z"
        - type: progress
          ts: "2026-08-25T11:00:00Z"
    - order: 900-bbbb
      packet_id: frag-evented
      status: in_progress
      kind: defect
      pickup_role: any
      priority: p2
      events:
        - type: claim
          ts: "2026-08-25T01:00:00Z"
    - order: 900-cccc
      packet_id: never-touched
      status: in_progress
      kind: defect
      pickup_role: any
      priority: p2
      events:
        - type: claim
          ts: "2026-08-25T01:00:00Z"
YAML

cat > "$W/plan/index.d/20260825t120000z-fixture-test.yaml" <<'YAML'
events:
  - packet_id: frag-evented
    event:
      type: progress
      ts: "2026-08-25T12:00:00Z"
      host: fixture
      summary: overlay activity
YAML

run() { ( cd "$W" && bash "$W/scripts/check-stranded-in-progress.sh" 2>/dev/null ); }
verdicts() { run | sed -n 's/^stranded\t[^\t]*\t[^\t]*\t//p' | sort; }

before="$(verdicts)"
sum="$(run | sed -n 's/^summary: //p')"

# ── 1. Events in the BASE count. This is the measured regression. ──────────
printf '%s\n' "$before" | grep -qx base-evented \
    && bad "REGRESSION: a packet whose events are in the compacted base reports stranded" \
    || ok "events in the compacted base count as activity"

# ── 2. Events in the FRAGMENT overlay still count (no regression the other way).
printf '%s\n' "$before" | grep -qx frag-evented \
    && bad "a packet with fragment-overlay events reports stranded" \
    || ok "events in the fragment overlay still count as activity"

# ── 3. TRUE POSITIVE. A claim with no events anywhere MUST report stranded. ─
printf '%s\n' "$before" | grep -qx never-touched \
    && ok "a claim with no events anywhere is still reported stranded" \
    || bad "the true positive was lost — the check now reports nothing"

# ── 4. The summary counts the population it examined, not just the hits. ───
case "$sum" in
    *population=3*in_progress=3*stranded=1*) ok "summary reports population=3 stranded=1" ;;
    *) bad "summary line unexpected: $sum" ;;
esac

# ── 5. COMPACTION INVARIANCE — the property that was violated. Folding the
#      fragment into the base must not change any verdict.
{ head -n -0 "$W/plan/index.yaml"; } > "$W/plan/index.yaml.bak"
awk '
/^      packet_id: frag-evented$/ { print; infrag=1; next }
infrag && /^        - type: claim$/ {
    print; getline; print
    print "        - type: progress"
    print "          ts: \"2026-08-25T12:00:00Z\""
    infrag=0; next
}
{ print }
' "$W/plan/index.yaml.bak" > "$W/plan/index.yaml"
rm -f "$W/plan/index.d/20260825t120000z-fixture-test.yaml"
after="$(verdicts)"
[ "$before" = "$after" ] \
    && ok "verdicts are invariant under compaction (before == after)" \
    || bad "compaction changed the verdict set: before=[$before] after=[$after]"

# ── 6. MUTATION CONTROL: the pre-fix fragment-only grep must fail arm 1. ───
cp "$W/plan/index.yaml.bak" "$W/plan/index.yaml"
cat > "$W/plan/index.d/20260825t120000z-fixture-test.yaml" <<'YAML'
events:
  - packet_id: frag-evented
    event:
      type: progress
      ts: "2026-08-25T12:00:00Z"
      host: fixture
      summary: overlay activity
YAML
legacy=$( cd "$W" && grep -rh -A3 "packet_id: base-evented\$" plan/index.d/*.yaml 2>/dev/null \
    | grep -cE 'event: (progress|completed|blocked)|type: (progress|completed|blocked)' || true )
[ "${legacy:-0}" -eq 0 ] \
    && ok "MUTATION: the pre-fix fragment-only grep sees 0 events for base-evented — arm 1 has teeth" \
    || bad "mutation control did not reproduce the pre-fix blindness (saw $legacy)"

echo "test-check-stranded-in-progress: $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
