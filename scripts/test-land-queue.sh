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

run_queue() {
    ( cd "$WORK_DIR" && env \
        TILLANDSIAS_LAND_QUEUE_GH="$GH_BIN" \
        TILLANDSIAS_LAND_QUEUE_GATE="bash $GATE_BIN" \
        TILLANDSIAS_LAND_QUEUE_PREFLIGHT="${PREFLIGHT_CMD:-}" \
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
if grep -q 'reason=gate-aborted:rc=255' "$GH_COMMENTS" && ! grep -q 'reason=gate-failed' "$GH_COMMENTS" \
   && [ "$g18" -eq 2 ] && ! grep -q stale-head <<<"$o18b"; then
    ok "ARM 18: an aborted gate (rc=255) is recorded as gate-aborted and re-gated after a plan-only move, never stale-skipped"
else
    bad "ARM 18: wanted reason=gate-aborted:rc=255 and a second gate; gates=$g18
$o18a
---
$o18b
comments: $(grep -o 'land-queue:evicted[^>]*' "$GH_COMMENTS")"
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
