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
# ARM 5  A fixture red in the caller's own regime is NOT this class. (2262-5kk6)
#        a: one no gate runs is refused as ungated-red, with its own last line.
#        PRE-FIX RESULT: FAILS, it was a note and the guard answered ok.
#        b: one a .step runs is a note naming that step;  c: so is one build.sh
#        runs inline;  d: a commented-out or `|| true` call is not a gate, nor is
#        a step that merely MENTIONS it;  e: could-not-run (exit 3) is a note.
#        f: one red only from the guard's scratch cwd is a note, not a red.
# ARM 6  With no arguments the population is the added fixtures (untracked
#        against the base), and the count is the fixtures examined.
# ARM 7  No timeout command: a NAMED skip, never an unbounded run.
# ARM 8  (2206-js5t) A scripts/lua/test-*.lua fixture is examined too: one
#        whose child resolves the plan binary after `cd /` passes while a plan
#        binary is on PATH and is REFUSED by name. PRE-FIX RESULT: FAILS, the
#        decider counted no .lua (`0 checked`).
# ARM 9  NEGATIVE CONTROL for 8: the absolutising Lua fixture is admitted
#        and counted. Arms 8-9 need a REAL runner (a stub cannot run Lua), so
#        they copy the caller's plan binary and skip by name without one.
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
if [ "$rc5" -eq 1 ] && [[ "$o5" == *"refused:fixture-default-target:ungated-red:scripts/test-red.sh"* ]] \
   && [[ "$o5" == *"broken regardless"* ]] && [[ "$o5" == *"why:"* ]]; then
    ok "ARM 5a a red fixture no gate runs is refused, in its own words"
else
    bad "ARM 5a expected ungated-red (rc=$rc5): $(printf '%s' "$o5" | tail -2 | tr '\n' ';')"
fi
# d first: none of these gates it.
mkdir -p "$R/scripts/gate-steps.d"
printf 'STEP_SCRIPT="scripts/test-other.sh"\nSTEP_READS="scripts/test-red.sh"\n# STEP_SCRIPT="scripts/test-red.sh"\n' > "$R/scripts/gate-steps.d/010-mention.step"
printf '    # _run bash "$SCRIPT_DIR/scripts/test-red.sh" 2>&1\n    _run bash "$SCRIPT_DIR/scripts/test-red.sh" 2>&1 || true\n' > "$R/build.sh"
o5="$(by_ctd scripts/test-red.sh)"; rc5=$?
if [ "$rc5" -eq 1 ] && [[ "$o5" == *"ungated-red:scripts/test-red.sh"* ]]; then
    ok "ARM 5d a mention, a comment and an advisory call are not gates"
else
    bad "ARM 5d a non-gate was taken for one (rc=$rc5): $(printf '%s' "$o5" | tail -2 | tr '\n' ';')"
fi
printf '    if ! _run bash "$SCRIPT_DIR/scripts/test-red.sh" 2>&1; then\n' > "$R/build.sh"
o5="$(by_ctd scripts/test-red.sh)"; rc5=$?
if [ "$rc5" -eq 0 ] && [[ "$o5" == *"scripts/test-red.sh:rc=1 gated-by: build.sh inline step — broken regardless"* ]] && [[ "$o5" != *refused:* ]]; then
    ok "ARM 5c one build.sh runs inline is a note that says so"
else
    bad "ARM 5c (rc=$rc5): $(printf '%s' "$o5" | tail -2 | tr '\n' ';')"
fi
rm -f "$R/build.sh"
printf 'STEP_SCRIPT="scripts/test-red.sh"\n' > "$R/scripts/gate-steps.d/020-red.step"
o5="$(by_ctd scripts/test-red.sh)"; rc5=$?
if [ "$rc5" -eq 0 ] && [[ "$o5" == *"scripts/test-red.sh:rc=1 gated-by: step 020-red.step — broken regardless"* ]] && [[ "$o5" != *refused:* ]]; then
    ok "ARM 5b one a step runs is a note naming the step"
else
    bad "ARM 5b (rc=$rc5): $(printf '%s' "$o5" | tail -2 | tr '\n' ';')"
fi
rm -rf "$R/scripts/gate-steps.d"
printf '#!/usr/bin/env bash\necho "could-not-run:x:no-tool"; exit 3\n' > "$R/scripts/test-cnr.sh"
o5="$(by_ctd scripts/test-cnr.sh)"; rc5=$?
if [ "$rc5" -eq 0 ] && [[ "$o5" == *"note:fixture-default-target:could-not-run:scripts/test-cnr.sh — could-not-run:x:no-tool"* ]]; then
    ok "ARM 5e could-not-run is a note, not a red"
else
    bad "ARM 5e (rc=$rc5): $(printf '%s' "$o5" | tail -2 | tr '\n' ';')"
fi
printf '#!/usr/bin/env bash\n[ -d scripts ] || { echo "not in the checkout"; exit 1; }\necho ok:cwd\n' > "$R/scripts/test-cnr.sh"
o5="$(by_ctd scripts/test-cnr.sh)"; rc5=$?
if [ "$rc5" -eq 0 ] && [[ "$o5" == *"note:fixture-default-target:red-only-from-scratch-cwd:scripts/test-cnr.sh:rc=1 — not in the checkout"* ]]; then
    ok "ARM 5f one red only from the scratch cwd is a note that says so"
else
    bad "ARM 5f (rc=$rc5): $(printf '%s' "$o5" | tail -2 | tr '\n' ';')"
fi
rm -f "$R/scripts/test-cnr.sh"

# ARM 7: no timeout command (a stock macOS without coreutils) is a NAMED
# skip, never an unbounded run of a fixture that might hang the gate.
o7="$(TILLANDSIAS_DEFAULT_TARGET_TIMEOUT_CMD=none by_ctd scripts/test-cd-first.sh)"; rc7=$?
if [ "$rc7" -eq 0 ] && [ "$(printf '%s' "$o7" | tail -1)" = "skip:fixture-default-target:no-timeout-command" ]; then
    ok "ARM 7 with no timeout command the decider skips by name instead of running unbounded"
else
    bad "ARM 7 expected skip:fixture-default-target:no-timeout-command (rc=$rc7): $(printf '%s' "$o7" | tail -2 | tr '\n' ';')"
fi

# ARMS 8-9: Lua fixtures, run by a real runner copied to the default target
# of a second scratch repo and to a PATH directory (the mask).
REALP="$(cd "$ROOT" && . scripts/plan-binary-probe.sh && resolve_plan_binary 2>/dev/null)" || REALP=""
case "$REALP" in ""|/*) ;; *) REALP="$ROOT/${REALP#./}" ;; esac
caps=""; [ -n "$REALP" ] && caps="$("$REALP" capabilities 2>/dev/null)"
if ! grep -qx script <<<"$caps"; then # sigpipe-ok: herestring, no upstream writer
    echo "skip:arm-8-9:no-real-lua-runner"
else
    L="$W/lrepo"
    mkdir -p "$L/scripts/lua" "$L/target/release" "$W/lpath"
    # The Lua runner roots a decider at the repository containing its cwd and
    # refuses outside one (2213-ag5u), so the stand-in checkout is a repository.
    git init -q "$L"
    cp "$DEC" "$ROOT/scripts/plan-binary-probe.sh" "$L/scripts/"
    cp "$REALP" "$L/target/release/tillandsias-plan"; cp "$REALP" "$W/lpath/tillandsias-plan"
    cat > "$L/scripts/res-cd-first.sh" <<'EOS'
. scripts/plan-binary-probe.sh
cd / || exit 1
P="$(resolve_plan_binary)" || exit 2
"$P" capabilities >/dev/null
EOS
    cat > "$L/scripts/res-absolute.sh" <<'EOS'
. scripts/plan-binary-probe.sh
P="$(resolve_plan_binary)" || exit 2
case "$P" in /*) ;; *) P="$PWD/${P#./}" ;; esac
cd / || exit 1
"$P" capabilities >/dev/null
EOS
    for k in cd-first absolute; do
        printf 'local r = proc.run{ argv = { "bash", "scripts/res-%s.sh" }, timeout_ms = 60000 }\nif r.ok then verdict.ok("lua-%s") end\nverdict.refused("lua-%s")\n' "$k" "$k" "$k" > "$L/scripts/lua/test-$k.lua"
    done
    by_lpath() { (cd "$L" && env -u TILLANDSIAS_PLAN_BIN -u TILLANDSIAS_SCRIPT_RUNNER_BIN -u CARGO_TARGET_DIR PATH="$W/lpath:$BASEPATH" bash "$L/scripts/preflight-fixtures-default-target.sh" "$@" 2>&1); }
    o8="$(by_lpath scripts/lua/test-cd-first.lua)"; rc8=$?
    if [ "$rc8" -ne 0 ] && [[ "$o8" == *"refused:fixture-default-target:scripts/lua/test-cd-first.lua"* ]]; then
        ok "ARM 8 a Lua fixture masked by a plan binary on PATH is refused"
    else
        bad "ARM 8 expected the cd-first Lua fixture refused (rc=$rc8): $(printf '%s' "$o8" | tail -2 | tr '\n' ';')"
    fi
    o9="$(by_lpath scripts/lua/test-absolute.lua)"; rc9=$?
    # Not noted as red in both regimes: a fixture the runner refused everywhere
    # is "checked" and noted, which would admit it vacuously (2213-ag5u).
    if [ "$rc9" -eq 0 ] && [ "$(printf '%s' "$o9" | tail -1)" = "ok:fixture-default-target:1 checked" ] \
       && [[ "$o9" != *"red-in-both-or-normal-regime"* ]]; then
        ok "ARM 9 the absolutising Lua fixture is admitted and counted"
    else
        bad "ARM 9 expected the absolutising Lua fixture admitted (rc=$rc9): $(printf '%s' "$o9" | tail -2 | tr '\n' ';')"
    fi
fi

# ARM 6: population mode. Base holds only the decider and resolver; the
# absolutising fixture is added (untracked), the rest are removed.
rm -f "$R/scripts/test-cd-first.sh" "$R/scripts/test-skips.sh" "$R/scripts/test-red.sh"
git -C "$R" init -q 2>/dev/null
git -C "$R" config user.email f@x.invalid; git -C "$R" config user.name f
git -C "$R" add scripts/preflight-fixtures-default-target.sh scripts/plan-binary-probe.sh
git -C "$R" commit -qm base
git -C "$R" update-ref refs/remotes/origin/linux-next HEAD
# The gate exports its frozen TILLANDSIAS_GATE_DIFF_BASE, a commit this scratch
# repo does not hold (2241-f8jg: a missing base is now named, not judged), so
# the arm names its own base.
o6="$(cd "$R" && TILLANDSIAS_DEFAULT_TARGET_BASE= TILLANDSIAS_GATE_DIFF_BASE=refs/remotes/origin/linux-next by_ctd)"; rc6=$?
if [ "$rc6" -eq 0 ] && [ "$(printf '%s' "$o6" | tail -1)" = "ok:fixture-default-target:1 checked" ]; then
    ok "ARM 6 a bare run finds the one added fixture and counts it"
else
    bad "ARM 6 expected ok:...:1 checked from the added population (rc=$rc6): $(printf '%s' "$o6" | tail -2 | tr '\n' ';')"
fi

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then echo "ok:fixture-default-target-fixture:$pass"; exit 0; fi
echo "violation:fixture-default-target-fixture:$pass/$total"; exit 1
