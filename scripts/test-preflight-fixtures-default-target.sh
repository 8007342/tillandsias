#!/usr/bin/env bash
# @trace order:1401-x76w
#
# test-preflight-fixtures-default-target.sh — 1401-x76w's verifiable closure.
#
# Every arm runs a COPY of the decider in a scratch repo whose plan binary is a
# stub at the default target (./target/release). Two fixtures there resolve it
# with the real resolver (scripts/plan-binary-probe.sh, copied):
#   test-cd-first.sh     resolves AFTER `cd /`, the 1375-2x4e shape
#   test-absolute.sh     resolves inside the checkout and absolutises first
#
# ARM 1  CARGO_TARGET_DIR masks it: with an absolute CARGO_TARGET_DIR the
#        cd-first fixture passes, and the decider must still REFUSE it by name.
#        PRE-FIX RESULT: FAILS, the decider does not exist; nothing refuses.
# ARM 2  PATH masks it: no CARGO_TARGET_DIR, but a directory on PATH holds a
#        plan binary (the ~/.local/bin copy the coordinator measured). The
#        decider must strip that entry and REFUSE.
# ARM 3  NEGATIVE CONTROL: the absolutising fixture is ADMITTED in both
#        masked regimes. A decider refusing everything would pass arms 1-2.
# ARM 4  A fixture that SKIPS when it cannot find the binary is refused too:
#        a skip is as blind as a failure.
# ARM 5  A fixture red in the caller's own regime is NOT this class: noted,
#        never refused.
# ARM 6  With no arguments the population is the added fixtures (untracked
#        against the base), and the count is the fixtures examined.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEC="$ROOT/scripts/preflight-fixtures-default-target.sh"
[ -f "$DEC" ] || { echo "skip:fixture-default-target-fixture:decider-absent"; exit 0; }

W="$(mktemp -d)" || exit 1
trap 'rm -rf "$W"' EXIT
pass=0; fail=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

R="$W/repo"
mkdir -p "$R/scripts" "$R/target/release" "$W/pathbin" "$W/ctd/release"
cp "$DEC" "$ROOT/scripts/plan-binary-probe.sh" "$R/scripts/"
for p in "$R/target/release" "$W/pathbin" "$W/ctd/release"; do
    printf '#!/bin/sh\nexit 0\n' > "$p/tillandsias-plan"; chmod +x "$p/tillandsias-plan"
done

cat > "$R/scripts/test-cd-first.sh" <<'EOS'
#!/usr/bin/env bash
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/plan-binary-probe.sh"
cd / || exit 1
P="$(resolve_plan_binary)" || { echo "no plan binary from /"; exit 2; }
"$P" capabilities && echo "ok:cd-first"
EOS
cat > "$R/scripts/test-absolute.sh" <<'EOS'
#!/usr/bin/env bash
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/plan-binary-probe.sh"
P="$(cd "$ROOT" && resolve_plan_binary)" || { echo "no plan binary"; exit 2; }
case "$P" in /*) ;; *) P="$ROOT/${P#./}" ;; esac
cd / || exit 1
"$P" capabilities && echo "ok:absolute"
EOS
cat > "$R/scripts/test-skips.sh" <<'EOS'
#!/usr/bin/env bash
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/plan-binary-probe.sh"
cd / || exit 1
P="$(resolve_plan_binary)" || { echo "skip:skips-fixture:no-plan-binary"; exit 0; }
"$P" capabilities && echo "ok:skips"
EOS
printf '#!/usr/bin/env bash\necho "broken regardless"; exit 1\n' > "$R/scripts/test-red.sh"
chmod +x "$R"/scripts/*.sh

# The masked regimes. A clean base PATH first: the host's own plan binary, if
# any, must not decide an arm.
BASEPATH=""
_ifs="$IFS"; IFS=:
for d in $PATH; do
    [ -e "$d/tillandsias-plan" ] || [ -e "$d/tillandsias-plan.exe" ] || BASEPATH="${BASEPATH:+$BASEPATH:}$d"
done
IFS="$_ifs"
by_ctd() { env -u TILLANDSIAS_PLAN_BIN CARGO_TARGET_DIR="$W/ctd" PATH="$BASEPATH" bash "$R/scripts/preflight-fixtures-default-target.sh" "$@" 2>&1; }
by_path() { env -u TILLANDSIAS_PLAN_BIN -u CARGO_TARGET_DIR PATH="$W/pathbin:$BASEPATH" bash "$R/scripts/preflight-fixtures-default-target.sh" "$@" 2>&1; }

# Precondition: the masks really mask. Without this, ARM 1/2 could pass on a
# fixture that fails in every regime.
pre_c="$(cd "$W" && env -u TILLANDSIAS_PLAN_BIN CARGO_TARGET_DIR="$W/ctd" PATH="$BASEPATH" bash "$R/scripts/test-cd-first.sh" 2>&1)"; rc_pc=$?
pre_p="$(cd "$W" && env -u TILLANDSIAS_PLAN_BIN -u CARGO_TARGET_DIR PATH="$W/pathbin:$BASEPATH" bash "$R/scripts/test-cd-first.sh" 2>&1)"; rc_pp=$?
if [ "$rc_pc" -eq 0 ] && [ "$rc_pp" -eq 0 ]; then
    ok "PRECONDITION the cd-first fixture passes under both masks"
else
    bad "PRECONDITION the cd-first fixture did not pass under a mask (ctd rc=$rc_pc, path rc=$rc_pp): $pre_c $pre_p"
fi

o1="$(by_ctd scripts/test-cd-first.sh)"; rc1=$?
if [ "$rc1" -ne 0 ] && [[ "$o1" == *"refused:fixture-default-target:scripts/test-cd-first.sh"* ]]; then
    ok "ARM 1 an absolute CARGO_TARGET_DIR does not hide the cd-first fixture"
else
    bad "ARM 1 expected a refusal under CARGO_TARGET_DIR (rc=$rc1): $(printf '%s' "$o1" | tail -2 | tr '\n' ';')"
fi

o2="$(by_path scripts/test-cd-first.sh)"; rc2=$?
if [ "$rc2" -ne 0 ] && [[ "$o2" == *"refused:fixture-default-target:scripts/test-cd-first.sh"* ]]; then
    ok "ARM 2 a plan binary on PATH does not hide the cd-first fixture"
else
    bad "ARM 2 expected a refusal under the PATH mask (rc=$rc2): $(printf '%s' "$o2" | tail -2 | tr '\n' ';')"
fi

o3c="$(by_ctd scripts/test-absolute.sh)"; rc3c=$?
o3p="$(by_path scripts/test-absolute.sh)"; rc3p=$?
if [ "$rc3c" -eq 0 ] && [ "$rc3p" -eq 0 ] && [ "$(printf '%s' "$o3c" | tail -1)" = "ok:fixture-default-target:1 checked" ]; then
    ok "ARM 3 the absolutising fixture is admitted under both masks"
else
    bad "ARM 3 the absolutising fixture was not admitted (ctd rc=$rc3c, path rc=$rc3p): $(printf '%s' "$o3c$o3p" | tail -2 | tr '\n' ';')"
fi

o4="$(by_ctd scripts/test-skips.sh)"; rc4=$?
if [ "$rc4" -ne 0 ] && [[ "$o4" == *"refused:fixture-default-target:scripts/test-skips.sh"* ]]; then
    ok "ARM 4 a fixture that skips without the mask is refused"
else
    bad "ARM 4 expected the skipping fixture refused (rc=$rc4): $(printf '%s' "$o4" | tail -2 | tr '\n' ';')"
fi

o5="$(by_ctd scripts/test-red.sh)"; rc5=$?
if [ "$rc5" -eq 0 ] && [[ "$o5" == *"note:fixture-default-target:red-in-both-or-normal-regime:scripts/test-red.sh"* ]] && [[ "$o5" != *refused:* ]]; then
    ok "ARM 5 a fixture red in the caller's regime is noted, not refused"
else
    bad "ARM 5 the always-red fixture was mis-classed (rc=$rc5): $(printf '%s' "$o5" | tail -2 | tr '\n' ';')"
fi

# ARM 6: population mode. Base holds only the decider and resolver; the
# absolutising fixture is added (untracked), the rest are removed.
rm -f "$R/scripts/test-cd-first.sh" "$R/scripts/test-skips.sh" "$R/scripts/test-red.sh"
git -C "$R" init -q 2>/dev/null
git -C "$R" config user.email f@x.invalid; git -C "$R" config user.name f
git -C "$R" add scripts/preflight-fixtures-default-target.sh scripts/plan-binary-probe.sh
git -C "$R" commit -qm base
git -C "$R" update-ref refs/remotes/origin/linux-next HEAD
o6="$(cd "$R" && by_ctd)"; rc6=$?
if [ "$rc6" -eq 0 ] && [ "$(printf '%s' "$o6" | tail -1)" = "ok:fixture-default-target:1 checked" ]; then
    ok "ARM 6 a bare run finds the one added fixture and counts it"
else
    bad "ARM 6 expected ok:...:1 checked from the added population (rc=$rc6): $(printf '%s' "$o6" | tail -2 | tr '\n' ';')"
fi

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then echo "ok:fixture-default-target-fixture:$pass"; exit 0; fi
echo "violation:fixture-default-target-fixture:$pass/$total"; exit 1
