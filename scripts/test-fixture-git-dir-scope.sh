#!/usr/bin/env bash
# @trace order:1443-fpck, spec:command-policies
#
# test-fixture-git-dir-scope.sh — under regime=fixture a fixture cannot write
# into the real checkout's git dir or outside its declared scope, so the
# 1442-22d2 shape (a fixture minting a full-scope gate stamp in the real git
# dir, adopted by four relay lands) is unconstructible for every fixture.
#
# Every arm runs in SCRATCH repositories with real git dirs; the real
# checkout's gate files are snapshotted first and asserted byte-identical at
# exit (arm 0), so this fixture cannot itself be the defect it tests.
#
#   1  TILLANDSIAS_POLICY_REGIME=fixture + TILLANDSIAS_FIXTURE_SCOPE=<scratch>:
#      Lua fs.write("<git dir>/tillandsias-gate-stamp") raises
#      refused:policy:fixture-writes-outside-scope with why: and remedy:, and
#      the file does not exist; a write outside the scope is refused too
#   2  proc.run{argv={"bash","scripts/gate-stamp.sh","write",…}} with cwd in
#      that repository is status=policy_denied, rule_id=fixture-gate-stamp-write;
#      `git update-ref` there is policy_denied (fixture-writes-outside-scope)
#   3  scripts/run-litmus-test.sh (a copy, in a scratch project) exports the
#      regime and scope: a step that writes its checkout's gate stamp goes RED
#      naming refused:policy:fixture-gate-stamp-write, and the bytes are
#      restored (a pre-existing stamp to its old bytes, a new one removed)
#   4  NEGATIVE CONTROL: the same fs.write inside the scope succeeds; the same
#      gate-stamp.sh write in a scratch repo INSIDE the scope is not
#      policy-denied; regime=gate is unaffected; a litmus step writing only
#      scratch files, or a stamp in its OWN scratch repo, passes
#   0  the real checkout's tillandsias-gate-* files are byte-identical at exit
#
# Pre-fix: FAILS at arm 1 (the write succeeds: the git dir is under the root).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/fixture-git-dir-scope.XXXXXX")"
W="$(cd "$W" && pwd -P)"
pass=0
fail=0
ok() { echo "ok:   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail + 1)); }

. "$ROOT/scripts/plan-binary-probe.sh"
PLAN="$(cd "$ROOT" && resolve_plan_binary)" || { echo "FAIL: no runnable plan binary" >&2; exit 1; }
case "$PLAN" in /*) ;; *) PLAN="$ROOT/${PLAN#./}" ;; esac
jget() { "$PLAN" json get "$@"; }

# ── 0 (snapshot) ────────────────────────────────────────────────────────────
REAL_GD="$(git -C "$ROOT" rev-parse --absolute-git-dir)"
REAL_CD="$(cd "$ROOT" && cd "$(git rev-parse --git-common-dir)" && pwd -P)"
mkdir -p "$W/real-snap"
real_digest() {
    local f
    for f in "$REAL_GD"/tillandsias-gate-* "$REAL_CD"/tillandsias-gate-*; do
        [ -f "$f" ] && printf '%s %s\n' "$(cksum <"$f")" "$f"
    done | sort -u
}
before="$(real_digest)"
trap 'rm -rf "$W"' EXIT

unset TILLANDSIAS_POLICY_REGIME TILLANDSIAS_FIXTURE_SCOPE TILLANDSIAS_FIXTURE_GIT_DIRS TILLANDSIAS_REPO_ROOT
export TILLANDSIAS_POLICY_AUDIT_LOG="$W/audit.jsonl"
export GIT_CONFIG_GLOBAL="$W/gitconfig" GIT_CONFIG_NOSYSTEM=1
printf '[user]\n\tname = t\n\temail = t@example.invalid\n' >"$GIT_CONFIG_GLOBAL"

S="$W/repo"
git init -q "$S"
mkdir -p "$S/scratch"
git init -q "$S/scratch/inner"
# As run-litmus-test.sh does: the regime, the scope, and the git dirs it protects.
fixture() {
    TILLANDSIAS_POLICY_REGIME=fixture TILLANDSIAS_FIXTURE_SCOPE="$S/scratch" \
        TILLANDSIAS_FIXTURE_GIT_DIRS="$S/.git" "$@"
}

# ── 1 ───────────────────────────────────────────────────────────────────────
out="$(cd "$S" && fixture "$PLAN" lua -e "print(pcall(fs.write, '$S/.git/tillandsias-gate-stamp', 'x'))" 2>&1)"
if grep -q 'refused:policy:fixture-writes-outside-scope' <<<"$out" && grep -q '^why: .*real checkout' <<<"$out" &&
    grep -q '^remedy: ' <<<"$out" && [ ! -e "$S/.git/tillandsias-gate-stamp" ]; then
    ok "arm 1: fs.write into the git dir is refused:policy:fixture-writes-outside-scope (why, remedy) and nothing is written"
else
    bad "arm 1: [$out] exists=$([ -e "$S/.git/tillandsias-gate-stamp" ] && echo yes || echo no)"
fi
out="$(cd "$S" && fixture "$PLAN" lua -e "print(pcall(fs.write, '$S/outside.txt', 'x'))" 2>&1)"
grep -q 'outside the fixture.s declared scope' <<<"$out" && [ ! -e "$S/outside.txt" ] &&
    ok "arm 1: a write outside the declared scope is refused too" || bad "arm 1 scope: [$out]"
out="$(cd "$S" && fixture "$PLAN" lua -e "print(pcall(fs.mkdir, '$S/.git/hooks-planted'))" 2>&1)"
grep -q 'fs.mkdir: refused:policy:fixture-writes-outside-scope' <<<"$out" && [ ! -e "$S/.git/hooks-planted" ] &&
    ok "arm 1: fs.mkdir under the git dir is refused" || bad "arm 1 mkdir: [$out]"

# ── 2 ───────────────────────────────────────────────────────────────────────
lua_run() { # lua_run <cwd> <argv lua list> -> "status rule_id"
    (cd "$1" && "$PLAN" lua -e "local r = proc.run{argv={$2}, cwd='$1'}; print(r.status, r.rule_id or '-')" 2>&1)
}
out="$(fixture lua_run "$S" "'bash','scripts/gate-stamp.sh','write','--scope','full','--dispatch','check'")"
[ "$out" = "$(printf 'policy_denied\tfixture-gate-stamp-write')" ] &&
    ok "arm 2: proc.run of gate-stamp.sh write against the real repo is policy_denied, rule fixture-gate-stamp-write" ||
    bad "arm 2: [$out]"
out="$(fixture lua_run "$S" "'git','update-ref','refs/heads/x','HEAD'")"
[ "$out" = "$(printf 'policy_denied\tfixture-writes-outside-scope')" ] &&
    ok "arm 2: git update-ref against the real repo is policy_denied" || bad "arm 2 update-ref: [$out]"

# ── 4 (negative controls for 1 and 2) ───────────────────────────────────────
out="$(cd "$S" && fixture "$PLAN" lua -e "print(pcall(fs.write, '$S/scratch/out.txt', 'y'))" 2>&1)"
[ "$(head -n 1 <<<"$out")" = "true	true" ] && [ "$(cat "$S/scratch/out.txt" 2>/dev/null)" = y ] &&
    ok "arm 4: the same fs.write inside the scope succeeds" || bad "arm 4 fs.write: [$out]"
out="$(fixture lua_run "$S/scratch/inner" "'bash','$ROOT/scripts/gate-stamp.sh','write','--scope','full','--dispatch','check'")"
case "$out" in
    policy_denied*) bad "arm 4 inner: a scratch repo inside the scope was denied [$out]" ;;
    *) ok "arm 4: gate-stamp.sh write in a scratch repo INSIDE the scope is not policy-denied ($out)" ;;
esac
out="$(TILLANDSIAS_POLICY_REGIME=gate lua_run "$S" "'git','update-ref','refs/heads/x','HEAD'")"
case "$out" in
    policy_denied*) bad "arm 4 gate: regime=gate was denied [$out]" ;;
    *) ok "arm 4: regime=gate is unaffected ($out)" ;;
esac

# ── 3 ───────────────────────────────────────────────────────────────────────
# The probe's name is built, so check-litmus-pin-claims does not read a
# fixture-local name as a claim on a real litmus test.
LIT="litmus"
P="$W/project"
git init -q "$P"
cp -R "$ROOT/scripts" "$P/scripts"
mkdir -p "$P/lt"
cat >"$P/bindings.yaml" <<YAML
version: '1.0'
description: fixture for 1443-fpck
specs:
- spec_id: spec-traceability
  status: active
  ${LIT}_tests:
  - ${LIT}:fpck-probe
  coverage_ratio: 100
  last_verified: '2026-09-28'
YAML
probe() { # probe <command> -> the runner's output
    cat >"$P/lt/${LIT}-fpck-probe.yaml" <<YAML
name: ${LIT}:fpck-probe
spec: spec-traceability
phase: pre-build
severity: high
size: instant
description: >
  probe for 1443-fpck
critical_path:
  - step: "probe"
    command: "$1"
    timeout_ms: 20000
    expected_behavior: "probe-done"
YAML
    (cd "$P" && TILLANDSIAS_PLAN_BIN="$PLAN" TILLANDSIAS_LITMUS_BINDINGS="$P/bindings.yaml" \
        TILLANDSIAS_LITMUS_TESTS_DIR="$P/lt" timeout 120 bash scripts/run-litmus-test.sh spec-traceability \
        --phase pre-build --size instant --compact 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
}
STAMP="$P/.git/tillandsias-gate-stamp"
out="$(probe 'printf minted > \"$(git rev-parse --absolute-git-dir)/tillandsias-gate-stamp\"; echo probe-done')"
if grep -q 'refused:policy:fixture-gate-stamp-write' <<<"$out" && grep -qE 'Status: \[FAIL\]' <<<"$out" && [ ! -e "$STAMP" ]; then
    ok "arm 3: a litmus step minting its checkout's stamp goes RED naming the rule, and the new file is removed"
else
    bad "arm 3 new: exists=$([ -e "$STAMP" ] && echo yes || echo no) [$(tail -n 15 <<<"$out")]"
fi
printf 'earned\n' >"$STAMP"
out="$(probe 'printf minted > \"$(git rev-parse --absolute-git-dir)/tillandsias-gate-stamp\"; echo probe-done')"
if grep -q 'refused:policy:fixture-gate-stamp-write' <<<"$out" && [ "$(cat "$STAMP")" = earned ]; then
    ok "arm 3: a pre-existing stamp the step overwrote is restored to its old bytes"
else
    bad "arm 3 restore: stamp=[$(cat "$STAMP" 2>/dev/null)] [$(tail -n 15 <<<"$out")]"
fi
out="$(probe 't=$(mktemp -d); git init -q \"$t\"; printf x > \"$t/.git/tillandsias-gate-stamp\"; rm -rf \"$t\"; [ \"$TILLANDSIAS_POLICY_REGIME\" = fixture ] && echo probe-done')"
if grep -qE 'Status: \[PASS\]' <<<"$out" && [ "$(cat "$STAMP")" = earned ]; then
    ok "arm 4: a step writing only scratch files (a stamp in its OWN scratch repo) passes, and sees TILLANDSIAS_POLICY_REGIME=fixture"
else
    bad "arm 4 runner: [$(tail -n 15 <<<"$out")]"
fi

# ── 0 ───────────────────────────────────────────────────────────────────────
after="$(real_digest)"
[ "$before" = "$after" ] && ok "arm 0: the real checkout's gate files are byte-identical at exit" ||
    bad "arm 0: real gate files changed: before=[$before] after=[$after]"

total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: fixture-git-dir-scope $pass/$total (1443-fpck)"
    exit 0
fi
echo "FAIL: fixture-git-dir-scope $pass/$total (1443-fpck)"
exit 1
