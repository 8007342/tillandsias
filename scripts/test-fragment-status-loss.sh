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

# ── 10. 785-sqe6 MUTATION: an events-ONLY fragment is still examined ────────
# THE REGRESSION THIS PACKET CLOSES. An early exit used to fire when no
# fragment declared a (packet_id, status) pair, which made the closure-event
# pass unreachable on exactly the shape `append-event` produces: an `events:`
# append with no `packets:` block. The gate printed `0 checked` and exit 0
# while pass two had never run.
S="$TDIR/eventsonly"; sandbox "$S"
cat >"$S/plan/index.d/a.yaml" <<'F'
events:
  - packet_id: alpha-packet
    event:
      type: completed
      ts: "2026-08-17T03:10:00Z"
      host: fixture
      summary: "closed via append-event; no packets block, no status entry"
F
out="$(cd "$S" && bash scripts/check-fragment-status-loss.sh 2>&1)"; rc=$?
assert "MUTATION events-only fragment still refuses" 1 \
    "alpha-packet: has a 'completed' EVENT but folds as 'ready'" "$rc" "$out"

# ── 11. 785-sqe6 NEGATIVE CONTROL: events-only against a fold that took it ──
# The same fragment shape must PASS when the transition really happened —
# otherwise scenario 10 would be satisfied by a gate that refuses every
# events-only fragment on sight.
S="$TDIR/eventsonly-ok"; sandbox "$S"
cat >"$S/plan/index.d/a.yaml" <<'F'
status:
  - packet_id: alpha-packet
    field: status
    value: completed
    ts: "2026-08-17T03:11:00Z"
    host: fixture

events:
  - packet_id: alpha-packet
    event:
      type: completed
      ts: "2026-08-17T03:11:00Z"
      host: fixture
      summary: closed WITH the status LWW entry beside it
F
out="$(cd "$S" && bash scripts/check-fragment-status-loss.sh 2>&1)"; rc=$?
assert "events-only fragment whose transition landed passes" 0 \
    "ok:no-fragment-status-loss:" "$rc" "$out"
if printf '%s' "$out" | grep -qE '^ok:no-fragment-status-loss:0 checked$'; then
    echo "FAIL: events-only pass reported 0 checked — the event pass did not run" >&2
    fail=1
else
    echo "ok: the events-only examination is visible in the checked count"
fi

# ── 12. 785-sqe6 CONTROL: genuinely nothing to examine stays fast and quiet ──
# The early exit was not wrong to exist, only wrong to depend on `declared`.
# A fragment set with neither declarations nor closure events must still be a
# silent `0 checked`, and so must an empty fragment directory.
S="$TDIR/nothing"; sandbox "$S"
cat >"$S/plan/index.d/a.yaml" <<'F'
events:
  - packet_id: alpha-packet
    event:
      type: progress
      ts: "2026-08-17T03:12:00Z"
      host: fixture
      summary: progress is not a closure
F
out="$(cd "$S" && bash scripts/check-fragment-status-loss.sh 2>&1)"; rc=$?
assert "no declarations and no closure events passes as 0 checked" 0 \
    "ok:no-fragment-status-loss:0 checked" "$rc" "$out"

S="$TDIR/emptydir"; sandbox "$S"
out="$(cd "$S" && bash scripts/check-fragment-status-loss.sh 2>&1)"; rc=$?
assert "empty fragment directory passes as 0 checked" 0 \
    "ok:no-fragment-status-loss:0 checked" "$rc" "$out"

# ── 13. 787-f7dh MUTATION: an UNPARSEABLE fragment hiding a closure ─────────
# The exact accident, reproduced rather than described: an unquoted colon-space
# inside `summary` invalidates the YAML. The fragment declares a `completed`
# event for a packet the fold still calls `ready`, so scenario 4 would refuse
# it — but the parser never gets that far. Before this packet the guard printed
# `ok` here, because "no events found" and "could not read the file" were the
# same answer.
S="$TDIR/unparseable"; sandbox "$S"
cat >"$S/plan/index.d/a.yaml" <<'F'
packets:
  - packet_id: alpha-packet
    order: 900
    status: ready
    title: "carries a closure the parser never reaches"
    events:
      - type: completed
        ts: "2026-08-17T03:12:00Z"
        host: fixture
        summary: broke the parse: an unquoted colon-space does it
F
out="$(cd "$S" && bash scripts/check-fragment-status-loss.sh 2>&1)"; rc=$?
assert "MUTATION unparseable fragment hiding a closure refuses" 1 \
    "violation:fragment-status-loss:1" "$rc" "$out"
# The refusal must NAME the file — "something failed" sends the reader hunting.
if ! printf '%s' "$out" | grep -qF 'plan/index.d/a.yaml'; then
    echo "FAIL: the refusal did not name the unparseable file; out=$out" >&2
    fail=1
else
    echo "ok: the refusal names the unparseable fragment"
fi

# ── 14. 787-f7dh NEGATIVE CONTROL: a VALID fragment with no events is quiet ──
# Distinguishes "refuses unreadable input" from "refuses input". Same shape as
# scenario 13 with the summary quoted, so the ONLY difference is parseability;
# here the closure is real and visible, so the correct answer is the scenario-4
# refusal naming the packet — not an unparseable verdict.
S="$TDIR/parseable-twin"; sandbox "$S"
cat >"$S/plan/index.d/a.yaml" <<'F'
packets:
  - packet_id: alpha-packet
    order: 900
    status: ready
    title: "same fragment, summary quoted"
    events:
      - type: completed
        ts: "2026-08-17T03:12:00Z"
        host: fixture
        summary: "broke the parse: an unquoted colon-space does it"
F
out="$(cd "$S" && bash scripts/check-fragment-status-loss.sh 2>&1)"; rc=$?
assert "the parseable twin is read and judged on its merits" 1 \
    "alpha-packet" "$rc" "$out"
if printf '%s' "$out" | grep -qF 'UNPARSEABLE'; then
    echo "FAIL: a valid fragment was reported unparseable; out=$out" >&2
    fail=1
else
    echo "ok: a valid fragment is never reported unparseable"
fi

# ── 696-6byc: the remedy must match the class that actually fired ──────────
# Before this, one cause and one remedy printed whichever class had fired, and
# both described the declared-under-`packets:` class. An author whose terminal
# EVENT disagreed with a non-terminal status was told to write a `status:`
# entry — which pushes the packet to completed rather than resolving the
# contradiction. Each scenario below carries its own cross-class negative
# control, because "prints a remedy" is satisfied by printing BOTH, and a gate
# that always prints both is exactly the misdirection being removed.
S="$TDIR/remedy-event"; sandbox "$S"
cat >"$S/plan/index.d/a.yaml" <<'F'
events:
  - packet_id: alpha-packet
    event:
      type: completed
      ts: "2026-08-17T11:20:00Z"
      host: fixture
      summary: "terminal event, no status transition — the EVENT class"
F
out="$(cd "$S" && bash scripts/check-fragment-status-loss.sh 2>&1)"; rc=$?
assert "event-class violation prints the event remedy" 1 "REMEDY (event):" "$rc" "$out"
case "$out" in
    *"REMEDY (declared):"*)
        echo "FAIL: event-class violation also printed the DECLARED remedy; out=$out" >&2
        fail=1
        ;;
    *) echo "ok: event-class violation does not print the declared remedy" ;;
esac

S="$TDIR/remedy-declared"; sandbox "$S"
cat >"$S/plan/index.d/a.yaml" <<'F'
packets:
  - packet_id: alpha-packet
    order: 900
    status: completed
    title: "terminal status declared under packets: and discarded by the G-Set"
F
out="$(cd "$S" && bash scripts/check-fragment-status-loss.sh 2>&1)"; rc=$?
assert "declared-class violation prints the declared remedy" 1 "REMEDY (declared):" "$rc" "$out"
case "$out" in
    *"REMEDY (event):"*)
        echo "FAIL: declared-class violation also printed the EVENT remedy; out=$out" >&2
        fail=1
        ;;
    *) echo "ok: declared-class violation does not print the event remedy" ;;
esac

# ── 797-qm4t: a NON-TERMINAL event on an unknown packet_id is REPORTED ──────
# The status and terminal-event channels only see a fragment that CLAIMS a
# closure. A `note` or `progress` aimed at a packet_id nobody filed is dropped
# in total silence — that is how a full set of GPU measurements for order 406
# was written against an invented id, landed nowhere, and drew four green
# signals. It is an ADVISORY, not a violation: this channel sees every note in
# an append-only corpus no one may rewrite, and 699-dycj forbids turning one
# host's typo into every host's red build.
S="$TDIR/anyevent-unknown"; sandbox "$S"
cat >"$S/plan/index.d/a.yaml" <<'F'
packets:
  - packet_id: alpha-packet
    order: 900
    status: ready
    title: "a real packet, so the fold knows something"
events:
  - packet_id: ghost-packet
    event:
      type: note
      ts: "2026-08-17T23:30:00Z"
      host: fixture
      summary: "a note addressed to a packet nobody ever filed"
F
out="$(cd "$S" && bash scripts/check-fragment-status-loss.sh 2>&1)"; rc=$?
assert "non-terminal event on an unknown packet_id is named" 0 \
    "ghost-packet: an events block addresses it but NO SUCH PACKET is in the fold" "$rc" "$out"
case "$out" in
    violation:*)
        echo "FAIL: an unknown-pid NOTE must not fail the gate (699-dycj); out=$out" >&2
        fail=1
        ;;
    *) echo "ok: unknown-pid note reports without failing the gate" ;;
esac

# NEGATIVE CONTROL: the same shape against a packet that DOES exist must stay
# silent, or the advisory becomes noise on every well-formed fragment.
S="$TDIR/anyevent-known"; sandbox "$S"
cat >"$S/plan/index.d/a.yaml" <<'F'
packets:
  - packet_id: alpha-packet
    order: 900
    status: ready
    title: "a real packet"
events:
  - packet_id: alpha-packet
    event:
      type: note
      ts: "2026-08-17T23:30:00Z"
      host: fixture
      summary: "an ordinary note on a real packet"
F
out="$(cd "$S" && bash scripts/check-fragment-status-loss.sh 2>&1)"; rc=$?
case "$out" in
    *"an events block addresses it"*)
        echo "FAIL: advisory fired on a KNOWN packet_id; out=$out" >&2
        fail=1
        ;;
    *) echo "ok: no advisory for a note on a packet the fold knows" ;;
esac

# ── 812-d45t: a packet DEFINITION under `events:` is REPORTED ───────────────
# Every gate accepts it and the fold drops it entirely. No packet_id is claimed
# as an event, so the unknown-packet channel above cannot see it either — this
# needs its own question. Advisory, not violation, for the 699-dycj reason:
# past fragments are append-only.
S="$TDIR/misplaced-definition"; sandbox "$S"
cat >"$S/plan/index.d/a.yaml" <<'F'
events:
  - packet_id: dropped-on-the-floor
    order: 999
    status: ready
    kind: bug
    title: "a packet definition written under the wrong key"
    deliverable: "should be reported, not silently discarded"
F
out="$(cd "$S" && bash scripts/check-fragment-status-loss.sh 2>&1)"; rc=$?
assert "misplaced packet definition is named" 0 \
    "dropped-on-the-floor is a packet DEFINITION under" "$rc" "$out"
case "$out" in
    violation:*) echo "FAIL: a misplaced definition must not fail the gate (699-dycj); out=$out" >&2; fail=1 ;;
    *) echo "ok: misplaced definition reports without failing the gate" ;;
esac

# NEGATIVE CONTROL: the SAME definition under the correct key must be silent,
# or the advisory fires on every well-formed fragment in the tree.
S="$TDIR/correct-definition"; sandbox "$S"
cat >"$S/plan/index.d/a.yaml" <<'F'
packets:
  - packet_id: properly-filed
    order: 999
    status: ready
    kind: bug
    title: "a packet definition under the correct key"
    deliverable: "must draw no advisory"
F
out="$(cd "$S" && bash scripts/check-fragment-status-loss.sh 2>&1)"; rc=$?
case "$out" in
    *"is a packet DEFINITION under"*)
        echo "FAIL: advisory fired on a CORRECTLY filed packet; out=$out" >&2; fail=1 ;;
    *) echo "ok: no advisory for a definition under packets:" ;;
esac

# ── 864-hv2n: awk state must not leak BETWEEN fragment files ────────────────
# The extraction kept `pid` in a global that nothing reset per file. A fragment
# whose last `  - packet_id:` is an EVENT leaves that id dangling; the next
# file's first `    status:` was then printed under it. Here a.yaml ends with a
# dangling event on beta-packet (folds in_progress) and b.yaml declares a
# terminal status for an unrelated NEW packet. The pre-fix scanner reported
# "beta-packet: declared 'completed'" — a violation against a packet no
# fragment declares, blocking a push over work nobody had touched.
S="$TDIR/cross-file-leak"; sandbox "$S"
cat >"$S/plan/index.d/a.yaml" <<'F'
events:
  - packet_id: beta-packet
    event:
      type: note
      ts: "2026-08-23T17:00:00Z"
      host: fixture
      summary: "a trailing event, deliberately the last packet_id in this file"
F
cat >"$S/plan/index.d/b.yaml" <<'F'
packets:
  - order: 902
    packet_id: gamma-fresh
    status: completed
    kind: fix
    title: "declared complete at birth in a LATER file"
    depends_on: []
F
out="$(cd "$S" && bash scripts/check-fragment-status-loss.sh 2>&1)"; rc=$?
case "$out" in
    *beta-packet*)
        echo "FAIL: status leaked across files onto beta-packet; out=$out" >&2; fail=1 ;;
    *) echo "ok: awk state does not leak between fragment files" ;;
esac
assert "a later file's own declaration is judged on its own merits" 0 "" "$rc" "$out"

# ── 864-hv2n: the house style must actually be SEEN ─────────────────────────
# Fragments open a packet with `  - order:` and put `    packet_id:` beneath it.
# The pre-fix scanner keyed on `  - packet_id:` as the item start, so it never
# matched a real packet declaration — the pass was dead for its stated purpose
# while appearing to work. This is the genuine loss it should always have
# caught: alpha-packet already exists as `ready`, so re-declaring it `completed`
# under `packets:` is discarded by the G-Set.
S="$TDIR/house-style-declaration"; sandbox "$S"
cat >"$S/plan/index.d/a.yaml" <<'F'
packets:
  - order: 900
    packet_id: alpha-packet
    status: completed
    kind: fix
    title: "re-declared terminal in house key order — the G-Set drops this"
    depends_on: []
F
out="$(cd "$S" && bash scripts/check-fragment-status-loss.sh 2>&1)"; rc=$?
assert "order-first declaration is seen and its loss refused" 1 \
    "alpha-packet" "$rc" "$out"

if [ "$fail" -eq 0 ]; then
    echo "ok: all fragment-status-loss scenarios passed"
    exit 0
fi
echo "fail: fragment-status-loss fixture scenarios failed"
exit 1
