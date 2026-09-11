#!/usr/bin/env bash
# @trace order:1024-c3h3
#
# Pin: an evidence SHA that the landing rewrote must be NAMED, and the landed
# commit offered in its place.
#
# THE SHAPE, reproduced here rather than described. The sanctioned closure order
# writes `set-field ... --evidence <sha>` at Finalization step 2, BEFORE step 4
# lands. land-on-platform-branch.sh fetches, integrates onto origin and REWRITES
# the commit, so the recorded SHA is the pre-rebase local one and never exists
# upstream. lenovinha measured four of four closures citing ghosts on
# 2026-09-04; yoga's 1011-d578 did the same.
#
# WHY IT IS WORSE THAN A WRONG STRING: a reader running the obvious check
# (`git merge-base --is-ancestor <sha> origin/linux-next`) gets NO and cannot
# tell "the code never landed" from "the ref was captured too early". Those need
# opposite responses. So the check must SEPARATE them, and arms 2 and 3 below
# are that separation — it is not enough to notice the ref is absent.
#
# WHAT THE RULE IS NOT: it is not "reachable from origin". A host that lands
# code and ledger in ONE push cites a SHA not yet upstream but reachable from
# the tip being pushed, and refusing that would flag correct work. Arm 4 pins
# it. A rewritten SHA is reachable from neither, which is what makes a ghost
# separable from an ordinary in-flight commit.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/check-fragment-closure-evidence-added.sh"
fail=0; pass=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail+1)); }

W="$(mktemp -d "${TMPDIR:-/tmp}/closure-evidence.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM
export GIT_TERMINAL_PROMPT=0
G() { git -c user.email=t@t -c user.name=t "$@"; }

git init -q --bare "$W/bare.git"
git init -q -b linux-next "$W/wc"
cd "$W/wc" || exit 2
git remote add origin "$W/bare.git"
git config core.hooksPath .git/hooks
git config core.autocrlf false
mkdir -p scripts plan/index.d
cp "$CHECK" scripts/
for f in plan-binary-probe.sh; do cp "$ROOT/scripts/$f" "scripts/" 2>/dev/null || true; done
chmod +x scripts/*.sh 2>/dev/null || true
printf 'base\n' > README.md
G add -A >/dev/null; G commit -q -m base
git push -q -u origin linux-next

_frag() { # $1=file $2=sha
    cat > "plan/index.d/$1" <<YAML
packets:
  - packet_id: fixture-packet
    order: 9999-fixt
    events:
      - type: completed
        ts: "2026-09-05T00:00:00Z"
        host: fixture
        summary: |
          closed with evidence_refs: $2
YAML
}

# The checker resolves its validator with a cwd-relative probe, and every arm
# below runs it from a scratch repo that has no target/. So on a host where
# nothing else supplies the binary the probe finds none, the checker takes its
# "not built" branch, and the fixture measures the SKIP instead of the rule.
#
# That is the SAME defect as test-pre-push-plan-lane-after-merge.sh:82 and
# test-pre-push-issue-capture-lane.sh (1058-fenk, 1060-wxdh): a cwd-relative
# probe in a script that has cd-ed into scratch. It hid on Linux because the
# fall-through found the host's tillandsias-plan on PATH, so the arms passed
# for a reason unrelated to what they assert; macOS has no such copy and the
# fixture went red for tooling, not behaviour.
#
# Worse than the three reds it caused: arm 5 is a NEGATIVE control ("a
# reachable SHA is not a ghost"), and a skipped gate flags nothing, so it
# PASSED VACUOUSLY — agreeing with the fixture for exactly the wrong reason.
#
# So resolve the checkout's own binary HERE, in the checkout, where the probe
# can see it. Resolving EXECUTES the candidate, so what is exported has been
# run and not merely found — the probe honours an explicit TILLANDSIAS_PLAN_BIN
# on existence alone (1060-wxdh), and handing it an unverified path is the
# shape that installed a dead binary over a canonical copy on yoga.
_validator="$(cd "$ROOT" && . scripts/plan-binary-probe.sh && resolve_plan_binary 2>/dev/null)" || _validator=""
case "$_validator" in ./*) _validator="$ROOT/${_validator#./}" ;; esac
if [ -z "$_validator" ]; then
    # NAMED SKIP, NOT RED, and not a silent pass either. Without a validator
    # every arm here measures the checker's skip branch; reporting that as
    # green is what this fix exists to stop.
    echo "skip:closure-evidence-survives-landing:no-validator — no runnable tillandsias-plan in this checkout, so the arms would measure the checker's skip branch rather than the rule (build with ./build.sh to enable)" >&2
    echo "closure-evidence-survives-landing: 0 passed, 0 failed (skipped)"
    exit 0
fi
export TILLANDSIAS_PLAN_BIN="$_validator"

_run() { ( cd "$W/wc" && TILLANDSIAS_CLOSURE_EVIDENCE_BASE=origin/linux-next \
    TILLANDSIAS_PLAN_BIN="$_validator" \
    bash scripts/check-fragment-closure-evidence-added.sh ) 2>&1; }

# ── Reproduce the landing rewrite ──────────────────────────────────────────
# Trunk moves, so integrating rewrites the local commit and changes its SHA —
# exactly what land-on-platform-branch.sh does.
G checkout -q -b work
printf 'local work\n' > work.txt
G add -A >/dev/null; G commit -q -m "the work commit"
PRE_SHA="$(git rev-parse HEAD)"

G checkout -q linux-next
printf 'someone else\n' > other.txt
G add -A >/dev/null; G commit -q -m "trunk moved"
git push -q origin linux-next

G checkout -q work
G rebase -q linux-next >/dev/null 2>&1 || { echo "SKIP: rebase unavailable" >&2; exit 0; }
POST_SHA="$(git rev-parse HEAD)"
G checkout -q linux-next
G merge -q --ff-only work
git push -q origin linux-next

[ "$PRE_SHA" != "$POST_SHA" ] \
    && ok "the landing really rewrote the commit ($(printf '%.7s' "$PRE_SHA") -> $(printf '%.7s' "$POST_SHA"))" \
    || bad "PRECONDITION: the rebase did not change the SHA; every arm below is vacuous"

# ── 1. THE GHOST: evidence captured before the rewrite ─────────────────────
_frag "20260905t000001z-ghost.yaml" "$PRE_SHA"
G add -A >/dev/null; G commit -q -m "close with a pre-landing sha"
out="$(_run)"
case "$out" in
    *"evidence-ref-not-upstream: $PRE_SHA"*) ok "a pre-landing evidence SHA is named" ;;
    *) bad "the ghost SHA was not flagged"; printf '%s\n' "$out" | tail -5 | sed 's/^/      /' >&2 ;;
esac

# ── 2. IT OFFERS THE LANDED COMMIT, which is what makes it correctable ─────
case "$out" in
    *"same subject is ${POST_SHA}"*) ok "the landed commit with the same subject is named" ;;
    *) bad "the landed candidate was not offered — a reader still cannot fix the ref" ;;
esac

# ── 3. THE OTHER DIAGNOSIS stays distinguishable ───────────────────────────
# A commit that genuinely never landed must NOT be reported as "captured too
# early" — the two need opposite responses, and conflating them is the defect
# one level up.
G reset -q --hard origin/linux-next
mkdir -p plan/index.d
G checkout -q -b never-landed
printf 'never\n' > never.txt
G add -A >/dev/null; G commit -q -m "a commit that never lands anywhere"
NEVER_SHA="$(git rev-parse HEAD)"
G checkout -q linux-next
G reset -q --hard origin/linux-next
mkdir -p plan/index.d
_frag "20260905t000002z-never.yaml" "$NEVER_SHA"
G add -A >/dev/null; G commit -q -m "close citing work that never landed"
out2="$(_run)"
case "$out2" in
    *"No commit with that subject is on"*) ok "work that never landed is reported as the OTHER diagnosis" ;;
    *) bad "a never-landed commit was not distinguished from a rewritten one"; printf '%s\n' "$out2" | tail -6 | sed 's/^/      /' >&2 ;;
esac

# ── 4. NEGATIVE CONTROL: a SHA in THIS push is not a ghost ────────────────
# A host that lands code and ledger together cites a SHA not yet upstream but
# reachable from the tip being pushed. Flagging that would red correct work, and
# an arm that only tested reachability-from-origin would do exactly that.
G reset -q --hard origin/linux-next
mkdir -p plan/index.d
printf 'in flight\n' > inflight.txt
G add -A >/dev/null; G commit -q -m "code landing in this very push"
INFLIGHT="$(git rev-parse HEAD)"
_frag "20260905t000003z-inflight.yaml" "$INFLIGHT"
G add -A >/dev/null; G commit -q -m "close citing the commit in this push"
out3="$(_run)"
case "$out3" in
    *"evidence-ref-not-upstream: $INFLIGHT"*)
        bad "a commit reachable from the pushed tip was flagged as a ghost — this would red correct work" ;;
    *) ok "a SHA reachable from the tip being pushed is not a ghost" ;;
esac

echo "closure-evidence-survives-landing: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
