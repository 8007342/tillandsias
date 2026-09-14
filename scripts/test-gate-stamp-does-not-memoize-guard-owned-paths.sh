#!/usr/bin/env bash
# @trace order:1127-waxf, order:930-i6x4, order:1036-e5w9
#
# test-gate-stamp-does-not-memoize-guard-owned-paths.sh — pin that the gate memo
# can tell "nothing moved" from "only the plan ledger moved", so a plan-only
# commit can no longer memoize away the guards written for plan-only commits.
#
# THE DEFECT. `compute` deliberately excludes plan/index.d/*.yaml,
# plan/loop_status.d/*.md and plan/mo-full-attestations.d/*.md (930-i6x4 — a
# sound optimisation: without it every sibling landing staled a stamp that
# remained true of every byte of code). Its side effect is that those are
# EXACTLY the paths check-fragment-status-loss.sh and
# `tillandsias-plan check --strict-fragments` exist to read. The exclusion and
# the guards cover the same paths in opposite directions and nothing reconciled
# them, so a commit touching only them could not stale the stamp, the memo
# returned ok:gate-fresh, and the guards never ran.
#
# MEASURED on lenovinha 2026-09-12, before the fix, on the real checkout:
#     (plant a 'completed' event on a packet that folds 'ready')
#     scripts/check-fragment-status-loss.sh -> rc=1, violation:fragment-status-loss:1
#     ./build.sh --check                    -> rc=0 in 2026ms, ok:gate-fresh,
#                                              guard appears 0 times in the log
#   after the fix, same tree:
#     ./build.sh --check                    -> rc=1 in 3310ms, naming the violation
#   and the 930-i6x4 cost control, a CLEAN fragment:
#     ./build.sh --check                    -> rc=0 in 4323ms (guards ran; no full gate)
#
# WHAT THIS FIXTURE COVERS AND WHAT IT DOES NOT, stated rather than implied.
# It drives scripts/gate-stamp.sh directly — the memo DECISION, which is where
# the defect lived. It does NOT invoke ./build.sh: this fixture runs INSIDE
# ./build.sh --check, and a nested gate would clobber the outer run's stamp and
# recurse. The end-to-end numbers above were measured by hand and are recorded
# on the 1127-waxf row; the wiring between the verdict and the guards is pinned
# by arm 5 below, which is a structural assertion rather than an execution.
#
# Hermetic: scratch git repo, no network. Removed on exit.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAMPER="$ROOT/scripts/gate-stamp.sh"
fail=0; pass=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail+1)); }

W="$(mktemp -d "${TMPDIR:-/tmp}/gate-stamp-plan.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM
G() { git -C "$W/wc" -c user.email=t@t -c user.name=t "$@"; }

git init -q -b linux-next "$W/wc"
mkdir -p "$W/wc/scripts" "$W/wc/plan/index.d" "$W/wc/plan/loop_status.d"
cp "$STAMPER" "$W/wc/scripts/gate-stamp.sh"
printf 'code\n' > "$W/wc/scripts/some-code.sh"
printf 'packets: []\n' > "$W/wc/plan/index.yaml"
G add -A >/dev/null 2>&1; G commit -q -m base

S() { ( cd "$W/wc" && bash scripts/gate-stamp.sh "$@" ); }
STAMP_FILE="$W/wc/.git/tillandsias-gate-stamp"

# Write stamps through gate-stamp.sh's OWN write path rather than by hand.
# GATE_STAMP_REQUIRE_TOKEN=0 is the documented bypass for the 940-f77j pass
# token, and using the real writer means the toolchain field is whatever this
# host actually reports — a hand-written one would differ and every arm below
# would die on stale:toolchain-changed for a reason unrelated to this packet.
_stamp_now() { ( cd "$W/wc" && GATE_STAMP_REQUIRE_TOKEN=0 bash scripts/gate-stamp.sh write --dispatch check >/dev/null ); }

D0="$(S compute)"
P0="$(S plan-digest)"

# ── ARM 1: the two digests are INDEPENDENT ──────────────────────────────────
# This is the property the whole fix rests on, and it is the one that could
# silently regress if someone ever "tidies" the 930-i6x4 exclusion.
printf 'packets: []\n' > "$W/wc/plan/index.d/20260912t000000z-probe.yaml"
D1="$(S compute)"; P1="$(S plan-digest)"
if [ "$D0" = "$D1" ]; then
    ok "arm1: adding a plan/index.d fragment does NOT move the code digest (930-i6x4 intact)"
else
    bad "arm1: the code digest moved on a plan fragment — 930-i6x4's exclusion is gone, and every sibling landing will re-gate"
fi
if [ "$P0" != "$P1" ]; then
    ok "arm1: the plan digest DOES move on that same fragment"
else
    bad "arm1: the plan digest did not move — the memo cannot see the ledger at all"
fi

# ── ARM 2: nothing moved -> full memo ───────────────────────────────────────
rm -f "$W/wc/plan/index.d/20260912t000000z-probe.yaml"
_stamp_now
out="$(S memo-check check)"
if [ "${out%% *}" = "ok:gate-fresh" ]; then
    ok "arm2: with both digests matching the memo is still whole-gate fresh (cost path unchanged)"
else
    bad "arm2: expected ok:gate-fresh, got: $out"
fi

# ── ARM 3: only the ledger moved -> the THIRD verdict ────────────────────────
printf 'packets: []\n' > "$W/wc/plan/index.d/20260912t000001z-moved.yaml"
out="$(S memo-check check)"
if [ "${out%% *}" = "ok:gate-fresh-except-plan" ]; then
    ok "arm3: a plan-only change yields ok:gate-fresh-except-plan, not ok:gate-fresh"
else
    bad "arm3: a plan-only change did not produce the partial verdict, got: $out"
fi
# NOT stale: refusing outright would re-impose the cost 930-i6x4 removed, and a
# gate that costs a full run per fragment is the one that gets worked around.
if [ "${out%% *}" = "stale:tree-changed-since-gate" ]; then
    bad "arm3: the memo refused outright — correct about the hole, wrong about the cost (930-i6x4)"
fi

# ── ARM 3b: a plan/issues change takes the SAME lane (1142-85zx) ────────────
# The fourth glob, and the one that motivated 1142-85zx: four of five full-gate
# forcings in one evening were plan-only and all four touched one coordinator
# drill record under plan/issues/. Same verdict as arm 3, and the pairing is
# asserted in both directions below, because excluding from `compute` WITHOUT
# adding to plan_digest yields a full ok:gate-fresh and silently retires the
# issue guard — 1127-waxf's hole, one directory over.
# The scratch worktree carries no plan/issues until a case needs one, and a
# printf into a missing directory fails silently enough to look like a verdict
# about the digest. Create it, then re-stamp so this arm starts from a CLEAN
# memo rather than inheriting arm 3's moved fragment.
mkdir -p "$W/wc/plan/issues"
_stamp_now
printf 'a drill record\n' > "$W/wc/plan/issues/zzz-1142-85zx-probe.md"
out="$(S memo-check check)"
if [ "${out%% *}" = "ok:gate-fresh-except-plan" ]; then
    ok "arm3b: a plan/issues-only change yields ok:gate-fresh-except-plan"
elif [ "${out%% *}" = "ok:gate-fresh" ]; then
    bad "arm3b: a plan/issues change was INVISIBLE to both digests — the issue guard would never run: $out"
else
    bad "arm3b: a plan/issues-only change did not produce the partial verdict, got: $out"
fi

# ── ARM 3c: TOP LEVEL ONLY — a subdirectory still re-gates ──────────────────
# The skip glob and plan_digest's -maxdepth 1 must cover exactly the same set. A
# file one level down is deliberately NOT in the fast lane, and asserting it is
# what stops the two from drifting apart into a path that is in neither.
rm -f "$W/wc/plan/issues/zzz-1142-85zx-probe.md"
_stamp_now
mkdir -p "$W/wc/plan/issues/research"
printf 'a nested record\n' > "$W/wc/plan/issues/research/zzz-1142-85zx-nested.md"
out="$(S memo-check check)"
case "${out%% *}" in
    stale:*) ok "arm3c: a plan/issues SUBDIRECTORY change still stales the stamp, as the glob says" ;;
    *)       bad "arm3c: a nested plan/issues file took the fast lane; the skip glob and the digest's -maxdepth disagree, got: $out" ;;
esac
rm -rf "$W/wc/plan/issues/research"

# ── ARM 3d: THE MUTATION CONTROL LIVES HERE, not in the author's memory ─────
#
# macuahuitl's arm 6c, adapted. Their construction and their reason, and the
# reason is the better half: arms 3b and 3c assert what the FIXED stamp does,
# and the only evidence they can distinguish fixed from broken was five
# mutations run by hand and written up in a commit message. Nobody re-runs a
# commit message. This arm rebuilds the pre-fix stamp and requires it to FAIL.
#
# BUILT BY CONTENT, NOT BY PROVENANCE, and that is the adaptation. Their version
# read the mutant from `git show HEAD:scripts/gate-stamp.sh`, which yields a
# mutant only while the fix is UNCOMMITTED — measured on yoga once 236329190 was
# on trunk: rc 0 and byte-identical to the worktree copy, so the arm would red on
# every host that had merged the fix, with a message accusing the checkout of
# having the change uncommitted. A fixture that asserts its own change has not
# landed yet is one step from pinning the bug's symptom as a contract.
#
# Stripping by content has the same failure mode as any mutation — matching
# nothing and certifying everything — so the cmp below is not a formality. Both
# of our fixtures produced exactly that false pass tonight, once each.
_mutant="$W/prefix-gate-stamp.sh"
sed -e '/plan\/issues\/\*\.md) case "\${path#plan\/issues\/}"/d' \
    -e '/find "\$REPO_ROOT\/plan\/issues" -maxdepth 1/d' \
    "$STAMPER" > "$_mutant"
if cmp -s "$STAMPER" "$_mutant"; then
    bad "arm3d: the pre-fix reconstruction stripped NOTHING — it is a copy of the fixed stamp, so anything it certifies is worthless (did the skip-glob or the plan_digest find get rewritten?)"
else
    ok "arm3d: the pre-fix reconstruction differs from the fixed stamp — the mutant is real"
    cp "$_mutant" "$W/wc/scripts/gate-stamp.sh"
    _stamp_now
    printf 'a drill record\n' > "$W/wc/plan/issues/zzz-1142-85zx-mutant.md"
    _mut_out="$(S memo-check check)"
    case "${_mut_out%% *}" in
        ok:gate-fresh-except-plan)
            bad "arm3d: the PRE-FIX stamp also produced ok:gate-fresh-except-plan — arms 3b/3c cannot tell fixed from broken: $_mut_out" ;;
        *)
            ok "arm3d: the pre-fix stamp does NOT put a plan/issues change on the fast lane (got: ${_mut_out%% *}) — 3b reds without the fix" ;;
    esac
    rm -f "$W/wc/plan/issues/zzz-1142-85zx-mutant.md"
    cp "$STAMPER" "$W/wc/scripts/gate-stamp.sh"
    _stamp_now
fi

# ── ARM 4: a stamp with no plan_digest FAILS CLOSED ─────────────────────────
_stamp_now
# Strip the field to synthesise a stamp written before this order.
#
# TEMP FILE, NOT `sed -i` — AND `-i ''` IS THE TRAP IN THE OTHER DIRECTION.
# `sed -i SCRIPT FILE` is GNU-only. BSD sed (macOS) reads the argument AFTER
# -i as the backup SUFFIX, so it took '/^plan_digest /d' as the extension and
# "$STAMP_FILE" as the script, errored to stderr, and LEFT THE FILE UNCHANGED
# — the strip silently did nothing, plan_digest was still recorded,
# `memo-check check` correctly answered ok:gate-fresh, and THIS ARM FAILED
# ITSELF on every macOS host while the code under test was fine. It blocked
# every macOS land until it was fixed (2026-09-12).
#
# Measured here, both forms:
#   BSD  sed -i '/^plan_digest /d' f   -> "unescaped newline inside substitute
#                                         pattern"; FILE UNCHANGED
#   BSD  sed -i '' '/^plan_digest /d' f -> correct
# But DO NOT "fix" it to `-i ''`: GNU sed consumes that empty string as the
# SCRIPT, so that form just moves the breakage to Linux. Swapping one
# platform's idiom for the other's is how the sibling grep -R fix (1087-h2z9)
# travelled wrong. The temp file has no GNU/BSD divergence at all.
LC_ALL=C sed '/^plan_digest /d' "$STAMP_FILE" > "$STAMP_FILE.tmp" \
    && mv "$STAMP_FILE.tmp" "$STAMP_FILE"
out="$(S memo-check check)"
if [ "$out" = "stale:no-plan-digest-recorded" ]; then
    ok "arm4: a pre-1127 stamp is stale, not assumed-unchanged (fail closed, one re-gate per host)"
else
    bad "arm4: a stamp with no plan_digest should be stale, got: $out"
fi

# ── ARM 5: the verdict is WIRED to the guards in build.sh ───────────────────
# Structural, and labelled as such: this fixture cannot run ./build.sh (it runs
# inside it). What it can refuse is the verdict existing with nothing hanging
# off it — a memo arm that returns the partial verdict and then skips the guards
# anyway would reproduce the defect with extra steps.
_arm="$(awk '/"ok:gate-fresh-except-plan "\*\)/,/;;/' "$ROOT/build.sh")"
if [ -z "$_arm" ]; then
    bad "arm5: build.sh has no ok:gate-fresh-except-plan arm — the verdict goes nowhere"
elif grep -q 'check-fragment-status-loss.sh' <<<"$_arm" && grep -q 'strict-fragments' <<<"$_arm"; then
    ok "arm5: build.sh's partial-memo arm runs BOTH ledger guards"
else
    bad "arm5: build.sh's partial-memo arm does not run both ledger guards"
fi
# 1142-85zx: the fourth glob brought a third guard with it. Same structural
# assertion, same reason — the lane must run the guard whose subject it admitted.
if grep -q 'check-issue-citation-convention.sh' <<<"$_arm"; then
    ok "arm5b: the partial-memo arm also runs the issue guard, whose subject joined the lane"
else
    bad "arm5b: plan/issues is in the fast lane but its guard does not run there (1142-85zx)"
fi

echo "test-gate-stamp-does-not-memoize-guard-owned-paths: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
