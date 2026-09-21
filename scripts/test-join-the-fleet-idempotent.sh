#!/usr/bin/env bash
# @trace order:1311-ajpm, spec:methodology-accountability
# bash-dialect: pure-3.2
#
# test-join-the-fleet-idempotent.sh — pins the contract of
# scripts/check-fleet-membership.sh, the verifier behind ./skills/join-the-fleet.
#
# THREE ARMS, matching the row's closure:
#   1. IDEMPOTENT AND NON-MUTATING: two runs on this checkout print the same
#      verdict line, and `git status --porcelain` is byte-identical before and
#      after — the checker reports, it never installs.
#   2. FORGE REGIME: under TILLANDSIAS_HOST_KIND=forge every host-only step is
#      a NAMED skip line, the verdict's skipped= count equals the number of
#      skip lines, and no toolbox or substrate step is reported as ran.
#   3. TROUBLESHOOTING: with the hooks inspected in a scaffold git dir that
#      has no pre-push hook, the checker prints
#      todo:join-the-fleet:hooks:scripts/install-hooks.sh and exits 1.
#
# Arms 2 and 3 run with JOIN_FLEET_PROBES=0 so they never execute the other
# guards (credential channel, experts, substrate): those have their own
# fixtures, and this one is about the checker's OWN grammar and honesty. Arm 1
# runs the real probes, because idempotence is a property of the whole walk.
#
# Grammar (one line on stdout last):
#   ok:join-the-fleet-idempotent:3/3 | fail:join-the-fleet-idempotent:<n> arm(s)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2
CHECKER="$ROOT/scripts/check-fleet-membership.sh"
[ -x "$CHECKER" ] || { echo "fail:join-the-fleet-idempotent:no-checker"; exit 1; }

W="$(mktemp -d "${TMPDIR:-/tmp}/join-the-fleet.XXXXXX")" || exit 3
trap 'rm -rf "$W"' EXIT
fails=0
bad() { echo "  FAIL  $*"; fails=$((fails + 1)); }
good() { echo "  PASS  $*"; }

# ---- arm 1 ------------------------------------------------------------------
echo "arm 1 — IDEMPOTENT AND NON-MUTATING: same verdict twice, tree untouched"
before="$(git status --porcelain --untracked-files=all 2>/dev/null)"
o1="$(bash "$CHECKER" 2>&1)"; r1=$?
o2="$(bash "$CHECKER" 2>&1)"; r2=$?
after="$(git status --porcelain --untracked-files=all 2>/dev/null)"
v1="$(printf '%s\n' "$o1" | tail -1)"
v2="$(printf '%s\n' "$o2" | tail -1)"
case "$v1" in
    ok:join-the-fleet:*:ran=*|todo:join-the-fleet:*:todos=*) ;;
    *) bad "arm1: verdict grammar wrong: '$v1'" ;;
esac
if [ "$v1" = "$v2" ] && [ "$r1" = "$r2" ]; then
    good "verdict stable across two runs: $v1 (rc=$r1)"
else
    bad "arm1: verdict or rc changed between two runs of an unchanged host: rc=$r1/$r2 '$v1' vs '$v2'"
fi
if [ "$before" = "$after" ]; then
    good "git status unchanged by two runs"
else
    bad "arm1: the checker changed the tree"
fi

# ---- arm 2 ------------------------------------------------------------------
echo "arm 2 — FORGE REGIME: host-only steps are named skips and the verdict counts them"
o3="$(TILLANDSIAS_HOST_KIND=forge JOIN_FLEET_PROBES=0 bash "$CHECKER" 2>&1)"; r3=$?
v3="$(printf '%s\n' "$o3" | tail -1)"
nskip="$(printf '%s\n' "$o3" | grep -c -e '^skip:join-the-fleet:' || true)"
claimed="$(printf '%s\n' "$v3" | sed -n 's/.*skipped=\([0-9][0-9]*\).*/\1/p')"
case "$v3" in
    *:forge:*) good "regime detected as forge: $v3" ;;
    *) bad "arm2: regime not forge in verdict: '$v3'" ;;
esac
if [ -n "$claimed" ] && [ "$claimed" = "$nskip" ]; then
    good "skipped=$claimed equals $nskip named skip lines"
else
    bad "arm2: verdict claims skipped=${claimed:-?} but $nskip skip lines were printed"
fi
if printf '%s\n' "$o3" | grep -q -e '^skip:join-the-fleet:toolbox:forge$'; then
    good "toolbox is a named skip in a forge"
else
    bad "arm2: toolbox not skipped by name in a forge"
fi
if printf '%s\n' "$o3" | grep -q -E -e '^ok:join-the-fleet:(toolbox|substrate)'; then
    bad "arm2: a host-only step reported ran in a forge"
else
    good "no host-only step reported as ran"
fi

# ---- arm 3 ------------------------------------------------------------------
echo "arm 3 — TROUBLESHOOTING: a missing pre-push hook yields todo: naming the installer, rc=1"
mkdir -p "$W/scaffold.git/hooks"
o4="$(JOIN_FLEET_GIT_DIR="$W/scaffold.git" JOIN_FLEET_PROBES=0 bash "$CHECKER" 2>&1)"; r4=$?
if printf '%s\n' "$o4" | grep -q -e '^todo:join-the-fleet:hooks:scripts/install-hooks.sh$' && [ "$r4" != 0 ]; then
    good "todo: names the hook installer, rc=$r4"
else
    bad "arm3: expected todo:join-the-fleet:hooks:scripts/install-hooks.sh with rc!=0, got rc=$r4: $(printf '%s\n' "$o4" | tail -2 | tr '\n' ' ')"
fi

if [ "$fails" = 0 ]; then
    echo "ok:join-the-fleet-idempotent:3/3"
    exit 0
fi
echo "fail:join-the-fleet-idempotent:$fails arm(s)"
exit 1
