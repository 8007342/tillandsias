#!/usr/bin/env bash
# Fixture for check-carry-forward.sh (order 831-ezea).
#
# A guard that has never been seen to FAIL is not a guard, and the claim this
# guard makes that is easiest to get wrong is the EXEMPTION: closures must not
# be named. So the two directions are both here, on the same run, over the same
# corpus shape — a fragment that touches-and-leaves-open with no next_action
# MUST be named, and a fragment that only CLOSES packets MUST NOT be. If the
# exemption were merely asserted in a comment, "advisory" would silently mean
# "advisory about everything", which is indistinguishable from noise and would
# be muted within a day.
#
# Hermetic: every scenario builds its own temp root and runs the guard there.
# The live plan/index.d is never touched, and the guard's own binary probe is
# pinned with TILLANDSIAS_PLAN_BIN so a CARGO_TARGET_DIR-exporting forge and a
# bare checkout behave identically (783-jdeh).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$ROOT/scripts/check-carry-forward.sh"
PROBE="$ROOT/scripts/plan-binary-probe.sh"
fails=0
ran=0

# Resolve the binary ONCE, by execution, through the shared probe (721-nyev).
# shellcheck source=scripts/plan-binary-probe.sh
. "$PROBE"
cd "$ROOT" || exit 2
PLAN_BIN="$(resolve_plan_binary)" || PLAN_BIN=""
if [ -z "$PLAN_BIN" ]; then
    echo "refused:no-plan-binary — build it first: cargo build --release -p tillandsias-plan" >&2
    exit 2
fi
case "$PLAN_BIN" in
    /*) ;;
    *) PLAN_BIN="$ROOT/${PLAN_BIN#./}" ;;
esac

# new_root — a temp checkout carrying the guard, the probe, and an empty
# fragment dir. Prints the path.
new_root() {
    local t
    t="$(mktemp -d "${TMPDIR:-/tmp}/carry-forward-fixture.XXXXXX")"
    mkdir -p "$t/scripts" "$t/plan/index.d"
    cp "$GUARD" "$PROBE" "$t/scripts/"
    printf '%s\n' "$t"
}

# expect <name> <root> <want-stdout> <want-exit> [plan-bin-override]
expect() {
    local name="$1" root="$2" want="$3" want_rc="$4" bin="${5:-$PLAN_BIN}"
    local got rc
    ran=$((ran + 1))
    got="$(cd "$root" && TILLANDSIAS_PLAN_BIN="$bin" bash scripts/check-carry-forward.sh 2>/dev/null)"
    rc=$?
    if [ "$got" != "$want" ] || [ "$rc" -ne "$want_rc" ]; then
        echo "FAIL: $name — got '$got' (rc=$rc), want '$want' (rc=$want_rc)" >&2
        fails=$((fails + 1))
    fi
    rm -rf "$root"
}

# ── DIRECTION 1: touched and left OPEN with no next_action is NAMED ──────────
T="$(new_root)"
printf 'events:\n  - packet_id: left-open\n    event:\n      type: progress\n      ts: "2026-08-19T00:00:00Z"\n      host: fixture\n      summary: did some of it\n' > "$T/plan/index.d/a.yaml"
expect "open-touch-is-named" "$T" "advisory:carry-forward:1 of 1 fragments" 0

# ── DIRECTION 2 (THE NEGATIVE CONTROL): a fragment that only CLOSES is NOT ───
# Same packet, same event count, same fragment count — the ONLY difference is
# that the cycle closed the packet. If this ever reports `advisory:`, the
# exemption is gone and the guard has become a packet counter.
T="$(new_root)"
printf 'events:\n  - packet_id: closed-out\n    event:\n      type: completed\n      ts: "2026-08-19T00:00:00Z"\n      host: fixture\n      summary: finished it\nstatus:\n  - packet_id: closed-out\n    field: status\n    value: completed\n    ts: "2026-08-19T00:00:00Z"\n    host: fixture\n' > "$T/plan/index.d/a.yaml"
expect "closure-is-exempt" "$T" "ok:carry-forward:0 of 1 fragments" 0

# ── Carry-forward on the LWW channel satisfies the check ────────────────────
T="$(new_root)"
printf 'events:\n  - packet_id: left-open\n    event:\n      type: progress\n      ts: "2026-08-19T00:00:00Z"\n      host: fixture\n      summary: did some of it\nstatus:\n  - packet_id: left-open\n    field: next_action\n    value: "Run scripts/check-carry-forward.sh and quote the verdict."\n    ts: "2026-08-19T00:00:00Z"\n    host: fixture\n' > "$T/plan/index.d/a.yaml"
expect "lww-next-action-satisfies" "$T" "ok:carry-forward:0 of 1 fragments" 0

# ── Carry-forward on an inline packet definition satisfies it too ───────────
T="$(new_root)"
printf 'packets:\n  - packet_id: fresh\n    order: 831-t\n    status: ready\n    title: "x"\n    next_action: "Write the fixture first."\n    events:\n      - type: filed\n        ts: "2026-08-19T00:00:00Z"\n        host: fixture\n' > "$T/plan/index.d/a.yaml"
expect "inline-next-action-satisfies" "$T" "ok:carry-forward:0 of 1 fragments" 0

# ── An EVENT-nested next_action does NOT satisfy it ─────────────────────────
# `answer.rs next_action_snippet` reads the PACKET field, so a value buried in
# an event is never printed on a `plan next` row. Accepting it would let a
# fragment pass with a carry-forward no selector can reach.
T="$(new_root)"
printf 'packets:\n  - packet_id: buried\n    order: 831-t\n    status: ready\n    title: "x"\n    events:\n      - type: progress\n        ts: "2026-08-19T00:00:00Z"\n        host: fixture\n        next_action: "invisible to plan next"\n' > "$T/plan/index.d/a.yaml"
expect "event-nested-next-action-is-not-carry-forward" "$T" "advisory:carry-forward:1 of 1 fragments" 0

# ── Mixed corpus: the count is fragments-with-gaps of fragments-checked ─────
T="$(new_root)"
printf 'events:\n  - packet_id: open-one\n    event:\n      type: note\n      ts: "2026-08-19T00:00:00Z"\n      host: fixture\n' > "$T/plan/index.d/a.yaml"
printf 'events:\n  - packet_id: closed-one\n    event:\n      type: verified\n      ts: "2026-08-19T00:00:00Z"\n      host: fixture\n' > "$T/plan/index.d/b.yaml"
printf 'events:\n  - packet_id: open-two\n    event:\n      type: progress\n      ts: "2026-08-19T00:00:00Z"\n      host: fixture\n' > "$T/plan/index.d/c.yaml"
expect "mixed-corpus-counts-fragments" "$T" "advisory:carry-forward:2 of 3 fragments" 0

# ── An UNREADABLE fragment is not an empty one (787-f7dh) ───────────────────
# It must not be counted as checked, and it must not be counted as clean. The
# hard refusal for this class is check-fragment-status-loss.sh's; here it is
# excluded from the denominator so the ratio never flatters itself.
T="$(new_root)"
printf 'packets:\n  - packet_id: x\n    events:\n      - type: note\n        summary: broke the parse: an unquoted colon-space does it\n' > "$T/plan/index.d/a.yaml"
expect "unparseable-is-not-counted-as-clean" "$T" "ok:carry-forward:0 of 0 fragments" 0

# ── A binary that predates the subcommand skips LOUDLY, never `ok` ──────────
T="$(new_root)"
printf 'events:\n  - packet_id: left-open\n    event:\n      type: note\n      ts: "2026-08-19T00:00:00Z"\n      host: fixture\n' > "$T/plan/index.d/a.yaml"
printf '#!/bin/sh\n[ "$1" = capabilities ] && { printf "status\\ncheck\\nquery\\n"; exit 0; }\nexit 1\n' > "$T/stale-plan"
chmod +x "$T/stale-plan"
expect "stale-binary-skips-loudly" "$T" "skipped:carry-forward:stale-plan-binary" 0 "$T/stale-plan"

# ── No fragments at all: the compacted checkout costs nothing and says so ────
T="$(new_root)"
expect "empty-corpus-is-ok" "$T" "ok:carry-forward:0 of 0 fragments" 0

if [ "$fails" -ne 0 ]; then
    echo "carry-forward-fixture: ${fails} of ${ran} scenarios FAILED"
    exit 1
fi
echo "carry-forward-fixture: ${ran}/${ran} scenarios pass"
