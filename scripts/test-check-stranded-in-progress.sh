#!/usr/bin/env bash
# @trace spec:methodology-accountability
# @trace order:946-pdpi, order:641-e2qa
#
# Fixture for check-stranded-in-progress.sh's stranding predicate.
#
# THE AUTHORITATIVE PAIR (946-pdpi, exit criterion 2 as restated by the
# coordinator; the ORIGINAL wording was vacuous and is deliberately not used).
# The original asked only that "a long-worked, compacted packet is NOT flagged"
# — which the UNFIXED code guaranteed unconditionally, so that arm passed
# against the bug and had no teeth. The pair below is what discriminates:
#
#   (a) a long-worked packet whose claim is RECENT        -> NOT flagged
#   (b) a long-worked packet whose claim is STALE         -> flagged
#
# and the mutation control is that the OLD predicate — count
# progress|completed|blocked over all history, flag zero — fails (b), because
# both fixture packets carry progress events and were therefore permanently
# immune.
#
# Verdict grammar:
#   ok:stranded-fixture:<n> passed        exit 0
#   violation:stranded-fixture:<case>     exit 1
#   blocked:<reason>                      exit 2
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

# Resolve through the shared probe, never a hardcoded target/ path (721-nyev):
# an executable bit is a claim, running the binary is evidence.
. "$(dirname "${BASH_SOURCE[0]}")/plan-binary-probe.sh"
PLAN_BIN="$(resolve_plan_binary)" || { echo "blocked:no-plan-binary"; exit 2; }
[ -n "$PLAN_BIN" ] || { echo "blocked:no-plan-binary"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "blocked:no-jq"; exit 2; }

D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT

# FIXED instants plus a pinned NOW, so the fixture does not depend on the wall
# clock and needs no date arithmetic at all. `date -u -d <iso>` is GNU-only and
# BSD date SUCCEEDS with garbage, which no exit-code guard can catch (761-g36m);
# a fixture that silently computed different instants on macOS would be worse
# than one that failed there.
#   NOW    = 2026-08-31T12:00:00Z  (epoch 1788177600)
NOW_EPOCH=1788177600
RECENT="2026-08-31T11:40:00Z"   # 20 minutes before NOW  -> inside an 8h window
STALE="2026-08-28T12:00:00Z"    # 3 days before NOW      -> outside it
OLD="2026-08-01T12:00:00Z"      # 30 days before NOW     -> long-worked history

# Both packets are LONG-WORKED: each carries progress events, so the old
# predicate counted a non-zero number for both and flagged neither. They differ
# only in WHEN the most recent activity happened, which is the whole point.
cat > "$D/ledger.yaml" <<LEDGEREOF
plan_index:
  default_status_values: [ready, in_progress, completed]
packets:
  - packet_id: long-worked-recent-claim
    order: 990-aaaa
    status: in_progress
    desired_release: v0.5
    pickup_role: linux
    priority: p2
    events:
      - type: progress
        ts: "${OLD}"
        host: fixture
        summary: worked a long time ago
      - type: progress
        ts: "${RECENT}"
        host: fixture
        summary: worked just now
  - packet_id: long-worked-stale-claim
    order: 990-bbbb
    status: in_progress
    desired_release: v0.5
    pickup_role: linux
    priority: p2
    events:
      - type: progress
        ts: "${OLD}"
        host: fixture
        summary: worked a long time ago
      - type: progress
        ts: "${STALE}"
        host: fixture
        summary: last touched three days ago, then abandoned
LEDGEREOF

# The probe may return a relative path; make it absolute before baking it into
# a wrapper that runs from a temp directory.
case "$PLAN_BIN" in
    /*) PLAN_ABS="$PLAN_BIN" ;;
    *)  PLAN_ABS="$PWD/${PLAN_BIN#./}" ;;
esac
printf '#!/usr/bin/env bash\nexec "%s" --index "%s/ledger.yaml" "$@"\n' \
    "$PLAN_ABS" "$D" > "$D/plan"
chmod +x "$D/plan"

run_sweep() {
    TILLANDSIAS_PLAN_BIN="$D/plan" TILLANDSIAS_STRANDED_HOURS=8 \
        TILLANDSIAS_STRANDED_NOW_EPOCH="$NOW_EPOCH" \
        scripts/check-stranded-in-progress.sh 2>/dev/null
}

pass=0
fail=""

out="$(run_sweep)"

# (a) recent claim on a long-worked packet must NOT be flagged.
if printf '%s\n' "$out" | grep -q '^stranded.*long-worked-recent-claim'; then
    fail="${fail}recent-claim-wrongly-flagged "
else
    pass=$((pass + 1))
fi

# (b) stale claim on a long-worked packet MUST be flagged. This is the arm the
#     old predicate could not satisfy at all.
if printf '%s\n' "$out" | grep -q '^stranded.*long-worked-stale-claim'; then
    pass=$((pass + 1))
else
    fail="${fail}stale-claim-not-flagged "
fi

# The row carries its age, so a reader does not re-derive it.
if printf '%s\n' "$out" | grep -q '^stranded.*long-worked-stale-claim.*idle-since=[0-9-]*T'; then
    pass=$((pass + 1))
else
    fail="${fail}stale-row-missing-idle-since "
fi

# POPULATION is confessed, so a green cannot be misread as health over nothing.
if printf '%s\n' "$out" | grep -qE '^summary: population=2 in_progress=2 stranded=1 threshold_events=[0-9]+$'; then
    pass=$((pass + 1))
else
    fail="${fail}summary-shape:$(printf '%s\n' "$out" | grep '^summary:') "
fi

# THRESHOLD IS HONOURED, not hard-coded: at a 96h threshold the 3-day-stale
# claim is inside the window and must fall out of the report. Without this,
# a predicate that flagged on something other than age could still pass above.
out_wide="$(TILLANDSIAS_PLAN_BIN="$D/plan" TILLANDSIAS_STRANDED_HOURS=96 \
    TILLANDSIAS_STRANDED_NOW_EPOCH="$NOW_EPOCH" \
    scripts/check-stranded-in-progress.sh 2>/dev/null)"
if printf '%s\n' "$out_wide" | grep -qE '^summary: population=2 in_progress=2 stranded=0 '; then
    pass=$((pass + 1))
else
    fail="${fail}threshold-not-honoured "
fi

# A non-numeric threshold REFUSES rather than silently defaulting — a typo must
# not be able to choose a different window (the 943-unii lesson).
bad="$(TILLANDSIAS_PLAN_BIN="$D/plan" TILLANDSIAS_STRANDED_HOURS=abc \
    scripts/check-stranded-in-progress.sh 2>/dev/null)"
if printf '%s\n' "$bad" | grep -q '^summary: unavailable:bad-stranded-hours:abc$'; then
    pass=$((pass + 1))
else
    fail="${fail}bad-threshold-not-refused "
fi

if [ -n "$fail" ]; then
    echo "violation:stranded-fixture:${fail% }"
    printf '%s\n' "$out" | sed 's/^/  /'
    exit 1
fi
echo "ok:stranded-fixture:${pass} passed"
