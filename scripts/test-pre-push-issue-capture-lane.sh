#!/usr/bin/env bash
# @trace order:889-twhe, order:881-29me, order:863-iicc
#
# test-pre-push-issue-capture-lane.sh — pin that the pre-push plan-only lane
# admits NEW plan/issues captures, and pin every boundary of that admission.
#
# WHY THE LANE WAS WIDENED. The meta-orchestration Reduction Engine makes
# filing a plan/issues capture a NON-NEGOTIABLE exit condition of every cycle
# ("an unfiled finding is a lost finding and a contract violation"), and this
# lane's allowlist covered the ledger overlays the loop writes while excluding
# exactly that path. So the loop's own mandatory step forced every
# finding-bearing cycle onto the full gate, on every host, every cycle.
# Measured on calmecacpilli 2026-08-25: 4.0 gate re-runs for ONE landed commit
# carrying two captures (107s + 110s + 121s + 122s), against 0 re-runs for the
# fragment-only pushes in the same session, at a 3.05 min mean inter-push gap.
# The losses COMPOUND rather than add — each rebase invalidates the build stamp
# and buys another ticket in the same race.
#
# WHY IT IS NARROW. This widens what may bypass the trunk's ONLY remaining
# gate, so the coordinator's ruling attached four conditions, and each arm
# below pins one of them:
#
#   (a) NEW files only — arms 1, 3
#   (b) validated in the lane by check-issue-citation-convention, not merely
#       allowed — arms 2, 6
#   (c) explicit depth + prose guards, copied from the attestation arm — arms
#       4, 5, 7
#   (d) A NEGATIVE CONTROL: a malformed capture must FALL BACK to the full
#       gate, demonstrated rather than argued — arm 2
#
# Arm 2 is the one that matters. Without it this is a hole rather than a lane:
# it proves the lane REFUSES a capture whose citations violate 881-29me, so
# admission is contingent on validation actually running against the pushed
# bytes.
#
# Hermetic: local bare remote, no network, no credentials. Scratch tree removed
# on exit.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/hooks/pre-push-local-gate.sh"
CHECKER="$ROOT/scripts/check-issue-citation-convention.sh"
fail=0; pass=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail+1)); }

W="$(mktemp -d "${TMPDIR:-/tmp}/prepush-issue-lane.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM
export GIT_TERMINAL_PROMPT=0
G() { git -c user.email=t@t -c user.name=t "$@"; }

git init -q --bare "$W/bare.git"
git init -q -b linux-next "$W/wc"
cd "$W/wc" || exit 2
git remote add origin "$W/bare.git"
# core.hooksPath is GLOBAL and OVERRIDES .git/hooks — pin it per scratch repo.
# A forge provisions core.hooksPath=~/.cache/tillandsias/git-hooks in
# ~/.gitconfig, and git's rule is that a set core.hooksPath replaces the
# per-repo hooks directory outright. The seeding `git push -u origin linux-next`
# below would then run the REAL forge hooks against this scratch tree, fail, and
# leave refs/remotes/origin/linux-next unset — so every arm that needs a remote
# base reported "remote base origin/linux-next is not present locally" and the
# fixture read 6 passed / 4 failed on EVERY forge in the fleet, for a reason
# entirely outside the behaviour under test. Same defect, same day, as the one
# fixed in test-pre-push-empty-ref-list.sh: a fixture that drives git must pin
# core.hooksPath or the ambient config silently substitutes its own hooks.
git config core.hooksPath .git/hooks
# The guard must sit at scripts/hooks/ in the scratch tree too: it sources
# ../plan-binary-probe.sh relative to itself, so a flattened copy silently
# loses its validator and every lane arm fails on a missing tool.
mkdir -p scripts/hooks plan/issues plan/index.d
cp "$GUARD" scripts/hooks/pre-push-local-gate.sh
cp "$CHECKER" scripts/check-issue-citation-convention.sh
# The guard sources/execs these; without gate-stamp.sh in particular the stamp
# check cannot run and the scratch push is accepted by the FULL-GATE path, so
# the lane never executes and every arm below would silently test nothing.
for f in plan-binary-probe.sh gate-stamp.sh common.sh; do
    cp "$ROOT/scripts/$f" "scripts/$f" 2>/dev/null || true
done
chmod +x scripts/*.sh scripts/hooks/*.sh
# ORDER 889-twhe, FIXTURE CORRECTION. The scratch tree needs a REAL base
# ledger. Without plan/index.yaml, `tillandsias-plan check` cannot fold, the
# lane's ledger validation fails for an environment reason, and the acceptance
# arms below can never pass — but ONLY on a host where a plan binary is
# resolvable. On a host with no binary the lane skips that validation and the
# same arms pass. So the fixture's verdict depended on whether the host had a
# plan binary in scope, which is exactly the "environment quietly does not
# reproduce the condition" shape this file exists to catch. Caught on
# macuahuitl, where it blocked the trunk's only gate.
printf 'packets: []\n' > plan/index.yaml
printf 'base\n' > plan/issues/existing.md
G add -A >/dev/null; G commit -q -m base
git push -q -u origin linux-next

# PRECONDITION, not an arm (lenovinha, 889-twhe): the fix above made the arms
# depend on this base staying foldable. If it ever stops being, every
# acceptance arm fails for a reason that has nothing to do with the lane — and
# the next reader debugs the lane. Assert the base FIRST so a broken base
# reports as a broken base. Skipped when no plan binary is resolvable, because
# then the lane skips ledger validation too and the base is not load-bearing.
_probe_bin="${TILLANDSIAS_PLAN_BIN:-$ROOT/target/release/tillandsias-plan}"
if [ -x "$_probe_bin" ]; then
    if ( cd "$W/wc" && "$_probe_bin" --index plan/index.yaml check >/dev/null 2>&1 ); then
        ok "PRECONDITION: the scratch base ledger folds"
    else
        echo "FAIL: PRECONDITION — the scratch base ledger does not fold; the arms below would fail for an environment reason, not a lane defect" >&2
        echo "issue-capture-lane: 0 passed, 1 failed"
        exit 1
    fi
fi

# Drive the guard the way git does: one "<lref> <lsha> <rref> <rsha>" line on
# stdin. No stamp exists in this scratch tree, so the lane is the ONLY thing
# that can accept a push here — which is exactly what makes each arm decisive.
run_guard() {
    local rsha; rsha="$(git rev-parse origin/linux-next)"
    printf 'refs/heads/linux-next %s refs/heads/linux-next %s\n' "$(git rev-parse HEAD)" "$rsha" \
        | bash scripts/hooks/pre-push-local-gate.sh 2>&1
}
reset_to_remote() { G reset -q --hard origin/linux-next; git clean -qfd; mkdir -p plan/issues plan/index.d scripts/hooks; printf "packets: []\n" > plan/index.yaml; }

# ── 1. (a) A NEW top-level capture with symbol citations is ADMITTED. ──────
printf 'The const lives in `main.rs` `build_git_run_args`.\n' > plan/issues/new-capture.md
G add -A >/dev/null; G commit -q -m "file a capture"
out="$(run_guard)"
# QUALIFICATION is the assertion, not acceptance. Whether the lane's ledger
# validation succeeds is an environment fact about the sandbox; whether the
# path is turned away as outside the allowlist is the behaviour 889-twhe
# changed. The CONTROL arm always drew that distinction; the acceptance arms
# did not, and that inconsistency is what made this fixture host-dependent.
lane_qualified() { ! grep -q "is outside plan/index.d/" <<<"$1"; }
if lane_qualified "$out" && grep -qE 'plan-only lane clean|plan-only lane: validated plan/issues/new-capture.md' <<<"$out"; then
    ok "a NEW plan/issues capture qualifies for the lane"
else
    bad "new capture was turned away: $(grep -m1 'not applicable\|FAILED\|refused' <<<"$out")"
fi
grep -q 'plan-only lane: validated plan/issues/new-capture.md' <<<"$out" \
    && ok "the push record NAMES the validated capture" \
    || bad "the accepted capture was not named in the push record"
reset_to_remote

# ── 2. (d) THE NEGATIVE CONTROL: a capture whose citations violate 881-29me
#      must FALL BACK to the full gate. Without this arm the lane is a hole.
printf 'The const lives at `main.rs:1136-1145`.\n' > plan/issues/bad-capture.md
G add -A >/dev/null; G commit -q -m "file a capture with a line citation"
out="$(run_guard)"
if grep -q 'plan-only lane clean' <<<"$out"; then
    bad "NEGATIVE CONTROL BREACHED — a line-number citation rode the lane"
else
    grep -q 'check-issue-citation-convention' <<<"$out" \
        && ok "a malformed capture falls back to the full gate, naming 881-29me" \
        || ok "a malformed capture falls back to the full gate"
fi
reset_to_remote

# ── 3. (a) A MODIFIED capture is refused — captures are immutable here for
#      the same reason fragments are: a new file is a capture, a modified one
#      can carry anything.
printf 'appended\n' >> plan/issues/existing.md
G add -A >/dev/null; G commit -q -m "modify an existing capture"
out="$(run_guard)"
grep -q 'plan-only lane clean' <<<"$out" \
    && bad "a MODIFIED plan/issues file rode the lane" \
    || ok "a MODIFIED capture takes the full gate"
reset_to_remote

# ── 4. (c) A class subdirectory is admitted at exactly one level deep. ─────
mkdir -p plan/issues/optimization
printf 'See `main.rs` `resolve_probe`.\n' > plan/issues/optimization/scoped.md
G add -A >/dev/null; G commit -q -m "file under a class directory"
out="$(run_guard)"
if lane_qualified "$out" && grep -qE 'plan-only lane clean|plan-only lane: validated plan/issues/optimization/scoped.md' <<<"$out"; then
    ok "a capture under optimization/ qualifies for the lane"
else
    bad "a class-directory capture was turned away: $(grep -m1 'not applicable\|FAILED' <<<"$out")"
fi
reset_to_remote

# ── 5. (c) Deeper than one level, and unknown directories, are refused. ────
mkdir -p plan/issues/optimization/deeper
printf 'text\n' > plan/issues/optimization/deeper/x.md
G add -A >/dev/null; G commit -q -m "file too deep"
out="$(run_guard)"
grep -q 'plan-only lane clean' <<<"$out" \
    && bad "a capture nested two levels deep rode the lane" \
    || ok "a capture nested two levels deep takes the full gate"
reset_to_remote

mkdir -p plan/issues/unsanctioned
printf 'text\n' > plan/issues/unsanctioned/x.md
G add -A >/dev/null; G commit -q -m "file under an unknown directory"
out="$(run_guard)"
grep -q 'plan-only lane clean' <<<"$out" \
    && bad "a capture under an unsanctioned directory rode the lane" \
    || ok "an unsanctioned class directory takes the full gate"
reset_to_remote

# ── 6. (b) A capture pushed ALONGSIDE code takes the full gate. The lane is
#      all-or-nothing; one non-plan path disqualifies the whole push.
printf 'See `main.rs` `resolve_probe`.\n' > plan/issues/with-code.md
printf 'echo hi\n' > scripts/some-code.sh
G add -A >/dev/null; G commit -q -m "capture plus code"
out="$(run_guard)"
grep -q 'plan-only lane clean' <<<"$out" \
    && bad "a push mixing a capture with code rode the lane" \
    || ok "a capture pushed alongside code takes the full gate"
reset_to_remote

# ── 7. (c) README.md under plan/issues is prose, not a capture. ────────────
printf 'How to file issues. See `main.rs` `main`.\n' > plan/issues/README.md
G add -A >/dev/null; G commit -q -m "add a README"
out="$(run_guard)"
grep -q 'plan-only lane clean' <<<"$out" \
    && bad "plan/issues/README.md rode the lane as if it were a capture" \
    || ok "plan/issues/README.md is prose and takes the full gate"
reset_to_remote

# ── 8. CONTROL: the pre-889 lanes still work, so this change is additive. ──
# Point the lane's validator at this checkout's real plan binary; the scratch
# tree has no target/. Without it the control arm would fail on a missing tool
# rather than on the behaviour it exists to protect.
export TILLANDSIAS_PLAN_BIN="${TILLANDSIAS_PLAN_BIN:-$ROOT/target/release/tillandsias-plan}"
printf 'packets: []\n' > plan/index.d/20260101t000000z-control.yaml
G add -A >/dev/null; G commit -q -m "a plain fragment"
out="$(run_guard)"
# The assertion is QUALIFICATION, not acceptance, and the distinction is the
# point: this scratch tree has no plan/index.yaml base, so `tillandsias-plan
# check` cannot fold a ledger here and the fragment fails VALIDATION for an
# environment reason. What must not happen is the fragment failing
# QUALIFICATION — being turned away as outside the allowlist — because that is
# what a regression in this change would look like.
if grep -q "is outside plan/index.d/" <<<"$out"; then
    bad "CONTROL BROKEN — a plan/index.d fragment no longer qualifies for the lane"
elif grep -qE 'plan-only lane clean|plan-only lane: validation FAILED' <<<"$out"; then
    ok "CONTROL: a plain plan/index.d fragment still qualifies for the lane"
else
    bad "CONTROL: unexpected verdict for a plain fragment: $(grep -m1 'not applicable\|FAILED' <<<"$out")"
fi
reset_to_remote

echo "issue-capture-lane: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "ok:issue-capture-lane:$pass"
