#!/usr/bin/env bash
# @trace order:1067-24q6
#
# `expire-claims` must not mutate unless asked. BOTH DIRECTIONS, because half
# of this is trivially satisfiable by breaking the reaper.
#
# THE DEFECT. The subcommand defaulted to write mode. Every other read-shaped
# plan subcommand (status, query, ready, next, blocked-by) is pure, so the
# shape of the CLI teaches that asking is safe; this one released another
# host's claim as a side effect of being asked what it would do, and said
# `mode=write` only in the summary line printed AFTER the mutation.
#
# It bit THREE INDEPENDENT HOSTS on 2026-09-05 — tlatoanis-macbook-air 14:49Z
# (bare), macuahuitl 16:41Z (`--list-live`, a flag whose name says list), yoga
# 17:5xZ (bare). Every one of them caught it only by reading `git status`
# afterwards. The claim recipe in the cycle skill is `git add plan/index.d/`,
# so a cycle that probed and then claimed would have published a stranger's
# lease release with nothing in its own commit naming it.
#
# WHY THE SECOND DIRECTION IS NOT OPTIONAL. "Bare invocation writes nothing"
# passes perfectly if the reaper never writes at all, and 641-e2qa criterion 2
# (a claim with no activity in its cycle returns to ready) would be silently
# gone. Arm 2 is that criterion, kept executable here.
#
# BYTE-IDENTICAL IS THE ASSERTION, not "no fragment appeared". A checksum over
# the whole ledger tree catches a fragment written under an unexpected name, an
# in-place base edit, and a mtime-only touch that a `find -newer` would miss.
#
# WHICH ARMS ARE REGRESSION ARMS, measured rather than assumed. Against the
# pre-fix binary this fixture scores 11 failed / 5 passed. The five that pass
# pre-fix are NOT all evidence: "bare exits 0" and "--dry-run is inert" were
# already true, but arms 7 and 8 pass pre-fix only because `--write` is an
# UNKNOWN FLAG there, so the binary exits 2 without touching anything. They
# earn their keep against the fixed binary — 7 that contradictory flags are
# refused rather than silently resolved, 8 that the opt-in did not become
# "expire whatever you find" — and a reader should not count them as proof
# the defect is caught.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE="$ROOT/scripts/plan-binary-probe.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()  { printf 'ok: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1" >&2; fail=$((fail + 1)); }

# Resolve BEFORE any cd, and against $ROOT: a cwd-relative resolve inside the
# scratch tree falls through to PATH and passes only on hosts that happen to
# have the binary installed (tool-resolution-after-cd-into-scratch).
# shellcheck source=/dev/null
. "$PROBE"
PLAN="${TILLANDSIAS_PLAN_BINARY:-$(resolve_plan_binary)}" || PLAN=""
if [ -z "$PLAN" ]; then
    echo "SKIP: tillandsias-plan not built; cannot exercise the reaper"
    exit 0
fi

# 1787745600 == 2026-08-26T12:00:00Z (`date -u -d @1787745600`).
NOW=1787745600
FRESH="2026-08-26T11:00:00Z"   # inside the 24h TTL
STALE="2026-08-20T00:00:00Z"   # outside it

seed_ledger() {
    rm -rf "$WORK/plan"
    mkdir -p "$WORK/plan/index.d"
    {
        printf 'plan_index:\n  version: v1\n  root: plan/\n  steps:\n'
        printf '    - packet_id: %s\n      order: 900-aaaa\n      title: "t"\n      status: in_progress\n      kind: fix\n      depends_on: []\n' "stale-claim"
        printf '      events:\n        - type: note\n          ts: "%s"\n          host: otherhost\n          summary: |\n            claimed for cycle %s\n' "$1" "$1"
    } > "$WORK/plan/index.yaml"
}

# A checksum over CONTENT AND PATHS of the whole ledger tree.
tree_sum() { find "$WORK/plan" -type f | sort | xargs sha256sum 2>/dev/null | sha256sum | cut -d' ' -f1; }

run() { "$PLAN" --index "$WORK/plan/index.yaml" expire-claims --now-epoch "$NOW" "$@" 2>&1; }

# ---- arm 1: BARE INVOCATION IS INERT (the reported defect) ----------------
seed_ledger "$STALE"
before="$(tree_sum)"
out="$(run)"; rc=$?
after="$(tree_sum)"
if [ "$before" = "$after" ]; then
    ok "bare expire-claims leaves the ledger byte-identical"
else
    bad "bare expire-claims MUTATED the ledger (this is the defect)"
fi
[ "$rc" -eq 0 ] && ok "bare expire-claims exits 0" || bad "bare expire-claims exit $rc, want 0"
case "$out" in
    *"mode=dry-run"*) ok "bare invocation reports mode=dry-run" ;;
    *) bad "bare invocation did not report mode=dry-run: $out" ;;
esac
# It must still SEE the stale claim — inertness by blindness is not the fix.
case "$out" in
    *"expire-candidate"*"stale-claim"*) ok "bare invocation still reports the stale candidate" ;;
    *) bad "bare invocation reported no candidate; it went blind, not read-only" ;;
esac

# ---- arm 2: THE OPT-IN NAMES ITSELF (criterion 2) -------------------------
case "$out" in
    *"--write"*) ok "dry-run output names --write so the reader learns it" ;;
    *) bad "dry-run output never mentions --write: $out" ;;
esac
case "$out" in
    *"nothing has been written"*) ok "dry-run output says nothing happened yet" ;;
    *) bad "dry-run output does not say it was inert" ;;
esac

# ---- arm 3: --list-live IS ALSO INERT (the flag that bit macuahuitl) ------
seed_ledger "$STALE"
before="$(tree_sum)"
run --list-live >/dev/null
[ "$before" = "$(tree_sum)" ] \
    && ok "--list-live alone leaves the ledger byte-identical" \
    || bad "--list-live alone MUTATED the ledger"

# ---- arm 4: EXPLICIT --dry-run STILL WORKS (existing callers) -------------
seed_ledger "$STALE"
before="$(tree_sum)"
out4="$(run --dry-run)"
[ "$before" = "$(tree_sum)" ] \
    && ok "--dry-run leaves the ledger byte-identical" \
    || bad "--dry-run MUTATED the ledger"

# ---- arm 5: --write STILL EXPIRES (641-e2qa criterion 2 preserved) --------
# THE NEGATIVE CONTROL FOR EVERY ARM ABOVE. Without this, deleting the writer
# entirely would score five green arms.
seed_ledger "$STALE"
before="$(tree_sum)"
out5="$(run --write)"
if [ "$before" != "$(tree_sum)" ]; then
    ok "--write mutates the ledger"
else
    bad "--write wrote NOTHING; 641-e2qa expiry has been weakened, not preserved"
fi
case "$out5" in
    *"expired-claim"*"stale-claim"*) ok "--write reports the claim as expired" ;;
    *) bad "--write did not report expired-claim: $out5" ;;
esac
case "$out5" in
    *"mode=write"*) ok "--write reports mode=write" ;;
    *) bad "--write did not report mode=write" ;;
esac
# The status must actually be ready afterwards, not merely a fragment on disk.
folded="$("$PLAN" --index "$WORK/plan/index.yaml" status stale-claim 2>&1)"
case "$folded" in
    *ready*) ok "--write folds through to status=ready" ;;
    *) bad "--write wrote a fragment that does not fold: $folded" ;;
esac

# ---- arm 6: --apply IS ACCEPTED AS THE SAME OPT-IN ------------------------
seed_ledger "$STALE"
before="$(tree_sum)"
run --apply >/dev/null
[ "$before" != "$(tree_sum)" ] \
    && ok "--apply is accepted as the write opt-in" \
    || bad "--apply did not write"

# ---- arm 7: CONTRADICTORY FLAGS ARE REFUSED, NOT RESOLVED ----------------
seed_ledger "$STALE"
before="$(tree_sum)"
out7="$(run --write --dry-run)"; rc7=$?
[ "$rc7" -eq 2 ] && ok "--write --dry-run refused with exit 2" \
    || bad "--write --dry-run exit $rc7, want 2"
[ "$before" = "$(tree_sum)" ] \
    && ok "a refused invocation writes nothing" \
    || bad "a refused invocation MUTATED the ledger"

# ---- arm 8: A FRESH CLAIM IS NOT TOUCHED EVEN BY --write -----------------
# Distinguishes "wrote because asked" from "writes whenever asked".
seed_ledger "$FRESH"
before="$(tree_sum)"
run --write >/dev/null
[ "$before" = "$(tree_sum)" ] \
    && ok "--write leaves a within-TTL claim alone" \
    || bad "--write expired a FRESH claim"

printf 'expire-claims-write-is-opt-in: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
printf 'ok:expire-claims-write-is-opt-in:%d\n' "$pass"
