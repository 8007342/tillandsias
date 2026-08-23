#!/usr/bin/env bash
# @trace order:555, spec:ci-release
#
# HARNESS AFFINITY worker selection (order 555): a forge cycle that knows
# which harness drives it (TILLANDSIAS_HOST_KIND=forge + TILLANDSIAS_AGENT)
# prefers a ready packet tagged [harness-validation, <that harness>] over the
# general backlog — so an OpenCode forge claims the OpenCode validation
# packet, not a random platform packet — and falls back to normal selection
# (never idle) when no matching packet is ready. Fixture-proven against
# scripts/select-work-batch.sh via the TILLANDSIAS_PLAN_BIN seam, the same
# wrapper-plus---index pattern litmus:cycle-batch-triage-shape uses.
#
# Vectors:
#   1 affinity fires: forge + TILLANDSIAS_AGENT=opencode + a ready
#     [harness-validation, opencode] packet -> that packet takes the batch
#     head and the header carries harness=<pid>
#   2 fallback: forge + TILLANDSIAS_AGENT=codex, no [harness-validation,
#     codex] packet ready -> normal non-empty batch, no harness= in header
#   3 forge-scoped: NON-forge host with TILLANDSIAS_AGENT set -> no harness=
#   4 dedup: the matching packet already sits in the chosen epic's batch ->
#     moved to the head, no duplicate, batch size unchanged
#   5 charset guard: a non-tag-shaped TILLANDSIAS_AGENT value -> no harness=,
#     batch intact
#
# GRAMMAR (exactly one line on stdout, last line):
#   ok:harness-affinity-selection:5
#   fail:<detail>
# Exit 0 on ok, 1 on fail.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELECTOR="$ROOT/scripts/select-work-batch.sh"
# The shared probe, not a hardcoded target/ path: an executable bit is a
# claim, running the binary is evidence (704-zcgi, 721-nyev).
. "$ROOT/scripts/plan-binary-probe.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/harness-affinity.XXXXXX")" || {
    echo "fail:mktemp"
    exit 1
}
trap 'rm -rf "$WORK"' EXIT

fail() {
    echo "fail:$1"
    exit 1
}

REAL_PLAN="$(resolve_plan_binary)" || fail "no-plan-binary (cargo build --release -p tillandsias-plan)"

# Fixture ledger A: the harness packet lives OUTSIDE the general epic.
cat > "$WORK/ledger-a.yaml" <<'EOF'
plan_index:
  default_status_values: [ready, completed]
packets:
  - packet_id: opencode-harness-validation
    order: 920-hopc
    status: ready
    desired_release: v0.5
    pickup_role: linux
    priority: p2
    release_target: harness-epic
    capability_tags: [harness-validation, opencode]
  - packet_id: general-one
    order: 920-gaaa
    status: ready
    desired_release: v0.5
    pickup_role: linux
    priority: p1
    release_target: general-epic
    capability_tags: [plan]
  - packet_id: general-two
    order: 920-gbbb
    status: ready
    desired_release: v0.5
    pickup_role: linux
    priority: p2
    release_target: general-epic
    capability_tags: [plan]
EOF

# Fixture ledger B: the harness packet lives INSIDE the only epic (dedup arm).
cat > "$WORK/ledger-b.yaml" <<'EOF'
plan_index:
  default_status_values: [ready, completed]
packets:
  - packet_id: opencode-harness-validation
    order: 920-hopc
    status: ready
    desired_release: v0.5
    pickup_role: linux
    priority: p3
    release_target: harness-epic
    capability_tags: [harness-validation, opencode]
  - packet_id: sibling-one
    order: 920-saaa
    status: ready
    desired_release: v0.5
    pickup_role: linux
    priority: p1
    release_target: harness-epic
    capability_tags: [plan]
  - packet_id: sibling-two
    order: 920-sbbb
    status: ready
    desired_release: v0.5
    pickup_role: linux
    priority: p2
    release_target: harness-epic
    capability_tags: [plan]
EOF

mk_plan() {
    printf '#!/usr/bin/env bash\nexec "%s" --index "%s" "$@"\n' "$REAL_PLAN" "$1" > "$WORK/plan"
    chmod +x "$WORK/plan"
}

# Common env: pin the tier (a 4-core CI host must not trip the low-end gate)
# and the capability set (host-tool probes stay out of the fixture).
run_selector() {
    TILLANDSIAS_PLAN_BIN="$WORK/plan" TILLANDSIAS_HOST_TIER=general \
        TILLANDSIAS_HOST_CAPS="nix" \
        "$@" bash "$SELECTOR" linux --release v0.5 --budget 3 --seed harness-fixture 2>&1
}

# ── 1: affinity fires on a forge with a matching packet ─────────────────────
mk_plan "$WORK/ledger-a.yaml"
out="$(run_selector env TILLANDSIAS_HOST_KIND=forge TILLANDSIAS_AGENT=opencode)"
printf '%s\n' "$out" | head -1 | grep -q ' harness=opencode-harness-validation' \
    || fail "v1-no-harness-note:$(printf '%s' "$out" | head -1)"
first_pid="$(printf '%s\n' "$out" | grep "^packet$(printf '\t')" | head -1 | cut -f3)"
[ "$first_pid" = "opencode-harness-validation" ] || fail "v1-head-is-$first_pid"

# ── 2: no matching packet -> normal batch, never idle ───────────────────────
out="$(run_selector env TILLANDSIAS_HOST_KIND=forge TILLANDSIAS_AGENT=codex)"
printf '%s\n' "$out" | head -1 | grep -q ' harness=' && fail "v2-harness-note-without-match"
n="$(printf '%s\n' "$out" | grep -c "^packet$(printf '\t')")"
[ "${n:-0}" -ge 1 ] || fail "v2-empty-batch"

# ── 3: scoped to forges — a bare-metal host never takes the branch ──────────
out="$(run_selector env -u TILLANDSIAS_HOST_KIND TILLANDSIAS_AGENT=opencode)"
printf '%s\n' "$out" | head -1 | grep -q ' harness=' && fail "v3-harness-note-off-forge"

# ── 4: matching packet already in the chosen epic -> moved, not duplicated ──
mk_plan "$WORK/ledger-b.yaml"
out="$(run_selector env TILLANDSIAS_HOST_KIND=forge TILLANDSIAS_AGENT=opencode)"
printf '%s\n' "$out" | head -1 | grep -q ' harness=opencode-harness-validation' \
    || fail "v4-no-harness-note"
first_pid="$(printf '%s\n' "$out" | grep "^packet$(printf '\t')" | head -1 | cut -f3)"
[ "$first_pid" = "opencode-harness-validation" ] || fail "v4-head-is-$first_pid"
dups="$(printf '%s\n' "$out" | grep "^packet$(printf '\t')" | cut -f3 | sort | uniq -d)"
[ -z "$dups" ] || fail "v4-duplicate-packet:$dups"
n="$(printf '%s\n' "$out" | grep -c "^packet$(printf '\t')")"
[ "${n:-0}" -eq 3 ] || fail "v4-size-$n-want-3"

# ── 5: a non-tag-shaped agent name falls back silently ──────────────────────
out="$(run_selector env TILLANDSIAS_HOST_KIND=forge TILLANDSIAS_AGENT='opencode; rm -rf /')"
printf '%s\n' "$out" | head -1 | grep -q ' harness=' && fail "v5-harness-note-bad-agent"
n="$(printf '%s\n' "$out" | grep -c "^packet$(printf '\t')")"
[ "${n:-0}" -ge 1 ] || fail "v5-empty-batch"

echo "ok:harness-affinity-selection:5"
exit 0
