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
# A shared work-queue ledger for the 1013-xm63 arms. Several hosts append to one
# of these, which is why an append and a rewrite are different in kind here.
printf -- '- 2026-09-01 macuahuitl: See `main.rs` `resolve_probe`.\n' > plan/issues/linux-next-work-queue-2026-05-25.md
G add -A >/dev/null; G commit -q -m base
git push -q -u origin linux-next

# PRECONDITION, not an arm (lenovinha, 889-twhe): the fix above made the arms
# depend on this base staying foldable. If it ever stops being, every
# acceptance arm fails for a reason that has nothing to do with the lane — and
# the next reader debugs the lane. Assert the base FIRST so a broken base
# reports as a broken base. Skipped when no plan binary is resolvable, because
# then the lane skips ledger validation too and the base is not load-bearing.
# ORDER 1058-fenk. RUNNABILITY, NOT THE EXECUTABLE BIT. This guard was
# `[ -x "$_probe_bin" ]`, and the bit is a CLAIM while running the binary is
# EVIDENCE — the rule scripts/plan-binary-probe.sh was centralised to enforce,
# rediscovered here the hard way.
#
# MEASURED by pirria 2026-09-05: cycle-preflight builds
# target/release/tillandsias-plan on the HOST, the gate consumes it inside the
# tillandsias-builder toolbox, and on a rolling-release host whose glibc is
# newer than the image (CachyOS 2.44 vs fedora-toolbox:42) the ELF runs on the
# host and cannot link in the toolbox:
#   ./target/release/tillandsias-plan: /lib64/libm.so.6: version `GLIBC_2.44' not found
# `[ -x ]` is true for that file. So an unlinkable binary took the branch meant
# for a present one, the fold failed for an environment reason, and the
# precondition reported a FAIL. Every gate on that host was red from 19:07Z at
# a head that had been green while target/release was empty — the variable was
# a host-built artefact, not trunk.
#
# An ELF that cannot link is exactly as unusable as an absent one and must take
# the SAME branch. resolve_plan_binary decides by executing `capabilities`, so
# it answers the question this guard was actually asking.
# RESOLVED FROM $ROOT, NOT FROM THE CURRENT DIRECTORY. This script has already
# `cd`-ed into the scratch repo by this point, and the probe's candidates are
# cwd-relative (./target/release/...), so resolving here searched a tree that by
# construction has no target/ and fell through to `command -v`. On a host with
# ~/.local/bin on PATH that silently still worked; INSIDE THE BUILDER TOOLBOX,
# where it is not, every ledger arm quietly stopped being exercised — a green
# fixture measuring nothing. Caught by this file's own control arm, which is
# the argument for having one. The replaced `[ -x "$ROOT/target/..." ]` was
# absolute and had no such dependency, so the runnability fix must not
# introduce one.
_probe_bin="$(cd "$ROOT" && . scripts/plan-binary-probe.sh && resolve_plan_binary)" || _probe_bin=""
case "$_probe_bin" in
    ./*) _probe_bin="$ROOT/${_probe_bin#./}" ;;
    ""|/*) ;;
    *) _probe_bin="$ROOT/$_probe_bin" ;;
esac
# shellcheck source=scripts/plan-binary-probe.sh
. "$ROOT/scripts/plan-binary-probe.sh"
# An explicit TILLANDSIAS_PLAN_BIN is honoured by the probe on EXISTENCE alone
# (deliberately — a stub that fails like a stale binary must stay
# distinguishable from an absent one), so runnability still has to be asked
# here rather than assumed from a successful resolve.
_probe_why=""
if [ -n "$_probe_bin" ]; then
    _probe_why="$("$_probe_bin" capabilities 2>&1 >/dev/null)" || _probe_bin=""
else
    # RECOVER THE REASON. resolve_plan_binary answers "which binary can I run"
    # and discards WHY each candidate lost — correct for its job, useless for a
    # skip message. "no runnable binary" and "the binary you built cannot link
    # here" send a reader to completely different places, and it was not
    # knowing which that cost pirria a day of red gates. So if a file IS sitting
    # at the conventional path, run it once and keep what it says.
    for _cand in "${CARGO_TARGET_DIR:-$ROOT/target}/release/tillandsias-plan" \
                 "$ROOT/target/release/tillandsias-plan"; do
        [ -f "$_cand" ] || continue
        _probe_why="$("$_cand" capabilities 2>&1 >/dev/null)" && continue
        _probe_why="${_probe_why:-$_cand exists but did not run}"
        break
    done
fi
if [ -z "$_probe_bin" ] && ! command -v yq >/dev/null 2>&1; then
    # NO VALIDATOR AT ALL. The lane must fail closed here (correctly), so every
    # arm below that expects ACCEPTANCE would fail on host tooling rather than on
    # lane behaviour — which is exactly how a sibling fixture took macOS out of
    # the landing path (1056-5344). Skip the whole file with a name.
    echo "skip:issue-capture-lane:no-validator — ${_probe_why:-no runnable tillandsias-plan} and no yq, so the lane cannot validate fragments here; the acceptance arms would fail on tooling, not behaviour" >&2
    echo "issue-capture-lane: 0 passed, 0 failed (skipped)"
    exit 0
fi
if [ -z "$_probe_bin" ]; then
    # NAMED, never silent: a skip that does not say why is indistinguishable
    # from a check that passed.
    echo "skip:plan-binary-not-runnable-here:${_probe_why:-no runnable tillandsias-plan resolved}" >&2
    echo "  The lane skips ledger validation without a runnable binary, so the" >&2
    echo "  scratch base is not load-bearing and the arms below still mean what" >&2
    echo "  they say. This is host state, not a lane defect (1058-fenk)." >&2
elif ( cd "$W/wc" && "$_probe_bin" --index plan/index.yaml check >/dev/null 2>&1 ); then
    ok "PRECONDITION: the scratch base ledger folds"
else
    echo "FAIL: PRECONDITION — the scratch base ledger does not fold; the arms below would fail for an environment reason, not a lane defect" >&2
    echo "issue-capture-lane: 0 passed, 1 failed"
    exit 1
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
# ORDER 1060-7mmm: ANY "not applicable" is a disqualification, not just the
# out-of-scope spelling. This helper used to check for one refusal string, so an
# arm asserting qualification passed while the lane was refusing for a DIFFERENT
# reason — measured here: the new M-qualifies arm was green against the pre-fix
# hook, which refuses an M with "has status 'M' ... only NEW issue captures
# qualify". That is the same defect as pinning one spelling of a class
# (1060-6fx7): a control that names one refusal certifies the others away.
lane_qualified() { ! grep -qE "plan-only lane: not applicable" <<<"$1"; }
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

# ── 3. A MODIFIED capture now QUALIFIES (order 1060-7mmm) ──────────────────
# THIS ARM WAS INVERTED, DELIBERATELY. It previously asserted that an M is
# refused, by analogy with the fragment arms — but the analogy does not hold.
# plan/index.d/ entries are CRDT records whose contract is append-only, so an M
# there is a corrupted ledger; a plan/issues capture is PROSE, and correcting it
# is the ordinary way it improves.
#
# esmeraldinha measured the asymmetry on 2026-09-05: the lane accepted the
# CREATION of a smoke report unreviewed and refused a FOUR-CHARACTER fix to it
# (a cited order id, 1029-5vwd, with no referent). A lane whose economics favour
# appending a new record over correcting an existing one selects for records
# that read as settled while carrying something wrong.
#
# The blast radius is unchanged and that is the argument: the M is validated
# per-file by check-issue-citation-convention against the PUSHED bytes, the same
# gate the A path runs, and case 3b below asserts an M elsewhere still takes the
# full gate.
printf 'See `main.rs` `resolve_probe`.\n' >> plan/issues/existing.md
G add -A >/dev/null; G commit -q -m "correct an existing capture"
out="$(run_guard)"
if lane_qualified "$out"; then
    ok "a CORRECTED capture (M under plan/issues/) qualifies for the lane"
else
    bad "a corrected capture was refused: $(grep -m1 'plan-only lane' <<<"$out")"
fi
reset_to_remote

# ── 3b. NEGATIVE CONTROL: an M ELSEWHERE still takes the full gate ─────────
# Without this, case 3 alone would be satisfied by admitting every M — which is
# the escape hatch this lane exists to keep shut. build.sh can reach the build.
printf '\n# touched by a fixture\n' >> build.sh
G add -A >/dev/null; G commit -q -m "modify build.sh"
out="$(run_guard)"
grep -q 'plan-only lane clean' <<<"$out" \
    && bad "a MODIFIED build.sh rode the lane" \
    || ok "a MODIFIED file outside the plan dirs still takes the full gate"
reset_to_remote

# ── 3c. A DELETED capture is still refused ────────────────────────────────
# D stays out: the lane cannot validate the absence of a record.
G rm -q plan/issues/existing.md
G commit -q -m "delete a capture"
out="$(run_guard)"
grep -q 'plan-only lane clean' <<<"$out" \
    && bad "a DELETED capture rode the lane" \
    || ok "a DELETED capture still takes the full gate"
reset_to_remote

# ── 3d. AN APPEND to a work-queue ledger qualifies (order 1013-xm63) ───────
# pirria's case: a cargo-less host can work and report but not COMPLY, because
# the worker skill's §6.3 mandates a work-queue line and that is an M by
# construction. The refusal sent it to a full gate it had no toolchain to run,
# and it complied by filing a NEW capture instead — fragmenting its history away
# from the queue a reader actually consults.
#
# PRESENCE OF THE SUCCESS, not absence of a failure string: this asserts the
# lane NAMED the validated file, which only happens on the accepting path. A
# control that tests for the absence of a particular refusal is only as strong
# as the enumeration of refusals, and that enumeration is never complete
# (1060-7mmm).
printf -- '- 2026-09-05 pirria: See `lib.rs` `resolve_plan_binary`.\n' >> plan/issues/linux-next-work-queue-2026-05-25.md
G add -A >/dev/null; G commit -q -m "append a work-queue line"
out="$(run_guard)"
grep -q 'plan-only lane: validated plan/issues/linux-next-work-queue-2026-05-25.md' <<<"$out" \
    && ok "an APPEND to a work-queue ledger qualifies and is named" \
    || bad "an append to a work-queue ledger was refused: $(grep -m1 'plan-only lane' <<<"$out")"
reset_to_remote

# ── 3e. A REWRITE of a work-queue ledger is still refused ──────────────────
# The negative control for 3d, and the reason the work-queue case is narrower
# than 1060-7mmm's: several hosts share this document, so the lane cannot tell a
# correction from an erasure of a sibling's line, and neither can a reader.
printf -- '- 2026-09-01 macuahuitl: REWRITTEN, and the original line is gone.\n' \
    > plan/issues/linux-next-work-queue-2026-05-25.md
G add -A >/dev/null; G commit -q -m "rewrite the work-queue ledger"
out="$(run_guard)"
if grep -q 'is a work-queue ledger and this edit REMOVES or REWRITES lines' <<<"$out"; then
    ok "a REWRITE of a work-queue ledger takes the full gate, naming the hunk"
else
    bad "a rewrite of a work-queue ledger was not refused by name: $(grep -m1 'plan-only lane' <<<"$out")"
fi
reset_to_remote

# ── 3f. A correction to NON-queue prose is still free (1060-7mmm holds) ────
# Guards the interaction: 1013-xm63 must not re-impose append-only on the
# ordinary report corrections 1060-7mmm deliberately enabled an hour earlier.
printf 'See `lib.rs` `other_fn`.\n' >> plan/issues/existing.md
G add -A >/dev/null; G commit -q -m "correct a non-queue capture"
out="$(run_guard)"
grep -q 'plan-only lane: validated plan/issues/existing.md' <<<"$out" \
    && ok "a correction to a non-queue capture is still free (1060-7mmm intact)" \
    || bad "the work-queue rule leaked onto ordinary captures: $(grep -m1 'plan-only lane' <<<"$out")"
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
# ORDER 1060-6fx7: hand over a binary that RUNS, or none at all. This used to
# export $ROOT/target/release/tillandsias-plan unconditionally, and the probe
# honours an explicit override on existence alone — so on a host where that file
# exists and cannot link, the lane took it as a validator and reported the
# LEDGER refused. $_probe_bin above is resolved AND executed, so exporting it is
# a claim the fixture has evidence for.
[ -n "$_probe_bin" ] && export TILLANDSIAS_PLAN_BIN="$_probe_bin"
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
