#!/usr/bin/env bash
# @trace spec:ci-release
#
# test-fragment-status-loss.sh — hermetic scenarios for the status-loss gate.
#
# ORDER 783-xyk5. The gate stopped folding the ledger once per declared packet
# and now reads it ONCE (`query --json`), joining both declaration classes in a
# single awk pass. That is a ~9x speedup on the dominant cost of every
# `./build.sh --check` — and it is exactly the kind of change that can quietly
# turn a fail-loud guard into a decorative one.
#
# So the bar for this fixture is MUTATION CONTROL, not coverage theatre: every
# class the gate exists to catch is seeded here as a real defect in a throwaway
# ledger, and the gate must still REFUSE it. A guard that got faster while
# catching less would be a regression, and these scenarios are what makes that
# statement falsifiable.
#
# Every scenario builds its own $T with a synthetic base ledger, its own
# fragments, and its own binary (the real one, or a stub for the degraded
# lanes), so nothing here depends on the repository's live ledger state.
#
# Run: scripts/test-fragment-status-loss.sh   (exit 0 = pass)

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/check-fragment-status-loss.sh"
PROBE="$ROOT/scripts/plan-binary-probe.sh"
fail=0

. "$PROBE"
REAL_PLAN="$(cd "$ROOT" && resolve_plan_binary)" || REAL_PLAN=""
if [ -z "$REAL_PLAN" ]; then
    echo "SKIP: tillandsias-plan not built; cannot exercise the fold" >&2
    exit 0
fi
case "$REAL_PLAN" in
    /*) ;;
    *) REAL_PLAN="$ROOT/${REAL_PLAN#./}" ;;
esac

# A throwaway repo: synthetic base ledger + the guard + a plan binary.
# `sandbox <dir> <binary>` — binary is the real one unless a stub is passed.
sandbox() {
    _sb_dir="$1"
    _sb_bin="${2:-$REAL_PLAN}"
    mkdir -p "$_sb_dir/scripts" "$_sb_dir/plan/index.d" "$_sb_dir/target/release"
    cp "$GUARD" "$PROBE" "$_sb_dir/scripts/"
    cp "$_sb_bin" "$_sb_dir/target/release/tillandsias-plan"
    chmod +x "$_sb_dir/target/release/tillandsias-plan"
    # Two packets, both non-terminal in the fold. Any terminal declaration or
    # closure event against these is therefore a genuine loss.
    cat >"$_sb_dir/plan/index.yaml" <<'LEDGER'
plan_index:
  version: v1
  root: plan/
  steps:
    - packet_id: alpha-packet
      order: 900
      title: "alpha"
      status: ready
      kind: fix
      depends_on: []
    - packet_id: beta-packet
      order: 901
      title: "beta"
      status: in_progress
      kind: fix
      depends_on: []
LEDGER
}

# assert <name> <expected-rc> <expected-substring-or-empty> <actual-rc> <output>
assert() {
    _a_name="$1"; _a_want_rc="$2"; _a_want="$3"; _a_rc="$4"; _a_out="$5"
    if [ "$_a_rc" != "$_a_want_rc" ]; then
        echo "FAIL: $_a_name — want rc=$_a_want_rc got rc=$_a_rc; out=$_a_out" >&2
        fail=1
        return
    fi
    if [ -n "$_a_want" ] && ! printf '%s' "$_a_out" | grep -qF "$_a_want"; then
        echo "FAIL: $_a_name — output missing '$_a_want'; out=$_a_out" >&2
        fail=1
        return
    fi
    echo "ok: $_a_name"
}

TDIR="$(mktemp -d)"
trap 'rm -rf "$TDIR"' EXIT

# ── 1. NEGATIVE CONTROL: declarations that MATCH the fold pass ──────────────
# Without this, a gate that refused everything would satisfy every scenario
# below.
S="$TDIR/clean"; sandbox "$S"
cat >"$S/plan/index.d/a.yaml" <<'F'
packets:
  - packet_id: alpha-packet
    order: 900
    status: ready
    title: "declares what the fold already says"
F
out="$(cd "$S" && bash scripts/check-fragment-status-loss.sh 2>&1)"; rc=$?
assert "matching declaration passes" 0 "ok:no-fragment-status-loss:1 checked" "$rc" "$out"

# ── 2. MUTATION: a terminal declaration the fold discarded ──────────────────
# The 635-i6vm class: `packets:` is a G-Set, so re-declaring with a new status
# is a no-op the diff makes look like a transition.
S="$TDIR/lost"; sandbox "$S"
cat >"$S/plan/index.d/a.yaml" <<'F'
packets:
  - packet_id: alpha-packet
    order: 900
    status: completed
    title: "declares completed; the fold still says ready"
F
out="$(cd "$S" && bash scripts/check-fragment-status-loss.sh 2>&1)"; rc=$?
assert "MUTATION discarded terminal declaration refuses" 1 \
    "alpha-packet: declared 'completed' in a fragment, folds as 'ready'" "$rc" "$out"

# ── 3. NEGATIVE CONTROL: a NON-terminal mismatch is not a loss ──────────────
# The fold being AHEAD of a stale `ready` declaration is correct, not a defect.
# A gate wider than the resolver's terminal set is decorative (649-b2e4).
S="$TDIR/ahead"; sandbox "$S"
cat >"$S/plan/index.d/a.yaml" <<'F'
packets:
  - packet_id: beta-packet
    order: 901
    status: ready
    title: "stale ready; the fold moved on to in_progress"
F
out="$(cd "$S" && bash scripts/check-fragment-status-loss.sh 2>&1)"; rc=$?
assert "fold ahead of a non-terminal declaration passes" 0 "ok:no-fragment-status-loss:1 checked" "$rc" "$out"

# ── 4. MUTATION: a closure EVENT with no status transition ──────────────────
# The 752-pst5 / 624-q4jj class: nothing is discarded, so nothing looks wrong,
# and the packet stays claimable forever.
S="$TDIR/event"; sandbox "$S"
cat >"$S/plan/index.d/a.yaml" <<'F'
packets:
  - packet_id: alpha-packet
    order: 900
    status: ready
    title: "a completed event, no status entry"
    events:
      - type: completed
        ts: "2026-08-17T02:30:00Z"
        host: fixture
        summary: closed without writing the status LWW entry
F
out="$(cd "$S" && bash scripts/check-fragment-status-loss.sh 2>&1)"; rc=$?
assert "MUTATION closure event without transition refuses" 1 \
    "alpha-packet: has a 'completed' EVENT but folds as 'ready'" "$rc" "$out"

# ── 5. NEGATIVE CONTROL: prose quoting the marker is not a declaration ──────
# 752-pst5's own reproduction, kept here so the batching change cannot
# reintroduce a text-level scan.
S="$TDIR/prose"; sandbox "$S"
cat >"$S/plan/index.d/a.yaml" <<'F'
packets:
  - packet_id: alpha-packet
    order: 900
    status: ready
    title: "quotes the marker in prose"
    context: |
      A host once wrote `type: completed` events with no status block.
      Quoting the marker is not an event declaration.
    events:
      - type: filed
        ts: "2026-08-17T02:30:00Z"
        host: fixture
        summary: filed
F
out="$(cd "$S" && bash scripts/check-fragment-status-loss.sh 2>&1)"; rc=$?
assert "prose quoting the marker is not a declaration" 0 "ok:no-fragment-status-loss:1 checked" "$rc" "$out"

# ── 6. 598-kibt: the per-file boundary stays isolated ───────────────────────
# The last packet of one fragment must not inherit the first closure marker of
# the next. Batching the fold must not merge the per-FILE event parse.
S="$TDIR/boundary"; sandbox "$S"
cat >"$S/plan/index.d/a.yaml" <<'F'
packets:
  - packet_id: beta-packet
    order: 901
    status: in_progress
    title: "last packet of this file, progress only"
    events:
      - type: progress
        ts: "2026-08-17T02:30:00Z"
        host: fixture
        summary: partial
F
cat >"$S/plan/index.d/b.yaml" <<'F'
packets:
  - packet_id: alpha-packet
    order: 900
    status: ready
    title: "first packet of the next file, closure event"
    events:
      - type: completed
        ts: "2026-08-17T02:31:00Z"
        host: fixture
        summary: done
F
out="$(cd "$S" && bash scripts/check-fragment-status-loss.sh 2>&1)"; rc=$?
assert "file boundary isolated: only the real closure is flagged" 1 \
    "alpha-packet: has a 'completed' EVENT but folds as 'ready'" "$rc" "$out"
if printf '%s' "$out" | grep -qF 'beta-packet'; then
    echo "FAIL: file boundary crossed — beta-packet inherited the next file's closure" >&2
    fail=1
else
    echo "ok: beta-packet did not inherit across the file boundary"
fi

# ── 7. 702-68zj: a binary predating the rule SKIPS the event pass loudly ────
# Stale host state, not a ledger defect: refuse to approximate the structural
# parse with a scanner that could invent completions.
S="$TDIR/stale"
STUB="$TDIR/stub-no-events"
cat >"$STUB" <<'STUBEOF'
#!/bin/sh
[ "$1" = capabilities ] && { printf 'status\ncheck\nquery\n'; exit 0; }
[ "$1" = status ] && { printf '900\tready\talpha-packet\n'; exit 0; }
exit 1
STUBEOF
chmod +x "$STUB"
sandbox "$S" "$STUB"
cat >"$S/plan/index.d/a.yaml" <<'F'
packets:
  - packet_id: alpha-packet
    order: 900
    status: ready
    title: "stale binary lane"
F
out="$(cd "$S" && bash scripts/check-fragment-status-loss.sh 2>&1)"; rc=$?
assert "stale binary skips the event pass loudly, not as a violation" 0 \
    "predates fragment-terminal-events" "$rc" "$out"

# ── 8. 783-xyk5 FAIL-SAFE: batch unavailable still catches the defect ───────
# The batched fold is a performance path, never a coverage boundary. A binary
# that advertises `query` but cannot serve it (or a jq-less host) must fall
# back to per-packet lookups and STILL refuse the mutation — an empty map
# silently passing every packet would be the very failure this gate exists to
# catch, reintroduced by an optimization.
S="$TDIR/fallback"
STUB="$TDIR/stub-no-query"
cat >"$STUB" <<'STUBEOF'
#!/bin/sh
[ "$1" = capabilities ] && { printf 'status\ncheck\nquery\nfragment-terminal-events\n'; exit 0; }
[ "$1" = status ] && {
    case "$2" in
        alpha-packet) printf '900\tready\talpha-packet\n'; exit 0 ;;
    esac
    exit 0
}
[ "$1" = fragment-terminal-events ] && exit 0
# `query` is advertised but deliberately unimplemented.
exit 1
STUBEOF
chmod +x "$STUB"
sandbox "$S" "$STUB"
cat >"$S/plan/index.d/a.yaml" <<'F'
packets:
  - packet_id: alpha-packet
    order: 900
    status: completed
    title: "terminal declaration, batch path unavailable"
F
out="$(cd "$S" && bash scripts/check-fragment-status-loss.sh 2>&1)"; rc=$?
assert "FAIL-SAFE unusable batch falls back and still refuses" 1 \
    "alpha-packet: declared 'completed' in a fragment, folds as 'ready'" "$rc" "$out"
if printf '%s' "$out" | grep -qF 'batched fold unavailable'; then
    echo "ok: the fallback announces itself"
else
    echo "FAIL: fallback taken silently — no note on stderr" >&2
    fail=1
fi

# ── 9. the batch path is the DEFAULT with a real binary ─────────────────────
# Negative control for scenario 8: if the fallback ran every time, scenario 8
# would pass while the speedup silently never happened.
S="$TDIR/batchdefault"; sandbox "$S"
cat >"$S/plan/index.d/a.yaml" <<'F'
packets:
  - packet_id: alpha-packet
    order: 900
    status: ready
    title: "real binary, batch path expected"
F
out="$(cd "$S" && bash scripts/check-fragment-status-loss.sh 2>&1)"; rc=$?
if printf '%s' "$out" | grep -qF 'batched fold unavailable'; then
    echo "FAIL: real binary fell back to per-packet lookups; the speedup is not live" >&2
    fail=1
else
    echo "ok: real binary uses the batched fold"
fi

if [ "$fail" -eq 0 ]; then
    echo "ok: all fragment-status-loss scenarios passed"
    exit 0
fi
echo "fail: fragment-status-loss fixture scenarios failed"
exit 1
