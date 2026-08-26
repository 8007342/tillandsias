#!/usr/bin/env bash
# @trace order:833-fpe7, spec:meta-orchestration
#
# Hermetic fixture for scripts/check-resumable-claim-dirt.sh.
#
# A detector that only ever says `resumable:` is the deadlock with extra
# steps — the negative controls here are the point. Six cases, each in a
# throwaway git repo with its own minimal ledger, driven through the REAL
# tillandsias-plan binary (resolved by plan-binary-probe) so the fold, the
# claim-convention match, and the TTL arithmetic are the production ones.
#
# Fixed clock: --now-epoch 1787446800 (2026-08-23T01:00:00Z), TTL 24h.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DETECTOR="$ROOT/scripts/check-resumable-claim-dirt.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
[ -f "$DETECTOR" ] || fail "detector not found: $DETECTOR"

. "$ROOT/scripts/plan-binary-probe.sh"
PLAN="$(cd "$ROOT" && resolve_plan_binary)" || fail "no runnable tillandsias-plan (build it: cargo build --release -p tillandsias-plan)"
# The probe may answer with a repo-relative path; the fixture repos have a
# different cwd, so pin it absolute before handing it through the seam.
case "$PLAN" in
    /*) ;;
    *) PLAN="$ROOT/${PLAN#./}" ;;
esac

NOW_EPOCH=1787446800  # 2026-08-23T01:00:00Z
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# scaffold <dir> <ledger-yaml>: throwaway repo with the ledger and the
# detector committed clean, so each case's dirt is exactly what it creates.
scaffold() {
    local dir="$1" ledger="$2"
    git init -q "$dir"
    mkdir -p "$dir/plan" "$dir/scripts"
    printf '%s' "$ledger" > "$dir/plan/index.yaml"
    # agent-identity.sh joined the detector's dependencies with 859-b2zc
    # (host resolution goes through the shared helper — the inline chain was
    # empty inside forge images). The fixture ships what the subject sources.
    cp "$DETECTOR" "$ROOT/scripts/plan-binary-probe.sh" \
       "$ROOT/scripts/agent-identity.sh" "$dir/scripts/"
    git -C "$dir" add -A
    git -C "$dir" -c user.name=fixture -c user.email=fixture@invalid \
        commit -q -m scaffold
}

# run <dir>: the detector under the fixture seams; stdout + "rc=<n>" captured.
run() {
    local dir="$1"
    ( cd "$dir" && \
      TILLANDSIAS_PLAN_BIN="$PLAN" \
      TILLANDSIAS_WORKSTATION=fixturehost \
      TILLANDSIAS_RESUME_NOW_EPOCH="$NOW_EPOCH" \
      bash scripts/check-resumable-claim-dirt.sh )
    echo "rc=$?"
}

LIVE_CLAIM='packets:
  - packet_id: fix-a
    order: 901-aaaa
    title: "a"
    status: in_progress
    desired_release: v0.5
    events:
      - type: note
        ts: "2026-08-23T00:00:00Z"
        host: fixturehost
        summary: claimed for cycle 2026-08-23T00:00Z
'

# --- case 1: clean tree ------------------------------------------------------
d="$WORK/clean"; scaffold "$d" "$LIVE_CLAIM"
out="$(run "$d")"
[ "$out" = "ok:clean-tree
rc=4" ] || fail "case 1: expected ok:clean-tree rc=4, got: $out"
echo "ok: case 1 — clean tree names itself"

# --- case 2 (NEGATIVE): an untracked file refuses ----------------------------
d="$WORK/untracked"; scaffold "$d" "$LIVE_CLAIM"
echo stray > "$d/stray.txt"
out="$(run "$d")"
[ "$out" = "unattributable:untracked-paths:stray.txt
rc=3" ] || fail "case 2: expected untracked refusal rc=3, got: $out"
echo "ok: case 2 — untracked dirt refused"

# --- case 3 (NEGATIVE): tracked dirt OLDER than the claim refuses ------------
d="$WORK/predates"; scaffold "$d" "$LIVE_CLAIM"
echo work > "$d/old.txt"
TZ=UTC touch -t 202608222300.00 "$d/old.txt"   # 2026-08-22T23:00Z < claim 00:00Z
git -C "$d" add old.txt
out="$(run "$d")"
[ "$out" = "unattributable:paths-predate-claim:old.txt
rc=3" ] || fail "case 3: expected predate refusal rc=3, got: $out"
echo "ok: case 3 — dirt older than the claim refused"

# --- case 4 (NEGATIVE): live claim held by ANOTHER host refuses --------------
OTHER_HOST="${LIVE_CLAIM//fixturehost/otherhost}"
d="$WORK/otherhost"; scaffold "$d" "$OTHER_HOST"
echo work > "$d/new.txt"; git -C "$d" add new.txt
out="$(run "$d")"
[ "$out" = "unattributable:no-live-claim-by-this-host
rc=3" ] || fail "case 4: expected no-own-claim refusal rc=3, got: $out"
echo "ok: case 4 — another host's claim is not ours"

# --- case 5 (NEGATIVE): own claim PAST the TTL refuses -----------------------
STALE_CLAIM="${LIVE_CLAIM//2026-08-23T00:00/2026-08-20T00:00}"
d="$WORK/staleclaim"; scaffold "$d" "$STALE_CLAIM"
echo work > "$d/new.txt"; git -C "$d" add new.txt
out="$(run "$d")"
[ "$out" = "unattributable:no-live-claim-by-this-host
rc=3" ] || fail "case 5: expected TTL refusal rc=3, got: $out"
echo "ok: case 5 — a claim past the TTL is not a resume anchor"

# --- case 6: the resumable case, naming BOTH orders --------------------------
TWO_CLAIMS="$LIVE_CLAIM"'  - packet_id: fix-b
    order: 902-bbbb
    title: "b"
    status: in_progress
    desired_release: v0.5
    events:
      - type: note
        ts: "2026-08-23T00:30:00Z"
        host: fixturehost
        summary: claimed for cycle 2026-08-23T00:30Z
'
d="$WORK/resumable"; scaffold "$d" "$TWO_CLAIMS"
echo work-a > "$d/a.txt"; echo work-b > "$d/b.txt"
git -C "$d" add a.txt b.txt
TZ=UTC touch -t 202608230045.00 "$d/a.txt" "$d/b.txt"  # after both claims
out="$(run "$d")"
[ "$out" = "resumable:901-aaaa,902-bbbb
rc=0" ] || fail "case 6: expected resumable:901-aaaa,902-bbbb rc=0, got: $out"
echo "ok: case 6 — own live claims, attributable dirt, both orders named"

echo "PASS: resumable claim dirt (6/6)"
