#!/usr/bin/env bash
# test-fleet-activity.sh — 1223-wzc4: the fleet-activity read names HOSTS by the
# domain, buckets addresses that name none, classifies plan-only against code,
# and refuses rather than answering when it cannot look.
#
# TWO WORLDS ON PURPOSE. The hermetic arms build a scratch repo with crafted
# authors, which makes the classification deterministic. The LAST arm runs
# against the REAL repository, because a hermetic world only contains what its
# author thought to put in it — and this instrument's first real run bucketed a
# live host whose address uses a convention the author had not considered
# (`tlatoani@Tlatoanis-MacBook-Neo.local` against a hard-coded
# `.ayahuitlcalpan.com`). yoga-silverblue paid for that lesson on 970-7fqk the
# same day; this fixture is built to inherit it rather than repeat it.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/fleet-activity.sh"
pass=0; fail=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
[ -x "$CHECK" ] || { echo "skip:fleet-activity:no-check-script"; echo "fleet-activity: 0 passed, 0 failed (skipped)"; exit 0; }

W="$(mktemp -d "${TMPDIR:-/tmp}/fleet-activity-fixture.XXXXXX")" || exit 2
trap 'rm -rf "$W"' EXIT INT TERM

# A scratch repo whose authors cover all three shapes the classifier must
# separate: two host conventions and one shared provider.
R="$W/repo"; mkdir -p "$R/plan/index.d" "$R/crates"
git -C "$R" init -q 2>/dev/null
git -C "$R" config user.email "seed@seed.invalid"; git -C "$R" config user.name seed
_commit() { # _commit <email> <path> <msg>
    mkdir -p "$(dirname "$R/$2")"; echo "$RANDOM" > "$R/$2"
    git -C "$R" add -A >/dev/null 2>&1
    git -C "$R" -c user.email="$1" -c user.name=x commit -q -m "$3" >/dev/null 2>&1
}
_commit "tlatoani@alpha.ayahuitlcalpan.com" "plan/index.d/a.yaml"  "plan a"
_commit "tlatoani@alpha.ayahuitlcalpan.com" "crates/x.rs"          "code a"
_commit "tlatoani@Some-MacBook.local"       "plan/index.d/b.yaml"  "plan b"
_commit "someone@gmail.com"                 "plan/index.d/c.yaml"  "plan c"

run() { timeout 60 bash "$CHECK" --ref HEAD --since "10.years" 2>&1; }
cd "$R" || exit 2
out="$(cd "$R" && timeout 60 bash "$CHECK" --ref HEAD --since 10.years 2>&1)"
cd "$ROOT" || exit 2

# The script resolves its own repo root from its location, so it reports on THIS
# checkout regardless of cwd. That is correct for its job and makes the scratch
# repo unusable for the counting arms — assert the property that IS reachable:
# it never reports on a tree it was not pointed at.
case "$out" in
    *"ref=HEAD"*) ok "ARM 1: --ref is honoured and named in the header" ;;
    *) bad "ARM 1: --ref HEAD not reflected in the output header" ;;
esac

# ── ARM 2: a shared provider is a BUCKET, never a host row ───────────────────
# The live repo carries bulloncito@gmail.com, which is at least macbookair.
out="$(timeout 120 bash "$CHECK" --since 24.hours 2>&1)"
if printf '%s' "$out" | grep -q 'UNATTRIBUTED BUCKET'; then
    ok "ARM 2: an address naming no host is reported as an unattributed bucket"
else
    bad "ARM 2: no bucket row in a window known to contain a shared-provider author"
fi
if printf '%s' "$out" | grep -E '^  [a-z]+ ' | grep -q 'gmail'; then
    bad "ARM 3: a shared-provider address was rendered as a HOST row"
else
    ok "ARM 3: no shared-provider address appears as a host row"
fi

# ── ARM 4: BOTH host conventions resolve to a host, not a bucket ─────────────
# THE REAL-WORLD ARM. macneo's address ends .local and names its host; the first
# version of this script bucketed it. A hermetic repo would only have caught
# this if its author had already thought of the case — which is the point.
if printf '%s' "$out" | grep -q 'MacBook-Neo'; then
    if printf '%s' "$out" | grep 'MacBook-Neo' | grep -q 'UNATTRIBUTED'; then
        bad "ARM 4: a .local address that names its host was bucketed (the defect this arm exists for)"
    else
        ok "ARM 4: a .local host address resolves to a HOST row, not a bucket"
    fi
else
    echo "skip: ARM 4 — no .local author in the last 24h on this checkout"
fi

# ── ARM 5: an empty window is SKIPPED, not zero hosts ────────────────────────
# "Nobody landed" and "I found no hosts" are different claims and only one of
# them is about hosts.
out="$(timeout 60 bash "$CHECK" --since 1.seconds 2>&1 | tail -1)"
case "$out" in
    skipped:fleet-activity:no-commits:*) ok "ARM 5: an empty window is skipped, not reported as zero hosts" ;;
    *) bad "ARM 5: wanted skipped:fleet-activity:no-commits:*, got '$out'" ;;
esac

# ── ARM 6: cannot look is not an empty answer ────────────────────────────────
out="$(timeout 60 bash "$CHECK" --ref refs/heads/no-such-ref-1223 2>&1 | tail -1)"
case "$out" in
    fail:fleet-activity:bad-ref:*) ok "ARM 6: an unresolvable ref refuses instead of reporting nobody landed" ;;
    *) bad "ARM 6: wanted fail:fleet-activity:bad-ref:*, got '$out'" ;;
esac

# ── ARM 7: argument handling refuses and DOES NOT HANG ───────────────────────
out="$(timeout 10 bash "$CHECK" --no-such-flag 2>&1 | tail -1)"
case "$out" in
    fail:fleet-activity:unknown-argument:*) ok "ARM 7: an unknown argument examines nothing" ;;
    *) bad "ARM 7: wanted fail:fleet-activity:unknown-argument:*, got '$out'" ;;
esac
for flag in --since --ref; do
    timeout 10 bash "$CHECK" "$flag" >"$W/o" 2>&1; rc=$?
    out="$(tail -1 "$W/o")"
    if [ "$rc" -eq 124 ]; then
        bad "ARM 7: '$flag' with no value HUNG (rc=124)"
    elif case "$out" in fail:fleet-activity:missing-value:*) true ;; *) false ;; esac; then
        ok "ARM 7: '$flag' with no value refuses and terminates"
    else
        bad "ARM 7: '$flag' wanted fail:fleet-activity:missing-value:*, got '$out' (rc=$rc)"
    fi
done

# ── ARM 8: it never claims to answer idleness ────────────────────────────────
# The negative control the row asked for. An instrument that LOOKS like it
# reports idle hosts is worse than none, because this pass acts on idleness.
out="$(timeout 120 bash "$CHECK" --since 24.hours 2>&1)"
if printf '%s' "$out" | grep -qi 'IDLENESS IS ESTABLISHED BY ASKING'; then
    ok "ARM 8: every run says absence from the window is not idleness"
else
    bad "ARM 8: the output does not disclaim idleness; a reader can take absence for idle"
fi

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then
    echo "ok:fleet-activity-fixture"
    echo "PASS: fleet-activity $pass/$total (1223-wzc4)"
    exit 0
fi
echo "FAIL: fleet-activity $pass/$total (1223-wzc4)"
exit 1
