#!/usr/bin/env bash
# @trace order:1247-3e64, order:1247-amcu
#
# Fixture for 1247-amcu slice 3: every refused:fragments-to-trunk:* verdict of
# push-plan-fragments-to-trunk.sh is followed by "  why: ..." and
# "  remedy: ..." on stderr, its verdict line unchanged, and a hook refusal is
# reported by its REAL cause.
#
# Hermetic: a bare scratch origin whose linux-next carries a minimal ledger
# (packets: []), a clone carrying the lane and its two helpers, and a stub
# pre-push hook (core.hooksPath) standing in for the real one.
#
#   1  usage                why/remedy (a flag the script does not take)
#   2  not-a-git-checkout   why/remedy (run from a directory in no repository)
#   3  missing              why/remedy; REMEDY EXECUTED (omit the path) -> ok
#   4  push, stale plan binary: the stub hook prints what the real hook prints
#      for a stale binary: the plan-only lane's "REFUSED ... STALE" line and its
#      REMEDY, then the generic "pre-push refused: the tree changed since
#      ./build.sh --check last passed". The verdict MUST name the stale binary
#      and the remedy MUST carry the cargo build, not send the reader to a full
#      gate. PRE-FIX RESULT: FAILS (the verdict quoted the stamp line: measured
#      on yolanda 2026-09-27/28). REMEDY EXECUTED: the stub's "binary rebuilt"
#      flag is set (standing in for the cargo build) -> the same command lands.
#   5  STATIC: every refused:fragments-to-trunk:* echo in the script's CODE
#      (comment lines stripped, so the usage header cannot satisfy it) is
#      followed within four lines by an _afford call. Covers the sites a
#      scratch origin cannot induce (fetch, trunk-fold, raced, exists, ...).
#
#   PASS: ok:plan-fragments-lane-affordance:<n>
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LANE="$ROOT/scripts/push-plan-fragments-to-trunk.sh"
[ -f "$LANE" ] || { echo "skip:plan-fragments-lane-affordance:lane-absent"; exit 0; }
# shellcheck source=scripts/plan-binary-probe.sh
. "$ROOT/scripts/plan-binary-probe.sh"
PLAN="$(cd "$ROOT" && resolve_plan_binary 2>/dev/null)" \
    || { echo "skip:plan-fragments-lane-affordance:no-plan-binary"; exit 0; }
case "$PLAN" in /*|[A-Za-z]:*) ;; *) PLAN="$ROOT/${PLAN#./}" ;; esac

W="$(mktemp -d)" || exit 1
trap 'rm -rf "$W"' EXIT
pass=0; fail=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
has_afford() { # <output> -> both lines present
    local out="$1"
    case "$out" in *"  why: "*) ;; *) return 1 ;; esac
    case "$out" in *"  remedy: "*) return 0 ;; esac
    return 1
}

# The scratch origin and a working clone.
git init -q --bare "$W/origin.git"
git init -q "$W/seed"
git -C "$W/seed" config user.email f@x.invalid; git -C "$W/seed" config user.name f
mkdir -p "$W/seed/plan"; printf 'packets: []\n' > "$W/seed/plan/index.yaml"
git -C "$W/seed" add -A >/dev/null 2>&1; git -C "$W/seed" commit -qm base
git -C "$W/seed" push -q "$W/origin.git" HEAD:refs/heads/linux-next
git clone -q -b linux-next "$W/origin.git" "$W/work" 2>/dev/null
C="$W/work"
git -C "$C" config user.email f@x.invalid; git -C "$C" config user.name f
mkdir -p "$C/scripts" "$C/plan/index.d" "$W/hooks"
cp "$LANE" "$ROOT/scripts/plan-binary-probe.sh" "$ROOT/scripts/agent-identity.sh" "$C/scripts/"
# The stub hook: refuses like the real hook does for a STALE plan binary until
# the "rebuilt" flag exists.
cat > "$W/hooks/pre-push" <<EOF
#!/bin/sh
[ -f "$W/rebuilt" ] && exit 0
echo "plan-only lane: REFUSED — the resolved plan binary is STALE (full gate required)"
echo "  REMEDY: cargo build --release -p tillandsias-plan && bash scripts/check-plan-binary-current.sh"
echo ""
echo "✗ pre-push refused: the tree changed since ./build.sh --check last passed"
exit 1
EOF
chmod +x "$W/hooks/pre-push"
git -C "$C" config core.hooksPath "$W/hooks"
lane() { (cd "$C" && TILLANDSIAS_PLAN_BIN="$PLAN" bash scripts/push-plan-fragments-to-trunk.sh "$@" 2>&1); }
frag() { # <name> -> a valid new packet fragment
    printf '%s\n' 'packets:' "  - packet_id: fixture-$1" "    order: 1-$1" '    status: ready' "    title: fixture $1" \
        > "$C/plan/index.d/20260928t00000$2z-fixture-$1.yaml"
}

# 1 usage
o1="$(lane --bogus)"
if [[ "$o1" == *"refused:fragments-to-trunk:usage:--bogus"* ]] && has_afford "$o1"; then
    ok "1 usage carries why/remedy"
else bad "1 usage: $(printf '%s' "$o1" | tail -3 | tr '\n' ';')"; fi

# 2 not-a-git-checkout
mkdir -p "$W/nogit"
o2="$(cd "$W/nogit" && TILLANDSIAS_PLAN_BIN="$PLAN" GIT_CEILING_DIRECTORIES="$W" bash "$C/scripts/push-plan-fragments-to-trunk.sh" 2>&1)"
if [[ "$o2" == *"refused:fragments-to-trunk:not-a-git-checkout"* ]] && has_afford "$o2"; then
    ok "2 not-a-git-checkout carries why/remedy"
else bad "2 not-a-git-checkout: $(printf '%s' "$o2" | tail -3 | tr '\n' ';')"; fi

# 3 missing, then its remedy (omit the path)
frag a 1
o3="$(lane plan/index.d/does-not-exist.yaml)"
o3r="$(lane --dry-run)"
if [[ "$o3" == *"refused:fragments-to-trunk:missing:plan/index.d/does-not-exist.yaml"* ]] && has_afford "$o3" \
   && [[ "$(printf '%s' "$o3r" | tail -1)" == ok:fragments-to-trunk:dry-run:*:1 ]]; then
    ok "3 missing carries why/remedy, and omitting the path clears it"
else bad "3 missing: $(printf '%s' "$o3" | tail -2 | tr '\n' ';') / remedy: $(printf '%s' "$o3r" | tail -1)"; fi

# 4 push refused for a stale plan binary: the REAL cause, then its remedy run
o4="$(lane)"
v4="$(printf '%s\n' "$o4" | grep '^refused:fragments-to-trunk:push:' || true)"
if [[ "$v4" == *"resolved plan binary is STALE"* ]] && [[ "$v4" != *"tree changed"* ]] \
   && [[ "$o4" == *"  remedy: cargo build --release -p tillandsias-plan"* ]]; then
    touch "$W/rebuilt"
    o4r="$(lane)"
    if [[ "$(printf '%s' "$o4r" | tail -1)" == ok:fragments-on-trunk:*:1 ]]; then
        ok "4 a stale-binary refusal names the stale binary and its cargo remedy, and the remedy clears it"
    else bad "4 remedy did not clear it: $(printf '%s' "$o4r" | tail -2 | tr '\n' ';')"; fi
else bad "4 push reason: verdict='${v4:-none}' remedy-line='$(printf '%s\n' "$o4" | grep '  remedy:' | head -1)'"; fi

# 5 STATIC: every refusal echo in code is followed by _afford within 4 lines
code="$(sed -e 's/^[[:space:]]*#.*$//' "$LANE")"
missing_sites="$(printf '%s\n' "$code" | awk '
    /echo "refused:fragments-to-trunk:/ { pending = NR; site = $0; next }
    pending && /_afford / { pending = 0; next }
    pending && NR - pending > 4 { print pending ": " site; pending = 0 }
    END { if (pending) print pending ": " site }')"
sites="$(printf '%s\n' "$code" | grep -c 'echo "refused:fragments-to-trunk:')" || true
if [ -z "$missing_sites" ] && [ "${sites:-0}" -ge 13 ]; then
    ok "5 all $sites refusal sites in code carry _afford"
else bad "5 sites=$sites without _afford: $(printf '%s' "$missing_sites" | tr '\n' ';')"; fi

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then echo "ok:plan-fragments-lane-affordance:$pass"; exit 0; fi
echo "violation:plan-fragments-lane-affordance:$pass/$total"; exit 1
