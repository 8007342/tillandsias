#!/usr/bin/env bash
# test-expire-claims-reads-the-status-write.sh — 1198-7q95: the claim-expiry
# sweep must age and attribute a claim from the STATUS WRITE that set
# in_progress, not from the newest event on the row.
#
# WHY THIS EXISTS. 1065-4t7t corrected the sibling `live_claims` to read the
# status channel and left `expire_claim_candidates` on the event channel, so
# the two halves of one instrument disagreed about who holds a claim.
# MEASURED on the live ledger 2026-09-15: 888-miiy carried a status write 35
# minutes old (yoga's) and an unrelated progress event from two weeks earlier
# (another host's); the sweep reported the row as a two-week-old claim
# belonging to the wrong host, the coordinator acted on it and asked that host
# to release work it had never held, and `--write` would have returned a live
# claim to ready.
#
# Hermetic: scratch ledgers under target/plan-scratch driven through
# `--index`. Nothing touches the real ledger, and every timestamp is relative
# to a FIXED --now-epoch so the fixture cannot rot as the clock moves (a
# hardcoded absolute moment is green when written and red forever after).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

_validator="$(cd "$ROOT" && . scripts/plan-binary-probe.sh && resolve_plan_binary 2>/dev/null)" || _validator=""
case "$_validator" in ./*) _validator="$ROOT/${_validator#./}" ;; esac
if [ -z "$_validator" ]; then
    echo "skip:expire-claims-status-write:no-validator — no runnable tillandsias-plan on this host; build one: cargo build --release -p tillandsias-plan"
    echo "expire-claims-status-write: 0 passed, 0 failed (skipped)"
    exit 0
fi
PLAN="$_validator"

_tmpbase="$ROOT/target/plan-scratch"; mkdir -p "$_tmpbase" 2>/dev/null || _tmpbase="${TMPDIR:-/tmp}"
W="$(mktemp -d "$_tmpbase/expire-status-write.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM

# A fixed clock. NOW is the cutoff anchor; the TTL is 24h, so "old" is any
# stamp before NOW-24h and "recent" is anything after it.
NOW_EPOCH=1800000000          # 2027-01-15T08:00:00Z, arbitrary and fixed
OLD_TS="2026-09-01T23:04:53Z" # far outside any TTL from NOW
RECENT_TS="2027-01-15T07:36:36Z"  # 24 minutes before NOW

mk_ledger() { # mk_ledger <dir> ; base carries two in_progress packets with OLD events only
    local d="$1"; mkdir -p "$d/plan/index.d"
    cat > "$d/plan/index.yaml" <<EOF
packets:
  - packet_id: leased-fresh
    order: 1-aaaa
    status: in_progress
    kind: bug
    priority: p2
    desired_release: v0.5
    pickup_role: linux
    title: a row whose newest EVENT is ancient and whose STATUS WRITE is recent
    unscoreable: "fixture packet; not scored"
    events:
      - type: progress
        ts: "$OLD_TS"
        agent_id: "linux-hosta-claude-20260901t225307z"
        host: hosta
        summary: |-
          an unrelated progress note from a host that never claimed this row
  - packet_id: leased-stale
    order: 2-bbbb
    status: in_progress
    kind: bug
    priority: p2
    desired_release: v0.5
    pickup_role: linux
    title: a row whose STATUS WRITE is genuinely old
    unscoreable: "fixture packet; not scored"
    events:
      - type: progress
        ts: "$OLD_TS"
        agent_id: "linux-hosta-claude-20260901t225307z"
        host: hosta
        summary: |-
          an old note beside an old claim
  - packet_id: unleased-old
    order: 3-cccc
    status: in_progress
    kind: bug
    priority: p2
    desired_release: v0.5
    pickup_role: linux
    title: a base-born in_progress with events and NO status write
    unscoreable: "fixture packet; not scored"
    events:
      - type: claim
        ts: "$OLD_TS"
        agent_id: "linux-hostc-claude-20260901t225307z"
        host: hostc
        summary: |-
          claimed for cycle 2026-09-01 by hostc
EOF
}

mk_lease() { # mk_lease <dir> <file-stem> <packet_id> <ts> <host>
    cat > "$1/plan/index.d/$2.yaml" <<EOF
status:
  - packet_id: $3
    field: status
    value: in_progress
    ts: "$4"
    host: $5
EOF
}

sweep() { "$PLAN" --index "$1/plan/index.yaml" expire-claims --now-epoch "$NOW_EPOCH" 2>/dev/null | grep -v OpenSpec; }

D="$W/a"; mk_ledger "$D"
mk_lease "$D" 20270115t073636z-fresh leased-fresh "$RECENT_TS" hostb
mk_lease "$D" 20260901t230453z-stale leased-stale "$OLD_TS" hostb
OUT="$(sweep "$D")"

# ── ARM 1: the measured case — recent status write, ancient event ──────────
if printf '%s\n' "$OUT" | grep -q 'leased-fresh'; then
    bad "ARM 1: a row claimed 24 minutes ago is listed as an expire candidate"
    printf '%s\n' "$OUT" | grep 'leased-fresh' | sed 's/^/      /'
else
    ok "ARM 1: a recent STATUS WRITE beside a two-week-old event is NOT an expire candidate — the sweep reads the write, not the prose"
fi

# ── ARM 2: attribution comes from the write, not the last toucher ──────────
line="$(printf '%s\n' "$OUT" | grep 'leased-stale' || true)"
if printf '%s' "$line" | grep -q 'claimant:hostb'; then
    ok "ARM 2: a genuinely old claim IS listed, and is attributed to the host that WROTE the status (hostb), not to the host of the newest event (hosta)"
elif [ -n "$line" ]; then
    bad "ARM 2: listed but misattributed: $(printf '%s' "$line" | cut -c1-110)"
else
    bad "ARM 2: a genuinely old claim was not listed at all — the fix must not silence real candidates"
fi

# ── ARM 3: the event fallback survives, because it is deliberate ───────────
# NOT a defect: a base-born in_progress carries no claimant, so the event
# channel is the only evidence there is, and 672-bz7u treats a claim filed
# with nothing after it as the stranded signature. This arm exists because
# this row's own filed criterion said such a row should never be aged off an
# event — which reading the code showed to be wrong. Pinned so the lease fix
# cannot quietly remove the fallback.
line="$(printf '%s\n' "$OUT" | grep 'unleased-old' || true)"
if printf '%s' "$line" | grep -q 'claimant:hostc'; then
    ok "ARM 3: with NO status write the event fallback still ages and attributes the row (hostc) — deliberate, and unchanged by the fix"
else
    bad "ARM 3: the event fallback was lost: $(printf '%s' "${line:-<not listed>}" | cut -c1-110)"
fi

# ── ARM 4: a lease whose host matches no event is young, not unknown-age ───
# The event loop keeps only the claimant's own events, and a claimant recorded
# as a PLATFORM (`linux`, 772-4se9's deliberate default) matches no event
# written by a workstation. Without the claim-ts floor such a row falls
# through with no last activity at all.
D2="$W/b"; mk_ledger "$D2"
mk_lease "$D2" 20270115t073636z-plat leased-fresh "$RECENT_TS" linux
OUT2="$(sweep "$D2")"
# CAPTURE, THEN COMPARE. `if ! <pipeline>` is refused by 795-imz3 and the
# refusal is right: under pipefail a SIGPIPE from grep -q can invert the guard,
# so an arm written that way can pass for the wrong reason. Both facts are
# numbers here, and neither test consults a pipeline's exit status.
unk="$(printf '%s\n' "$OUT2" | grep -oE 'unknown_age=[0-9]+' | head -1)"
listed="$(printf '%s\n' "$OUT2" | grep -c 'leased-fresh')"
if [ "$listed" -eq 0 ] && [ "$unk" = "unknown_age=0" ]; then
    ok "ARM 4: a fresh claim whose host matches no event is neither expired nor unknown-age — setting a claim is itself activity"
else
    bad "ARM 4: unknown_age reported as '${unk:-<absent>}', leased-fresh listed=$listed (want listed=0 and unknown_age=0)"
fi

# ── ARM 5: TRACEABILITY, and it is NOT a mutation control ─────────────────
# ARMS 1 AND 2 ARE THE BEHAVIOURAL DISCRIMINATORS and they fail on the pre-fix
# code by construction: without the lease read, arm 1's row is aged off its
# 2026-09-01 event and listed, and arm 2 reports claimant:hosta (the last
# toucher) instead of hostb (the writer). Both differ in OUTPUT, not in source
# text, so this fixture needs no mutant to have teeth — which is why the check
# below is labelled for what it is. A structural grep cannot tell a live call
# from a dead one, and calling one a mutation control is how an arm passes for
# a commented-out call (measured elsewhere in this tree on 2026-09-15).
SRC="$ROOT/crates/tillandsias-plan/src/main.rs"
if [ ! -f "$SRC" ]; then
    echo "skip: ARM 5 — crate source not present (running against an installed binary)"
else
    grep -q 'ORDER 1198-7q95' "$SRC" \
        && ok "ARM 5 (traceability, not a control): expire_claim_candidates cites its order, so the next reader can find why the lease is read first" \
        || bad "ARM 5: the order citation is gone from the crate — arms 1 and 2 still carry the teeth, but the reasoning is now unfindable"
fi

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then
    echo "ok:expire-claims-reads-the-status-write"
    echo "PASS: expire-claims-reads-the-status-write $pass/$total (1198-7q95)"
    exit 0
fi
echo "FAIL: expire-claims-reads-the-status-write $pass/$total (1198-7q95)"
exit 1
