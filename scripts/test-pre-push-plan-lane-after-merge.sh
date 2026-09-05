#!/usr/bin/env bash
# @trace order:1056-5344
#
# test-pre-push-plan-lane-after-merge.sh — on a platform branch the plan-only
# lane must survive the MANDATED merge of origin/linux-next, and must not
# become a way to smuggle code past the gate.
#
# THE DEFECT. methodology pull_merge_cadence.pre_push_gate requires merging
# origin/linux-next into a platform branch before EVERY push. That merge brings
# other hosts' non-plan files into the diff against the platform remote, and the
# lane judges that whole diff — so a one-file ledger append costs the floor a
# full gate whenever anyone touched a code file on trunk. The two rules compose
# into "plan-only only if trunk has not moved", and the busier the trunk the
# less reachable the lane. FOUND by esmeraldinha 2026-09-05T04:3xZ with a
# ledger-only cycle; trunk was landing several times an hour that night.
#
# WHY EVERY ARM HERE IS CROSS-BRANCH, and this is the trap that makes a
# careless fixture worthless. MEASURED while designing this: a repro that
# merges origin/main into main on the SAME branch does not reproduce the defect
# at all — the remote already contains the foreign file, so it never enters
# `git diff remote..local` and the lane is never disqualified. Both the broken
# and the fixed formulation look correct there. The defect exists only when the
# merge SOURCE and the push TARGET are different refs, which is esmeraldinha's
# actual shape: origin/linux-next merged into windows-next, where linux-next's
# files genuinely are new relative to the target. A same-branch fixture would
# pass against the unfixed hook and prove nothing.
#
# WHY --first-parent AND NOT --no-merges ALONE. "The paths this push's own
# non-merge commits touch" reads naturally as
# `git log --no-merges remote..local`, and that is WRONG: a commit arriving
# through the mandated merge is itself a non-merge commit newly reachable on
# the ref, so it is included and the scoped set is identical to the status quo.
# Measured: that formulation returned the foreign README alongside the ledger
# fragment. `--first-parent --no-merges` returned the fragment alone. Arm 1
# fails against the naive reading.
#
# WHY ARM 3 EXISTS — --first-parent ALONE IS A BYPASS. A host can commit code
# on a side branch, merge it with --no-ff, and push; the code arrives through
# the second parent and the first-parent view cannot see it. That is not the
# un-gated union this order knowingly accepts (trunk's own content, gated when
# the coordinator merges into linux-next); it is arbitrary unreviewed code
# taking a lane that exists for ledger appends. The condition that closes it:
# scope to the first-parent view ONLY IF every merge in the pushed range has a
# second parent that is an ancestor of origin/linux-next. Arm 3 is the negative
# control for it, and without arm 3 this fixture licenses a hole.
#
# Hermetic: local bare remote, no network, no credentials.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/hooks/pre-push-local-gate.sh"
fail=0; pass=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail+1)); }

# ── A VALIDATOR, HANDED OVER HERMETICALLY (macbookair, 2026-09-05) ──────────
#
# THIS FIXTURE TOOK EVERY macOS HOST OUT OF THE LANDING PATH. Arms 1, 4 and 5
# failed at trunk HEAD with:
#   plan-only lane: not applicable — neither yq nor target/release/tillandsias-plan
#   is available to validate fragments (fail closed; full gate required)
# so the gate refused and no macOS host could land anything.
#
# WHY IT PASSED ON LINUX AND NOWHERE ELSE. The hook resolves its validator with
# cwd inside the SCRATCH repo, which by construction has no target/, so
# resolve_plan_binary walks past every checkout candidate and reaches
# `command -v tillandsias-plan`. On a Linux host with ~/.local/bin on PATH that
# silently succeeds; on macOS, where that is absent and yq is absent by policy,
# the lane fails closed — correctly. The fixture was depending on ambient host
# tooling and calling it a lane property.
#
# It is the SAME defect I fixed in test-pre-push-issue-capture-lane.sh for
# 1058-fenk hours earlier — a cwd-relative probe in a script that has cd-ed into
# scratch — and I left it in the fixture I was writing at the time. macbookair's
# discriminating measurement is what separated the two candidate causes: putting
# a stub yq on PATH changed nothing, so the fault was how the temp repo reaches
# a validator, not which tools the host has.
#
# So the checkout's OWN binary is resolved here, in the checkout, where the
# probe can see it — and resolving EXECUTES `capabilities`, so what is exported
# below has been run, not merely found. That matters because the probe honours
# an explicit TILLANDSIAS_PLAN_BIN on existence alone (1060-wxdh): handing over
# an unverified path is exactly the shape that installed a dead binary over a
# canonical copy on yoga.
_validator="$(cd "$ROOT" && . scripts/plan-binary-probe.sh && resolve_plan_binary 2>/dev/null)" || _validator=""
case "$_validator" in ./*) _validator="$ROOT/${_validator#./}" ;; esac
if [ -n "$_validator" ]; then
    export TILLANDSIAS_PLAN_BIN="$_validator"
elif command -v yq >/dev/null 2>&1; then
    : # yq alone satisfies the lane's fragment validation
else
    # NAMED SKIP, NOT RED. A host with no validator cannot exercise the lane's
    # acceptance arms, and refusing there would red the gate for missing
    # tooling rather than for a lane defect — which is how this fixture took
    # macOS out of the landing path in the first place.
    echo "skip:plan-lane-after-merge:no-validator — no runnable tillandsias-plan and no yq, so the lane cannot validate fragments on this host; the acceptance arms would fail on tooling, not behaviour" >&2
    echo "plan-lane-after-merge: 0 passed, 0 failed (skipped)"
    exit 0
fi

W="$(mktemp -d "${TMPDIR:-/tmp}/prepush-lane-merge.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM
export GIT_TERMINAL_PROMPT=0
G() { git -c user.email=t@t -c user.name=t "$@"; }

git init -q --bare "$W/bare.git"
git init -q -b linux-next "$W/wc"
cd "$W/wc" || exit 2
git remote add origin "$W/bare.git"
# core.hooksPath is GLOBAL and OVERRIDES .git/hooks; a forge sets it in
# ~/.gitconfig and the seeding push below would run the REAL hooks against this
# scratch tree. Same trap already documented in test-pre-push-issue-capture-lane.sh.
git config core.hooksPath .git/hooks
# CRLF noise is not a finding. On the Windows floor every arm logged "LF will be
# replaced by CRLF" for the scratch repos' own files, which reads like a fixture
# fault and is not one (esmeraldinha, 2026-09-05, where all 5 arms passed under
# MSYS git on drvfs). Pinning it keeps the output legible so a real message is
# not lost among warnings about files this fixture wrote itself.
git config core.autocrlf false
# The guard sources siblings relative to itself, so it must sit at scripts/hooks/.
mkdir -p scripts/hooks plan/index.d
cp "$GUARD" scripts/hooks/pre-push-local-gate.sh
for f in plan-binary-probe.sh gate-stamp.sh common.sh; do
    cp "$ROOT/scripts/$f" "scripts/$f" 2>/dev/null || true
done
chmod +x scripts/*.sh scripts/hooks/*.sh 2>/dev/null || true
printf 'packets: []\n' > plan/index.yaml
printf 'base\n' > README.md
G add -A >/dev/null; G commit -q -m base
git push -q -u origin linux-next
# Both platform branches start level, as they do in the fleet.
git push -q origin linux-next:windows-next

# Trunk moves with another host's NON-PLAN file — the condition that
# disqualifies the lane today.
printf 'base\nchanged by another host\n' > README.md
G add -A >/dev/null; G commit -q -m "foreign code change on trunk"
git push -q origin linux-next
G reset -q --hard origin/linux-next~1

# Drive the guard the way git does: one ref line on stdin, pushing WINDOWS-NEXT.
run_guard() {
    local rsha; rsha="$(git rev-parse origin/windows-next)"
    printf 'refs/heads/windows-next %s refs/heads/windows-next %s\n' \
        "$(git rev-parse HEAD)" "$rsha" \
        | bash scripts/hooks/pre-push-local-gate.sh 2>&1
}

# `reset --hard` does not recreate plan/index.d/ (it holds no tracked files in
# this scratch base), and a write into a missing directory fails SILENTLY as far
# as the arm is concerned: the commit is then empty, the push carries nothing,
# and the guard refuses for "no changes" — so a scope arm PASSES while testing
# nothing. Both arms 2 and 3 did exactly that on the first run of this fixture.
reset_branch() { G reset -q --hard origin/windows-next; git clean -qfd; mkdir -p plan/index.d scripts/hooks; }

G checkout -q -B windows-next origin/windows-next
mkdir -p plan/index.d

# ── ARM 1: a ledger-only cycle takes the lane after the mandated merge ──────
printf 'packets: []\n' > plan/index.d/20260905t000000z-fixture.yaml
G add -A >/dev/null; G commit -q -m "ledger append"
G fetch -q origin
G merge -q --no-edit origin/linux-next -m "mandated merge of origin/linux-next"
out="$(run_guard)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'plan-only lane'; then
    ok "ARM 1: ledger-only push takes the lane despite a merge carrying foreign code"
else
    bad "ARM 1: lane refused a ledger-only push after the mandated merge (rc=$rc)"
    printf '%s\n' "$out" | sed 's/^/      /' >&2
fi

# ── ARM 2: the host's OWN code change still requires the full gate ──────────
reset_branch
printf 'packets: []\n' > plan/index.d/20260905t000001z-fixture.yaml
printf 'fn main() {}\n' > own_code.rs
G add -A >/dev/null; G commit -q -m "ledger append PLUS the host's own code"
G merge -q --no-edit origin/linux-next -m "mandated merge of origin/linux-next"
# NON-VACUITY: prove the file the arm depends on is actually in the push.
# Captured, not piped into `if !`: grep -q exits on its first match and
# SIGPIPEs the producer, which under pipefail inverts the guard (795-imz3) —
# and a non-vacuity check that reports the wrong answer is worse than none.
_outgoing="$(G diff --name-only origin/windows-next HEAD)"
case "$_outgoing" in
    *own_code.rs*) ;;
    *) bad "ARM 2 is VACUOUS — own_code.rs is not in the outgoing diff; the arm would pass on an empty push" ;;
esac
out="$(run_guard)"; rc=$?
if [ "$rc" -ne 0 ]; then
    ok "ARM 2: a push whose own commits touch code still requires the full gate"
else
    bad "ARM 2: the lane accepted a push carrying the host's own code file"
    printf '%s\n' "$out" | sed 's/^/      /' >&2
fi

# ── ARM 3: NEGATIVE CONTROL — code hidden behind a NON-TRUNK merge ──────────
# Without this arm the fix is a hole rather than a lane: --first-parent alone
# cannot see a second parent, so a side-branch merge would smuggle code through.
reset_branch
G branch -q -D side 2>/dev/null || true
G checkout -q -b side
printf 'fn sneaky() {}\n' > sneaky.rs
G add -A >/dev/null; G commit -q -m "code parked on a side branch"
G checkout -q windows-next
printf 'packets: []\n' > plan/index.d/20260905t000002z-fixture.yaml
G add -A >/dev/null; G commit -q -m "ledger append"
G merge -q --no-ff --no-edit side -m "merge side branch"
G merge -q --no-edit origin/linux-next -m "mandated merge of origin/linux-next"
# Captured, not piped into `if !`: grep -q exits on its first match and
# SIGPIPEs the producer, which under pipefail inverts the guard (795-imz3) —
# and a non-vacuity check that reports the wrong answer is worse than none.
_outgoing="$(G diff --name-only origin/windows-next HEAD)"
case "$_outgoing" in
    *sneaky.rs*) ;;
    *) bad "ARM 3 is VACUOUS — sneaky.rs is not in the outgoing diff; the arm would pass on an empty push" ;;
esac
out="$(run_guard)"; rc=$?
if [ "$rc" -ne 0 ]; then
    ok "ARM 3: code arriving via a NON-TRUNK merge still requires the full gate"
else
    bad "ARM 3: BYPASS — code hidden behind a side-branch merge took the plan-only lane"
    printf '%s\n' "$out" | sed 's/^/      /' >&2
fi

# ── ARM 4: the un-gated union is RECORDED, not implied ──────────────────────
# Criterion 3. A lane that scopes past a merge accepts a head neither side
# gated together (754-kptj). The debt has to be a fact on disk that the
# coordinator's land can read, not something a reader infers from topology.
reset_branch
rm -f .git/tillandsias-union-ungated
printf 'packets: []\n' > plan/index.d/20260905t000003z-fixture.yaml
G add -A >/dev/null; G commit -q -m "ledger append"
G merge -q --no-edit origin/linux-next -m "mandated merge of origin/linux-next"
out="$(run_guard)"; rc=$?
if [ "$rc" -eq 0 ] && [ -s .git/tillandsias-union-ungated ] \
   && printf '%s' "$out" | grep -q 'UN-GATED UNION'; then
    ok "ARM 4: the lane records the un-gated union for the coordinator's land"
else
    bad "ARM 4: the lane took a merge-scoped push without recording the union debt (rc=$rc)"
    printf '%s\n' "$out" | sed 's/^/      /' >&2
fi

# ── ARM 5: no merge in the range writes NO marker ───────────────────────────
# The debt must be recorded only when it is actually incurred; a marker on
# every plan push would make the signal meaningless and land would clear it
# forever without it ever having meant anything.
reset_branch
rm -f .git/tillandsias-union-ungated
printf 'packets: []\n' > plan/index.d/20260905t000004z-fixture.yaml
G add -A >/dev/null; G commit -q -m "ledger append, no merge"
out="$(run_guard)"; rc=$?
if [ "$rc" -eq 0 ] && [ ! -s .git/tillandsias-union-ungated ]; then
    ok "ARM 5: a push with no merge takes the lane and records no union debt"
else
    bad "ARM 5: a merge-free push either failed the lane or recorded a spurious union marker (rc=$rc)"
    printf '%s\n' "$out" | sed 's/^/      /' >&2
fi

echo "plan-lane-after-merge: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
