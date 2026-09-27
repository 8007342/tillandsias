#!/usr/bin/env bash
# @trace spec:meta-orchestration
# @trace order:1247-omqr, order:1247-amcu
#
# Fixture for the affordance slice of check-claims-across-branches.sh: every
# refusal says WHY it refused and WHAT would make it not a refusal, as two
# labelled stderr lines ("  why: …", "  remedy: …"), beside an UNCHANGED stdout
# verdict token.
#
#   1  blocked:no-plan-binary     carries why/remedy; REMEDY EXECUTED: a runnable
#                                 TILLANDSIAS_PLAN_BIN clears it
#   2  blocked:fetch-failed       carries why/remedy; REMEDY EXECUTED: --no-fetch
#                                 clears it
#   3  claimed-elsewhere          per-packet mode carries why/remedy
#   4  claimed-elsewhere          --batch mode carries why/remedy
#   5  blocked:empty-fold         carries why/remedy
#   (blocked:no-siblings-folded: unreachable in practice, see the scratch-checkout
#    note below; covered by ARM 8 statically)
#   7  unknown-packet             carries why/remedy
#   8  STATIC: every refusal token the script emits sits within six lines of an
#      _afford call, so a refusal added later without one fails here
#      (blocked:no-root is reachable only when the checkout is unreadable, so
#      it is covered by this arm alone)
#
#   PASS: claims-affordance <n>/<n>
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/check-claims-across-branches.sh"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok:   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; [ -n "${2:-}" ] && echo "      $2"; }

W="$(mktemp -d "${TMPDIR:-/tmp}/claims-afford.XXXXXX")" || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$W"' EXIT INT TERM

# A stub plan binary. $2 = the status it answers; $3 = what `ready any` prints.
mkstub() {
    mkdir -p "$1"
    cat > "$1/tillandsias-plan" <<EOF
#!/bin/sh
case " \$* " in
    *" ready any "*) printf '%s' "$3" ;;
    *" status "*) [ -n "$2" ] || exit 1; echo "PKT	$2	some-packet-name" ;;
esac
exit 0
EOF
    chmod +x "$1/tillandsias-plan"
}
mkstub "$W/hold" in_progress "OTHER-PKT
"
mkstub "$W/empty" in_progress ""
mkstub "$W/unknown" "" "OTHER-PKT
"
mkstub "$W/free" ready "SOME-PKT
"

# Run the check; stdout and stderr land in separate files.
run() { # $1=workdir, rest=env/args (env via `env`)
    local d="$1"; shift
    (cd "$d" && env "$@" >"$W/out" 2>"$W/err"); echo $?
}
has_afford() { # both labels present on stderr
    grep -q '^  why: ' "$W/err" && grep -q '^  remedy: ' "$W/err"
}
first() { head -1 "$W/out"; }

# ARM 1
rc="$(run "$ROOT" TILLANDSIAS_PLAN_BIN="$W/nonexistent" bash "$CHECK" SOME-PKT --no-fetch)"
if [ "$rc" = 2 ] && [ "$(first)" = "blocked:no-plan-binary" ] && has_afford; then
    rc2="$(run "$ROOT" TILLANDSIAS_PLAN_BIN="$W/free/tillandsias-plan" bash "$CHECK" SOME-PKT --no-fetch)"
    if [ "$rc2" = 0 ]; then
        ok "ARM 1: blocked:no-plan-binary says why and what clears it, and the remedy (a runnable TILLANDSIAS_PLAN_BIN) clears it"
    else
        bad "ARM 1: the stated remedy did not clear the refusal" "rc=$rc2 out=$(first)"
    fi
else
    bad "ARM 1: blocked:no-plan-binary without its affordance" "rc=$rc out=$(first) err=$(tr '\n' '|' <"$W/err")"
fi

# ARM 3
rc="$(run "$ROOT" TILLANDSIAS_XBRANCH_CLAIM_HOST=some-other-host TILLANDSIAS_PLAN_BIN="$W/hold/tillandsias-plan" bash "$CHECK" SOME-PKT --no-fetch)"
case "$(first)" in
    (claimed-elsewhere:SOME-PKT:*) cf=1 ;;
    (*) cf=0 ;;
esac
if [ "$rc" = 1 ] && [ "$cf" = 1 ] && has_afford; then
    ok "ARM 3: claimed-elsewhere (per-packet) says why and what to do"
else
    bad "ARM 3: per-packet claimed-elsewhere without its affordance" "rc=$rc out=$(first)"
fi

# ARM 4
rc="$(run "$ROOT" TILLANDSIAS_PLAN_BIN="$W/hold/tillandsias-plan" bash "$CHECK" --batch SOME-PKT)"
grep -q '^claimed-elsewhere:SOME-PKT:' "$W/out" && cb=1 || cb=0
if [ "$rc" = 1 ] && [ "$cb" = 1 ] && has_afford; then
    ok "ARM 4: claimed-elsewhere (--batch) says why and what to do"
else
    bad "ARM 4: batch claimed-elsewhere without its affordance" "rc=$rc out=$(tr '\n' '|' <"$W/out")"
fi

# ARM 5
rc="$(run "$ROOT" TILLANDSIAS_PLAN_BIN="$W/empty/tillandsias-plan" bash "$CHECK" --batch SOME-PKT)"
grep -q '^blocked:empty-fold:' "$W/err" && ef=1 || ef=0
if [ "$ef" = 1 ] && has_afford; then
    ok "ARM 5: blocked:empty-fold says why and what to check"
else
    bad "ARM 5: blocked:empty-fold without its affordance" "rc=$rc err=$(tr '\n' '|' <"$W/err")"
fi

# SCRATCH CHECKOUT for ARM 2: this script and the probe, one commit, and a
# resolvable sibling ref, so only the FETCH can refuse.
#
# blocked:no-siblings-folded has no behavioural arm, on purpose: --batch has no
# --no-fetch, and its fetch names every sibling, so a missing sibling fails the
# fetch first (blocked:fetch-failed); when the fetch succeeds every sibling
# resolves and at least one folds. The verdict is unreachable in practice, so
# asserting it here would test a fixture artefact; ARM 8 still requires its
# affordance statically.
R="$W/repo"
mkdir -p "$R/scripts" "$R/plan/index.d"
cp "$CHECK" "$ROOT/scripts/plan-binary-probe.sh" "$R/scripts/"
printf 'packets: []\n' > "$R/plan/index.yaml"
git -C "$R" init -q -b work/fixture
git -C "$R" -c user.email=f@f -c user.name=f add -A >/dev/null
git -C "$R" -c user.email=f@f -c user.name=f commit -q -m base
git -C "$R" update-ref refs/remotes/origin/linux-next HEAD

# ARM 2 — in the scratch checkout (which now has a resolvable sibling), with
# origin pointed at a path that does not exist, so the fetch itself fails.
git -C "$R" remote add origin "$W/no-such-remote"
rc="$(run "$R" TILLANDSIAS_PLAN_BIN="$W/free/tillandsias-plan" bash scripts/check-claims-across-branches.sh SOME-PKT)"
if [ "$rc" = 2 ] && [ "$(first)" = "blocked:fetch-failed" ] && has_afford; then
    rc2="$(run "$R" TILLANDSIAS_PLAN_BIN="$W/free/tillandsias-plan" bash scripts/check-claims-across-branches.sh SOME-PKT --no-fetch)"
    if [ "$rc2" = 0 ]; then
        ok "ARM 2: blocked:fetch-failed says why and what clears it, and the remedy (--no-fetch) clears it"
    else
        bad "ARM 2: the stated remedy did not clear the refusal" "rc=$rc2 out=$(first)"
    fi
else
    bad "ARM 2: blocked:fetch-failed without its affordance" "rc=$rc out=$(first) err=$(tr '\n' '|' <"$W/err")"
fi

# ARM 7
rc="$(run "$ROOT" TILLANDSIAS_PLAN_BIN="$W/unknown/tillandsias-plan" bash "$CHECK" NO-SUCH-PKT --no-fetch)"
case "$(first)" in
    (unknown-packet:NO-SUCH-PKT:*) up=1 ;;
    (*) up=0 ;;
esac
if [ "$rc" = 2 ] && [ "$up" = 1 ] && has_afford; then
    ok "ARM 7: unknown-packet says why and what to check"
else
    bad "ARM 7: unknown-packet without its affordance" "rc=$rc out=$(first)"
fi

# ARM 8 — static completeness over the script's own refusal sites.
missing="$(awk '
    { line[NR] = $0 }
    /echo "(blocked:|claimed-elsewhere:|unknown-packet:)/ { sites[++n] = NR }
    END {
        for (i = 1; i <= n; i++) {
            s = sites[i]; found = 0
            for (j = s - 6; j <= s + 6; j++) if (j > 0 && line[j] ~ /_afford /) found = 1
            if (!found) print s ": " line[s]
        }
    }' "$CHECK")"
if [ -z "$missing" ]; then
    ok "ARM 8: every refusal site in the script sits beside an _afford call"
else
    bad "ARM 8: refusal sites without an affordance" "$missing"
fi

total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: claims-affordance $pass/$total (1247-omqr)"
    exit 0
fi
echo "FAIL: claims-affordance $pass/$total (1247-omqr)"
exit 1
