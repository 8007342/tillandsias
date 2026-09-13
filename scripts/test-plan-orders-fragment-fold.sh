#!/usr/bin/env bash
# @trace spec:methodology-accountability, order:832-q4mn
#
# Offline fixture for order 832-q4mn: `tillandsias-policy plan-orders` must
# check the FOLDED ledger (plan/index.yaml ⊕ plan/index.d/), not the base alone.
#
# WHY IT MATTERED. Every host on this fleet files new packets as FRAGMENTS by
# design (582-nqw5: a shared monolith conflicts between concurrent writers), so
# new order tokens — precisely where collisions happen — were invisible to the
# gate that runs on every push. A duplicate waited for whoever next compacted,
# which could be days later and on a different host. Measured before the fix: a
# fragment declaring an order the base already carried still produced
# `ok: plan orders unique`.
#
# Hermetic: builds tiny synthetic ledgers in a temp tree and points the checker
# at them with --index. Never reads the repo's real plan/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# `cargo run` prints its own noise on stderr; keep stdout+stderr together and
# let the assertions look for the verdict tokens.
run_orders() {
    ( cd "$1" && cargo run -q --manifest-path "$ROOT/Cargo.toml" \
        -p tillandsias-policy -- plan-orders --index plan/index.yaml 2>&1 ) || true
}

new_tree() {
    local d="$1"
    mkdir -p "$d/plan/index.d"
    cat > "$d/plan/index.yaml" <<'EOF'
plan_index:
  steps:
    - packet_id: alpha
      order: 700-aaaa
      status: ready
    - packet_id: beta
      order: 701-bbbb
      status: ready
EOF
}

# ---------------------------------------------------------------------------
# Case 1 — THE DEFECT. A fragment re-using a base order token must be caught.
# Red before the fix: the fragment was never read.
# ---------------------------------------------------------------------------
new_tree "$WORK/c1"
cat > "$WORK/c1/plan/index.d/collide.yaml" <<'EOF'
packets:
  - packet_id: gamma
    order: 700-aaaa
    status: ready
EOF
out="$(run_orders "$WORK/c1")"
printf '%s' "$out" | grep -q 'duplicate-order:700-aaaa' \
    || fail "case 1: a fragment colliding with the base was not detected: $out"
echo "case 1 ok: a fragment colliding with a base order is caught"

# ---------------------------------------------------------------------------
# Case 2 — CONTROL. A fragment with a fresh order must still pass, and must be
# COUNTED. Without this, a checker that flagged everything would satisfy case 1.
# ---------------------------------------------------------------------------
new_tree "$WORK/c2"
cat > "$WORK/c2/plan/index.d/fresh.yaml" <<'EOF'
packets:
  - packet_id: gamma
    order: 702-cccc
    status: ready
EOF
out="$(run_orders "$WORK/c2")"
printf '%s' "$out" | grep -q 'ok: plan orders unique' \
    || fail "case 2: a non-colliding fragment must pass: $out"
printf '%s' "$out" | grep -q '1 from fragments' \
    || fail "case 2: the fragment was not folded (count missing): $out"
echo "case 2 ok: a non-colliding fragment passes and is counted"

# ---------------------------------------------------------------------------
# Case 3 — TWO FRAGMENTS colliding with each other, neither with the base.
# This is the real multi-host shape: two hosts each file a new packet and
# neither one's gate can see the other's.
# ---------------------------------------------------------------------------
new_tree "$WORK/c3"
cat > "$WORK/c3/plan/index.d/host-a.yaml" <<'EOF'
packets:
  - packet_id: from-host-a
    order: 800-dupe
    status: ready
EOF
cat > "$WORK/c3/plan/index.d/host-b.yaml" <<'EOF'
packets:
  - packet_id: from-host-b
    order: 800-dupe
    status: ready
EOF
out="$(run_orders "$WORK/c3")"
printf '%s' "$out" | grep -q 'duplicate-order:800-dupe' \
    || fail "case 3: two colliding fragments were not detected: $out"
echo "case 3 ok: two fragments colliding with each other are caught"

# ---------------------------------------------------------------------------
# Case 4 — THE LWW CHANNEL. set-field records a terminal status in a `status:`
# channel, NOT by re-declaring under `packets:` (that would be a G-Set no-op).
# Folding only `packets:` would read every fragment-completed packet as still
# open — and "is any member open" is exactly what the duplicate rule turns on.
# A duplicate group whose other member was completed via that channel must
# grandfather, not violate.
# ---------------------------------------------------------------------------
#
# The base already has one member done; the fragment closes the OTHER, so the
# group becomes all-done and grandfathers. Grandfathering requires EVERY member
# to be terminal — a group with one open member is a genuine violation, which
# is why the base member here is already `completed`.
mkdir -p "$WORK/c4/plan/index.d"
cat > "$WORK/c4/plan/index.yaml" <<'EOF'
plan_index:
  steps:
    - packet_id: alpha
      order: 700-aaaa
      status: completed
    - packet_id: alpha-old
      order: 700-aaaa
      status: ready
EOF
cat > "$WORK/c4/plan/index.d/close-old.yaml" <<'EOF'
status:
  - packet_id: alpha-old
    field: status
    value: completed
    ts: "2026-08-19T10:00:00Z"
EOF
out="$(run_orders "$WORK/c4")"
printf '%s' "$out" | grep -q 'ok: plan orders unique' \
    || fail "case 4: a fragment-completed duplicate must grandfather, not violate: $out"
printf '%s' "$out" | grep -q '1 grandfathered' \
    || fail "case 4: expected the group to be counted as grandfathered: $out"
echo "case 4 ok: the status LWW channel is applied before the open-member test"

# ---------------------------------------------------------------------------
# Case 5 — NEGATIVE CONTROL for case 4. Without the override the SAME tree must
# violate, proving case 4 passes because the channel was read and not because
# the rule is lax.
# ---------------------------------------------------------------------------
rm "$WORK/c4/plan/index.d/close-old.yaml"
out="$(run_orders "$WORK/c4")"
printf '%s' "$out" | grep -q 'duplicate-order:700-aaaa' \
    || fail "case 5: without the status override the duplicate must violate: $out"
echo "case 5 ok: removing the override restores the violation"

echo "PASS: plan-orders fragment-fold fixture (order 832-q4mn)"
