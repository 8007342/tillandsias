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

    : > "$GH_COMMENTS"; : > "$GATE_LOG"

    cat > "$GH_BIN" <<GH
#!/usr/bin/env bash
# Fake gh. Answers 'pr list' from a file and records 'pr comment' to a log.
case "\$1 \$2" in
    "pr list")    cat "$GH_PRS" ;;
    "pr comment") shift 2; printf '%s\n' "\$*" >> "$GH_COMMENTS" ;;
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

run_queue() {
    ( cd "$WORK_DIR" && env \
        TILLANDSIAS_LAND_QUEUE_GH="$GH_BIN" \
        TILLANDSIAS_LAND_QUEUE_GATE="bash $GATE_BIN" \
        TILLANDSIAS_LAND_QUEUE_REMOTE=origin \
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
scaffold arm9
candidate arm9 9001-aaaa a.txt A
candidate arm9 9002-bbbb b.txt B
candidate arm9 9003-cccc c.txt C
cat > "$GH_PRS" <<JSON
[{"number":1,"headRefName":"work/9001-aaaa","isDraft":false},
 {"number":2,"headRefName":"work/9002-bbbb","isDraft":false},
 {"number":3,"headRefName":"work/9003-cccc","isDraft":false}]
JSON
cat > "$GATE_BIN" <<'GATE'
#!/usr/bin/env bash
# A gate that drains stdin, exactly as ./build.sh --check does.
cat >/dev/null 2>&1 || true
exit 0
GATE
# AND THE FAKE gh DRAINS STDIN TOO, which is what makes this arm discriminate.
# The gate alone does not: the queue redirects it from /dev/null, so an arm
# built only on a hungry GATE passes even with the fd-3 read reverted — measured
# when this arm was written. gh is invoked inside the loop with no such
# redirect, so a hungry gh tests the fd the LIST is read on rather than one
# subprocess's plumbing. Two guards, and the arm must fail if EITHER is removed.
sed -i '2i cat >/dev/null 2>&1 || true' "$GH_BIN"

# BOUNDED, BECAUSE THE DEFECT'S FAILURE MODE IS A HANG AND NOT A WRONG ANSWER.
# Measured 2026-09-21: with the fd-3 read reverted and a stdin-hungry gh, this
# arm did not print a wrong verdict — it BLOCKED, and the whole fixture died at
# its own 600 s bound with rc=124 and no ARM 9 line at all. A silent hang is the
# worst failure an arm can have: it is indistinguishable from a slow host, it
# produces no verdict to read, and whoever meets it goes looking for an
# infrastructure problem instead of the assertion that fired. So the subject is
# bounded HERE and a timeout is reported as this arm's own named failure.
out9="$(timeout 120 env \
    TILLANDSIAS_LAND_QUEUE_GH="$GH_BIN" \
    TILLANDSIAS_LAND_QUEUE_GATE="bash $GATE_BIN" \
    TILLANDSIAS_LAND_QUEUE_REMOTE=origin \
    TILLANDSIAS_TRUNK_BRANCH=linux-next \
    bash -c 'cd "$1" && bash "$2"' _ "$WORK_DIR" "$QUEUE" 2>&1)"
_rc9=$?
if [ "$_rc9" -eq 124 ]; then
    bad "ARM 9: the queue BLOCKED (timeout 120s) with a stdin-consuming gate and gh — the candidate list is being read on stdin and a reader in the loop is waiting on it. This is the field defect of 2026-09-21, and its shape is a hang rather than a wrong answer."
else
n9="$(printf '%s' "$out9" | sed -n 's/^land:\([0-9]*\) .*/\1/p' | tr '\n' ',')"
case "$out9" in
    *"ok:land-queue:3 "*)
        if [ "$n9" = "1,2,3," ]; then
            ok "ARM 9: a STDIN-CONSUMING gate still lets all three candidates be processed — the list is read on fd 3, not stdin"
        else
            bad "ARM 9: the queue reported 3 examined but landed '$n9'"
        fi ;;
    *)
        bad "ARM 9: a stdin-consuming gate cut the drain short (landed '$n9') — the candidate list is being eaten by the loop body, which is the field defect of 2026-09-21
$(printf '%s' "$out9" | tail -3)" ;;
esac
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
