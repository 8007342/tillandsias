#!/usr/bin/env bash
# @trace order:1115-srfr, spec:ci-release
#
# Fixture for scripts/report-held-claims.sh.
#
# THE ARMS ARE WRITTEN TO RED. Each was observed failing against the state the
# script exists to fix before being kept — an arm that passes without the
# script asserts nothing, which is the failure this whole family of orders
# keeps meeting.
#
# ARM 3 IS THE ONE MOST EASILY GOT WRONG. A check that cannot run must SAY so;
# a silent zero is indistinguishable from "nothing held" and would reintroduce
# the invisibility the script removes (965-sxec).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

pass=0; fail=0
check() { # name expected-regex actual
    if printf '%s' "$3" | grep -qE "$2"; then pass=$((pass+1)); else
        fail=$((fail+1)); echo "FAIL: $1"; echo "  want=~[$2]"; echo "  got =[$(printf '%s' "$3" | head -3)]"
    fi
}

# A synthetic ledger: one packet in_progress held by `fixturehost`, one ready.
scratch() {
    local d; d="$(mktemp -d "${TMPDIR:-/tmp}/held-claims-fx.XXXXXX")"
    mkdir -p "$d/plan/index.d" "$d/scripts"
    cat > "$d/plan/index.yaml" <<'YAML'
plan_index:
  version: v1
  items:
    - packet_id: fixture-held-packet
      order: 1115-aaaa
      status: in_progress
      title: held by the fixture host
      events:
        - type: note
          ts: "2026-01-01T00:00:00Z"
          host: fixturehost
          summary: claimed for cycle by fixturehost
    - packet_id: fixture-ready-packet
      order: 1115-bbbb
      status: ready
      title: not held
YAML
    cp scripts/report-held-claims.sh scripts/plan-binary-probe.sh scripts/agent-identity.sh "$d/scripts/" 2>/dev/null
    printf '%s' "$d"
}

PLAN_REAL="$(. scripts/plan-binary-probe.sh; resolve_plan_binary 2>/dev/null || true)"

# ── ARM 1: a host holding nothing gets an AFFIRMATIVE line, never silence ────
out="$(TILLANDSIAS_PLAN_BIN="$PLAN_REAL" bash scripts/report-held-claims.sh definitely-no-such-host-1115 2>&1)"
check "a host holding nothing prints an affirmative ok line" \
    '^ok:cycle-claims-released:0 held by definitely-no-such-host-1115' "$out"

# ── ARM 2: a host that IS holding gets named, with the release command ───────
# Scoped against the LIVE ledger by asking about whichever host actually holds
# something; if the fleet holds nothing at all the arm reports that rather than
# pretending to have tested it.
holder="$("$PLAN_REAL" expire-claims --list-live 2>/dev/null | awk -F'\t' '$1=="live-claim"{print $4; exit}')"
if [ -n "$holder" ]; then
    out="$(TILLANDSIAS_PLAN_BIN="$PLAN_REAL" bash scripts/report-held-claims.sh "$holder" 2>&1)"
    check "a host that holds claims is warned and the packets are named" \
        "^warn:cycle-claims-held:[0-9]+ by $holder" "$out"
    check "the warning names the release command for each held packet" \
        'tillandsias-plan set-field .* status ready --reason' "$out"
else
    echo "note: no host currently holds a claim, so the held-arm could not run against the live ledger"
fi

# ── ARM 3: no plan binary is a NAMED skip, never a quiet pass ────────────────
stub="$(mktemp -d "${TMPDIR:-/tmp}/held-claims-nobin.XXXXXX")"
out="$(TILLANDSIAS_PLAN_BIN="$stub/does-not-exist" PATH="/usr/bin:/bin" \
    bash scripts/report-held-claims.sh somehost 2>&1)"
check "an absent plan binary is a named skip, not a quiet zero" \
    '^skip:cycle-claims:no-plan-binary' "$out"
rm -rf "$stub"

# ── ARM 4: it never fails the cycle it reports on ────────────────────────────
TILLANDSIAS_PLAN_BIN="$PLAN_REAL" bash scripts/report-held-claims.sh definitely-no-such-host-1115 >/dev/null 2>&1
check "advisory: exit 0 even in the reachable states" '^0$' "$?"

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: cycle-claims-report $pass/$total (1115-srfr)"
    exit 0
fi
echo "FAIL: cycle-claims-report $pass/$total (1115-srfr)"
exit 1
