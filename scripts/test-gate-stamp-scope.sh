#!/usr/bin/env bash
# @trace spec:methodology-accountability
#
# Hermetic fixture for SCOPED gate stamps (order 765-dt8h).
#
# The stamp used to record THAT a gate passed against these bytes, never WHICH
# gate. That was safe only while every gate validated the whole tree. This
# fixture pins the property that makes scoping safe to build on at all: a
# stamp declares its scope, and pre-push refuses a push that reaches outside
# it.
#
# The load-bearing case is 4 — a stamp scoped to {plan-ledger} against a push
# touching crates/. If that ever passes, every future selector converts its
# skips into trunk exposure, which is the single highest silent-green risk the
# 2026-08-15 velocity audit identified (F5).
#
# Every case drives a REAL `git push` against a REAL bare remote through the
# REAL hook, and asserts the remote head did or did not move. A fixture that
# only inspected verdict strings could not tell a refusal from a refusal that
# pushed anyway.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The fragment validator the plan-only lane looks for (case 7). Resolved from
# the REAL checkout through the shared probe (721-nyev: an executable bit is a
# claim, running the binary is evidence), and absolutized because the arm runs
# from inside the temp repo.
. "$ROOT/scripts/plan-binary-probe.sh"
LANE_PLAN_BIN="$(cd "$ROOT" && resolve_plan_binary 2>/dev/null || true)"
case "$LANE_PLAN_BIN" in
    "") ;;
    /*) ;;
    *) LANE_PLAN_BIN="$ROOT/${LANE_PLAN_BIN#./}" ;;
esac

fail() { echo "FAIL: $*" >&2; exit 1; }

# Build a throwaway repo with the real scripts, a bare origin, and the real
# pre-push hook installed. Echoes the worktree path.
make_repo() {
    local d="$1"
    mkdir -p "$d/work"
    git init -q -b main "$d/work"
    # core.hooksPath is GLOBAL and REPLACES .git/hooks (a forge sets it in
    # ~/.gitconfig), so an unpinned scratch repo runs the REAL forge hooks
    # instead of this fixture's. Pin it per repo. Same defect as 889-twhe
    # and 877-mynm; found by sweeping for the class rather than by being
    # blocked, because neither of these fixtures is wired into build.sh.
    git -C "$d/work" config core.hooksPath .git/hooks
    (
        cd "$d/work" || exit 1
        git config user.email f@t
        git config user.name f
        git config core.autocrlf false
        mkdir -p scripts/hooks plan/index.d plan/loop_status.d crates/demo
        cp "$ROOT/scripts/gate-stamp.sh" scripts/
        cp "$ROOT/scripts/hooks/pre-push-local-gate.sh" scripts/hooks/
        cp "$ROOT/scripts/plan-binary-probe.sh" scripts/ 2>/dev/null || true
        # ORDER 1069-5sp4: the lane now runs the scorable-obligation guard, so
        # the temp repo carries it and the arm exercises the REAL lane path
        # rather than the absent-checker skip. (The lane only NOTES the absence,
        # so this cp is not required for the arm to pass — it is here so the arm
        # measures the lane instead of which scripts the fixture copied, the same
        # substitution this file's own case-7 note records for yq on macOS.)
        cp "$ROOT/scripts/check-scorable-obligation-added.sh" scripts/ 2>/dev/null || true
        printf 'packets: []\n' > plan/index.yaml
        printf 'pub fn seed() {}\n' > crates/demo/lib.rs
        printf 'seed\n' > README.md
        git add -A
        git commit -qm base
        git init -q --bare "$d/origin.git"
        git remote add origin "$d/origin.git"
        git push -q origin main
        printf '#!/usr/bin/env bash\nexec bash "$(git rev-parse --show-toplevel)/scripts/hooks/pre-push-local-gate.sh" "$@"\n' > .git/hooks/pre-push
        chmod +x .git/hooks/pre-push
    )
}

remote_head() { git -C "$1/work" ls-remote origin refs/heads/main 2>/dev/null | cut -f1; }

# ORDER 940-f77j — `write` now requires the one-shot pass token a GREEN gate
# issues, naming the tree it validated. This fixture stands in for the gate
# (its subject is scope semantics, not stamp earning), so it issues the token
# the way build.sh does before each write it expects to get past the token
# check. Run from inside the case's work directory, after the tree is final.
issue_pass_token() {
    local _d
    _d="$(bash scripts/gate-stamp.sh compute)" || return 1
    {
        echo 'version 1'
        echo "digest $_d"
        echo 'dispatch check'
        echo 'issued now'
    } > "$(git rev-parse --absolute-git-dir)/tillandsias-gate-pass-token"
}

# ── classifier totality ───────────────────────────────────────────────────────
# The `other` arm is what makes an unscoped path fail closed; if the taxonomy
# ever silently classified an unknown path as something a scoped stamp covers,
# every case below would still pass while the guarantee was gone.
out="$(printf 'plan/index.d/x.yaml\ncrates/a/src/lib.rs\nweird-top-level-thing\n' | bash "$ROOT/scripts/gate-stamp.sh" classify)"
[ "$(printf '%s\n' "$out" | tr '\n' ' ')" = "other plan-ledger rust " ] \
    || fail "case 0: classifier returned '$out'"
echo "ok: case 0 — classifier is total (unknown path -> other)"

# ── case 1: a full-scope stamp behaves exactly as today ───────────────────────
D="$WORK/c1"; make_repo "$D"
(
    cd "$D/work" || exit 1
    issue_pass_token || exit 1
    bash scripts/gate-stamp.sh write --scope full --dispatch check >/dev/null
) || fail "case 1: write failed"
before="$(remote_head "$D")"
out="$(cd "$D/work" && printf 'pub fn more() {}\n' >> crates/demo/lib.rs && git add -A && git commit -qm edit >/dev/null 2>&1 && issue_pass_token && bash scripts/gate-stamp.sh write --scope full --dispatch check >/dev/null && git push origin main 2>&1)"
rc=$?
after="$(remote_head "$D")"
[ "$rc" = 0 ] || fail "case 1: full-scope push refused: $out"
[ "$before" != "$after" ] || fail "case 1: full-scope push did not advance the remote"
echo "ok: case 1 — a full-scope stamp accepts the push, as today"

# ── case 2 (LOAD-BEARING NEGATIVE): scoped stamp, out-of-scope push ───────────
# A stamp scoped to {plan-ledger} against a diff touching crates/ — the
# packet's named negative litmus.
D="$WORK/c2"; make_repo "$D"
before="$(remote_head "$D")"
out="$(cd "$D/work" && printf 'packets: []\n' > plan/index.d/frag.yaml && printf 'pub fn sneak() {}\n' >> crates/demo/lib.rs && git add -A && git commit -qm mixed >/dev/null 2>&1 && issue_pass_token && bash scripts/gate-stamp.sh write --scope plan-ledger --dispatch check >/dev/null && git push origin main 2>&1)"
rc=$?
after="$(remote_head "$D")"
[ "$rc" != 0 ] || fail "case 2: an out-of-scope push was ACCEPTED (this is the F5 silent-green risk)"
printf '%s' "$out" | grep -q 'scoped to .plan-ledger.' || fail "case 2: refusal did not name the scope: $out"
printf '%s' "$out" | grep -q 'rust' || fail "case 2: refusal did not name the missing class: $out"
printf '%s' "$out" | grep -q 'build.sh --check' || fail "case 2: refusal did not print the rerun command: $out"
[ "$before" = "$after" ] || fail "case 2: remote advanced despite the refusal"
echo "ok: case 2 — scoped stamp refuses an out-of-scope push, naming the missing class"

# ── case 3: scoped stamp accepts a push INSIDE its scope ──────────────────────
# The positive half of case 2 — without it, "refuse everything" would satisfy
# the negative case and the scope field would be decorative.
D="$WORK/c3"; make_repo "$D"
before="$(remote_head "$D")"
out="$(cd "$D/work" && printf 'packets: []\n' > plan/index.d/frag.yaml && git add -A && git commit -qm frag >/dev/null 2>&1 && issue_pass_token && bash scripts/gate-stamp.sh write --scope plan-ledger --dispatch check >/dev/null && git push origin main 2>&1)"
rc=$?
after="$(remote_head "$D")"
[ "$rc" = 0 ] || fail "case 3: an in-scope push was refused: $out"
printf '%s' "$out" | grep -q "scoped stamp 'plan-ledger' covers every outgoing change class" \
    || fail "case 3: acceptance did not announce the scope check: $out"
[ "$before" != "$after" ] || fail "case 3: in-scope push did not advance the remote"
echo "ok: case 3 — scoped stamp accepts a push inside its scope, loudly"

# ── case 4: a LEGACY (v1) stamp migrates loudly, never silently passes ────────
D="$WORK/c4"; make_repo "$D"
before="$(remote_head "$D")"
out="$(cd "$D/work" && printf 'pub fn edit() {}\n' >> crates/demo/lib.rs && git add -A && git commit -qm edit >/dev/null 2>&1 && bash scripts/gate-stamp.sh compute > .git/tillandsias-gate-stamp && git push origin main 2>&1)"
rc=$?
after="$(remote_head "$D")"
[ "$rc" != 0 ] || fail "case 4: a legacy bare-digest stamp was ACCEPTED"
printf '%s' "$out" | grep -q 'predates scope recording' || fail "case 4: refusal did not explain the migration: $out"
printf '%s' "$out" | grep -q 'build.sh --check' || fail "case 4: refusal did not print the rerun command: $out"
[ "$before" = "$after" ] || fail "case 4: remote advanced on a legacy stamp"
echo "ok: case 4 — a legacy v1 stamp refuses with migration guidance"

# ── case 5: an unknown scope token is STALE, not permissive ───────────────────
D="$WORK/c5"; make_repo "$D"
before="$(remote_head "$D")"
out="$(cd "$D/work" && printf 'packets: []\n' > plan/index.d/frag.yaml && git add -A && git commit -qm frag >/dev/null 2>&1 && bash scripts/gate-stamp.sh compute > /tmp/.d5 && { printf 'version 2\n'; printf 'digest %s\n' "$(cat /tmp/.d5)"; printf 'scope plan-ledger,typo-class\n'; printf 'dispatch check\n'; } > .git/tillandsias-gate-stamp && git push origin main 2>&1)"
rc=$?
after="$(remote_head "$D")"
rm -f /tmp/.d5
[ "$rc" != 0 ] || fail "case 5: an unknown scope class was ACCEPTED"
printf '%s' "$out" | grep -q 'does not declare a usable scope' || fail "case 5: refusal was not the unusable-scope refusal: $out"
[ "$before" = "$after" ] || fail "case 5: remote advanced on an unknown scope token"
echo "ok: case 5 — an unknown scope token is treated as stale (fail closed)"

# ── case 6 (NEGATIVE CONTROL): write refuses an unknown class up front ────────
D="$WORK/c6"; make_repo "$D"
# The token is issued first so the refusal reached is the one under test
# (the unknown-scope-class check), not the earlier no-token refusal — the
# same guard-masks-test trap yoga's 940-f77j fix named in test-gate-stamp.sh.
out="$(cd "$D/work" && issue_pass_token && bash scripts/gate-stamp.sh write --scope nonsense 2>&1)"
rc=$?
[ "$rc" != 0 ] || fail "case 6: write accepted an unknown scope class"
[ "$out" = "stale:unknown-scope-class:nonsense" ] || fail "case 6: unexpected verdict '$out'"
echo "ok: case 6 — write refuses an unknown scope class at write time"

# ── case 7: the 668-2xeh plan-only lane still works under a legacy stamp ──────
# The lane never consults scope; the migration must not strand a fragments-only
# push, which is the exact class the lane was built to rescue.
D="$WORK/c7"; make_repo "$D"
before="$(remote_head "$D")"
# Name the fragment validator explicitly. The lane fails closed when neither yq
# nor a runnable tillandsias-plan can parse a pushed plan/index.d/ blob — correct
# behaviour, and fatal to THIS fixture, whose temp repo has an empty target/ and
# which therefore depends on yq being on PATH. No macOS host has yq, so case 7
# failed there for want of a validator while linux-next passed: the arm stopped
# testing the lane's stamp handling and started testing tool availability.
# resolve_plan_binary honours this override, so the lane gets a real reader.
out="$(cd "$D/work" && printf 'packets: []\n' > plan/index.d/lane.yaml && git add -A && git commit -qm frag >/dev/null 2>&1 && TILLANDSIAS_PLAN_BIN="$LANE_PLAN_BIN" git push origin main 2>&1)"
rc=$?
after="$(remote_head "$D")"
[ "$rc" = 0 ] || fail "case 7: plan-only lane broke under the new stamp handling: $out"
printf '%s' "$out" | grep -q 'plan-only lane clean' || fail "case 7: lane did not accept: $out"
[ "$before" != "$after" ] || fail "case 7: lane accepted but the remote did not advance"
echo "ok: case 7 — the 668-2xeh plan-only lane is preserved intact"

echo "PASS: gate-stamp-scope (8/8)"
