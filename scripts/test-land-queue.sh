#!/usr/bin/env bash
# @trace order:1316-bnzt, spec:ci-release
#
# THE SCAFFOLD IS THE PART NOBODY REVIEWS, so it is described before the arms.
# Each arm builds a real bare repository as the remote, a real clone as the
# lander, a fake `gh` that answers `pr list` from a file the arm writes and
# records `pr comment` to another, and a stub gate whose exit status the arm
# chooses. Nothing here touches the tillandsias repository: every path is under
# a mktemp -d that the trap removes.
#
# WHY A REAL GIT REMOTE AND NOT A MOCK. The queue's central claim is about
# ancestry on the remote — "the only proof that counts is asking the remote" —
# and a mocked remote would let the fixture agree with the queue about a fact
# neither had checked. The merges, the conflicts and the fast-forwards are real.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUEUE="$ROOT/scripts/land-queue.sh"

pass=0; fail=0; skipped=0
ok()      { printf 'ok:   %s\n' "$1"; pass=$((pass + 1)); }
bad()     { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }
skiparm() { printf 'skip: %s\n' "$1"; skipped=$((skipped + 1)); }

for t in git jq; do
    command -v "$t" >/dev/null 2>&1 || {
        printf 'skip:land-queue:no-%s — every arm drives the queue with it\n' "$t"
        exit 0
    }
done
[ -x "$QUEUE" ] || { echo "skip:land-queue:no-queue-script"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── scaffold <name> — a bare remote with a trunk, plus a clone to land from ──
# Returns by setting REMOTE_DIR / WORK_DIR / GH_BIN / GH_PRS / GH_COMMENTS /
# GATE_BIN / GATE_LOG. Globals rather than a command substitution because a
# subshell's assignments never reach the caller — the 1299-s2sv lesson.
scaffold() {
    local name="$1"
    REMOTE_DIR="$TMP/$name/remote.git"
    WORK_DIR="$TMP/$name/work"
    GH_PRS="$TMP/$name/prs.json"
    GH_COMMENTS="$TMP/$name/comments.log"
    GH_DRAFTS="$TMP/$name/drafts.log"
    GATE_LOG="$TMP/$name/gate.log"
    GH_BIN="$TMP/$name/gh"
    GATE_BIN="$TMP/$name/gate.sh"
    mkdir -p "$TMP/$name"

    git init -q --bare "$REMOTE_DIR"
    git init -q "$WORK_DIR"
    git -C "$WORK_DIR" config user.email t@l; git -C "$WORK_DIR" config user.name t
    git -C "$WORK_DIR" config commit.gpgsign false
    echo base > "$WORK_DIR/base.txt"
    git -C "$WORK_DIR" add -A && git -C "$WORK_DIR" commit -q -m base
    git -C "$WORK_DIR" branch -M linux-next
    git -C "$WORK_DIR" remote add origin "$REMOTE_DIR"
    git -C "$WORK_DIR" push -q origin linux-next
    # A bare repo initialised before this branch existed still has HEAD pointing
    # at its init default, so `git clone` of it checks NOTHING out and every
    # command in the clone fails on an unborn HEAD. Arm 5's mover was silently
    # broken by exactly this: it never moved the target, and the arm read the
    # resulting "landed" as the queue failing to notice a move that never
    # happened.
    git -C "$REMOTE_DIR" symbolic-ref HEAD refs/heads/linux-next
    git -C "$WORK_DIR" fetch -q origin

    : > "$GH_COMMENTS"; : > "$GATE_LOG"; : > "$GH_DRAFTS"

    cat > "$GH_BIN" <<GH
#!/usr/bin/env bash
# Fake gh. Answers 'pr list' from a file and records 'pr comment' to a log.
case "\$1 \$2" in
    "pr list")    cat "$GH_PRS" ;;
    "pr comment") shift 2; printf '%s\n' "\$*" >> "$GH_COMMENTS" ;;
    # 1765-q7rg: the PR's comments as gh's JSON, carrying only the queue's own
    # eviction markers for that PR (the part the queue reads back).
    "pr view")
        printf '{"comments":['
        grep -o "<!-- land-queue:evicted pr=\$3 [^>]*-->" "$GH_COMMENTS" \
            | sed 's/.*/{"body":"&"}/' | paste -sd, -
        printf ']}\n' ;;
    "pr ready")   shift 2; printf '%s\n' "\$*" >> "$GH_DRAFTS" ;;
    *) exit 1 ;;
esac
GH
    chmod +x "$GH_BIN"
}

# candidate <name> <order> <file> <content> — a work ref on the remote
candidate() {
    local name="$1" order="$2" file="$3" content="$4"
    git -C "$WORK_DIR" checkout -q -B "work/$order" origin/linux-next
    printf '%s\n' "$content" > "$WORK_DIR/$file"
    git -C "$WORK_DIR" add -A
    git -C "$WORK_DIR" commit -q -m "work($order)"
    git -C "$WORK_DIR" push -q origin "work/$order"
    git -C "$WORK_DIR" checkout -q linux-next
}

# 2152-lqrf: the refresh key reads a dep-info and writes a stamp, by default
# under the GATE's CARGO_TARGET_DIR, i.e. the real shared target. A fixture must
# never read or write production state, so both are pinned to scratch unless an
# arm names its own (ARM 40). Measured: unpinned, ARM 22b stamped the target and
# the NEXT gate's ARM 22 skipped its failing refresh and gated #22 (red).
# 2174-dail: the land-queue KNOBS are pinned too (BATCH_K, TRAIN_LOG, DAILY_*). A
# host that runs its queue with TILLANDSIAS_LAND_QUEUE_BATCH_K=4 exported reaches
# this fixture through the gate, and every one-at-a-time arm then ran as a train
# (macuahuitl run 26: ARM 1b/2/17a/22/30/34 red). Arms set ARM_* instead.
run_queue() {
    ( cd "$WORK_DIR" && env -u TILLANDSIAS_LAND_QUEUE_BUNDLE_LOG -u TILLANDSIAS_LAND_QUEUE_HEAVY_PROBE \
        TILLANDSIAS_LAND_QUEUE_SHADOW_INTAKE="${ARM_SHADOW:-}" TILLANDSIAS_LAND_QUEUE_SHADOW_LOG="${ARM_SHADOW_LOG:-$TMP/shadow.$$.log}" \
        TILLANDSIAS_LAND_QUEUE_SHADOW_LOCK="${ARM_SHADOW_LOCK:-$TMP/shadow.$$.lock}" TILLANDSIAS_LAND_QUEUE_SHADOW_TREE="${ARM_SHADOW_TREE:-$TMP/shadow.$$.tree}" \
        TILLANDSIAS_LAND_QUEUE_SHADOW_PR_S="${ARM_SHADOW_PR_S:-60}" TILLANDSIAS_LAND_QUEUE_SHADOW_RUN_S="${ARM_SHADOW_RUN_S:-60}" \
        ${ARM_HEAVY_PROBE:+"TILLANDSIAS_LAND_QUEUE_HEAVY_PROBE=$ARM_HEAVY_PROBE"} \
        TILLANDSIAS_BUNDLE_HEAVY_MAX="${ARM_HEAVY_MAX:-2}" \
        TILLANDSIAS_LAND_QUEUE_GH="$GH_BIN" \
        TILLANDSIAS_LAND_QUEUE_GATE="bash $GATE_BIN" \
        TILLANDSIAS_LAND_QUEUE_PREFLIGHT="${PREFLIGHT_CMD:-}" \
        TILLANDSIAS_LAND_QUEUE_PLAN_REFRESH="${PLAN_REFRESH_CMD:-}" \
        TILLANDSIAS_LAND_QUEUE_BATCH_K="${ARM_BATCH_K:-1}" \
        TILLANDSIAS_LAND_QUEUE_TRAIN_LOG="${ARM_TRAIN_LOG:-$TMP/trains.$$.log}" \
        TILLANDSIAS_LAND_QUEUE_DAILY_SKIP="${ARM_DAILY_SKIP:-1}" \
        TILLANDSIAS_LAND_QUEUE_DAILY_MAX_AGE_S="${ARM_DAILY_MAX_AGE_S:-86400}" \
        TILLANDSIAS_LAND_QUEUE_PLAN_DEPINFO="${TILLANDSIAS_LAND_QUEUE_PLAN_DEPINFO:-$TMP/no-plan-depinfo.d}" \
        TILLANDSIAS_LAND_QUEUE_PLAN_REFRESH_STAMP="${TILLANDSIAS_LAND_QUEUE_PLAN_REFRESH_STAMP:-$TMP/plan-refresh-stamp.$$}" \
        TILLANDSIAS_LAND_QUEUE_HOST_DOOR="${HOST_DOOR_CMD:-}" \
        TILLANDSIAS_LAND_QUEUE_SIDECAR_STAGE="" \
        TILLANDSIAS_LAND_QUEUE_PLAN_LANE_CHECK="${PLAN_LANE_CMD:-echo plan-lane >> $GATE_LOG.plan-lane}" \
        TILLANDSIAS_LAND_QUEUE_REMOTE=origin \
        TILLANDSIAS_LAND_QUEUE_LOGDIR="${LOGDIR_OVERRIDE:-$TMP/logs-$$}" \
        TILLANDSIAS_TRUNK_BRANCH=linux-next \
        bash "$QUEUE" "$@" 2>&1 )
}

# ──────────────────────────────────────────────────────────── ARM 1
# THREE CANDIDATES LAND ONE AT A TIME IN PR-NUMBER ORDER.
scaffold arm1
candidate arm1 1001-aaaa a.txt A
candidate arm1 1002-bbbb b.txt B
candidate arm1 1003-cccc c.txt C
cat > "$GH_PRS" <<JSON
[{"number":3,"headRefName":"work/1003-cccc","isDraft":false},
 {"number":1,"headRefName":"work/1001-aaaa","isDraft":false},
 {"number":2,"headRefName":"work/1002-bbbb","isDraft":false}]
JSON
cat > "$GATE_BIN" <<GATE
#!/usr/bin/env bash
echo "gated \$(git rev-parse HEAD)" >> "$GATE_LOG"
exit 0
GATE
out1="$(run_queue)"
order_seen="$(printf '%s' "$out1" | sed -n 's/^land:\([0-9]*\) .*/\1/p' | tr '\n' ',')"
if [ "$order_seen" = "1,2,3," ]; then
    ok "ARM 1: three candidates landed one at a time in PR-NUMBER order (1,2,3), not the order gh listed them (3,1,2)"
else
    bad "ARM 1: wanted landings in order 1,2,3; got '$order_seen'
$out1"
fi

# AND THE TRUNK GREW BY EXACTLY THREE MERGES, each one an ancestor of the next:
# a queue that landed three things in parallel would not produce a chain.
n_merges="$(git -C "$WORK_DIR" rev-list --count --merges origin/linux-next 2>/dev/null)"
if [ "${n_merges:-0}" -eq 3 ]; then
    ok "ARM 1b: the remote trunk carries exactly 3 merge commits — a serialized chain, not a race"
else
    bad "ARM 1b: wanted 3 merges on the remote trunk, got ${n_merges:-0}"
fi

# ──────────────────────────────────────────────────────────── ARM 2
# A CANDIDATE WHOSE GATE FAILS IS EVICTED, ITS REFUSAL IS RECORDED ON THE PR,
# AND THE QUEUE CONTINUES rather than aborting.
scaffold arm2
candidate arm2 2001-aaaa a.txt A
candidate arm2 2002-bbbb b.txt B
cat > "$GH_PRS" <<JSON
[{"number":1,"headRefName":"work/2001-aaaa","isDraft":false},
 {"number":2,"headRefName":"work/2002-bbbb","isDraft":false}]
JSON
# Red for the first candidate only, keyed on the FILE the merge brought in --
# not on the PR number, which the gate cannot see.
cat > "$GATE_BIN" <<GATE
#!/usr/bin/env bash
if [ -f a.txt ] && [ ! -f b.txt ]; then echo "boom: a.txt is not acceptable"; exit 1; fi
exit 0
GATE
out2="$(run_queue)"
ev2="$(printf '%s' "$out2" | sed -n 's/^evict:land-queue:\([0-9]*\):gate-failed.*/\1/p')"
land2="$(printf '%s' "$out2" | sed -n 's/^land:\([0-9]*\) .*/\1/p')"
cmt2="$(cat "$GH_COMMENTS" 2>/dev/null)"
if [ "$ev2" = "1" ] && [ "$land2" = "2" ]; then
    case "$cmt2" in
        *"1 --body"*"gate failed"*) ok "ARM 2: the red candidate was EVICTED with its refusal on PR #1, and the queue continued and landed #2" ;;
        *) bad "ARM 2: evicted #1 and landed #2, but the PR was not annotated with the gate failure. comments: $cmt2" ;;
    esac
else
    bad "ARM 2: wanted evict=1 land=2; got evict='$ev2' land='$land2'
$out2"
fi

# ──────────────────────────────────────────────────────────── ARM 3
# A CANDIDATE THAT CONFLICTS WITH THE MOVED TARGET IS EVICTED WITH THE
# CONFLICTING PATHS NAMED, and the queue continues.
scaffold arm3
candidate arm3 3001-aaaa shared.txt "from-one"
candidate arm3 3002-bbbb shared.txt "from-two"
candidate arm3 3003-cccc other.txt "unrelated"
cat > "$GH_PRS" <<JSON
[{"number":1,"headRefName":"work/3001-aaaa","isDraft":false},
 {"number":2,"headRefName":"work/3002-bbbb","isDraft":false},
 {"number":3,"headRefName":"work/3003-cccc","isDraft":false}]
JSON
cat > "$GATE_BIN" <<'GATE'
#!/usr/bin/env bash
exit 0
GATE
out3="$(run_queue)"
conf3="$(printf '%s' "$out3" | sed -n 's/^evict:land-queue:2:conflict:\(.*\)/\1/p')"
land3="$(printf '%s' "$out3" | sed -n 's/^land:\([0-9]*\) .*/\1/p' | tr '\n' ',')"
case "$conf3" in
    *shared.txt*)
        if [ "$land3" = "1,3," ]; then
            ok "ARM 3: the conflicting candidate was evicted NAMING shared.txt, and the queue continued to #3"
        else
            bad "ARM 3: named the conflict but the queue did not continue correctly (landed '$land3')"
        fi ;;
    "") bad "ARM 3: no conflict eviction for #2 at all
$out3" ;;
    *)  bad "ARM 3: evicted #2 but named '$conf3' instead of shared.txt — the author is sent back to reproduce it" ;;
esac

# ──────────────────────────────────────────────────────────── ARM 4
# A LANDING PUSHES EXACTLY ONE MERGE COMMIT WHOSE SECOND PARENT IS THE PR HEAD,
# so GitHub closes the PR by ancestry with no `gh pr merge` call.
scaffold arm4
candidate arm4 4001-aaaa a.txt A
head4="$(git -C "$WORK_DIR" rev-parse origin/work/4001-aaaa)"
cat > "$GH_PRS" <<JSON
[{"number":7,"headRefName":"work/4001-aaaa","isDraft":false}]
JSON
cat > "$GATE_BIN" <<'GATE'
#!/usr/bin/env bash
exit 0
GATE
out4="$(run_queue)"
tip4="$(git -C "$WORK_DIR" rev-parse origin/linux-next)"
p2_4="$(git -C "$WORK_DIR" rev-parse "origin/linux-next^2" 2>/dev/null || true)"
nmerge4="$(git -C "$WORK_DIR" rev-list --count --merges origin/linux-next)"
if [ "$p2_4" = "$head4" ] && [ "$nmerge4" -eq 1 ]; then
    ok "ARM 4: exactly one merge landed and its SECOND PARENT is the PR head — the PR closes by ancestry"
else
    bad "ARM 4: wanted one merge whose second parent is $head4; got $nmerge4 merge(s), second parent '$p2_4' (tip $tip4)"
fi
case "$(cat "$GH_COMMENTS")" in
    *"pr merge"*) bad "ARM 4b: the queue called gh pr merge — the row says the PR closes by ancestry" ;;
    *)            ok "ARM 4b: no gh pr merge call was made" ;;
esac

# ──────────────────────────────────────────────────────────── ARM 5
# THE TREE THAT SHIPS MUST BE THE TREE THAT GATED.
#
# THIS IS THE ARM A STATIC SCAFFOLD CANNOT HAVE. Every arm above moves the
# target before the run; this one moves it DURING the gate, from inside the
# stub gate itself, which is the only window where the defect lives: the queue
# has a green verdict in hand, and it is about a tree nobody is pushing.
#
# WHAT IT IS ACTUALLY ASSERTING, stated because the mutation run showed the
# obvious reading is wrong. Disabling the queue's comparison does NOT land a
# stale tree — git rejects the push as a non-fast-forward and the candidate is
# re-queued anyway. So this arm does not pin "a stale tree cannot ship"; git
# pins that. It pins that the queue DISTINGUISHES an ordinary, expected race
# (`target-moved`, naming both SHAs, no push attempted) from `push-did-not-land`,
# which is the line a blocked credential helper and a lost network also produce.
# Telling those apart is the difference between "re-run it" and "wake someone".
scaffold arm5
candidate arm5 5001-aaaa a.txt A
cat > "$GH_PRS" <<JSON
[{"number":1,"headRefName":"work/5001-aaaa","isDraft":false}]
JSON
# A second clone is what moves the target, because the lander's own checkout is
# detached mid-landing and pushing from it would not be another host.
OTHER="$TMP/arm5/other"
git clone -q "$REMOTE_DIR" "$OTHER"
git -C "$OTHER" config user.email o@o; git -C "$OTHER" config user.name o
git -C "$OTHER" config commit.gpgsign false
cat > "$GATE_BIN" <<GATE
#!/usr/bin/env bash
# Another host lands while this candidate is gating.
echo moved > "$OTHER/moved.txt"
git -C "$OTHER" add -A
git -C "$OTHER" commit -q -m "another host"
git -C "$OTHER" push -q origin HEAD:linux-next
exit 0
GATE
before5="$(git -C "$WORK_DIR" rev-parse origin/linux-next)"
out5="$(run_queue)"
git -C "$WORK_DIR" fetch -q origin linux-next
after5="$(git -C "$WORK_DIR" rev-parse origin/linux-next)"
other5="$(git -C "$OTHER" rev-parse HEAD 2>/dev/null || echo NONE)"
rq5="$(printf '%s' "$out5" | sed -n 's/^requeue:land-queue:1:target-moved.*/yes/p')"

# THE PREMISE, ASSERTED BEFORE ANY VERDICT IS READ. This arm is only meaningful
# if the mover actually moved the target during the gate. When it did not, the
# queue landing the candidate is CORRECT behaviour, and scoring that as a
# failure blames the subject for the scaffold. The first version of this arm had
# no such check and reported the queue as broken when the mover's clone had no
# checkout at all.
if [ "$other5" = "NONE" ] || [ "$other5" = "$before5" ]; then
    skiparm "ARM 5: COULD NOT RUN — the mover never moved the target (before=$before5 other=$other5), so there is no stale-target window to detect"
elif [ "$rq5" = "yes" ] && [ "$after5" = "$other5" ]; then
    ok "ARM 5: the target moved DURING the gate, so the candidate was RE-QUEUED and nothing was pushed — trunk carries only the other host's commit"
elif [ "$rq5" = "yes" ]; then
    bad "ARM 5: it re-queued but trunk is not the other host's commit (before=$before5 after=$after5 other=$other5) — something was pushed anyway"
else
    bad "ARM 5: the target moved mid-gate and the queue did not say so — it reported a bare push failure, which is indistinguishable from a credential or network fault
$out5"
fi

# ARM 5b, THE NEGATIVE CONTROL for arm 5: with the target NOT moving, the same
# scaffold must LAND. Without this, an arm 5 that re-queued everything for any
# reason would read as a pass.
cat > "$GATE_BIN" <<'GATE'
#!/usr/bin/env bash
exit 0
GATE
out5b="$(run_queue)"
case "$out5b" in
    *"land:1 "*) ok "ARM 5b (control): with a target that does NOT move, the same candidate lands — arm 5 is detecting the move, not refusing everything" ;;
    *)           bad "ARM 5b (control): the candidate did not land even with a still target, so arm 5 proves nothing
$out5b" ;;
esac

# ──────────────────────────────────────────────────────────── ARM 6
# THE QUEUE KEEPS NO LOCAL STATE, so a run killed anywhere cannot leave a
# half-state that disagrees with the remote. The next run re-derives the queue
# from `gh pr list`; nothing but the lock is written under .git.
scaffold arm6
candidate arm6 6001-aaaa a.txt A
candidate arm6 6002-bbbb b.txt B
cat > "$GH_PRS" <<JSON
[{"number":1,"headRefName":"work/6001-aaaa","isDraft":false},
 {"number":2,"headRefName":"work/6002-bbbb","isDraft":false}]
JSON
cat > "$GATE_BIN" <<'GATE'
#!/usr/bin/env bash
exit 0
GATE
run_queue --limit 1 >/dev/null 2>&1
# The remote is now the only record of what happened. Remove #1 from the fake
# queue the way GitHub would once its PR closed, and run again.
cat > "$GH_PRS" <<JSON
[{"number":2,"headRefName":"work/6002-bbbb","isDraft":false}]
JSON
out6="$(run_queue)"
stray="$(find "$WORK_DIR/.git" -maxdepth 1 -name 'tillandsias-land-queue*' 2>/dev/null | tr '\n' ' ')"
land6="$(printf '%s' "$out6" | sed -n 's/^land:\([0-9]*\) .*/\1/p')"
if [ "$land6" = "2" ] && [ -z "$stray" ]; then
    ok "ARM 6: the second run re-derived the queue from gh and landed #2, leaving no queue state under .git"
elif [ "$land6" = "2" ]; then
    bad "ARM 6: it landed #2 but left state behind: $stray — a killed run could disagree with the remote"
else
    bad "ARM 6: the second run did not land #2 from a re-read queue (got '$land6')
$out6"
fi

# ──────────────────────────────────────────────────────────── ARM 7
# AN EMPTY CAPTURE FROM gh IS NOT AN EMPTY QUEUE. A missing or unauthenticated
# gh writes nothing and exits non-zero, and reading that as "no work" is the
# silent false negative this fleet keeps finding.
scaffold arm7
cat > "$GH_BIN" <<'GH'
#!/usr/bin/env bash
exit 4
GH
chmod +x "$GH_BIN"
out7="$(run_queue)"; rc7=$?
case "$out7" in
    *"fail:land-queue:cannot-read-queue"*)
        if [ "$rc7" -ne 0 ]; then
            ok "ARM 7: a gh that fails REFUSES (rc=$rc7) instead of reporting an empty queue"
        else
            bad "ARM 7: it named the failure but exited 0, so a caller reads success"
        fi ;;
    *) bad "ARM 7: a failing gh was not distinguished from an empty queue (rc=$rc7)
$out7" ;;
esac

# ARM 7b: a well-formed EMPTY list really is an empty queue, and must not refuse.
scaffold arm7b
cat > "$GH_PRS" <<'JSON'
[]
JSON
out7b="$(run_queue)"; rc7b=$?
case "$out7b" in
    *"ok:land-queue:0 "*) ok "ARM 7b: a well-formed empty list is an empty queue and exits 0 — the refusal in 7 is about the FAILURE, not about emptiness" ;;
    *) bad "ARM 7b: an empty queue did not report ok (rc=$rc7b)
$out7b" ;;
esac

# ARM 7c (2100-vkpg): A QUEUE OF ONLY DRAFTS LANDS NOTHING AND SAYS WHICH DRAFTS
# IT PASSED OVER. Pre-fix the output was the bare "queue is empty" line, which is
# how 18 drafts sat unlanded for weeks: this arm fails on that code.
scaffold arm7c
cat > "$GH_PRS" <<'JSON'
[{"number":196,"headRefName":"work/1375-amye","isDraft":true},
 {"number":42,"headRefName":"work/7001-aaaa","isDraft":true}]
JSON
out7c="$(run_queue)"; rc7c=$?
if grep -q 'advisory:land-queue:ignored-draft:#42:work/7001-aaaa' <<<"$out7c" \
   && grep -q 'advisory:land-queue:ignored-draft:#196:work/1375-amye' <<<"$out7c" \
   && grep -q 'ok:land-queue:0 ' <<<"$out7c" && [ "$rc7c" -eq 0 ]; then
    ok "ARM 7c: every ignored draft is named, and a drafts-only queue still exits 0 as empty"
else
    bad "ARM 7c: wanted an ignored-draft advisory for #42 and #196 plus ok:land-queue:0 (rc=$rc7c)
$out7c"
fi

# ──────────────────────────────────────────────────────────── ARM 8
# THE INVOKING CHECKOUT IS PUT BACK WHERE IT WAS.
#
# The queue detaches HEAD to build each merge, so where it leaves the caller is
# part of its contract, not a detail. Both starting states are exercised because
# they take DIFFERENT code paths and only one of them was ever right: from a
# branch the restore is by name, and from an already-detached HEAD
# `rev-parse --abbrev-ref HEAD` yields the literal "HEAD", so the restore used
# to put the caller wherever the QUEUE last left HEAD. That is a silent no-op,
# and the state it failed to restore from is exactly the one an interrupted
# earlier run leaves behind.
scaffold arm8
candidate arm8 8001-aaaa a.txt A
cat > "$GH_PRS" <<JSON
[{"number":1,"headRefName":"work/8001-aaaa","isDraft":false}]
JSON
cat > "$GATE_BIN" <<'GATE'
#!/usr/bin/env bash
exit 0
GATE

# 8a — from a BRANCH: the caller keeps their branch, by name.
git -C "$WORK_DIR" checkout -q linux-next
branch_before="$(git -C "$WORK_DIR" rev-parse --abbrev-ref HEAD)"
run_queue >/dev/null 2>&1
branch_after="$(git -C "$WORK_DIR" rev-parse --abbrev-ref HEAD)"
if [ "$branch_after" = "$branch_before" ]; then
    ok "ARM 8a: invoked from a branch, the queue left the caller on '$branch_before'"
else
    bad "ARM 8a: the caller started on '$branch_before' and was left on '$branch_after'"
fi

# 8b — from a DETACHED HEAD: the caller keeps their COMMIT.
#
# THE DETACH POINT MUST BE SOMEWHERE THE QUEUE WOULD NOT LEAVE HEAD ANYWAY, or
# the arm is vacuous. The first version detached at the trunk tip, which is
# exactly where a run ends up, so it passed against the BROKEN restore and
# against the fixed one alike — a guard whose subject is the answer it is
# checking for. Measured: mutation run, 13/13 with the defect reinstated.
#
# So it detaches at the trunk's PARENT and gives the queue a fresh candidate to
# land. A working restore returns HEAD to that parent; a broken one leaves it on
# the merge the queue just built, and the two are now different commits.
scaffold arm8b
candidate arm8b 8002-bbbb b.txt B
cat > "$GH_PRS" <<JSON
[{"number":1,"headRefName":"work/8002-bbbb","isDraft":false}]
JSON
cat > "$GATE_BIN" <<'GATE'
#!/usr/bin/env bash
exit 0
GATE
# One landing first, so the trunk has a parent to stand on that is not its tip.
run_queue >/dev/null 2>&1
git -C "$WORK_DIR" fetch -q origin linux-next
git -C "$WORK_DIR" checkout -q --detach "origin/linux-next^1"
det_before="$(git -C "$WORK_DIR" rev-parse HEAD)"
tip_before="$(git -C "$WORK_DIR" rev-parse origin/linux-next)"
# A second candidate, so the run this arm measures actually builds a merge.
candidate arm8b 8003-cccc c.txt C
git -C "$WORK_DIR" checkout -q --detach "$det_before"
cat > "$GH_PRS" <<JSON
[{"number":2,"headRefName":"work/8003-cccc","isDraft":false}]
JSON
run_queue >/dev/null 2>&1
det_after="$(git -C "$WORK_DIR" rev-parse HEAD)"
if [ "$det_before" = "$tip_before" ]; then
    skiparm "ARM 8b: COULD NOT RUN — the detach point equals the trunk tip, so a broken restore would be indistinguishable from a working one"
elif [ "$det_after" = "$det_before" ]; then
    ok "ARM 8b: invoked from a DETACHED HEAD, the queue left the caller on the same commit (${det_before:0:9})"
else
    bad "ARM 8b: the caller started detached at ${det_before:0:9} and was left at ${det_after:0:9} — the restore recorded the literal 'HEAD' instead of a commit"
fi

# ──────────────────────────────────────────────────────────── ARM 9
# A GATE THAT READS STDIN MUST NOT EAT THE CANDIDATE LIST.
#
# THIS ARM EXISTS BECAUSE THE FIXTURE MISSED THE DEFECT IN THE FIELD. Every stub
# gate above is `exit 0`, which consumes nothing, so arms 1 and 3 land three
# candidates each and passed while the REAL queue — whose gate is
# `./build.sh --check`, and which reads stdin — drained exactly one per run and
# reported ok:land-queue:1 with --limit 2. Measured 2026-09-21 on this host,
# landing another host's PRs.
#
# The world the fixture built had a gate that does not read. The subject's
# world has one that does. So the stub here CONSUMES STDIN on purpose, and the
# assertion is that all three candidates are still processed.
#
# THE FIRST CANDIDATE FAILS ITS GATE, AND THAT IS THE ARM. pr_comment is the
# only stdin-inheriting reader in the loop, and it is reached ONLY from the
# evict and re-queue branches. An arm whose candidates all land never calls it,
# so the hungry gh below is unreachable and the only guard left is the gate —
# which the queue redirects from /dev/null. Measured 2026-09-22: with every
# candidate landing, this arm scored 16/16 GREEN against the fd-3 read reverted.
# It asserted a mechanism it did not exercise.
#
# So the failing candidate goes FIRST: pr_comment runs before the rest of the
# list has been read. If the list is on stdin, its gh eats the remainder and
# candidates 2-4 vanish or the queue blocks. If it is on fd 3, they all process.
scaffold arm9
candidate arm9 9000-fail fail.txt F
candidate arm9 9001-aaaa a.txt A
candidate arm9 9002-bbbb b.txt B
candidate arm9 9003-cccc c.txt C
cat > "$GH_PRS" <<JSON
[{"number":1,"headRefName":"work/9000-fail","isDraft":false},
 {"number":2,"headRefName":"work/9001-aaaa","isDraft":false},
 {"number":3,"headRefName":"work/9002-bbbb","isDraft":false},
 {"number":4,"headRefName":"work/9003-cccc","isDraft":false}]
JSON
cat > "$GATE_BIN" <<'GATE'
#!/usr/bin/env bash
# A gate that drains stdin, exactly as ./build.sh --check does.
cat >/dev/null 2>&1 || true
# ...and that FAILS on the merge carrying fail.txt, so candidate 1 is evicted
# and the loop reaches pr_comment while three candidates are still unread.
[ -f fail.txt ] && exit 1
exit 0
GATE
# AND THE FAKE gh DRAINS STDIN TOO, which is what makes this arm discriminate.
# The gate alone does not: the queue redirects it from /dev/null, so an arm
# built only on a hungry GATE passes even with the fd-3 read reverted — measured
# when this arm was written. gh is invoked inside the loop with no such
# redirect, so a hungry gh tests the fd the LIST is read on rather than one
# subprocess's plumbing. Two guards, and the arm must fail if EITHER is removed.
#
# 1553-x8js: this was GNU `sed -i '2i ...'`. BSD sed read the script as a
# backup suffix and the path as the script, failed ("invalid command code f"),
# and left gh NOT hungry — so on darwin ARM 9 ran with only the gate draining
# stdin, the shape the paragraph above measured as passing even with the fd-3
# read reverted. Built portably now, and the build is checked before the arm's
# verdict is allowed to mean anything.
_gh9_before="$(cat "$GH_BIN")"
awk 'NR == 2 { print "cat >/dev/null 2>&1 || true" } { print }' "$GH_BIN" > "$GH_BIN.tmp" \
    && mv "$GH_BIN.tmp" "$GH_BIN" && chmod +x "$GH_BIN"
if [ ! -s "$GH_BIN" ] || [ "$(cat "$GH_BIN")" = "$_gh9_before" ] \
   || [ "$(sed -n 2p "$GH_BIN")" != 'cat >/dev/null 2>&1 || true' ] \
   || [ "$(sed -n 1p "$GH_BIN")" != '#!/usr/bin/env bash' ] || [ ! -x "$GH_BIN" ]; then
    bad "ARM 9 SETUP: the stdin-hungry gh stub was NOT built (empty, unchanged, wrong line 2, or not executable) — ARM 9's verdict below proves nothing"
fi

# BOUNDED, BECAUSE THE DEFECT'S FAILURE MODE IS A HANG AND NOT A WRONG ANSWER.
# Measured 2026-09-21: with the fd-3 read reverted and a stdin-hungry gh, this
# arm did not print a wrong verdict — it BLOCKED, and the whole fixture died at
# its own 600 s bound with rc=124 and no ARM 9 line at all. A silent hang is the
# worst failure an arm can have: it is indistinguishable from a slow host, it
# produces no verdict to read, and whoever meets it goes looking for an
# infrastructure problem instead of the assertion that fired. So the subject is
# bounded HERE and a timeout is reported as this arm's own named failure.
# The run gets its OWN stdin (1809-iexe). Inherited, the hungry gh read the
# caller's: a gate started with an open, never-closing stdin (a detached
# process) hung this arm into its timeout although the queue was correct —
# measured on yolanda-windows 2026-10-20, red under `sleep 200 |`, green under
# </dev/null. The list's fd is decided inside the queue, so this does not blunt
# the arm: with the fd-3 read reverted, gh still eats the list.
out9="$(timeout 120 env \
    TILLANDSIAS_LAND_QUEUE_GH="$GH_BIN" \
    TILLANDSIAS_LAND_QUEUE_GATE="bash $GATE_BIN" \
    TILLANDSIAS_LAND_QUEUE_PLAN_REFRESH="" \
    TILLANDSIAS_LAND_QUEUE_HOST_DOOR="" \
    TILLANDSIAS_LAND_QUEUE_SIDECAR_STAGE="" \
    TILLANDSIAS_LAND_QUEUE_REMOTE=origin \
    TILLANDSIAS_TRUNK_BRANCH=linux-next \
    bash -c 'cd "$1" && bash "$2"' _ "$WORK_DIR" "$QUEUE" </dev/null 2>&1)"
_rc9=$?
if [ "$_rc9" -eq 124 ]; then
    bad "ARM 9: the queue BLOCKED (timeout 120s) with a stdin-consuming gate and gh — the candidate list is being read on stdin and a reader in the loop is waiting on it. This is the field defect of 2026-09-21, and its shape is a hang rather than a wrong answer."
else
n9="$(printf '%s' "$out9" | sed -n 's/^land:\([0-9]*\) .*/\1/p' | tr '\n' ',')"
case "$out9" in
    *"ok:land-queue:4 "*)
        if [ "$n9" = "2,3,4," ]; then
            ok "ARM 9: an evicting first candidate runs pr_comment (stdin-hungry gh) with three candidates still unread, and all three are still processed — the list is read on fd 3, not stdin"
        else
            bad "ARM 9: the queue examined 4 but landed '$n9' (expected 2,3,4) — a reader in the loop body ate the candidate list"
        fi ;;
    *)
        bad "ARM 9: a stdin-consuming loop body cut the drain short (landed '$n9', expected 2,3,4) — the candidate list is being eaten by the loop body, which is the field defect of 2026-09-21
$(printf '%s' "$out9" | tail -3)" ;;
esac
fi

# ─────────────────────────────────────────────────────────── ARM 10
# A PLAN-ONLY TRUNK MOVE IS ADOPTED; ANY OTHER MOVE STILL RE-QUEUES.
#
# THE PAIR IS THE ARM. A lone adopt-case passes against "never re-queue", which
# would ship a gate verdict about a tree nobody is pushing — the exact thing
# arm 5 exists to prevent. A lone re-queue case passes against "never adopt",
# which is today's behaviour and the defect. Only both together distinguish a
# CLASSIFIER from a policy, and that is lenovinha's divergence rule applied to
# this row: the arm must contain the case that separates the two answers.
#
# The mover pushes from a second clone during the gate, as arm 5 does — the only
# window where the defect lives.

# 10a — the move is plan/ only: ADOPT and LAND.
scaffold adopt
candidate adopt 1001-plan a.txt A
cat > "$GH_PRS" <<JSON
[{"number":1,"headRefName":"work/1001-plan","isDraft":false}]
JSON
OTHER="$TMP/adopt/other"; git clone -q "$REMOTE_DIR" "$OTHER"
git -C "$OTHER" config user.email o@o; git -C "$OTHER" config user.name o
git -C "$OTHER" config commit.gpgsign false
cat > "$GATE_BIN" <<GATE
#!/usr/bin/env bash
mkdir -p "$OTHER/plan/index.d"
printf 'packets: []\n' > "$OTHER/plan/index.d/20260922t000000z-probe-yoga.yaml"
git -C "$OTHER" add -A
git -C "$OTHER" commit -q -m "plan(probe): a fragment lands mid-gate"
git -C "$OTHER" push -q origin HEAD:linux-next
exit 0
GATE
out10a="$(run_queue)"
case "$out10a" in
    *"adopt:land-queue:1:plan-only-move"*)
        case "$out10a" in
            *"land:1 "*) ok "ARM 10a: a PLAN-ONLY trunk move mid-gate is ADOPTED and the candidate lands — the gate's verdict still describes the code, and the fleet's ledger traffic stops costing a gate each" ;;
            *) bad "ARM 10a: it adopted but did not land: $(printf '%s' "$out10a" | tail -2)" ;;
        esac ;;
    *"requeue:land-queue:1:target-moved"*)
        bad "ARM 10a: a plan-only move still RE-QUEUED — this is the 1335-2nzf defect, and with six hosts appending fragments it means the queue lands nothing during busy hours" ;;
    *)  bad "ARM 10a: neither adopted nor re-queued (did the mover run?): $(printf '%s' "$out10a" | tail -2)" ;;
esac

# 10b — the move touches a NON-plan path: still RE-QUEUE. Same scaffold, same
# mover, one different file. If 10a passes and this fails, the change is not a
# classifier, it is "stop checking".
scaffold noadopt
candidate noadopt 1002-code b.txt B
cat > "$GH_PRS" <<JSON
[{"number":2,"headRefName":"work/1002-code","isDraft":false}]
JSON
OTHER2="$TMP/noadopt/other"; git clone -q "$REMOTE_DIR" "$OTHER2"
git -C "$OTHER2" config user.email o@o; git -C "$OTHER2" config user.name o
git -C "$OTHER2" config commit.gpgsign false
cat > "$GATE_BIN" <<GATE
#!/usr/bin/env bash
mkdir -p "$OTHER2/crates/x/src"
printf 'fn main() {}\n' > "$OTHER2/crates/x/src/main.rs"
git -C "$OTHER2" add -A
git -C "$OTHER2" commit -q -m "fix(probe): a CRATE lands mid-gate"
git -C "$OTHER2" push -q origin HEAD:linux-next
exit 0
GATE
out10b="$(run_queue)"
case "$out10b" in
    *"requeue:land-queue:2:target-moved"*)
        ok "ARM 10b: a move touching crates/ still RE-QUEUES — the change is a CLASSIFIER, not a decision to stop checking" ;;
    *"adopt:land-queue:2"*)
        bad "ARM 10b: a crates/ move was ADOPTED — the gate's verdict does NOT describe that tree, and this would ship a green about code the gate never saw" ;;
    *)  bad "ARM 10b: neither adopted nor re-queued (did the mover run?): $(printf '%s' "$out10b" | tail -2)" ;;
esac

# ──────────────────────────────────────────────────────────── ARM 11
# A FROZEN TARGET HOLDS CODE, and the queue asks ORIGIN itself (1255-s4im).
# The pre-push hook refuses this only on a hooked host; the queue must not
# depend on which host runs it. Held BEFORE the gate: no gate is spent.
# 11b is the NEGATIVE CONTROL: a plan-only candidate under the same live freeze
# lands — the plan lane is how coordination keeps moving during a cut.
scaffold arm11
candidate arm11 1101-aaaa a.txt A
cat > "$GH_PRS" <<JSON
[{"number":1,"headRefName":"work/1101-aaaa","isDraft":false}]
JSON
cat > "$GATE_BIN" <<GATE
#!/usr/bin/env bash
echo gated >> "$GATE_LOG"
exit 0
GATE
frozen11="$(git -C "$WORK_DIR" rev-parse origin/linux-next)"
git -C "$WORK_DIR" push -q origin "$frozen11:refs/tillandsias/freeze/linux-next/fixture/1700000000"
out11="$(run_queue)"
git -C "$WORK_DIR" fetch -q origin linux-next
after11="$(git -C "$WORK_DIR" rev-parse origin/linux-next)"
if grep -q '^hold:land-queue:1:frozen:refs/tillandsias/freeze/linux-next/fixture/1700000000' <<<"$out11" \
   && [ "$after11" = "$frozen11" ] && [ ! -s "$GATE_LOG" ]; then
    ok "ARM 11: a code candidate into a frozen trunk is HELD before the gate (gate not run, trunk unchanged), naming the marker"
else
    bad "ARM 11: wanted hold + no gate + unchanged trunk; gate=$(wc -l < "$GATE_LOG" | tr -d ' ') after=$after11 frozen=$frozen11
$out11"
fi
mkdir -p "$WORK_DIR/plan/index.d"
git -C "$WORK_DIR" checkout -q -B work/1102-bbbb origin/linux-next
mkdir -p "$WORK_DIR/plan/index.d"; echo "x: 1" > "$WORK_DIR/plan/index.d/frag.yaml"
git -C "$WORK_DIR" add -A && git -C "$WORK_DIR" commit -q -m "work(1102-bbbb): plan only"
git -C "$WORK_DIR" push -q origin work/1102-bbbb
git -C "$WORK_DIR" checkout -q linux-next
cat > "$GH_PRS" <<JSON
[{"number":2,"headRefName":"work/1102-bbbb","isDraft":false}]
JSON
out11b="$(run_queue)"
case "$out11b" in
    *"land:2 "*) ok "ARM 11b (control): a plan-only candidate lands under the same live freeze — the hold is about held paths, not about the freeze existing" ;;
    *)           bad "ARM 11b (control): the plan-only candidate did not land under the freeze
$out11b" ;;
esac

# ──────────────────────────────────────────────────────────── ARM 12
# A FREEZE SET WHILE THE CANDIDATE GATES IS NOT PUSHED THROUGH. The gate is
# green; the cut froze the branch inside the 40-minute window; the queue must
# re-ask at push. The stub gate sets the freeze, exactly where the window is.
scaffold arm12
candidate arm12 1201-aaaa a.txt A
cat > "$GH_PRS" <<JSON
[{"number":1,"headRefName":"work/1201-aaaa","isDraft":false}]
JSON
before12="$(git -C "$WORK_DIR" rev-parse origin/linux-next)"
cat > "$GATE_BIN" <<GATE
#!/usr/bin/env bash
# The cut freezes the trunk while this candidate is gating.
git --git-dir="$REMOTE_DIR" update-ref refs/tillandsias/freeze/linux-next/cut/1700000001 "$before12"
exit 0
GATE
out12="$(run_queue)"
git -C "$WORK_DIR" fetch -q origin linux-next
after12="$(git -C "$WORK_DIR" rev-parse origin/linux-next)"
if grep -q '^requeue:land-queue:1:frozen-mid-gate:refs/tillandsias/freeze/linux-next/cut/1700000001' <<<"$out12" \
   && [ "$after12" = "$before12" ]; then
    ok "ARM 12: a freeze set DURING the gate is honoured at push — re-queued, nothing pushed, the marker named"
else
    bad "ARM 12: wanted requeue frozen-mid-gate and an unchanged trunk; before=$before12 after=$after12
$out12"
fi
# ARM 12b, NEGATIVE CONTROL: the same scaffold with the freeze cleared lands.
git --git-dir="$REMOTE_DIR" update-ref -d refs/tillandsias/freeze/linux-next/cut/1700000001
cat > "$GATE_BIN" <<'GATE'
#!/usr/bin/env bash
exit 0
GATE
out12b="$(run_queue)"
case "$out12b" in
    *"land:1 "*) ok "ARM 12b (control): with no freeze the same candidate lands — arm 12 detects the freeze, not refusing everything" ;;
    *)           bad "ARM 12b (control): did not land with no freeze
$out12b" ;;
esac

# ──────────────────────────────────────────────────────────── ARM 13
# EVERY LANDING RECORDS WHAT IT OWED ITS CARRIED OBLIGATIONS (1577-568c): one
# `Carried: <backlog> <state> [<item-or-reason>]` trailer per backlog on the land
# commit, read from the guard on the merged tree. The trunk carries the real
# rule and a decider in the shell-to-lua area. PRE-FIX: no land commit carries
# a Carried trailer and the silent candidate lands.
scaffold arm13
mkdir -p "$WORK_DIR/methodology" "$WORK_DIR/scripts"
cp "$ROOT/methodology/convergence.yaml" "$WORK_DIR/methodology/"
printf '#!/usr/bin/env bash\necho ok:x\n' > "$WORK_DIR/scripts/check-x.sh"
printf '.cache/\n' > "$WORK_DIR/.gitignore"
git -C "$WORK_DIR" add -A && git -C "$WORK_DIR" commit -q -m "the rule and one decider"
git -C "$WORK_DIR" push -q origin linux-next
candidate arm13 1301-aaaa notes.txt "not in the area"
candidate arm13 1302-bbbb scripts/check-x.sh "$(printf '#!/usr/bin/env bash\necho ok:x2')"
git -C "$WORK_DIR" checkout -q -B work/1303-cccc origin/linux-next
printf '#!/usr/bin/env bash\necho ok:x3\n' > "$WORK_DIR/scripts/check-x.sh"
git -C "$WORK_DIR" add -A
git -C "$WORK_DIR" commit -q -m "work(1303-cccc)" -m "Carried-Waiver: shell-to-lua no-item-in-reach"
git -C "$WORK_DIR" push -q origin work/1303-cccc
git -C "$WORK_DIR" checkout -q linux-next
cat > "$GH_PRS" <<JSON
[{"number":1,"headRefName":"work/1301-aaaa","isDraft":false},
 {"number":2,"headRefName":"work/1302-bbbb","isDraft":false},
 {"number":3,"headRefName":"work/1303-cccc","isDraft":false}]
JSON
cat > "$GATE_BIN" <<GATE
#!/usr/bin/env bash
echo "gated \$(git rev-parse HEAD)" >> "$GATE_LOG"
exit 0
GATE
out13="$(run_queue)"
git -C "$WORK_DIR" fetch -q origin linux-next
tr13="$(git -C "$WORK_DIR" log --first-parent --format='%s|%(trailers:key=Carried,valueonly,separator=;)' origin/linux-next | grep '^land(')"
# The trailer carries ONE entry per backlog in convergence.yaml, joined by `;`
# (1590-j20f added manifest-dir-runtime, and arms that compared the WHOLE value
# against `shell-to-lua ...` went red although land-queue was right). So 13a/13b
# assert the shell-to-lua COMPONENT, and 13d asserts one entry per backlog.
# carried_of <land(N) subject> -> that land commit's entries, one per line
# (the subject is followed by one separator character, dropped by position).
carried_of() {
    local l
    l="$(grep -m1 -F "$1" <<<"$tr13")"
    l="${l#"$1"}"
    tr ';' '\n' <<<"${l:1}"
}
if grep -qx 'shell-to-lua not-due' <<<"$(carried_of 'land(1): work/1301-aaaa into linux-next')"; then
    ok "ARM 13a: a not-due candidate lands with 'Carried: shell-to-lua not-due'"
else
    bad "ARM 13a: wanted a land(1) commit with Carried: shell-to-lua not-due; got
$tr13
$out13"
fi
if grep -qx 'shell-to-lua waived no-item-in-reach' <<<"$(carried_of 'land(3): work/1303-cccc into linux-next')"; then
    ok "ARM 13b: a due candidate carrying a Carried-Waiver trailer lands with 'Carried: shell-to-lua waived no-item-in-reach'"
else
    bad "ARM 13b: wanted a land(3) commit with Carried: shell-to-lua waived; got
$tr13
$out13"
fi
# ARM 13d: one Carried entry per backlog in the REAL convergence.yaml, so a
# new backlog cannot silently drop out of the tally (or re-break 13a/13b).
n_backlogs="$(awk '/^  backlogs:/{f=1; next} f && /^[^ ]/{f=0} f && /^    - name: /{n++} END{print n+0}' "$ROOT/methodology/convergence.yaml")"
n_entries="$(grep -c . <<<"$(carried_of 'land(1): work/1301-aaaa into linux-next')")"
if [ "$n_backlogs" -ge 1 ] && [ "$n_entries" = "$n_backlogs" ]; then
    ok "ARM 13d: the land trailer carries one entry per backlog ($n_entries of $n_backlogs in convergence.yaml)"
else
    bad "ARM 13d: wanted $n_backlogs Carried entries (one per backlog), got $n_entries:
$tr13"
fi
# ARM 13c: the due, SILENT candidate is evicted before any gate runs, the
# trailer line to add is on stdout and in the PR comment, and it never lands.
if grep -qx 'evict:land-queue:2:carried-silent:shell-to-lua' <<<"$out13" \
   && grep -q 'Carried-Waiver: shell-to-lua <reason>' <<<"$out13" \
   && grep -q '^2 --body Evicted' "$GH_COMMENTS" && grep -q '^Carried-Waiver: shell-to-lua' "$GH_COMMENTS" \
   && ! grep -q '^land(2)' <<<"$tr13" \
   && [ "$(grep -c . "$GATE_LOG")" -eq 2 ]; then
    ok "ARM 13c: a due, silent candidate is EVICTED as carried-silent before its gate, with the waiver line on stdout and on the PR"
else
    bad "ARM 13c: wanted evict carried-silent for #2, the waiver line on stdout and the PR, 2 gates run; gates=$(grep -c . "$GATE_LOG")
$out13
comments: $(cat "$GH_COMMENTS")"
fi


# ──────────────────────────────────────────────────────────── ARMS 14-17
# ORDER 1765-q7rg: the queue's pre-gate checks and its bounded flaky retry.
# trunk_push <file> <content> — a commit straight onto the remote trunk, from
# the lander clone, between queue runs.
trunk_push() {
    git -C "$WORK_DIR" checkout -q linux-next
    git -C "$WORK_DIR" pull -q --ff-only origin linux-next
    mkdir -p "$WORK_DIR/$(dirname "$1")"
    printf '%s\n' "$2" > "$WORK_DIR/$1"
    git -C "$WORK_DIR" add -A && git -C "$WORK_DIR" commit -q -m "trunk: $1"
    git -C "$WORK_DIR" push -q origin linux-next
}
gates() { grep -c . "$GATE_LOG"; }

# ── ARM 14 — A HEAD THE QUEUE ALREADY EVICTED IS NOT RE-GATED OVER A
#            PLAN-ONLY TRUNK MOVE; A CODE MOVE OR A NEW HEAD IS.
scaffold stale
candidate stale 1401-aaaa a.txt A
cat > "$GH_PRS" <<'JSON'
[{"number":1,"headRefName":"work/1401-aaaa","isDraft":false}]
JSON
sed "s|@LOG@|$GATE_LOG|" > "$GATE_BIN" <<'GATE'
#!/usr/bin/env bash
echo "gated $(git rev-parse HEAD)" >> "@LOG@"
echo "violation:stub-gate:red"
exit 1
GATE
o14a="$(run_queue)"
trunk_push plan/index.d/20261017t000000z-probe.yaml 'packets: []'
o14b="$(run_queue)"
g14b="$(gates)"
trunk_push code.txt C
o14c="$(run_queue)"
g14c="$(gates)"
git -C "$WORK_DIR" checkout -q work/1401-aaaa
echo A2 > "$WORK_DIR/a.txt"; git -C "$WORK_DIR" commit -qam "work(1401): new head"
git -C "$WORK_DIR" push -q origin work/1401-aaaa; git -C "$WORK_DIR" checkout -q linux-next
o14d="$(run_queue)"
g14d="$(gates)"
if grep -q '^evict:land-queue:1:gate-failed' <<<"$o14a" \
   && grep -q 'land-queue:evicted pr=1 head=[0-9a-f]* base=[0-9a-f]* reason=gate-failed' "$GH_COMMENTS" \
   && grep -q '^skip:land-queue:1:stale-head:.*classes=plan-ledger' <<<"$o14b" && [ "$g14b" -eq 1 ]; then
    ok "ARM 14a: an evicted head over a PLAN-ONLY trunk move is skipped, no gate spent (gates=$g14b)"
else
    bad "ARM 14a: wanted gate-failed eviction with a marker, then skip:stale-head and still 1 gate; gates=$g14b
$o14a
---
$o14b"
fi
if [ "$g14c" -eq 2 ] && ! grep -q 'stale-head' <<<"$o14c"; then
    ok "ARM 14b: the same head over a CODE trunk move is re-gated (NEGATIVE CONTROL)"
else
    bad "ARM 14b: wanted a second gate after a code move; gates=$g14c
$o14c"
fi
if [ "$g14d" -eq 3 ] && ! grep -q 'stale-head' <<<"$o14d"; then
    ok "ARM 14c: a CHANGED head is re-gated (NEGATIVE CONTROL)"
else
    bad "ARM 14c: wanted a third gate after a new head; gates=$g14d
$o14d"
fi

# ── ARM 15 — THE SECOND IDENTICAL CONFLICT AT AN UNCHANGED HEAD DRAFTS THE PR.
scaffold draft
candidate draft 1501-aaaa base.txt candidate-side
cat > "$GH_PRS" <<'JSON'
[{"number":1,"headRefName":"work/1501-aaaa","isDraft":false}]
JSON
printf '#!/usr/bin/env bash\nexit 0\n' > "$GATE_BIN"
trunk_push base.txt trunk-side
o15a="$(run_queue)"; d15a="$(grep -c . "$GH_DRAFTS")"
o15b="$(run_queue)"; d15b="$(grep -c . "$GH_DRAFTS")"
if grep -q '^evict:land-queue:1:conflict:base.txt' <<<"$o15a" && [ "$d15a" -eq 0 ] \
   && grep -q '^draft:land-queue:1:repeat-conflict' <<<"$o15b" && [ "$d15b" -eq 1 ] \
   && grep -qx '1 --undo' "$GH_DRAFTS" && grep -q 'converted this PR to a \*\*draft\*\*' "$GH_COMMENTS"; then
    ok "ARM 15: the first conflict evicts, the second identical one at the same head drafts the PR and says so"
else
    bad "ARM 15: wanted no draft on the first conflict and one on the second; drafts=$d15a/$d15b
$o15a
---
$o15b
drafts: $(cat "$GH_DRAFTS")"
fi

# ── ARM 16 — THE PREFLIGHT DOOR EVICTS A DECIDER RED BEFORE THE GATE; A STALE
#            PLAN BINARY ON THE LANDER DOES NOT.
scaffold door
candidate door 1601-aaaa a.txt A
cat > "$GH_PRS" <<'JSON'
[{"number":1,"headRefName":"work/1601-aaaa","isDraft":false}]
JSON
sed "s|@LOG@|$GATE_LOG|" > "$GATE_BIN" <<'GATE'
#!/usr/bin/env bash
echo gated >> "@LOG@"
exit 0
GATE
PF_BIN="$TMP/door/pf.sh"
printf '#!/usr/bin/env bash\necho "violation:stub-decider:red"\nexit 1\n' > "$PF_BIN"
o16a="$(PREFLIGHT_CMD="bash $PF_BIN" run_queue)"; g16a="$(gates)"; c16a="$(cat "$GH_COMMENTS")"
# A fresh scaffold: the same head over an unchanged trunk would now (rightly)
# be stale-skipped by arm 14's rule, and this arm is about the door.
scaffold door2
candidate door2 1602-aaaa a.txt A
cat > "$GH_PRS" <<'JSON'
[{"number":1,"headRefName":"work/1602-aaaa","isDraft":false}]
JSON
sed "s|@LOG@|$GATE_LOG|" > "$GATE_BIN" <<'GATE'
#!/usr/bin/env bash
echo gated >> "@LOG@"
exit 0
GATE
PF_BIN="$TMP/door2/pf.sh"
printf '#!/usr/bin/env bash\necho "refused:preflight:stale-plan-binary — stub"\nexit 1\n' > "$PF_BIN"
o16b="$(PREFLIGHT_CMD="bash $PF_BIN" run_queue)"; g16b="$(gates)"
if grep -q '^evict:land-queue:1:preflight-failed' <<<"$o16a" && [ "$g16a" -eq 0 ] \
   && grep -q 'violation:stub-decider:red' <<<"$c16a" && grep -q 'reason=preflight-failed' <<<"$c16a"; then
    ok "ARM 16a: a decider-level preflight red evicts with no full gate spent"
else
    bad "ARM 16a: wanted evict preflight-failed and 0 gates; gates=$g16a
$o16a"
fi
if [ "$g16b" -eq 1 ] && grep -q '^land:1 ' <<<"$o16b"; then
    ok "ARM 16b: a stale plan binary on the lander is not the candidate's red — the full gate decides (NEGATIVE CONTROL)"
else
    bad "ARM 16b: wanted the full gate to run and land; gates=$g16b
$o16b"
fi

# ── ARM 17 — flaky: RE-QUEUES ONCE AT THE BACK; A SECOND flaky: EVICTS.
scaffold flaky
candidate flaky 1701-aaaa a.txt A
candidate flaky 1702-bbbb b.txt B
cat > "$GH_PRS" <<'JSON'
[{"number":1,"headRefName":"work/1701-aaaa","isDraft":false},
 {"number":2,"headRefName":"work/1702-bbbb","isDraft":false}]
JSON
FLAKES="$TMP/flaky/flakes"; echo 1 > "$FLAKES"
sed -e "s|@LOG@|$GATE_LOG|" -e "s|@FLAKES@|$FLAKES|" > "$GATE_BIN" <<'GATE'
#!/usr/bin/env bash
echo gated >> "@LOG@"
left="$(cat "@FLAKES@")"
if [ -f a.txt ] && [ "$left" -gt 0 ]; then
    echo $((left - 1)) > "@FLAKES@"
    echo "flaky:240-900-z3kv.step:violation:x,violation:y"
    exit 1
fi
exit 0
GATE
o17a="$(run_queue)"
order17="$(printf '%s' "$o17a" | sed -n 's/^land:\([0-9]*\) .*/\1/p' | tr '\n' ',')"
if grep -q '^requeue:land-queue:1:flaky:240-900-z3kv.step' <<<"$o17a" && [ "$order17" = "2,1," ]; then
    ok "ARM 17a: a flaky: red re-queues ONCE at the back and then lands (order 2,1)"
else
    bad "ARM 17a: wanted requeue flaky for #1 and landings 2,1; got '$order17'
$o17a"
fi
scaffold flaky2
candidate flaky2 1701-aaaa a.txt A
cat > "$GH_PRS" <<'JSON'
[{"number":1,"headRefName":"work/1701-aaaa","isDraft":false}]
JSON
FLAKES="$TMP/flaky2/flakes"; echo 9 > "$FLAKES"
sed -e "s|@LOG@|$GATE_LOG|" -e "s|@FLAKES@|$FLAKES|" > "$GATE_BIN" <<'GATE'
#!/usr/bin/env bash
echo gated >> "@LOG@"
left="$(cat "@FLAKES@")"
if [ -f a.txt ] && [ "$left" -gt 0 ]; then
    echo $((left - 1)) > "@FLAKES@"
    echo "flaky:240-900-z3kv.step:violation:x,violation:y"
    exit 1
fi
exit 0
GATE
o17b="$(run_queue)"; g17b="$(gates)"
o17c="$(run_queue)"; g17c="$(gates)"
if [ "$g17b" -eq 2 ] && grep -q '^evict:land-queue:1:gate-failed:rc=1:flaky:' <<<"$o17b" \
   && grep -q 'reason=flaky' "$GH_COMMENTS" && grep -q '^flaky:240-900-z3kv.step' "$GH_COMMENTS" \
   && [ "$g17c" -eq 4 ] && ! grep -q stale-head <<<"$o17c"; then
    ok "ARM 17b: a second flaky: evicts, the comment names the token, and a flaky eviction is never stale-skipped"
else
    bad "ARM 17b: wanted 2 gates then an eviction naming flaky:, then two more (re-queue, evict) — never stale-skipped; gates=$g17b/$g17c
$o17b
---
$o17c"
fi

# ── ARM 18 — A GATE THAT DIES (rc=255, the host going down) IS NOT A VERDICT:
#            recorded as gate-aborted, and never stale-skipped. Measured on
#            #505, 2026-10-17: macuahuitl crashed mid-gate and the queue evicted.
scaffold abort
candidate abort 1801-aaaa a.txt A
cat > "$GH_PRS" <<'JSON'
[{"number":1,"headRefName":"work/1801-aaaa","isDraft":false}]
JSON
sed "s|@LOG@|$GATE_LOG|" > "$GATE_BIN" <<'GATE'
#!/usr/bin/env bash
echo gated >> "@LOG@"
exit 255
GATE
o18a="$(run_queue)"
trunk_push plan/index.d/20261017t000000z-probe.yaml 'packets: []'
o18b="$(run_queue)"; g18="$(gates)"
# ORDER 2234-a964 supersedes the comment half: an aborted gate is now
# could-not-run:host, so it posts NO eviction comment at all (macuahuitl run 29:
# 14 PRs falsely evicted rc=255 by a keyring quota), and the PR is simply gated
# again on the next run. What ARM 18 protected still holds: never stale-skipped.
if ! grep -q 'land-queue:evicted' "$GH_COMMENTS" 2>/dev/null \
   && grep -q 'could-not-run:host:gate-aborted:rc=255' <<<"$o18a" \
   && [ "$g18" -eq 2 ] && ! grep -q stale-head <<<"$o18b"; then
    ok "ARM 18: an aborted gate (rc=255) is could-not-run:host, evicts and comments nobody, and is re-gated on the next run, never stale-skipped"
else
    bad "ARM 18: wanted could-not-run:host:gate-aborted:rc=255, no eviction comment, and a second gate; gates=$g18
$o18a
---
$o18b
comments: $(grep -o 'land-queue:evicted[^>]*' "$GH_COMMENTS" 2>/dev/null)"
fi

# ── ARM 19 — A CFG-GATED macOS CRATE LANDS ONLY WITH A NATIVE LINT (1235-rfub).
#            The gate compiles the tray as stubs and cannot lint it; the queue
#            must ask check-native-lint-attested.sh before spending a gate.
#            Measured: land(594) at 32a9f83ef put a new tray source on trunk with
#            no Native-Lint attestation. PRE-FIX: #1 lands — this arm FAILS.
#   #1 the incident's useless_format in the tray, unattested -> EVICTED, the
#      accountable host named, no gate; an EXPORTED override must not excuse it
#   #2 a change outside the gated crate -> lands (NEGATIVE CONTROL)
#   #3 the same tray change with a Native-Lint trailer bound to its tree -> lands
#   #4 a tray change carrying `Native-Lint-Unattested: <reason>` -> lands, and
#      the land commit repeats the debt
scaffold nlint
tray_candidate() {  # <order> <file under src/> <content> [extra commit args...]
    local order="$1" file="$2" content="$3"; shift 3
    git -C "$WORK_DIR" checkout -q -B "work/$order" origin/linux-next
    mkdir -p "$WORK_DIR/crates/tillandsias-macos-tray/src"
    printf '%s\n' "$content" > "$WORK_DIR/crates/tillandsias-macos-tray/src/$file"
    git -C "$WORK_DIR" add -A
    git -C "$WORK_DIR" commit -q -m "work($order): tray" "$@"
}
tray_candidate 1901-aaaa action_host.rs 'fn f() -> Result<(), String> { std::fs::read("x").map_err(|e| format!("{e}"))?; Ok(()) }'
git -C "$WORK_DIR" push -q origin work/1901-aaaa
candidate nlint 1902-bbbb b.txt B
tray_candidate 1903-cccc g.rs 'fn g() {}'
t19="$(git -C "$WORK_DIR" rev-parse HEAD:crates/tillandsias-macos-tray)"
git -C "$WORK_DIR" commit -q --allow-empty -m "native-lint: darwin ok (mac)" \
    --trailer "Native-Lint: mac darwin crates/tillandsias-macos-tray=$t19 clippy-all-targets-D-warnings"
git -C "$WORK_DIR" push -q origin work/1903-cccc
tray_candidate 1904-dddd h.rs 'fn h() {}' -m "Native-Lint-Unattested: no mac awake for the fixture"
git -C "$WORK_DIR" push -q origin work/1904-dddd
git -C "$WORK_DIR" checkout -q linux-next
cat > "$GH_PRS" <<'JSON'
[{"number":1,"headRefName":"work/1901-aaaa","isDraft":false},
 {"number":2,"headRefName":"work/1902-bbbb","isDraft":false}]
JSON
sed "s|@LOG@|$GATE_LOG|" > "$GATE_BIN" <<'GATE'
#!/usr/bin/env bash
echo "gated $(git rev-parse HEAD)" >> "@LOG@"
exit 0
GATE
o19a="$(TILLANDSIAS_NATIVE_LINT_UNATTESTED="leaked from the caller" run_queue)"; g19a="$(gates)"
if grep -q '^evict:land-queue:1:native-lint-unattested:tillandsias-macos-tray$' <<<"$o19a" \
   && grep -q '^land:2 ' <<<"$o19a" && ! grep -q '^land:1 ' <<<"$o19a" && [ "$g19a" -eq 1 ] \
   && grep -q 'Accountable: the authoring host' "$GH_COMMENTS" \
   && grep -q 'reason=native-lint-unattested:tillandsias-macos-tray' "$GH_COMMENTS"; then
    ok "ARM 19a: an unattested macOS-tray change is EVICTED before its gate, naming the accountable host; an exported override does not excuse it; a non-tray candidate lands"
else
    bad "ARM 19a: wanted evict native-lint-unattested for #1, land #2, 1 gate; gates=$g19a
$o19a
comments: $(cat "$GH_COMMENTS")"
fi
cat > "$GH_PRS" <<'JSON'
[{"number":3,"headRefName":"work/1903-cccc","isDraft":false}]
JSON
o19b="$(run_queue)"
if grep -q '^land:3 ' <<<"$o19b"; then
    ok "ARM 19b: the tray change with a Native-Lint attestation bound to its tree lands (NEGATIVE CONTROL)"
else
    bad "ARM 19b: wanted the attested tray candidate to land
$o19b"
fi
cat > "$GH_PRS" <<'JSON'
[{"number":4,"headRefName":"work/1904-dddd","isDraft":false}]
JSON
o19c="$(run_queue)"
git -C "$WORK_DIR" fetch -q origin linux-next
d19="$(git -C "$WORK_DIR" log --first-parent --format='%s|%(trailers:key=Native-Lint-Unattested,valueonly)' origin/linux-next | grep '^land(4)')"
if grep -q '^land:4 ' <<<"$o19c" && grep -q '^debt:land-queue:4:native-lint-unattested:' <<<"$o19c" \
   && grep -q 'no mac awake for the fixture' <<<"$d19"; then
    ok "ARM 19c: a candidate carrying Native-Lint-Unattested lands as named debt, repeated on the land commit"
else
    bad "ARM 19c: wanted land #4 with the debt on the land commit; land commit: [$d19]
$o19c"
fi
# ──────────────────────────────────────────────────── ARMS 20a-c (order 1839-fuvg)
# @trace order:1839-fuvg
# 20a: a refused push says WHY. The remote's pre-receive refuses with a named
# line; the queue output and the PR comment must carry it (pre-fix: the push's
# output went to /dev/null and only push-did-not-land:rc=1 was printed).
scaffold push20a
candidate push20a 2001-aaaa a.txt A
cat > "$GH_PRS" <<'JSON'
[{"number":1,"headRefName":"work/2001-aaaa","isDraft":false}]
JSON
printf '#!/bin/sh\necho "refused:fixture-hook:named-refusal-line" >&2\nexit 1\n' > "$REMOTE_DIR/hooks/pre-receive"
chmod +x "$REMOTE_DIR/hooks/pre-receive"
printf '#!/usr/bin/env bash\nexit 0\n' > "$GATE_BIN"
o20a="$(run_queue)"
if grep -q 'requeue:land-queue:1:push-did-not-land' <<<"$o20a" \
   && grep -q 'refused:fixture-hook:named-refusal-line' <<<"$o20a" \
   && grep -q 'refused:fixture-hook:named-refusal-line' "$GH_COMMENTS"; then
    ok "ARM 20a: a refused push prints the push's own refusal line beside push-did-not-land and carries it in the PR comment"
else
    bad "ARM 20a: the refusal line is missing from the output or the PR comment
$o20a
comments: $(cat "$GH_COMMENTS")"
fi

# 20b: the target gains a ledger fragment AFTER the queue's re-read and BEFORE
# the push (a client pre-push hook plays the concurrent plan-lane push, once).
# The push is rejected non-fast-forward; the queue must re-adopt and land, not
# re-queue for a full re-gate.
scaffold push20b
candidate push20b 2002-bbbb b.txt B
cat > "$GH_PRS" <<'JSON'
[{"number":2,"headRefName":"work/2002-bbbb","isDraft":false}]
JSON
printf '#!/usr/bin/env bash\nexit 0\n' > "$GATE_BIN"
OTHER20="$TMP/push20b/other"; git clone -q "$REMOTE_DIR" "$OTHER20"
git -C "$OTHER20" config user.email o@o; git -C "$OTHER20" config user.name o
git -C "$OTHER20" config commit.gpgsign false
mkdir -p "$WORK_DIR/.git/hooks"
cat > "$WORK_DIR/.git/hooks/pre-push" <<HOOK
#!/usr/bin/env bash
grep -q " refs/heads/linux-next " || exit 0  # 2248-jihs: race the TRUNK push, not the queue-status publish
[ -e "$TMP/push20b/raced" ] && exit 0
: > "$TMP/push20b/raced"
mkdir -p "$OTHER20/plan/index.d"
printf 'packets: []\n' > "$OTHER20/plan/index.d/20261023t000000z-race-fuvg.yaml"
git -C "$OTHER20" add -A
git -C "$OTHER20" commit -q -m "plan(race): a fragment lands between gate and push"
git -C "$OTHER20" push -q origin HEAD:linux-next
exit 0
HOOK
chmod +x "$WORK_DIR/.git/hooks/pre-push"
o20b="$(run_queue)"
if grep -q 'plan-only-move-at-push' <<<"$o20b" && grep -q '^land:2 ' <<<"$o20b"; then
    ok "ARM 20b: a push refused because a ledger fragment landed between gate and push is re-adopted and lands, with no re-gate"
else
    bad "ARM 20b: wanted adopt-at-push then land:2
$o20b"
fi

# 20c: an evicted candidate's gate log is KEPT at the path the evict line and
# the PR comment name, holds the gate's output, and retention is bounded.
scaffold log20c
candidate log20c 2003-cccc c.txt C
cat > "$GH_PRS" <<'JSON'
[{"number":3,"headRefName":"work/2003-cccc","isDraft":false}]
JSON
printf '#!/usr/bin/env bash\necho "FAIL: marker-gate-output-xyz"\nexit 1\n' > "$GATE_BIN"
LOGDIR_OVERRIDE="$TMP/log20c/logs"
o20c="$(run_queue)"
p20c="$(sed -n 's/^evict:land-queue:3:.*kept at \(.*\)$/\1/p' <<<"$o20c" | head -n 1)"
if [ -n "$p20c" ] && [ -f "$p20c" ] && grep -q 'marker-gate-output-xyz' "$p20c" \
   && grep -qF "$p20c" "$GH_COMMENTS"; then
    ok "ARM 20c: the evicted candidate's full gate log exists at the path named in the evict line and the PR comment"
else
    bad "ARM 20c: no kept gate log (path=[$p20c])
$o20c"
fi
for _i in 1 2 3 4; do sleep 1; TILLANDSIAS_LAND_QUEUE_LOG_KEEP=2 run_queue >/dev/null 2>&1; done
n20c="$(ls -1d "$LOGDIR_OVERRIDE"/*/ 2>/dev/null | wc -l)"
if [ "$n20c" -le 2 ] && [ "$n20c" -ge 1 ]; then
    ok "ARM 20c2: log retention is bounded to the newest N run directories ($n20c kept of 5 runs)"
else
    bad "ARM 20c2: expected 1-2 run dirs after 5 runs with KEEP=2, found $n20c"
fi
unset LOGDIR_OVERRIDE

# ──────────────────────────────────────────────────────────── ARM 21
# THE QUEUE READS THE WHOLE QUEUE, NOT gh's FIRST PAGE (1959-tdn5).
#
# MEASURED ON macuahuitl 2026-11-02: `gh pr list` without --limit returns the
# NEWEST 30 open PRs. With 30+ open (drafts count), the OLDEST non-draft PR —
# #679 that day — never appeared in the capture, so the queue reported a
# smaller queue than existed and the oldest ready work never landed. A fake gh
# that honours --limit the way the real one does (default 30, newest first)
# over 31 open PRs where only the OLDEST is ready must still land it.
lq_gh_paged() {  # fake gh whose `pr list` honours --limit (default 30), newest first
    cat > "$GH_BIN" <<GH
#!/usr/bin/env bash
case "\$1 \$2" in
    "pr list")
        lim=30
        while [ \$# -gt 0 ]; do
            case "\$1" in --limit) lim="\$2"; shift ;; --limit=*) lim="\${1#*=}" ;; esac
            shift
        done
        # GH_PRS holds one PR object per line, newest first; gh pages from the top.
        printf '['; head -n "\$lim" "$GH_PRS" | paste -sd, -; printf ']\n' ;;
    "pr comment") shift 2; printf '%s\n' "\$*" >> "$GH_COMMENTS" ;;
    "pr view")    printf '{"comments":[]}\n' ;;
    *) exit 1 ;;
esac
GH
    chmod +x "$GH_BIN"
}
scaffold arm21
candidate arm21 2100-oldp old.txt OLD
: > "$GH_PRS"
for _i in $(seq 31 -1 2); do
    printf '{"number":%d,"headRefName":"work/%d-drft","isDraft":true}\n' "$_i" "$((2100 + _i))" >> "$GH_PRS"
done
printf '{"number":1,"headRefName":"work/2100-oldp","isDraft":false}\n' >> "$GH_PRS"
lq_gh_paged
printf '#!/usr/bin/env bash\nexit 0\n' > "$GATE_BIN"
out21="$(run_queue)"; rc21=$?
if [ "$rc21" -eq 0 ] && grep -q '^land:1 ' <<<"$out21"; then
    ok "ARM 21: the oldest non-draft PR among 31 open ones lands — the queue asked gh for more than its first page"
else
    bad "ARM 21: with 31 open PRs (30 newer drafts) the oldest ready PR #1 did not land (rc=$rc21) — gh's default page of 30 hid it
$out21"
fi

# ARM 21b: WHEN THE CAPTURE IS EXACTLY AS LONG AS THE LIMIT, THE QUEUE MAY BE
# TRUNCATED AND THE SCRIPT MUST REFUSE, not land a possibly-partial list. The
# fake gh honours whatever --limit the script passes; the file holds 600 PRs,
# so a capture equal to the limit means the page boundary was hit.
scaffold arm21b
: > "$GH_PRS"
for _i in $(seq 600 -1 1); do
    printf '{"number":%d,"headRefName":"work/%d-drft","isDraft":true}\n' "$_i" "$((3000 + _i))" >> "$GH_PRS"
done
lq_gh_paged
printf '#!/usr/bin/env bash\nexit 0\n' > "$GATE_BIN"
out21b="$(run_queue)"; rc21b=$?
case "$out21b" in
    *"fail:land-queue:queue-may-be-truncated"*)
        if [ "$rc21b" -ne 0 ]; then
            ok "ARM 21b: a capture as long as the list limit REFUSES (rc=$rc21b) instead of landing from a possibly truncated queue"
        else
            bad "ARM 21b: it named the truncation but exited 0, so a caller reads success"
        fi ;;
    *) bad "ARM 21b: a capture equal to the list limit was not refused (rc=$rc21b)
$out21b" ;;
esac

# ──────────────────────────────────────────────────────────── ARM 22
# ORDER 1992-lqpb, amended by 2143-z5uj: A STALE PLAN BINARY IS THIS HOST'S
# STATE, NOT THE CANDIDATE'S. When the refresh from one candidate's merge cannot
# make it current, THAT candidate is skipped (could-not-run:host:...) and evicts
# nobody, and the run CONTINUES: ending it stalled the whole queue on one merge.
# The refresh stub fails for the first candidate only (a marker file).
scaffold arm22
candidate arm22 1022-aaaa a22.txt A
candidate arm22 1024-cccc c22.txt C
cat > "$GH_PRS" <<JSON
[{"number":22,"headRefName":"work/1022-aaaa","isDraft":false},
 {"number":24,"headRefName":"work/1024-cccc","isDraft":false}]
JSON
cat > "$GATE_BIN" <<GATE
#!/usr/bin/env bash
echo "gated" >> "$GATE_LOG"
exit 0
GATE
_m22="$TMP/arm22/refresh-failed-once"
out22="$(PLAN_REFRESH_CMD="if [ -e '$_m22' ]; then exit 0; fi; : > '$_m22'; echo stale-plan-binary >&2; exit 1" run_queue)"; rc22=$?
if grep -q '^could-not-run:host:plan-binary-stale:#22:' <<<"$out22" \
    && ! grep -q '^evict:' <<<"$out22" && grep -q '^land:24 ' <<<"$out22" && ! grep -q '^land:22 ' <<<"$out22" \
    && [ "$rc22" -eq 0 ] && [ "$(grep -c . "$GATE_LOG")" -eq 1 ] && [ ! -s "$GH_COMMENTS" ]; then
    ok "ARM 22: a plan binary that cannot be refreshed skips THAT candidate (could-not-run:host:plan-binary-stale), evicts nobody, comments nothing, and the run lands the next (2143-z5uj)"
else
    bad "ARM 22: wanted #22 skipped as could-not-run:host, #24 landed, rc=0, 1 gate, no comment; got rc=$rc22 gates=$(grep -c . "$GATE_LOG") comments=$(grep -c . "$GH_COMMENTS")
$out22"
fi
# ...and a refresh that succeeds lets the candidate land as before.
scaffold arm22b
candidate arm22b 1023-bbbb b22.txt B
cat > "$GH_PRS" <<JSON
[{"number":23,"headRefName":"work/1023-bbbb","isDraft":false}]
JSON
cat > "$GATE_BIN" <<GATE
#!/usr/bin/env bash
exit 0
GATE
out22b="$(PLAN_REFRESH_CMD='true' run_queue)"
if grep -q '^land:23 ' <<<"$out22b"; then
    ok "ARM 22b: a refresh that succeeds lets the candidate land"
else
    bad "ARM 22b: wanted land:23 after a successful refresh
$out22b"
fi


# ──────────────────────────────────────────────────────────── ARM 30
# ORDER 2143-z5uj: THE QUEUE IS RE-READ BEFORE EVERY CANDIDATE. #3 is labelled
# land:priority WHILE #1 GATES (the gate stub rewrites the list on its first
# call), so #3 is gated next, before #2. On trunk the list is read once, the
# label is never seen, and the order is 1,2,3.
scaffold arm30
candidate arm30 1301-aaaa a30.txt A
candidate arm30 1302-bbbb b30.txt B
candidate arm30 1303-cccc c30.txt C
cat > "$GH_PRS" <<JSON
[{"number":1,"headRefName":"work/1301-aaaa","isDraft":false,"labels":[]},
 {"number":2,"headRefName":"work/1302-bbbb","isDraft":false,"labels":[]},
 {"number":3,"headRefName":"work/1303-cccc","isDraft":false,"labels":[]}]
JSON
cat > "$TMP/arm30/prs-relabelled.json" <<JSON
[{"number":2,"headRefName":"work/1302-bbbb","isDraft":false,"labels":[]},
 {"number":3,"headRefName":"work/1303-cccc","isDraft":false,"labels":[{"name":"land:priority"}]}]
JSON
cat > "$GATE_BIN" <<GATE
#!/usr/bin/env bash
[ -s "$GATE_LOG" ] || cp "$TMP/arm30/prs-relabelled.json" "$GH_PRS"
echo "gated" >> "$GATE_LOG"
exit 0
GATE
out30="$(run_queue)"
seen30="$(sed -n 's/^land:\([0-9]*\) .*/\1/p' <<<"$out30" | tr '\n' ',')"
if [ "$seen30" = "1,3,2," ]; then
    ok "ARM 30: a PR labelled land:priority while candidate 1 gated is gated next (1,3,2) — the queue is re-read per candidate (2143-z5uj)"
else
    bad "ARM 30: wanted landings 1,3,2; got '$seen30'
$out30"
fi

# ARM 30b: land:priority from the START jumps the number order.
scaffold arm30b
candidate arm30b 1304-aaaa a30b.txt A
candidate arm30b 1305-bbbb b30b.txt B
cat > "$GH_PRS" <<JSON
[{"number":4,"headRefName":"work/1304-aaaa","isDraft":false},
 {"number":5,"headRefName":"work/1305-bbbb","isDraft":false,"labels":[{"name":"land:priority"}]}]
JSON
cat > "$GATE_BIN" <<GATE
#!/usr/bin/env bash
exit 0
GATE
out30b="$(run_queue)"
seen30b="$(sed -n 's/^land:\([0-9]*\) .*/\1/p' <<<"$out30b" | tr '\n' ',')"
if [ "$seen30b" = "5,4," ]; then
    ok "ARM 30b: land:priority lands before a lower PR number"
else
    bad "ARM 30b: wanted 5,4; got '$seen30b'
$out30b"
fi

# ──────────────────────────────────────────────────────────── ARM 31
# land:hold replaces draft-as-hold: the held PR is never gated, and is NAMED.
scaffold arm31
candidate arm31 1311-aaaa a31.txt A
candidate arm31 1312-bbbb b31.txt B
cat > "$GH_PRS" <<JSON
[{"number":11,"headRefName":"work/1311-aaaa","isDraft":false,"labels":[{"name":"land:hold"}]},
 {"number":12,"headRefName":"work/1312-bbbb","isDraft":false,"labels":[]}]
JSON
cat > "$GATE_BIN" <<GATE
#!/usr/bin/env bash
echo "gated" >> "$GATE_LOG"
exit 0
GATE
out31="$(run_queue)"
if grep -q '^hold:land-queue:#11:' <<<"$out31" && ! grep -q '^land:11 ' <<<"$out31" \
    && grep -q '^land:12 ' <<<"$out31" && [ "$(grep -c . "$GATE_LOG")" -eq 1 ]; then
    ok "ARM 31: a land:hold PR is named and never gated; the next PR lands"
else
    bad "ARM 31: wanted #11 held+named, #12 landed, 1 gate; got gates=$(grep -c . "$GATE_LOG")
$out31"
fi

# ──────────────────────────────────────────────────────────── ARM 32
# A RED IN A TEST THE CANDIDATE DID NOT TOUCH IS RE-RUN ONCE. The gate stub
# fails its first call naming scripts/test-other.sh, then passes.
scaffold arm32
candidate arm32 1321-aaaa a32.txt A
cat > "$GH_PRS" <<JSON
[{"number":21,"headRefName":"work/1321-aaaa","isDraft":false}]
JSON
cat > "$GATE_BIN" <<GATE
#!/usr/bin/env bash
echo "gated" >> "$GATE_LOG"
if [ "\$(grep -c . "$GATE_LOG")" -eq 1 ]; then echo "FAIL scripts/test-other.sh: flaked"; exit 1; fi
exit 0
GATE
out32="$(run_queue)"
if grep -q '^flaky:scripts/test-other.sh ' <<<"$out32" && grep -q '^land:21 ' <<<"$out32" \
    && ! grep -q '^evict' <<<"$out32" && [ "$(grep -c . "$GATE_LOG")" -eq 2 ]; then
    ok "ARM 32: an untouched test red then green on the identical tree prints flaky:<test> and lands (2 gates)"
else
    bad "ARM 32: wanted flaky:scripts/test-other.sh, landed, 2 gates; got gates=$(grep -c . "$GATE_LOG")
$out32"
fi

# ARM 32b: red TWICE in the untouched test evicts, naming evicted:<test>.
scaffold arm32b
candidate arm32b 1322-aaaa a32b.txt A
cat > "$GH_PRS" <<JSON
[{"number":22,"headRefName":"work/1322-aaaa","isDraft":false}]
JSON
# 2118-tpmy: the red is the CANDIDATE's (trunk, without a32b.txt, is green),
# so after the two candidate gates the trunk check gates once more and evicts.
cat > "$GATE_BIN" <<GATE
#!/usr/bin/env bash
echo "gated" >> "$GATE_LOG"
if [ -e a32b.txt ]; then echo "FAIL scripts/test-other.sh: real"; exit 1; fi
exit 0
GATE
out32b="$(run_queue)"
if grep -q '^evicted:scripts/test-other.sh ' <<<"$out32b" && grep -q '^evict:land-queue:22:gate-failed' <<<"$out32b" \
    && ! grep -q '^land:22 ' <<<"$out32b" && [ "$(grep -c . "$GATE_LOG")" -eq 3 ]; then
    ok "ARM 32b: an untouched test red twice, trunk green, prints evicted:<test> and evicts (3 gates)"
else
    bad "ARM 32b: wanted evicted:scripts/test-other.sh, evicted, 3 gates; got gates=$(grep -c . "$GATE_LOG")
$out32b"
fi

# ARM 32c, NEGATIVE CONTROL: a red in a test the candidate's diff TOUCHES is
# judged on the first run — no re-run, so a PR cannot re-roll its own red.
scaffold arm32c
candidate arm32c 1323-aaaa scripts-test-mine.txt A
git -C "$WORK_DIR" checkout -q work/1323-aaaa
mkdir -p "$WORK_DIR/scripts"; printf 'x\n' > "$WORK_DIR/scripts/test-mine.sh"
git -C "$WORK_DIR" add -A; git -C "$WORK_DIR" commit -q -m mine; git -C "$WORK_DIR" push -q origin work/1323-aaaa
git -C "$WORK_DIR" checkout -q linux-next
cat > "$GH_PRS" <<JSON
[{"number":23,"headRefName":"work/1323-aaaa","isDraft":false}]
JSON
cat > "$GATE_BIN" <<GATE
#!/usr/bin/env bash
echo "gated" >> "$GATE_LOG"
if [ "\$(grep -c . "$GATE_LOG")" -eq 1 ]; then echo "FAIL scripts/test-mine.sh: mine"; exit 1; fi
exit 0
GATE
out32c="$(run_queue)"
if grep -q '^evict:land-queue:23:gate-failed' <<<"$out32c" && ! grep -q '^flaky:' <<<"$out32c" \
    && [ "$(grep -c . "$GATE_LOG")" -eq 1 ]; then
    ok "ARM 32c (control): a red in a test the diff touches evicts on the first run, no re-run"
else
    bad "ARM 32c: wanted one gate and an eviction; got gates=$(grep -c . "$GATE_LOG")
$out32c"
fi

# ARM 32d, NEGATIVE CONTROL: a red that names NO test is never re-rolled.
scaffold arm32d
candidate arm32d 1324-aaaa a32d.txt A
cat > "$GH_PRS" <<JSON
[{"number":24,"headRefName":"work/1324-aaaa","isDraft":false}]
JSON
cat > "$GATE_BIN" <<GATE
#!/usr/bin/env bash
echo "gated" >> "$GATE_LOG"
if [ "\$(grep -c . "$GATE_LOG")" -eq 1 ]; then echo "error: something broke"; exit 1; fi
exit 0
GATE
out32d="$(run_queue)"
if grep -q '^evict:land-queue:24:gate-failed' <<<"$out32d" && [ "$(grep -c . "$GATE_LOG")" -eq 1 ]; then
    ok "ARM 32d (control): a red naming no test evicts on the first run"
else
    bad "ARM 32d: wanted one gate and an eviction; got gates=$(grep -c . "$GATE_LOG")
$out32d"
fi

# ARM 32e-g (2277-7trt): red-twice:<test>: says the step runner already ran that
# step twice on this tree. (e) candidate-only red: no identical-tree re-run, the
# trunk check still gates once and the candidate is evicted (2 gates, not 3).
# (f) trunk fails it too: the queue holds, nobody is evicted (2 gates). (g)
# CONTROL: another untouched red beside it still re-runs (3 gates).
arm32rt() { # <name> <order> <num> <gate body, sees candidate file rt.txt>
    scaffold "$1"
    mkdir -p "$WORK_DIR/scripts"; echo "# $1" > "$WORK_DIR/scripts/test-hs.sh"
    git -C "$WORK_DIR" add -A; git -C "$WORK_DIR" commit -q -m hs; git -C "$WORK_DIR" push -q origin linux-next
    candidate "$1" "$2" rt.txt A
    printf '[{"number":%s,"headRefName":"work/%s","isDraft":false}]\n' "$3" "$2" > "$GH_PRS"
    printf '#!/usr/bin/env bash\necho gated >> "%s"\n%s\nexit 0\n' "$GATE_LOG" "$4" > "$GATE_BIN"
    out32rt="$(run_queue)"; g32rt="$(grep -c . "$GATE_LOG")"
}
_rt="echo 'red-twice:test-hs.sh:rc=1,rc=1'"
arm32rt arm32e 1325-aaaa 25 "if [ -e rt.txt ]; then $_rt; exit 1; fi"
if [ "$g32rt" -eq 2 ] && grep -q '^land-queue: #25 red-twice in scripts/test-hs.sh' <<<"$out32rt" \
    && grep -q '^evict:land-queue:25:gate-failed' <<<"$out32rt" && ! grep -q 're-running the gate once' <<<"$out32rt"; then
    ok "ARM 32e: a red-twice red is not re-run; the trunk is asked once and the candidate is evicted (2 gates)"
else
    bad "ARM 32e: wanted 2 gates, no re-run, evicted; got gates=$g32rt
$out32rt"
fi
arm32rt arm32f 1326-aaaa 26 "$_rt; exit 1"
if [ "$g32rt" -eq 2 ] && grep -q '^hold:trunk-red:scripts/test-hs.sh ' <<<"$out32rt" && ! grep -q '^evict' <<<"$out32rt"; then
    ok "ARM 32f: a red-twice red the trunk shares holds the queue and evicts nobody (2 gates)"
else
    bad "ARM 32f: wanted 2 gates and hold:trunk-red; got gates=$g32rt
$out32rt"
fi
arm32rt arm32g 1327-aaaa 27 "if [ -e rt.txt ]; then $_rt; echo 'FAIL scripts/test-other.sh: x'; exit 1; fi"
if [ "$g32rt" -eq 3 ] && grep -q 're-running the gate once' <<<"$out32rt"; then
    ok "ARM 32g (control): a red-twice beside another untouched red still re-runs once (3 gates)"
else
    bad "ARM 32g: wanted 3 gates and a re-run; got gates=$g32rt
$out32rt"
fi

# ──────────────────────────────────────────────────────────── ARM 33
# Operator ruling 2026-11-20: A PLAN-LEDGER-ONLY PR LANDS ON THE PLAN-LANE
# CHECKS WITH ZERO BUILD-CHECK INVOCATIONS. #1166 took 53 min of full gate.
scaffold arm33
git -C "$WORK_DIR" checkout -q -B work/1331-aaaa origin/linux-next
mkdir -p "$WORK_DIR/plan/index.d"
printf 'packets: []\n' > "$WORK_DIR/plan/index.d/20261120t000000z-arm33-yoga.yaml"
git -C "$WORK_DIR" add -A; git -C "$WORK_DIR" commit -q -m "plan(arm33)"; git -C "$WORK_DIR" push -q origin work/1331-aaaa
git -C "$WORK_DIR" checkout -q linux-next
cat > "$GH_PRS" <<JSON
[{"number":31,"headRefName":"work/1331-aaaa","isDraft":false}]
JSON
cat > "$GATE_BIN" <<GATE
#!/usr/bin/env bash
echo "gated" >> "$GATE_LOG"
exit 0
GATE
out33="$(run_queue)"
if grep -q '^land:31 ' <<<"$out33" && grep -q 'lane=plan-only' <<<"$out33" \
    && [ ! -s "$GATE_LOG" ] && [ "$(grep -c . "$GATE_LOG.plan-lane" 2>/dev/null)" = 1 ]; then
    ok "ARM 33: a plan-ledger-only PR lands with zero build-check invocations and one plan-lane check"
else
    bad "ARM 33: wanted landed, lane=plan-only, 0 gates, 1 plan-lane check; got gates=$(grep -c . "$GATE_LOG") plan-lane=$(grep -c . "$GATE_LOG.plan-lane" 2>/dev/null)
$out33"
fi

# ARM 33b: with the lane switched OFF the same PR takes the full gate.
scaffold arm33b
git -C "$WORK_DIR" checkout -q -B work/1332-aaaa origin/linux-next
mkdir -p "$WORK_DIR/plan/index.d"
printf 'packets: []\n' > "$WORK_DIR/plan/index.d/20261120t000000z-arm33b-yoga.yaml"
git -C "$WORK_DIR" add -A; git -C "$WORK_DIR" commit -q -m "plan(arm33b)"; git -C "$WORK_DIR" push -q origin work/1332-aaaa
git -C "$WORK_DIR" checkout -q linux-next
cat > "$GH_PRS" <<JSON
[{"number":32,"headRefName":"work/1332-aaaa","isDraft":false}]
JSON
cat > "$GATE_BIN" <<GATE
#!/usr/bin/env bash
echo "gated" >> "$GATE_LOG"
exit 0
GATE
out33b="$(TILLANDSIAS_LAND_QUEUE_PLAN_ONLY_LANE=0 run_queue)"
if grep -q '^land:32 ' <<<"$out33b" && [ "$(grep -c . "$GATE_LOG")" -eq 1 ]; then
    ok "ARM 33b (control): TILLANDSIAS_LAND_QUEUE_PLAN_ONLY_LANE=0 sends the same PR through the full gate"
else
    bad "ARM 33b: wanted landed on 1 full gate; got gates=$(grep -c . "$GATE_LOG")
$out33b"
fi

# ──────────────────────────────────────────────────────────── ARM 34
# 2118-tpmy THE HOST DOOR: could-not-run:host:<cause> evicts NOBODY and the run
# goes on. The door stub refuses its first call (disk-low), then answers ok:
# #41 is skipped (not gated, not evicted), #42 lands.
scaffold arm34
candidate arm34 1341-aaaa a34.txt A
candidate arm34 1342-aaaa b34.txt B
cat > "$GH_PRS" <<JSON
[{"number":41,"headRefName":"work/1341-aaaa","isDraft":false},
 {"number":42,"headRefName":"work/1342-aaaa","isDraft":false}]
JSON
cat > "$GATE_BIN" <<GATE
#!/usr/bin/env bash
echo "gated" >> "$GATE_LOG"
exit 0
GATE
DOOR_BIN="$TMP/door-arm34.sh"
cat > "$DOOR_BIN" <<DOOR
#!/usr/bin/env bash
echo "asked" >> "$TMP/door-arm34.log"
if [ "\$(grep -c . "$TMP/door-arm34.log")" -eq 1 ]; then
    echo "could-not-run:host:disk-low:3.0G free under target, floor 40G"; exit 3
fi
echo "ok:host-door:disk=900G tmp=6.0G swap-free=90%"
DOOR
out34="$(HOST_DOOR_CMD="bash $DOOR_BIN" run_queue)"
if grep -q '^could-not-run:host:disk-low:.* #41 is not evicted' <<<"$out34" && ! grep -q '^evict' <<<"$out34" \
    && ! grep -q '^land:41 ' <<<"$out34" && grep -q '^land:42 ' <<<"$out34" \
    && [ "$(grep -c . "$GATE_LOG")" -eq 1 ] && ! grep -q 'land-queue:evicted' "$GH_COMMENTS" 2>/dev/null; then
    ok "ARM 34: a host-door refusal is could-not-run:host:<cause>, evicts nobody, and the run continues (#42 lands)"
else
    bad "ARM 34: wanted #41 could-not-run (no eviction, no gate) and #42 landed on 1 gate; got gates=$(grep -c . "$GATE_LOG")
$out34"
fi

# ──────────────────────────────────────────────────────────── ARM 34b
# 2238-gpxz WHERE THE WALL CLOCK GOES: a landed candidate prints one
# timing:land-queue:#N:<stage>=<s>s line per stage, in stage order, and a
# candidate that stopped at the host door prints none past where it stopped.
t34="$(grep -o '^timing:land-queue:#42:[a-z+-]*=[0-9]*s$' <<<"$out34" | sed -E 's/^timing:land-queue:#42:([a-z+-]*)=.*/\1/' | tr '\n' ' ')"
if [ "$t34" = "merge+door plan-refresh preflight gate post-gate+push " ] \
    && ! grep -q '^timing:land-queue:#41:' <<<"$out34"; then
    ok "ARM 34b: a landed candidate times every stage in order; one stopped at the door times none"
else
    bad "ARM 34b: wanted #42 stages 'merge+door plan-refresh preflight gate post-gate+push' and none for #41; got '$t34'
$out34"
fi

# ──────────────────────────────────────────────────────────── ARM 35
# 2118-tpmy RED ON TRUNK TOO: the untouched test is red twice on the candidate
# AND on the bare trunk -> hold:trunk-red:<test>. Nobody is evicted, the queue
# holds (exit 4) and #44 behind it is not gated. A second run at the same trunk
# base reads the memo: no gate is spent on the known trunk red.
scaffold arm35
candidate arm35 1343-aaaa a35.txt A
candidate arm35 1344-aaaa b35.txt B
cat > "$GH_PRS" <<JSON
[{"number":43,"headRefName":"work/1343-aaaa","isDraft":false},
 {"number":44,"headRefName":"work/1344-aaaa","isDraft":false}]
JSON
cat > "$GATE_BIN" <<GATE
#!/usr/bin/env bash
echo "gated" >> "$GATE_LOG"
echo "FAIL scripts/test-other.sh: broken on trunk"; exit 1
GATE
out35="$(run_queue)"; rc35=$?
g35="$(grep -c . "$GATE_LOG")"
if grep -q '^hold:trunk-red:scripts/test-other.sh ' <<<"$out35" && ! grep -q '^evict' <<<"$out35" \
    && ! grep -q '^evicted:' <<<"$out35" && grep -q '^hold:land-queue:' <<<"$out35" \
    && [ "$g35" -eq 3 ] && ! grep -q 'land-queue:evicted' "$GH_COMMENTS" 2>/dev/null; then
    ok "ARM 35: red twice on the candidate AND on trunk is hold:trunk-red:<test>; nobody evicted; #44 not gated (3 gates)"
else
    bad "ARM 35: wanted hold:trunk-red, no eviction, held run, 3 gates; got gates=$g35 rc=$rc35
$out35"
fi
: > "$GATE_LOG"
out35b="$(run_queue)"
g35b="$(grep -c . "$GATE_LOG")"
if grep -q '^hold:trunk-red:scripts/test-other.sh ' <<<"$out35b" && [ "$g35b" -eq 2 ] && ! grep -q '^evict' <<<"$out35b"; then
    ok "ARM 35b: at the same trunk base the trunk red is remembered: no trunk gate is spent again (2 gates)"
else
    bad "ARM 35b: wanted hold from the memo on 2 candidate gates; got gates=$g35b
$out35b"
fi

# ──────────────────────────────────────────────────────────── ARM 40
# ORDER 2152-lqrf (build speed): THE PLAN-BINARY REFRESH IS SKIPPED WHEN ITS
# INPUTS ARE UNCHANGED. The refresh stub writes a dep-info naming base.txt (a
# tracked file) plus a binary, and counts its runs. #40 and #41 do not touch
# base.txt: ONE refresh, the second candidate prints the skip. #42 edits
# base.txt: the refresh runs again. Premise first: the stub's dep-info exists
# and names the dep after the first run.
scaffold arm40
candidate arm40 1040-aaaa a40.txt A
candidate arm40 1041-bbbb b40.txt B
candidate arm40 1042-cccc base.txt changed
cat > "$GH_PRS" <<JSON
[{"number":40,"headRefName":"work/1040-aaaa","isDraft":false},
 {"number":41,"headRefName":"work/1041-bbbb","isDraft":false},
 {"number":42,"headRefName":"work/1042-cccc","isDraft":false}]
JSON
cat > "$GATE_BIN" <<GATE
#!/usr/bin/env bash
echo "gated" >> "$GATE_LOG"
exit 0
GATE
_d40="$TMP/arm40/tgt"; mkdir -p "$_d40"
_r40="$TMP/arm40/refresh.count"; : > "$_r40"
cat > "$TMP/arm40/refresh.sh" <<REFRESH
#!/usr/bin/env bash
echo run >> "$_r40"
printf '%s: %s\n' "$_d40/plan" "$WORK_DIR/base.txt" > "$_d40/plan.d"
echo built >> "$_d40/plan"
REFRESH
out40="$(TILLANDSIAS_LAND_QUEUE_PLAN_DEPINFO="$_d40/plan.d" TILLANDSIAS_LAND_QUEUE_PLAN_REFRESH_STAMP="$_d40/stamp" \
    PLAN_REFRESH_CMD="bash '$TMP/arm40/refresh.sh'" run_queue)"; rc40=$?
n40="$(grep -c . "$_r40")"
if ! grep -q "base.txt" "$_d40/plan.d" 2>/dev/null; then
    bad "ARM 40 premise: the refresh stub never wrote a dep-info naming base.txt
$out40"
elif grep -q '^plan-refresh:skipped:inputs-unchanged:#41:' <<<"$out40" \
    && ! grep -q '^plan-refresh:skipped:inputs-unchanged:#42:' <<<"$out40" \
    && [ "$n40" -eq 2 ] && [ "$rc40" -eq 0 ] && [ "$(grep -c '^land:' <<<"$out40")" -eq 3 ]; then
    ok "ARM 40: the plan refresh runs once for two candidates that leave its inputs alone, and again for one that edits an input (2152-lqrf)"
else
    bad "ARM 40: wanted 2 refreshes (#40, #42), #41 skipped, 3 landed, rc=0; got refreshes=$n40 rc=$rc40
$out40"
fi
# ARM 40b, NEGATIVE CONTROL: no dep-info (the refresh writes none) means no key,
# so EVERY candidate refreshes, as before this change.
scaffold arm40b
candidate arm40b 1043-dddd d40.txt D
candidate arm40b 1044-eeee e40.txt E
cat > "$GH_PRS" <<JSON
[{"number":43,"headRefName":"work/1043-dddd","isDraft":false},
 {"number":44,"headRefName":"work/1044-eeee","isDraft":false}]
JSON
cat > "$GATE_BIN" <<GATE
#!/usr/bin/env bash
exit 0
GATE
_r40b="$TMP/arm40b/refresh.count"; : > "$_r40b"
out40b="$(TILLANDSIAS_LAND_QUEUE_PLAN_DEPINFO="$TMP/arm40b/none.d" TILLANDSIAS_LAND_QUEUE_PLAN_REFRESH_STAMP="$TMP/arm40b/stamp" \
    PLAN_REFRESH_CMD="echo run >> '$_r40b'" run_queue)"
if [ "$(grep -c . "$_r40b")" -eq 2 ] && ! grep -q '^plan-refresh:skipped' <<<"$out40b"; then
    ok "ARM 40b (control): with no dep-info every candidate refreshes"
else
    bad "ARM 40b: wanted 2 refreshes and no skip; got $(grep -c . "$_r40b")
$out40b"
fi

# ──────────────────────────────────────────────────────────── ARM 41
# ORDER 2153-trn1: A BATCH TRAIN GATES THE UNION ONCE AND LANDS ONE COMMIT.
# Three candidates, K=4: exactly ONE gate; the trunk advances by ONE
# first-parent commit whose parents are the old trunk plus the three heads, and
# whose tree holds all three files; every member prints land:; the train log
# records it. Premise first: three distinct heads were pushed.
scaffold arm41
candidate arm41 1051-aaaa a41.txt A
candidate arm41 1052-bbbb b41.txt B
candidate arm41 1053-cccc c41.txt C
cat > "$GH_PRS" <<JSON
[{"number":51,"headRefName":"work/1051-aaaa","isDraft":false},
 {"number":52,"headRefName":"work/1052-bbbb","isDraft":false},
 {"number":53,"headRefName":"work/1053-cccc","isDraft":false}]
JSON
cat > "$GATE_BIN" <<GATE
#!/usr/bin/env bash
echo "gated" >> "$GATE_LOG"
exit 0
GATE
_b41="$(git -C "$REMOTE_DIR" rev-parse linux-next)"
_t41="$TMP/arm41/trains.log"
if [ "$(git -C "$REMOTE_DIR" for-each-ref --format='%(objectname)' 'refs/heads/work/*' | sort -u | grep -c .)" -ne 3 ]; then
    bad "ARM 41 premise: three distinct work heads were not pushed"
else
    # HEAVY_MAX=4: the scratch tree's empty fixture population probes every member heavy.
    out41="$(ARM_BATCH_K=4 ARM_HEAVY_MAX=4 ARM_TRAIN_LOG="$_t41" run_queue)"; rc41=$?
    _h41="$(git -C "$REMOTE_DIR" rev-parse linux-next)"
    _np41="$(git -C "$REMOTE_DIR" rev-list --parents -n 1 "$_h41" | wc -w)"
    _fp41="$(git -C "$REMOTE_DIR" rev-list --first-parent --count "$_b41..$_h41")"
    _files41="$(git -C "$REMOTE_DIR" ls-tree --name-only "$_h41" | grep -c '^[abc]41\.txt$')"
    if [ "$rc41" -eq 0 ] && [ "$(grep -c . "$GATE_LOG")" -eq 1 ] && [ "$_np41" -eq 5 ] && [ "$_fp41" -eq 1 ] \
        && [ "$_files41" -eq 3 ] && [ "$(grep -c '^land:5[123] .*train=' <<<"$out41")" -eq 3 ] \
        && grep -q 'result=landed:' "$_t41" 2>/dev/null; then
        ok "ARM 41: a train of 3 gates the union ONCE and lands ONE first-parent commit with 4 parents carrying all three trees (2153-trn1)"
    else
        bad "ARM 41: wanted rc=0, 1 gate, 1 first-parent commit with 4 parents (5 words), 3 files, 3 land: lines, a landed train-log line; got rc=$rc41 gates=$(grep -c . "$GATE_LOG") words=$_np41 fp=$_fp41 files=$_files41
$out41"
    fi
fi
# ARM 41b: a RED train evicts nobody; the members go one at a time and land.
scaffold arm41b
candidate arm41b 1054-dddd d41.txt D
candidate arm41b 1055-eeee e41.txt E
cat > "$GH_PRS" <<JSON
[{"number":54,"headRefName":"work/1054-dddd","isDraft":false},
 {"number":55,"headRefName":"work/1055-eeee","isDraft":false}]
JSON
_m41b="$TMP/arm41b/red-once"
cat > "$GATE_BIN" <<GATE
#!/usr/bin/env bash
echo "gated" >> "$GATE_LOG"
if [ ! -e "$_m41b" ]; then : > "$_m41b"; echo "FAIL: scripts/test-flaky-train.sh"; exit 1; fi
exit 0
GATE
_t41b="$TMP/arm41b/trains.log"
out41b="$(ARM_BATCH_K=4 ARM_TRAIN_LOG="$_t41b" run_queue)"
if grep -q '^train:red:' <<<"$out41b" && ! grep -q '^evict' <<<"$out41b" \
    && [ "$(grep -c '^land:5[45] ' <<<"$out41b")" -eq 2 ] && ! grep -q 'train=' <<<"$(grep '^land:' <<<"$out41b")" \
    && [ "$(grep -c . "$GATE_LOG")" -eq 3 ] && grep -q 'result=red:' "$_t41b" 2>/dev/null; then
    ok "ARM 41b: a red train evicts nobody; its members land one at a time (1 train gate + 2 member gates)"
else
    bad "ARM 41b: wanted train:red, no evict, #54 and #55 landed singly, 3 gates, a red train-log line; got gates=$(grep -c . "$GATE_LOG")
$out41b"
fi
# ARM 41c, NEGATIVE CONTROL: K unset (the default) runs no train at all.
scaffold arm41c
candidate arm41c 1056-ffff f41.txt F
candidate arm41c 1057-gggg g41.txt G
cat > "$GH_PRS" <<JSON
[{"number":56,"headRefName":"work/1056-ffff","isDraft":false},
 {"number":57,"headRefName":"work/1057-gggg","isDraft":false}]
JSON
cat > "$GATE_BIN" <<GATE
#!/usr/bin/env bash
echo "gated" >> "$GATE_LOG"
exit 0
GATE
out41c="$(run_queue)"
if ! grep -q '^train' <<<"$out41c" && [ "$(grep -c . "$GATE_LOG")" -eq 2 ] && [ "$(grep -c '^land:5[67] ' <<<"$out41c")" -eq 2 ]; then
    ok "ARM 41c (control): with BATCH_K unset there is no train; one gate per candidate"
else
    bad "ARM 41c: wanted no train, 2 gates, 2 landed; got gates=$(grep -c . "$GATE_LOG")
$out41c"
fi

# ──────────────────────────────────────────────────────────── ARM 50
# ORDER 2174-dail (operator 2026-11-22: small gates piggyback on a daily run).
# The gate stub records the selector env the queue hands it, and plays a gate
# whose class selector skipped one step when (and only when) a proof is given.
dail_gate() { # writes $GATE_BIN: records env, emits a skip line under a proof
    cat > "$GATE_BIN" <<GATE
#!/usr/bin/env bash
echo "gated" >> "$GATE_LOG"
printf 'base=%s marker=%s\n' "\${TILLANDSIAS_CLASS_BASE:-none}" "\$(cat "\${TILLANDSIAS_FULL_GATE_MARKER:-/nonexistent}" 2>/dev/null || echo absent)" >> "$GATE_LOG.env"
[ -n "\${TILLANDSIAS_CLASS_BASE:-}" ] && echo "skip:class-selector:gate-step:999-zzzz — declared-inputs=path:x.txt"
exit 0
GATE
}
# 50a FRESH GREEN PROOF: the gate gets the proved commit and its epoch; the
# land's not-run: line names the skipped step.
scaffold arm50a
candidate arm50a 1060-aaaa a50.txt A
cat > "$GH_PRS" <<JSON
[{"number":60,"headRefName":"work/1060-aaaa","isDraft":false}]
JSON
dail_gate
_p50="$(git -C "$REMOTE_DIR" rev-parse linux-next)"; _e50="$(date -u +%s)"
git -C "$REMOTE_DIR" update-ref "refs/attest/daily-full/$_e50" "$_p50"
out50a="$(run_queue)"
if grep -q "^base=$_p50 marker=$_e50$" "$GATE_LOG.env" 2>/dev/null \
    && grep -q '^land:60 ' <<<"$out50a" && grep -q 'not-run: gate-step:999-zzzz .*daily proof' <<<"$out50a"; then
    ok "ARM 50a: a fresh green daily proof reaches the gate (class base + epoch) and the land names the skipped step (2174-dail)"
else
    bad "ARM 50a: wanted base=$_p50 marker=$_e50 and a not-run line naming 999-zzzz; env=$(cat "$GATE_LOG.env" 2>/dev/null)
$out50a"
fi
# 50b STALE PROOF (> 24 h): no class base, no marker; the land runs full.
scaffold arm50b
candidate arm50b 1061-bbbb b50.txt B
cat > "$GH_PRS" <<JSON
[{"number":61,"headRefName":"work/1061-bbbb","isDraft":false}]
JSON
dail_gate
git -C "$REMOTE_DIR" update-ref "refs/attest/daily-full/$(( $(date -u +%s) - 90000 ))" "$(git -C "$REMOTE_DIR" rev-parse linux-next)"
out50b="$(run_queue)"
if grep -q '^base=none marker=absent$' "$GATE_LOG.env" 2>/dev/null && grep -q 'not-run: nothing .*daily-run-stale' <<<"$out50b"; then
    ok "ARM 50b: a daily proof older than 24 h freezes the land back to full (no class base, no marker)"
else
    bad "ARM 50b: wanted base=none marker=absent and not-run nothing (daily-run-stale); env=$(cat "$GATE_LOG.env" 2>/dev/null)
$out50b"
fi
# 50c RED NEWER THAN GREEN: full, naming the red.
scaffold arm50c
candidate arm50c 1062-cccc c50.txt C
cat > "$GH_PRS" <<JSON
[{"number":62,"headRefName":"work/1062-cccc","isDraft":false}]
JSON
dail_gate
_t50c="$(git -C "$REMOTE_DIR" rev-parse linux-next)"; _e50c="$(date -u +%s)"
git -C "$REMOTE_DIR" update-ref "refs/attest/daily-full/$((_e50c - 60))" "$_t50c"
git -C "$REMOTE_DIR" update-ref "refs/attest/daily-red/$_e50c" "$_t50c"
out50c="$(run_queue)"
if grep -q '^base=none marker=absent$' "$GATE_LOG.env" 2>/dev/null && grep -q 'not-run: nothing .*daily-run-red' <<<"$out50c"; then
    ok "ARM 50c: a red daily run newer than the last green freezes lands back to full"
else
    bad "ARM 50c: wanted a full land naming daily-run-red; env=$(cat "$GATE_LOG.env" 2>/dev/null)
$out50c"
fi
# 50d --daily-full publishes the proof: green -> daily-full ref, red -> daily-red.
scaffold arm50d
cat > "$GH_PRS" <<JSON
[]
JSON
cat > "$GATE_BIN" <<GATE
#!/usr/bin/env bash
echo "\${TILLANDSIAS_CLASS_SELECTOR:-on}" >> "$GATE_LOG"
exit 0
GATE
out50d="$(run_queue --daily-full)"; rc50d=$?
_t50d="$(git -C "$REMOTE_DIR" rev-parse linux-next)"
_g50d="$(git -C "$REMOTE_DIR" for-each-ref --format='%(objectname)' refs/attest/daily-full/)"
cat > "$GATE_BIN" <<GATE
#!/usr/bin/env bash
exit 1
GATE
out50e="$(run_queue --daily-full)"; rc50e=$?
_r50d="$(git -C "$REMOTE_DIR" for-each-ref --format='%(objectname)' refs/attest/daily-red/)"
if [ "$rc50d" -eq 0 ] && [ "$_g50d" = "$_t50d" ] && grep -qx off "$GATE_LOG" && [ "$rc50e" -eq 1 ] && [ "$_r50d" = "$_t50d" ] \
    && grep -q '^ok:land-queue:daily-full:' <<<"$out50d" && grep -q '^red:land-queue:daily-full:' <<<"$out50e"; then
    ok "ARM 50d: --daily-full gates the trunk tip with the selector OFF and publishes daily-full (green) or daily-red (red)"
else
    bad "ARM 50d: wanted rc 0 + daily-full ref at the trunk tip (selector off), then rc 1 + daily-red; got rc=$rc50d/$rc50e green='$_g50d' red='$_r50d' tip=$_t50d
$out50d
$out50e"
fi
# ARM 52 (coordinator 2026-11-22): A GATE NEVER SEES THE QUEUE'S KNOBS. run_queue
# hands the queue a dozen TILLANDSIAS_LAND_QUEUE_* settings, and the host may
# export more (BATCH_K=4 redded run 26's train through this very fixture). The
# gate stub records every such name it can see: there must be none. PREMISE:
# the queue itself really was given them (BATCH_K exported here too).
scaffold arm52
candidate arm52 1070-aaaa a52.txt A
cat > "$GH_PRS" <<JSON
[{"number":70,"headRefName":"work/1070-aaaa","isDraft":false}]
JSON
cat > "$GATE_BIN" <<GATE
#!/usr/bin/env bash
echo "gated" >> "$GATE_LOG"
compgen -v TILLANDSIAS_LAND_QUEUE_ >> "$GATE_LOG.knobs" 2>/dev/null
: >> "$GATE_LOG.knobs"
exit 0
GATE
out52="$(TILLANDSIAS_LAND_QUEUE_BATCH_K=4 run_queue)"
if [ "$(grep -c . "$GATE_LOG")" -eq 1 ] && [ ! -s "$GATE_LOG.knobs" ] && grep -q '^land:70 ' <<<"$out52"; then
    ok "ARM 52: the gate inherits no TILLANDSIAS_LAND_QUEUE_* knob, even with BATCH_K exported by the host (2174-dail)"
else
    bad "ARM 52: wanted 1 gate, no queue knobs visible to it, #70 landed; gates=$(grep -c . "$GATE_LOG") knobs=$(tr '\n' ' ' < "$GATE_LOG.knobs" 2>/dev/null)
$out52"
fi

# ARM 51: THE REAL SELECTOR against a proof (scripts/change-class.sh may-skip,
# its own repo). A step whose declared input changed since the proved commit is
# NOT skipped; a docs-only change is; a stale proof runs everything.
_c51="$TMP/arm51"; mkdir -p "$_c51/scripts"
cp "$ROOT/scripts/change-class.sh" "$ROOT/scripts/gate-stamp.sh" "$_c51/scripts/"
git -C "$_c51" init -q; git -C "$_c51" config user.email t@l; git -C "$_c51" config user.name t
echo a > "$_c51/x.txt"; echo r > "$_c51/README.md"
git -C "$_c51" add -A; git -C "$_c51" commit -qm proved
_b51="$(git -C "$_c51" rev-parse HEAD)"; date -u +%s > "$_c51.marker"
# The selector knobs are the CALLER's: --daily-full gates with TILLANDSIAS_CLASS_SELECTOR=off
# exported, and the arm inherited it (run/run/run on macuahuitl 2026-11-22). Unset them all.
ms51() { ( cd "$_c51" && unset TILLANDSIAS_CLASS_SELECTOR TILLANDSIAS_TRUNK_BRANCH TILLANDSIAS_CHANGE_CLASS_REMOTE TILLANDSIAS_FULL_GATE_MAX_AGE_S && TILLANDSIAS_CLASS_BASE="$_b51" TILLANDSIAS_FULL_GATE_MARKER="$_c51.marker" bash scripts/change-class.sh may-skip gate-step:t path:x.txt 2>/dev/null ); }
echo b >> "$_c51/x.txt"; git -C "$_c51" commit -qam x; v51a="$(ms51)"
git -C "$_c51" reset -q --hard "$_b51"; echo more >> "$_c51/README.md"; git -C "$_c51" commit -qam doc; v51b="$(ms51)"
echo 1 > "$_c51.marker"; v51c="$(ms51)"
if [ "$v51a" = run ] && [ "$v51b" = skip ] && [ "$v51c" = run ]; then
    ok "ARM 51: against a proof, a changed declared input RUNS, a docs-only change SKIPS, a stale proof RUNS (real change-class.sh)"
else
    bad "ARM 51: wanted run/skip/run; got '$v51a'/'$v51b'/'$v51c'"
fi


# ARM 53 (2209-dfix): the publish goes through the REAL pre-push hook. The first
# live --daily-full on macuahuitl (2026-11-22) gated green-or-red and then could
# not publish: the hook refused refs/attest/daily-red/<epoch> as a new ref needing
# a full gate. A daily verdict ref is exempt; a non-epoch name under the same
# namespace and an ordinary branch are not (premise: this repo has no gate stamp,
# so anything not exempt is refused).
_c53="$TMP/arm53"; mkdir -p "$_c53/w/scripts/hooks"
git init -q --bare "$_c53/r.git"
cp "$ROOT/scripts/hooks/pre-push-local-gate.sh" "$_c53/w/scripts/hooks/"; cp "$ROOT/scripts/gate-stamp.sh" "$_c53/w/scripts/"
git -C "$_c53/w" init -q; git -C "$_c53/w" config user.email t@l; git -C "$_c53/w" config user.name t
git -C "$_c53/w" add -A; git -C "$_c53/w" commit -qm base
git -C "$_c53/w" push -q "$_c53/r.git" HEAD:refs/heads/linux-next 2>/dev/null
printf '#!/bin/sh\nexec bash scripts/hooks/pre-push-local-gate.sh "$@"\n' > "$_c53/w/.git/hooks/pre-push"; chmod +x "$_c53/w/.git/hooks/pre-push"
p53() { ( cd "$_c53/w" && git push -q "$_c53/r.git" "HEAD:$1" < /dev/null > /dev/null 2>&1 ); echo $?; }
v53a="$(p53 refs/attest/daily-full/1795348746)"; v53b="$(p53 refs/attest/daily-red/1795348747)"
v53c="$(p53 refs/attest/daily-red/not-an-epoch)"; v53d="$(p53 refs/heads/not-exempt)"
if [ "$v53d" != 0 ] && [ "$v53c" != 0 ] && [ "$v53a" = 0 ] && [ "$v53b" = 0 ]; then
    ok "ARM 53: the real pre-push hook lets daily-full/daily-red <epoch> refs through and still refuses a non-epoch attest name and a branch (2209-dfix)"
else
    bad "ARM 53: wanted push rc 0/0/refused/refused (daily-full, daily-red, non-epoch, branch); got $v53a/$v53b/$v53c/$v53d"
fi

# ARM 54 (2209-dfix): a held lock is SAID. The 03:42 timer --daily-full died with
# no output while run 28 held the lock. With a live holder, --daily-full waits
# (bounded) and then names the holder; a plain run names it too; no gate runs.
sleep 300 & _h54=$!
_l54="$(cd "$WORK_DIR" && git rev-parse --show-toplevel)/.git/tillandsias-land-queue.lock"
mkdir -p "$_l54"; echo "$_h54" > "$_l54/pid"; : > "$GATE_LOG"
out54a="$(TILLANDSIAS_LAND_QUEUE_DAILY_LOCK_WAIT_S=0 run_queue --daily-full)"; rc54a=$?
out54b="$(run_queue)"; rc54b=$?
kill "$_h54" 2>/dev/null; wait "$_h54" 2>/dev/null; rm -rf "$_l54"
if [ "$rc54a" = 3 ] && [ "$rc54b" = 3 ] && grep -q "^land-queue:daily-full:waiting-for-lock:$_h54 " <<<"$out54a" \
    && grep -q "^skip:land-queue:daily-full:lock-held:$_h54 " <<<"$out54a" && grep -q "^skip:land-queue:in-flight:$_h54 " <<<"$out54b" \
    && [ ! -s "$GATE_LOG" ]; then
    ok "ARM 54: a live lock holder is named by --daily-full (after its bounded wait) and by a plain run; neither gates (2209-dfix)"
else
    bad "ARM 54: wanted rc 3/3 naming holder $_h54 and no gate; got rc=$rc54a/$rc54b gates=$(grep -c . "$GATE_LOG")
$out54a
$out54b"
fi

# ARM 55 (2215-trad): a train survives a PLAN-ONLY move of the trunk mid-gate.
# Run 29 (macuahuitl 2026-11-22) gated a 4-member train ~25 min, then pushed
# nothing: plan fragments had moved linux-next. The gate here moves the trunk
# ONCE, from a side clone: 55 by a plan/index.d fragment (adopt, one gate, the
# train lands on the new tip); 55b by a code file (no adopt, members go singly).
arm55() { # <name> <moved path> <out var>
    scaffold "$1"
    candidate "$1" 1061-aaaa a55.txt A
    candidate "$1" 1062-bbbb b55.txt B
    cat > "$GH_PRS" <<JSON
[{"number":61,"headRefName":"work/1061-aaaa","isDraft":false},
 {"number":62,"headRefName":"work/1062-bbbb","isDraft":false}]
JSON
    _side="$TMP/$1/side"; _once="$TMP/$1/moved"
    git clone -q "$REMOTE_DIR" "$_side"; git -C "$_side" config user.email t@l; git -C "$_side" config user.name t
    cat > "$GATE_BIN" <<GATE
#!/usr/bin/env bash
echo "gated" >> "$GATE_LOG"
if [ ! -e "$_once" ]; then
    : > "$_once"; mkdir -p "$_side/\$(dirname "$2")"; echo moved > "$_side/$2"
    git -C "$_side" add -A && git -C "$_side" commit -qm move && git -C "$_side" push -q origin HEAD:linux-next
fi
exit 0
GATE
    _moved55="$(git -C "$_side" rev-parse HEAD)"
    printf -v "$3" '%s' "$(ARM_BATCH_K=4 ARM_TRAIN_LOG="$TMP/$1/trains.log" run_queue)"
}
arm55 arm55 plan/index.d/20261122t000000z-arm55.yaml out55
_h55="$(git -C "$REMOTE_DIR" rev-parse linux-next)"; _mv55="$(git -C "$TMP/arm55/side" rev-parse HEAD)"
if grep -q '^train:adopt:plan-only-move:' <<<"$out55" && [ "$(grep -c '^land:6[12] .*train=' <<<"$out55")" -eq 2 ] \
    && [ "$(grep -c . "$GATE_LOG")" -eq 1 ] && git -C "$REMOTE_DIR" merge-base --is-ancestor "$_mv55" "$_h55" \
    && [ "$(git -C "$REMOTE_DIR" ls-tree --name-only "$_h55" | grep -c '^[ab]55\.txt$')" -eq 2 ]; then
    ok "ARM 55: a train whose trunk moved by plan fragments only is adopted onto the new tip and lands on its one gate (2215-trad)"
else
    bad "ARM 55: wanted train:adopt, #61/#62 landed by the train, 1 gate, the fragment commit kept; got gates=$(grep -c . "$GATE_LOG")
$out55"
fi
arm55 arm55b src55.rs out55b
if grep -q '^train:target-moved:' <<<"$out55b" && ! grep -q '^train:adopt' <<<"$out55b" && ! grep -q 'train=' <<<"$(grep '^land:' <<<"$out55b")"; then
    ok "ARM 55b: a code move mid-gate is not adopted; the train pushes nothing and its members go one at a time"
else
    bad "ARM 55b: wanted train:target-moved, no adopt, no train= land; got
$out55b"
fi

# ARM 56 (2248-jihs): `--status` answers without the lock. (a) no holder: the
# idle line naming the newest land; (b) a live holder: the running phase from
# the run dir's `current`, with elapsed rendered; neither gates nor locks; (c) a
# real run published its last word to refs/tillandsias/queue/status.
: > "$GATE_LOG"
out56a="$(run_queue --status)"; rc56a=$?
sleep 300 & _h56=$!
_l56="$(cd "$WORK_DIR" && git rev-parse --show-toplevel)/.git/tillandsias-land-queue.lock"
mkdir -p "$_l56" "$TMP/lq56/run1"; echo "$_h56" > "$_l56/pid"
echo "$TMP/lq56/run1" > "$TMP/lq56/current-run"
echo "queue:gating:#7 work/0001-abcd phase=gate started=$(( $(date +%s) - 5 )) train=- waiting=2" > "$TMP/lq56/run1/current"
out56b="$(LOGDIR_OVERRIDE="$TMP/lq56" run_queue --status)"; rc56b=$?
kill "$_h56" 2>/dev/null; wait "$_h56" 2>/dev/null
_lock56=$([ -d "$_l56" ] && echo held); rm -rf "$_l56"
pub56="$(git -C "$REMOTE_DIR" log -1 --format=%s refs/tillandsias/queue/status 2>/dev/null)"
if [ "$rc56a" = 0 ] && grep -Eq '^queue:idle last-land=[0-9a-f]{40} [0-9]+s$' <<<"$out56a" \
    && [ "$rc56b" = 0 ] && grep -Eq '^queue:gating:#7 work/0001-abcd phase=gate elapsed=[5-9] train=- waiting=2$' <<<"$out56b" \
    && [ "$_lock56" = held ] && [ ! -s "$GATE_LOG" ] && grep -q '^queue:idle last-land=' <<<"$pub56"; then
    ok "ARM 56: --status says idle/last-land or the live phase with elapsed, takes no lock, gates nothing; a run publishes refs/tillandsias/queue/status (2248-jihs)"
else
    bad "ARM 56: got rc=$rc56a/$rc56b lock=$_lock56 gates=$(grep -c . "$GATE_LOG") published='$pub56'
$out56a
$out56b"
fi
# ARM 57 (bundle landing phase 1): every train writes ONE bundles.log line beside
# trains.log, and heavy= counts members by gate-changed's own answer. (a) landed:
# one of two members probed heavy; (b) a red train, promoted=-; (c) a gate rc=137
# is the host's, aborted and never red; (d) a probe that does not answer reads `-`,
# never 0; (e) the REAL default probe answers in the scratch tree (its empty
# fixture population is heavy by gate-changed's rule, so 2).
_p57="$TMP/heavy57.sh"
cat > "$_p57" <<'PROBE'
if grep -q heavy <<<"$(git diff --name-only "$1")"; then echo "heavy:guard:x"; else echo "select:intake fixtures=1/9"; fi
PROBE
arm57() { # <name> <gate rc on the first gate> <probe> <out var for the line(s)>
    scaffold "$1"
    candidate "$1" 1071-aaaa light57.txt A
    candidate "$1" 1072-bbbb heavy57.txt B
    cat > "$GH_PRS" <<JSON
[{"number":71,"headRefName":"work/1071-aaaa","isDraft":false},
 {"number":72,"headRefName":"work/1072-bbbb","isDraft":false}]
JSON
    printf '#!/usr/bin/env bash\n[ -e "%s" ] && exit 0\n: > "%s"\nexit %s\n' "$TMP/$1/once" "$TMP/$1/once" "$2" > "$GATE_BIN"
    out57="$out57
$(ARM_BATCH_K=4 ARM_HEAVY_PROBE="$3" ARM_TRAIN_LOG="$TMP/$1/trains.log" run_queue)"
    printf -v "$4" '%s' "$(cat "$TMP/$1/bundles.log" 2>&1)"
}
out57=""
arm57 arm57a 0 "bash $_p57" l57a; _h57="$(git -C "$REMOTE_DIR" rev-parse linux-next)"
_t57="$(git -C "$REMOTE_DIR" rev-parse "linux-next^{tree}")"
arm57 arm57b 1 "bash $_p57" l57b
arm57 arm57c 137 "bash $_p57" l57c
arm57 arm57d 0 "false" l57d
arm57 arm57e 0 "" l57e
_ok57=1
grep -Eq "^bundle:green:train-[0-9]+ members=2 heavy=1 base=[0-9a-f]{9} tree=${_t57:0:9} gate_s=[0-9]+ reason=train promoted=${_h57:0:9} cause=landed:${_h57:0:9} ids=#71,#72 ts=[0-9TZ:-]+$" <<<"$l57a" || _ok57="a"
grep -Eq '^bundle:red:train-[0-9]+ members=2 heavy=1 .* promoted=- cause=red:rc=1:unjudged:no-step-named ' <<<"$l57b" || _ok57="$_ok57 b"
grep -Eq '^bundle:aborted:train-[0-9]+ .* promoted=- cause=red:rc=137 ' <<<"$l57c" || _ok57="$_ok57 c"
grep -Eq '^bundle:green:train-[0-9]+ members=2 heavy=- ' <<<"$l57d" || _ok57="$_ok57 d"
grep -Eq '^bundle:green:train-[0-9]+ members=2 heavy=2 ' <<<"$l57e" || _ok57="$_ok57 e"
[ "$(grep -c . <<<"$l57a$l57b$l57c$l57d$l57e")" -ge 1 ] && for _l in "$l57a" "$l57b" "$l57c" "$l57d" "$l57e"; do
    [ "$(grep -c . <<<"$_l")" -eq 1 ] || _ok57="$_ok57 not-one-line"
done
if [ "$_ok57" = 1 ]; then
    ok "ARM 57: one bundles.log line per train (green/red/aborted) with members, heavy, base, tree, gate seconds, promoted; an unanswered heavy probe reads '-'"
else
    bad "ARM 57: failed: $_ok57
a=$l57a
b=$l57b
c=$l57c
d=$l57d
e=$l57e
$out57"
fi
# ARM 58 (2281-xx62): TILLANDSIAS_BUNDLE_HEAVY_MAX caps a train's non-light members.
# Queue order heavy, heavy, light. (a) max=1: the second heavy is put back and the
# light one behind it still joins, so the train is #71,#73 and #72 lands alone;
# (b) max=2: all three ride; (c) an unanswered probe counts toward the cap, so
# max=1 leaves one member, which is no train; (d) max=0 takes no heavy member;
# (e) an unreadable max is said aloud and read as 2.
arm58() { # <name> <max> <probe> -> o58 (queue output), l58 (bundle lines)
    scaffold "$1"
    candidate "$1" 1081-aaaa heavy58a.txt A
    candidate "$1" 1082-bbbb heavy58b.txt B
    candidate "$1" 1083-cccc light58.txt C
    cat > "$GH_PRS" <<JSON
[{"number":71,"headRefName":"work/1081-aaaa","isDraft":false},
 {"number":72,"headRefName":"work/1082-bbbb","isDraft":false},
 {"number":73,"headRefName":"work/1083-cccc","isDraft":false}]
JSON
    printf '#!/usr/bin/env bash\nexit 0\n' > "$GATE_BIN"
    o58="$(ARM_BATCH_K=4 ARM_HEAVY_MAX="$2" ARM_HEAVY_PROBE="$3" ARM_TRAIN_LOG="$TMP/$1/trains.log" run_queue)"
    l58="$(cat "$TMP/$1/bundles.log" 2>/dev/null)"
    _n58="$(grep -cE '^land:7[123] .*gate=green' <<<"$o58")"
}
_ok58=1
arm58 arm58a 1 "bash $_p57"; _d58="$o58"
{ grep -q 'members=2 heavy=1 .* ids=#71,#73 ' <<<"$l58" && grep -q 'train:accept:#71 tier=heavy' <<<"$o58" \
  && grep -q 'train:accept:#73 tier=light' <<<"$o58" && grep -q 'train:heavy-deferred:#72 tier=heavy max=1' <<<"$o58" \
  && [ "$_n58" -eq 3 ]; } || _ok58="$_ok58 a"
arm58 arm58b 2 "bash $_p57"; _d58="$_d58
$o58"
{ grep -q 'members=3 heavy=2 .* ids=#71,#72,#73 ' <<<"$l58" && [ "$_n58" -eq 3 ]; } || _ok58="$_ok58 b"
arm58 arm58c 1 false; _d58="$_d58
$o58"
{ [ -z "$l58" ] && grep -q 'train:heavy-deferred:#72 tier=unknown max=1' <<<"$o58" && [ "$_n58" -eq 3 ]; } || _ok58="$_ok58 c"
arm58 arm58d 0 "bash $_p57"; _d58="$_d58
$o58"
{ [ -z "$l58" ] && grep -q 'train:heavy-deferred:#71 tier=heavy max=0' <<<"$o58" && [ "$_n58" -eq 3 ]; } || _ok58="$_ok58 d"
arm58 arm58e two "bash $_p57"; _d58="$_d58
$o58"
{ grep -q "train:heavy-max-unreadable:'two'" <<<"$o58" && grep -q 'members=3 heavy=2 ' <<<"$l58"; } || _ok58="$_ok58 e"
if [ "$_ok58" = 1 ]; then
    ok "ARM 58: HEAVY_MAX caps a train's heavy and unmeasured members; the rest go one at a time"
else
    bad "ARM 58: failed: $_ok58
$_d58"
fi
# ARM 60 (bundle landing phase 0): SHADOW INTAKE records intake's verdict beside the
# gate's and changes nothing. One run, three candidates: #81 gate green + intake ok,
# #82 gate red + intake red, #83 gate green + heavy (rc 10). (b) the stub writes into
# its own tree and the queue's checkout stays clean; every shadow ran after the last
# gate. (c) OFF by default: no log. (d) a train's members log via=train. (e) the run
# bound names what it drops; (f) a per-PR timeout is timeout, never red. (g) a red
# intake on a green gate (a false red) keeps its log. (h) --status names the log.
_sh60="$TMP/shadow60.sh"
cat > "$_sh60" <<'SH'
[ -e dirt-from-shadow ] && dirty=dirty || dirty=clean
echo "shadow gates=$(grep -c . "@GATES@") nice=$(nice) $dirty shared=${TILLANDSIAS_SHARED_TARGET:-on}" >> "@SEEN@"
echo dirt > dirt-from-shadow; echo dirt >> seed-dirt
if [ -e c83.txt ]; then echo "heavy:guard:x fixtures=9 crates=28 changed=1"; exit 10; fi
if [ -e c82.txt ]; then echo "select:intake fixtures=6/9 deferred=1 crates=0/28 changed=1 base=x"; exit 1; fi
if [ -e c84.txt ]; then : > "@LOCK@/stop"; exit 0; fi
if [ -e c81.txt ]; then echo "select:intake fixtures=5/9 deferred=1 crates=2/28 changed=1 base=x"; exit 0; fi
if [ -e slow.txt ]; then sleep 30; fi
exit 1
SH
arm60() { # <name> <K> <files...> ; env SH60_* pass through
    local n="$1" k="$2" i=81 f js="" ; shift 2
    scaffold "$n"
    for f in "$@"; do candidate "$n" "10$i-aaaa" "$f" A; js="$js${js:+,}{\"number\":$i,\"headRefName\":\"work/10$i-aaaa\",\"isDraft\":false}"; i=$((i + 1)); done
    printf '[%s]\n' "$js" > "$GH_PRS"
    printf '#!/usr/bin/env bash\necho gated >> "%s"\n[ -e c82.txt ] && exit 1\nexit 0\n' "$GATE_LOG" > "$GATE_BIN"
    : > "$TMP/$n/seen"
    sed -e "s#@GATES@#$GATE_LOG#; s#@SEEN@#$TMP/$n/seen#; s#@LOCK@#$TMP/$n/lock#" "$_sh60" > "$TMP/$n/stub.sh"
    out60="$(ARM_BATCH_K="$k" ARM_SHADOW="${SH60_CMD-bash $TMP/$n/stub.sh}" ARM_SHADOW_LOCK="$TMP/$n/lock" ARM_SHADOW_TREE="$TMP/$n/shtree" \
        ARM_SHADOW_LOG="$TMP/$n/shadow.log" ARM_SHADOW_PR_S="${SH60_PR_S:-60}" ARM_SHADOW_RUN_S="${SH60_RUN_S:-60}" LOGDIR_OVERRIDE="$TMP/$n/logs" run_queue)"
    [ -d "$WORK_DIR/.git/tillandsias-land-queue.lock" ] && _b60="$_b60 $n-land-lock-held"
    [ -n "${SH60_J:-}" ] || for _w in $(seq 1 600); do [ "$(grep -cE '^(shadow:accept|unmeasured):' "$TMP/$n/shadow.log" 2>/dev/null || [ -e "$TMP/$n/shadow.log" ] || echo 0)" -ge "${SH60_LINES:-1}" ] && [ ! -d "$TMP/$n/lock" ] && break; sleep 0.1; done
    l60="$(cat "$TMP/$n/shadow.log" 2>/dev/null)"
}
_b60=""
SH60_LINES=3 arm60 arm60a 1 c81.txt c82.txt c83.txt
grep -Eq '^shadow:accept:81 tier=intake selected=5/9 crates=2 intake_s=[0-9]+ intake=ok gate=green via=single base=[0-9a-f]{9} head=[0-9a-f]{9} rc=0 ts=' <<<"$l60" || _b60="$_b60 a81"
grep -Eq '^shadow:accept:82 tier=intake selected=6/9 crates=0 .* intake=red gate=red ' <<<"$l60" || _b60="$_b60 a82"
grep -Eq '^shadow:accept:83 tier=heavy selected=-/9 crates=- .* intake=- gate=green ' <<<"$l60" || _b60="$_b60 a83"
[ "$(grep -c "^shadow:accept:" <<<"$l60")" -eq 3 ] && grep -Eq "^shadow:tree $TMP/arm60a/shtree size_mb=[0-9]+$" <<<"$l60" && grep -q '^land:81 ' <<<"$out60" && grep -q '^land:83 ' <<<"$out60" && grep -q '^evict:land-queue:82' <<<"$out60" || _b60="$_b60 a-landing"
[ "$(grep -c 'gates=3 nice=10 clean shared=off$' "$TMP/arm60a/seen")" -eq 3 ] || _b60="$_b60 b-order"
[ -z "$(git -C "$WORK_DIR" status --porcelain --untracked-files=no)" ] && [ ! -e "$WORK_DIR/dirt-from-shadow" ] && [ ! -e "$WORK_DIR/target/shadow-intake" ] && [ -e "$TMP/arm60a/shtree/.git" ] || _b60="$_b60 b-isolation"
st60="$(ARM_SHADOW=x ARM_SHADOW_LOG="$TMP/arm60a/shadow.log" run_queue --status)"
grep -Eq "^queue:shadow (idle|running) pr=[-#0-9]+ log=$TMP/arm60a/shadow.log lines=3$" <<<"$st60" || _b60="$_b60 h-status"
SH60_CMD="" SH60_LINES=0 arm60 arm60c 1 c81.txt
[ ! -e "$TMP/arm60c/shadow.log" ] && [ ! -s "$TMP/arm60c/seen" ] && grep -q '^land:81 ' <<<"$out60" && ! grep -q shadow <<<"$out60" || _b60="$_b60 c-off"
SH60_LINES=2 arm60 arm60d 4 c81.txt c83.txt
[ "$(grep -c 'gate=green via=train' <<<"$l60")" -eq 2 ] && [ "$(grep -c . "$GATE_LOG")" -eq 1 ] || _b60="$_b60 d-train"
SH60_RUN_S=0 arm60 arm60e 1 c81.txt
grep -q '^unmeasured:shadow:81:run-bound gate=green' <<<"$l60" && grep -q '^land:81 ' <<<"$out60" || _b60="$_b60 e-bound"
SH60_PR_S=1 arm60 arm60f 1 slow.txt
grep -q 'intake=timeout gate=green .* rc=124 ' <<<"$l60" || _b60="$_b60 f-timeout"
arm60 arm60g 1 other.txt
grep -q 'intake=red gate=green ' <<<"$l60" && ls "$TMP/arm60g/logs"/*/shadow-81-false-red.log >/dev/null 2>&1 || _b60="$_b60 g-false-red"
# (i) a stop request ends it at the next PR, and what it dropped is named; (j) a land
# run that starts while a shadow holds its lock asks it to stop, and still lands.
SH60_LINES=2 arm60 arm60i 1 c84.txt other.txt
grep -q '^shadow:accept:81 .* intake=ok ' <<<"$l60" && grep -q '^unmeasured:shadow:82:stopped gate=green' <<<"$l60" || _b60="$_b60 i-stop"
# (k) a stop MID-BUILD ends the build's whole process tree and names the PR; (l) the same
# through the builder wrapper leaves nothing running IN THE TOOLBOX (a named skip where
# there is no builder). The sleep's duration is its marker, so only it is looked for.
_m60="86$(( $$ % 100000 ))"
printf 'sleep %s & sleep %s\n' "$_m60" "$_m60" > "$TMP/mid60.sh"
printf 'bash "%s" sleep %s\n' "$ROOT/scripts/with-tillandsias-builder.sh" "1$_m60" > "$TMP/mid60tb.sh"
mid60() { # <name> <stub> <pattern>: run it, stop it once the marker is live, count what is left
    ( for _w in $(seq 1 300); do pgrep -f "$3" >/dev/null && { sleep 1; : > "$TMP/$1/lock/stop"; break; }; sleep 0.1; done ) &
    local _sp=$!
    SH60_CMD="bash $2" arm60 "$1" 1 other.txt; wait "$_sp"
    grep -q '^unmeasured:shadow:81:stopped-mid-build gate=green' <<<"$l60" || _b60="$_b60 $1-unnamed"
    for _w in $(seq 1 100); do pgrep -f "$3" >/dev/null || break; sleep 0.1; done
    pgrep -f "$3" >/dev/null && { _b60="$_b60 $1-survivor"; pkill -f "$3"; }
}
mid60 arm60k "$TMP/mid60.sh" "^sleep $_m60\$"
if command -v toolbox >/dev/null 2>&1 && toolbox list -c 2>/dev/null | grep -q tillandsias-builder; then
    mid60 arm60l "$TMP/mid60tb.sh" "^sleep 1$_m60\$"
else echo "skip: ARM 60l — no tillandsias-builder toolbox here"; fi
sleep 300 & _h60=$!
mkdir -p "$TMP/arm60j/lock"; echo "$_h60" > "$TMP/arm60j/lock/pid"
SH60_CMD="" SH60_LINES=0 SH60_J=1 arm60 arm60j 1 c81.txt
[ -e "$TMP/arm60j/lock/stop" ] && grep -q '^land:81 ' <<<"$out60" || _b60="$_b60 j-signal"
kill "$_h60" 2>/dev/null; wait "$_h60" 2>/dev/null
if [ -z "$_b60" ]; then
    ok "ARM 60: shadow intake logs intake beside the gate after the last gate, in its own tree; off by default, bounded by name, and lands exactly what it would have"
else
    bad "ARM 60: failed:$_b60
$l60
$out60
$(cat "$TMP/arm60a/seen")"
fi
# ARM 61 (bundle landing phase 2 prep): `--status` also says what is next, the open
# train and the shadow, and `--status --pr N` answers "is my PR gating?". Asked from
# INSIDE a real gate, so it reads what a run really wrote. (a) a train of #91,#92 with
# #93 left waiting (K=2): bundle open, heavy counted, next, and each PR's own answer;
# (b) idle: bundle open=- with the last bundles.log line; (c) a live shadow is named,
# a stop request shows; (d) `--pr` alone never runs the queue, and without a number is
# refused; (e) the published body carries no local path; (f) the first line is ARM 56's.
scaffold arm61
for _i in 1 2 3; do candidate arm61 "109$_i-aaaa" "s61$_i.txt" A; done
cat > "$GH_PRS" <<JSON
[{"number":91,"headRefName":"work/1091-aaaa","isDraft":false},
 {"number":92,"headRefName":"work/1092-aaaa","isDraft":false},
 {"number":93,"headRefName":"work/1093-aaaa","isDraft":false}]
JSON
_st61="$TMP/arm61/st"; mkdir -p "$_st61" "$TMP/arm61/sk"
cat > "$GATE_BIN" <<GATE
#!/usr/bin/env bash
n="\$(grep -c . "$GATE_LOG")"; echo gated >> "$GATE_LOG"
s() { ( cd "$WORK_DIR" && TILLANDSIAS_LAND_QUEUE_GH="$GH_BIN" TILLANDSIAS_LAND_QUEUE_REMOTE=origin TILLANDSIAS_TRUNK_BRANCH=linux-next TILLANDSIAS_LAND_QUEUE_LOGDIR="$TMP/arm61/logs" TILLANDSIAS_LAND_QUEUE_TRAIN_LOG="$TMP/arm61/trains.log" TILLANDSIAS_LAND_QUEUE_SHADOW_LOCK="$TMP/arm61/sk" TILLANDSIAS_LAND_QUEUE_SHADOW_LOG="$TMP/arm61/shadow.log" bash "$QUEUE" "\$@" 2>&1 ); }
s --status > "$_st61/status.\$n"; for p in 91 93 99; do s --status --pr "#\$p" > "$_st61/pr\$p.\$n"; done
git -C "$REMOTE_DIR" log -1 --format=%B refs/tillandsias/queue/status > "$_st61/pub.\$n"
exit 0
GATE
sleep 300 & _h61=$!
echo "$_h61" > "$TMP/arm61/sk/pid"; printf 88 > "$TMP/arm61/sk/current"
out61="$(ARM_BATCH_K=2 ARM_HEAVY_PROBE="bash $_p57" ARM_TRAIN_LOG="$TMP/arm61/trains.log" ARM_SHADOW_LOCK="$TMP/arm61/sk" ARM_SHADOW_LOG="$TMP/arm61/shadow.log" LOGDIR_OVERRIDE="$TMP/arm61/logs" run_queue)"
_b61=""; _s0="$(cat "$_st61/status.0")"; _s1="$(cat "$_st61/status.1")"
grep -Eq '^queue:gating:#91 train phase=train-gate elapsed=[0-9]+ train=#91,#92 waiting=[0-9]+$' <<<"$_s0" || _b61="$_b61 f-first-line"
grep -Eq '^queue:bundle open=train-[0-9]+ members=#91,#92 heavy=0 base=[0-9a-f]{9} phase=train-gate elapsed=[0-9]+$' <<<"$_s0" || _b61="$_b61 a-bundle"
grep -q '^queue:next #93$' <<<"$_s0" || _b61="$_b61 a-next"
grep -q '^queue:pr:#91 gating in-train .*\|^queue:pr:#91 gating ' "$_st61/pr91.0" || _b61="$_b61 a-pr91"
grep -q '^queue:pr:#93 waiting position=1 of=1$' "$_st61/pr93.0" || _b61="$_b61 a-pr93"
grep -q '^queue:pr:#99 not-in-this-run ' "$_st61/pr99.0" || _b61="$_b61 a-pr99"
grep -Eq '^queue:gating:#93 work/1093-aaaa phase=gate ' <<<"$_s1" && grep -Eq '^queue:bundle open=- last=bundle:green:train-[0-9]+ members=2 ' <<<"$_s1" && grep -q '^queue:next -$' <<<"$_s1" || _b61="$_b61 b-single"
grep -q '^queue:pr:#93 gating ' "$_st61/pr93.1" || _b61="$_b61 b-pr93"
# the run asked this live shadow to stop at its start (2285-haa6), so it reads stopping
grep -q "^queue:shadow stopping pr=#88 log=$TMP/arm61/shadow.log lines=0$" <<<"$_s0" || _b61="$_b61 c-shadow"
kill "$_h61" 2>/dev/null; wait "$_h61" 2>/dev/null
grep -q '^queue:bundle open=train-' "$_st61/pub.0" && ! grep -qF "$TMP" "$_st61/pub.0" || _b61="$_b61 e-published"
_si="$(ARM_SHADOW_LOCK="$TMP/arm61/sk" ARM_TRAIN_LOG="$TMP/arm61/trains.log" LOGDIR_OVERRIDE="$TMP/arm61/logs" run_queue --status)"
grep -q '^queue:idle last-land=' <<<"$_si" && grep -q '^queue:bundle open=- last=bundle:green:' <<<"$_si" && grep -q '^queue:shadow idle pr=- ' <<<"$_si" && ! grep -q '^queue:next' <<<"$_si" || _b61="$_b61 b-idle"
_g61="$(grep -c . "$GATE_LOG")"
_p1="$(LOGDIR_OVERRIDE="$TMP/arm61/logs" run_queue --pr 91)"
_p3="$(LOGDIR_OVERRIDE="$TMP/arm61/logs" run_queue --status --pr)"; _r3=$?
[ "$(grep -c . "$GATE_LOG")" -eq "$_g61" ] && grep -q '^queue:pr:#91 idle ' <<<"$_p1" || _b61="$_b61 d-pr-alone"
[ "$_r3" -ne 0 ] && grep -q 'fail:land-queue:pr-needs-a-number' <<<"$_p3" || _b61="$_b61 d-no-number"
if [ -z "$_b61" ]; then
    ok "ARM 61: --status names the open train, what is next and the shadow from inside a real gate, --pr answers for one PR, and neither runs the queue"
else
    bad "ARM 61: failed:$_b61
$_s0
--
$_s1
--
$_si
$(head -3 "$_st61"/pr*)
$_p1
$_p3"
fi
# ARM 62 (bundle landing phase 1): A RED TRAIN IS DIAGNOSED BY ITS FAILING STEP. The
# scratch tree has one gate-run step (scripts/test-s62.sh, red iff bad.txt exists), run
# through a stub build.sh exactly as the gate would. (a) one member brings bad.txt: named
# by the first red merge, it leaves the train, the rest land on ONE more gate and its own
# gate evicts it; (b) a flake: the same members ride again; (c) the trunk is red: held,
# nobody evicted; (d) a script the log names but no gate step runs is NEVER executed;
# (e) red alone on the trunk while its whole gate is green is not judged; (f) a member that
# ADDS the red step is the culprit; (g) diagnosis off is the old fallback; (h) two members
# each bring their own red (two steps named, one per red-script line the gate reaches):
# the second train is red too and the rest go one at a time, no third train.
arm62() { # <name> <gate body> <files of members 91..93>; sets out62 l62
    local _f _i=0 _o
    scaffold "$1"
    git -C "$WORK_DIR" checkout -q linux-next
    mkdir -p "$WORK_DIR/scripts/gate-steps.d"
    printf 'echo ran-s62 >> "%s"\n[ ! -e bad.txt ]\n' "$TMP/$1/step-runs" > "$WORK_DIR/scripts/test-s62.sh"
    printf 'echo actor >> "%s"\n' "$TMP/$1/actor-ran" > "$WORK_DIR/scripts/test-actor62.sh"
    printf 'STEP_DESC="s62"\nSTEP_SCRIPT="scripts/test-s62.sh"\n' > "$WORK_DIR/scripts/gate-steps.d/100-s62.step"
    cat > "$WORK_DIR/build.sh" <<'BLD'
#!/usr/bin/env bash
[ "$1 $2 $3" = "--gate-steps . --gate-step" ] || exit 2
bash "$(sed -n 's/^STEP_SCRIPT="\(.*\)"$/\1/p' scripts/gate-steps.d/"$4"-*.step)"
BLD
    chmod +x "$WORK_DIR/build.sh"
    [ -z "${A62_TRUNK:-}" ] || printf 'x\n' > "$WORK_DIR/$A62_TRUNK"
    git -C "$WORK_DIR" add -A; git -C "$WORK_DIR" commit -q -m base62; git -C "$WORK_DIR" push -q origin linux-next
    : > "$TMP/$1/prs"
    for _f in $3; do
        _i=$((_i + 1)); _o="109$_i-aaaa"
        if [ "$_f" = addstep ]; then
            git -C "$WORK_DIR" checkout -q -B "work/$_o" origin/linux-next
            printf 'exit 1\n' > "$WORK_DIR/scripts/test-new62.sh"
            printf 'STEP_SCRIPT="scripts/test-new62.sh"\n' > "$WORK_DIR/scripts/gate-steps.d/200-new.step"
            git -C "$WORK_DIR" add -A; git -C "$WORK_DIR" commit -q -m add; git -C "$WORK_DIR" push -q origin "work/$_o"; git -C "$WORK_DIR" checkout -q linux-next
        else candidate "$1" "$_o" "$_f" "$_f"; fi
        printf '{"number":9%s,"headRefName":"work/%s","isDraft":false}\n' "$_i" "$_o" >> "$TMP/$1/prs"
    done
    { echo '['; paste -sd, "$TMP/$1/prs"; echo ']'; } > "$GH_PRS"
    printf '#!/usr/bin/env bash\necho "gated" >> "%s"\nn="$(grep -c . "%s")"\n%s\n' "$GATE_LOG" "$GATE_LOG" "$2" > "$GATE_BIN"
    out62="$(ARM_BATCH_K=4 ARM_HEAVY_MAX=4 ARM_TRAIN_LOG="$TMP/$1/trains.log" run_queue)"; rc62=$?
    l62="$(cat "$TMP/$1/bundles.log" 2>/dev/null)"; g62="$(grep -c . "$GATE_LOG")"
}
_g62='[ ! -e bad.txt ] || { echo "red-script:scripts/test-s62.sh"; exit 1; }'
_b62=""; _all62=""
chk62() { _all62="$_all62
== $1
$l62
$out62"; }
arm62 arm62a "$_g62" "ok1.txt bad.txt ok3.txt"; chk62 a
grep -q '^train:red:culprit=#92 ' <<<"$out62" && [ "$(grep -c '^land:9[13] .*train=' <<<"$out62")" -eq 2 ] && [ "$g62" -eq 3 ] \
    && grep -q '^evict:land-queue:92:' <<<"$out62" && grep -q '^bundle:red:.* cause=red:rc=1:culprit=#92 ' <<<"$l62" || _b62="$_b62 a-culprit"
arm62 arm62b 'if [ "$n" -eq 1 ]; then echo "red-script:scripts/test-s62.sh"; exit 1; fi' "ok1.txt ok2.txt"; chk62 b
grep -q '^train:red:flaky ' <<<"$out62" && [ "$(grep -c '^land:9[12] .*train=' <<<"$out62")" -eq 2 ] && [ "$g62" -eq 2 ] \
    && grep -q 'cause=red:rc=1:flaky ' <<<"$l62" || _b62="$_b62 b-flaky"
A62_TRUNK=bad.txt arm62 arm62c "$_g62" "ok1.txt ok2.txt"; chk62 c
grep -q '^hold:trunk-red:scripts/test-s62.sh ' <<<"$out62" && ! grep -qE '^(evict|land:)' <<<"$out62" && [ "$g62" -eq 2 ] && [ "$rc62" -eq 4 ] || _b62="$_b62 c-trunk"
arm62 arm62d 'if [ "$n" -eq 1 ]; then echo "red-script:scripts/test-actor62.sh"; exit 1; fi' "ok1.txt ok2.txt"; chk62 d
[ ! -e "$TMP/arm62d/actor-ran" ] && grep -q '^train:red:rc=1:unjudged:' <<<"$out62" && [ "$(grep -c '^land:9[12] ' <<<"$out62")" -eq 2 ] && [ "$g62" -eq 3 ] || _b62="$_b62 d-actor"
A62_TRUNK=bad.txt arm62 arm62e 'if [ "$n" -eq 1 ]; then echo "red-script:scripts/test-s62.sh"; exit 1; fi' "ok1.txt ok2.txt"; chk62 e
grep -q '^train:red:rc=1:unjudged:scripts/test-s62.sh:red-alone-on-trunk' <<<"$out62" && ! grep -q '^hold' <<<"$out62" && [ "$(grep -c '^land:9[12] ' <<<"$out62")" -eq 2 ] || _b62="$_b62 e-not-confirmed"
arm62 arm62f '[ ! -e scripts/test-new62.sh ] || { echo "red-script:scripts/test-new62.sh"; exit 1; }' "ok1.txt addstep ok3.txt"; chk62 f
grep -q '^train:red:culprit=#92 ' <<<"$out62" && [ "$(grep -c '^land:9[13] .*train=' <<<"$out62")" -eq 2 ] || _b62="$_b62 f-adds-step"
TILLANDSIAS_LAND_QUEUE_TRAIN_DIAGNOSE=0 arm62 arm62g "$_g62" "ok1.txt bad.txt ok3.txt"; chk62 g
grep -q '^train:red:rc=1 — ' <<<"$out62" && ! grep -q 'culprit' <<<"$out62" && [ ! -e "$TMP/arm62g/step-runs" ] && [ "$g62" -eq 4 ] || _b62="$_b62 g-off"
arm62 arm62h "$_g62"'; [ ! -e worse.txt ] || { echo "FAIL: something unnamed"; exit 1; }' "bad.txt worse.txt ok3.txt"; chk62 h
[ "$(grep -c '^train: ' <<<"$out62")" -eq 2 ] && grep -q '^train:red:culprit=#91 ' <<<"$out62" && grep -q '^train:red:rc=1 — ' <<<"$out62" \
    && grep -q '^land:93 ' <<<"$out62" && [ "$(grep -c '^evict:land-queue:9[12]:' <<<"$out62")" -eq 2 ] || _b62="$_b62 h-second-red"
if [ -z "$_b62" ]; then
    ok "ARM 62: a red train is judged by its failing step: culprit leaves and the rest land, flake rides again, trunk red holds, and only a gate-run step is ever executed"
else
    bad "ARM 62: failed:$_b62
$_all62"
fi
# ARM 63: the REAL build.sh _run and _error print red-script:<path> once for a script that
# exited 1 and was refused, and nothing for an advisory red, a could-not-run (3) or a green.
mkdir -p "$TMP/arm63/scripts"
printf 'exit "$1"\n' > "$TMP/arm63/scripts/test-s63.sh"
{ printf 'SCRIPT_DIR="%s"; RED=; NC=; _PHASE_WORK_MS=0\n_require_host_build_tools() { :; }; _now_ms() { echo 0; }; _info() { :; }\n' "$TMP/arm63"
  sed -n -e '/^_RED_SCRIPT=""$/,/^}$/p' -e '/^_run() {$/,/^}$/p' "$ROOT/build.sh"
  cat <<'DRV'
t() { _run bash "$SCRIPT_DIR/scripts/test-s63.sh" "$1"; }
t 1; _error refused; _error second
echo --; t 1; t 0; _error after-green
echo --; t 3; _error could-not-run
echo --; t 1; _info advisory
DRV
} > "$TMP/arm63/drv.sh"
o63="$(bash "$TMP/arm63/drv.sh" 2>&1 | tr '\n' '|')"
if [ "$o63" = "red-script:scripts/test-s63.sh|[build] refused|[build] second|--|[build] after-green|--|[build] could-not-run|--|" ]; then
    ok "ARM 63: build.sh names a refused script once as red-script:<path>, never an advisory, a could-not-run or a green one"
else
    bad "ARM 63: got $o63"
fi
printf '\n'
if [ "$fail" -eq 0 ]; then
    if [ "$skipped" -gt 0 ]; then
        printf 'ok:land-queue:%d/%d (%d skipped)\n' "$pass" "$((pass + fail))" "$skipped"
    else
        printf 'ok:land-queue:%d/%d\n' "$pass" "$((pass + fail))"
    fi
    exit 0
fi
printf 'blocked:land-queue:%d-failed-of-%d\n' "$fail" "$((pass + fail))"
exit 1
