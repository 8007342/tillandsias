#!/usr/bin/env bash
# @trace order:1316-bnzt, spec:ci-release
#
# land-queue.sh — ONE serialized landing at a time into the trunk branch, drawn
# from open pull requests in number order.
#
# WHY THIS EXISTS. Today every host lands into linux-next itself, so the shared
# branch is raced by everyone at once: a host gates a tree, origin moves while
# it gates, the pre-push hook refuses because the gate validated a different
# tree, and the host gates again. Measured on yoga 2026-09-20 on ONE row:
# 10 gate cycles across two slices, 5 of them lost purely to RE-GATING AN
# UNCHANGED TREE after another host pushed first. That is not an argument
# against gating; it is an argument against re-gating a tree that did not
# change. One lander removes the race without removing a single check.
#
# THE SHAPE IS NOT NOVEL and is not being invented here: it is what bors/homu,
# the Chromium CQ and GitLab merge trains all do — test the candidate against
# TARGET PLUS CANDIDATE, land one at a time, evict and continue on failure.
#
# ═══ EVERY CANDIDATE GATES AT FULL, AND THAT IS DELIBERATE ═══
#
# Tiered integration (LIGHT / SCOPED / FULL, proportional to blast radius) is
# NOT in this script and must not be added to it. It belongs to order 765-xpct,
# whose fifth exit criterion reads: "Operator (Tlatoani) approval recorded
# before activation, as the symmetric twin of bar_raise_governance
# (methodology/convergence.yaml:425) — scope reduction is a bar decision the
# loop must not self-enact." Choosing to run FEWER checks before code reaches
# trunk is exactly that reduction. A coordinator session agreeing the design is
# sound is not that approval, and neither is this comment.
#
# So the queue is a strict improvement with nobody's permission: the same gate
# every host runs today, run once by one lander instead of N times by N hosts.
# When 765-xpct lands WITH the operator's recorded decision, this script asks it
# for the tier; until then `tier=full` is not a placeholder, it is the answer.
#
# ═══ THE TREE THAT SHIPS MUST BE THE TREE THAT GATED ═══
#
# A queue exists BECAUSE the target moves. Between "the gate went green on
# merge(target@T1, head)" and "the push lands merge(target@T2, head)" the target
# can move again, and the green verdict then describes a tree nobody is pushing.
# So the target is read again immediately before the push and compared against
# the SHA that was gated; a mismatch RE-QUEUES the candidate and pushes nothing.
#
# WHAT THIS CHECK IS AND IS NOT, measured rather than asserted. Disabling it in
# the fixture (`if false` in place of the comparison) does NOT ship a stale tree:
# the push is rejected, because a merge built on target@T1 is not a fast-forward
# of target@T2, and git refuses it. The candidate is re-queued either way. So
# this is NOT the last line of defence and this comment will not pretend it is.
#
# What it buys is the DIAGNOSIS, and that is worth the ten lines. Without it the
# queue reports `push-did-not-land:rc=1`, which is the same line a blocked
# credential helper, a lost network and a protected branch produce — the reader
# is handed a push failure and has to work out that it was an ordinary, expected
# race. With it, the queue never attempts a push it knows will fail and says
# `target-moved:gated-on=<a> now=<b>`, naming the cause. It is also the half
# that keeps holding if a later hand relaxes the push to `--force-with-lease`,
# at which point git stops catching it and this does.
#
# It is invisible to any fixture whose scaffold target never moves, which is why
# scripts/test-land-queue.sh moves it from inside the stub gate rather than
# before the run.
#
# ═══ WHAT COUNTS AS EVIDENCE THAT SOMETHING LANDED ═══
#
# Not the exit status, and not the push output. 859-4jny records both bugs from
# the loop this replaces: `if git push | tee LOG | tail -3; then` tests TAIL's
# status, and grepping the output for "<branch> -> <branch>" also matches
# `! [rejected]  linux-next -> linux-next (fetch first)`. Together they reported
# LANDED for a refused push. The only proof is asking the remote:
# `git merge-base --is-ancestor` against a freshly fetched ref.
#
# ═══ NO LOCAL QUEUE STATE ═══
#
# The queue is `gh pr list`, re-read every run. There is no local queue file,
# because a queue whose recovery depends on its own bookkeeping can lose a
# landing silently: kill it mid-landing and the file says one thing while the
# remote says another. Killed anywhere, the next run re-derives the truth from
# the remote — either the merge is an ancestor of trunk or it is not.
#
# Usage:
#   scripts/land-queue.sh [--limit N] [--dry-run] [--base <branch>]
#
# Exit: 0 the run completed (landed, evicted and re-queued counts on stdout)
#       1 could not read the queue (gh missing, unauthenticated, bad JSON)
#       2 the working tree is dirty — this script rewrites HEAD and refuses to
#         do that over uncommitted work
#       3 another landing is in flight (the lock is held)
set -uo pipefail

# THE REPOSITORY IS THE ONE YOU ARE STANDING IN, NOT THE ONE THIS SCRIPT LIVES
# IN. Deriving it from BASH_SOURCE — the habit every other script in this tree
# uses, correctly, because they act on their own repository — makes THIS script
# land into the checkout it was invoked FROM the file of, which for a queue is a
# different repository than the operator meant. Caught by its own fixture on the
# first run: every arm ran against the live tillandsias checkout and was saved
# only by an unrelated dirty-tree refusal. A clean tree would have had it
# merging scaffold branches into the real trunk.
# THE SCRIPT'S OWN DIRECTORY, CAPTURED BEFORE ANY cd, AND IT IS NOT $ROOT.
#
# TWO DIFFERENT QUESTIONS THAT BOTH LOOK LIKE "WHERE AM I":
#   $ROOT      the repository being LANDED INTO — the checkout you invoked from
#   $_SELF_DIR where THIS SCRIPT'S SIBLINGS live — gate-stamp.sh and friends
# They are the same path in production and different in every fixture, which is
# why the fixture caught it: the scaffold repo has no scripts/ directory, so
# `$ROOT/scripts/gate-stamp.sh` did not exist, the classifier returned nothing,
# and the 1335-2nzf adopt path re-queued every time while reporting no error.
#
# AND IT IS CAPTURED BEFORE THE cd DELIBERATELY. BASH_SOURCE[0] is the
# INVOCATION path; reading it after `cd "$ROOT"` resolves it against the wrong
# directory for any relative invocation — the exact defect landed tonight as
# 1337-3tk6's follow-up, arriving here from the opposite direction.
_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "fail:land-queue:not-a-git-repo — run this from the checkout you are landing into" >&2
    exit 1
}
[ -n "$ROOT" ] || { echo "fail:land-queue:not-a-git-repo" >&2; exit 1; }
cd "$ROOT" || exit 1

# ── SEAMS ────────────────────────────────────────────────────────────────────
# Named here, at the top, so a reader knows what this script consults before
# reading any logic that depends on it. Each is overridable ONLY so the fixture
# can drive the script; every default is the production value.
GH="${TILLANDSIAS_LAND_QUEUE_GH:-gh}"
GATE="${TILLANDSIAS_LAND_QUEUE_GATE:-./build.sh --check}"
REMOTE="${TILLANDSIAS_LAND_QUEUE_REMOTE:-origin}"
TRUNK="${TILLANDSIAS_TRUNK_BRANCH:-linux-next}"
LOCKDIR="${TILLANDSIAS_LAND_QUEUE_LOCK:-$ROOT/.git/tillandsias-land-queue.lock}"
# A work ref's grammar, from methodology/multi-host-development.yaml's
# creation_regex. A PR whose head is not one of these is not a queue entry.
WORK_RE='^work/[0-9]{3,4}-[a-z0-9]{4}$'

LIMIT=0
DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --limit)   LIMIT="${2:-0}"; shift 2 ;;
        --limit=*) LIMIT="${1#*=}"; shift ;;
        --base)    TRUNK="${2:-$TRUNK}"; shift 2 ;;
        --base=*)  TRUNK="${1#*=}"; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        *) echo "fail:land-queue:unknown-argument:$1" >&2; exit 1 ;;
    esac
done

landed=0; evicted=0; requeued=0; skipped=0

say() { printf '%s\n' "$*"; }

# ORDER 1375-2x4e: the queue JSON is read with `tillandsias-plan json get`, the jq
# subset on the binary every gate host already has, not with jq. Resolved from
# THIS script's directory: the fixture runs it against scratch repositories.
# shellcheck source=scripts/plan-binary-probe.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/plan-binary-probe.sh" 2>/dev/null || true
PLAN="$(resolve_plan_binary 2>/dev/null)" || { say "fail:land-queue:no-plan-binary — the queue is read with tillandsias-plan json get"; exit 1; }

# pr_comment <number> <text> — record a verdict where the author will see it.
# A failure to comment is NOT a failure to evict: the eviction already happened
# and the queue must keep going, so this is advisory and says so.
pr_comment() {
    local n="$1" body="$2"
    [ "$DRY_RUN" -eq 1 ] && { say "dry-run: would comment on #$n"; return 0; }
    if ! "$GH" pr comment "$n" --body "$body" >/dev/null 2>&1; then
        say "advisory:land-queue:comment-failed:$n — the eviction stands; the PR was not annotated"
    fi
}

# ── THE WORKING TREE MUST BE CLEAN ───────────────────────────────────────────
# This script checks out and rewrites HEAD. Doing that over uncommitted work
# destroys it, and `git checkout` would happily carry the changes across.
dirty="$(git status --porcelain 2>/dev/null)"
if [ -n "$dirty" ]; then
    say "fail:land-queue:dirty-tree — this script rewrites HEAD; commit or stash first"
    exit 2
fi

# ── SERIALIZATION ────────────────────────────────────────────────────────────
# mkdir is the atomic claim. The lock records the holder's PID so a reader can
# tell a live landing from a crashed one, and a stale lock whose PID is gone is
# reclaimed rather than blocking the fleet forever.
if ! mkdir "$LOCKDIR" 2>/dev/null; then
    holder="$(cat "$LOCKDIR/pid" 2>/dev/null || true)"
    if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
        say "skip:land-queue:in-flight:$holder — one landing at a time, by design"
        exit 3
    fi
    say "land-queue: reclaiming a lock whose holder ($holder) is gone"
    rm -rf "$LOCKDIR"
    mkdir "$LOCKDIR" 2>/dev/null || { say "fail:land-queue:lock-unavailable"; exit 3; }
fi
printf '%s\n' "$$" > "$LOCKDIR/pid"
# WHERE TO PUT THE CHECKOUT BACK. `rev-parse --abbrev-ref HEAD` returns the
# literal string "HEAD" when the caller is already detached, and `git checkout
# HEAD` then restores wherever the QUEUE last left HEAD rather than where the
# caller started. Measured on yoga 2026-09-20: from a detached HEAD the restore
# is a silent no-op, and the state it fails to restore from is precisely the one
# an earlier interrupted run leaves behind. A branch name is recorded as a name
# so the caller keeps their branch; anything else is recorded as a SHA.
_start_ref="$(git symbolic-ref --quiet --short HEAD 2>/dev/null \
              || git rev-parse HEAD 2>/dev/null \
              || echo HEAD)"
cleanup() {
    git checkout -q "$_start_ref" 2>/dev/null || true
    rm -rf "$LOCKDIR"
}
trap cleanup EXIT INT TERM

# ── READ THE QUEUE ───────────────────────────────────────────────────────────
# From the remote, every run. `gh` writing nothing is NOT an empty queue: an
# unauthenticated or missing gh also writes nothing, and treating that as "no
# work" is the silent-empty false negative this fleet keeps finding. So an
# empty capture with a non-zero status REFUSES, and only a well-formed empty
# list means the queue is empty.
_qjson="$(mktemp)"
"$GH" pr list --base "$TRUNK" --state open \
      --json number,headRefName,isDraft > "$_qjson" 2>/dev/null
_qrc=$?
if [ "$_qrc" -ne 0 ]; then
    say "fail:land-queue:cannot-read-queue:gh-exit-$_qrc — this is NOT an empty queue"
    rm -f "$_qjson"
    exit 1
fi
if ! "$PLAN" json get -e 'type == "array"' < "$_qjson" >/dev/null 2>&1; then
    say "fail:land-queue:queue-not-an-array — gh exited 0 with output that is not a PR list"
    rm -f "$_qjson"
    exit 1
fi

# Two values per ready PR on alternating lines, paired by `paste - -` and
# ordered by number: the subset has no sort_by or string interpolation.
_cands="$("$PLAN" json get -r '.[] | select(.isDraft | not) | .number, .headRefName' < "$_qjson" | paste - - | sort -n)"
rm -f "$_qjson"

if [ -z "$_cands" ]; then
    say "ok:land-queue:0 landed=0 evicted=0 requeued=0 skipped=0 — the queue is empty"
    exit 0
fi

git fetch -q "$REMOTE" "$TRUNK" 2>/dev/null || true

_n=0
# THE CANDIDATE LIST IS READ ON FD 3, NOT STDIN, AND THAT IS NOT STYLE.
#
# MEASURED IN THE FIELD ON THIS SCRIPT'S SECOND REAL USE, 2026-09-21: invoked
# with `--limit 2` over two ready PRs it processed ONE and reported
# `ok:land-queue:1`. The loop body runs the real gate, `./build.sh --check`,
# which READS STDIN — and the loop was reading its candidates from a here-string
# on stdin, so the gate swallowed the remaining candidates and the loop ended
# after one iteration.
#
# THE FIXTURE COULD NOT SEE IT. Its stub gate is `exit 0`, which consumes
# nothing, so arms 1 and 3 land three candidates each and pass while the real
# queue drains one per run. A fixture only tests the world it builds, and the
# world it built had a gate that does not read.
#
# fd 3 makes the body's stdin habits irrelevant instead of forbidding them: any
# future step may read stdin freely and the candidate list is untouchable.
while IFS=$'\t' read -r num head <&3; do
    [ -n "$num" ] || continue
    if [ "$LIMIT" -gt 0 ] && [ "$_n" -ge "$LIMIT" ]; then break; fi
    _n=$((_n + 1))

    # A PR whose head is not a work ref is not a queue entry. Named, not
    # silently dropped: the author needs to know which lane the queue reads.
    if ! [[ "$head" =~ $WORK_RE ]]; then
        say "skip:land-queue:$num:not-a-work-ref:$head"
        pr_comment "$num" "This queue lands \`work/<order>\` refs only; \`$head\` is not one. See methodology/multi-host-development.yaml → work_ref_lane."
        skipped=$((skipped + 1))
        continue
    fi

    if ! git fetch -q "$REMOTE" "$head" 2>/dev/null; then
        say "skip:land-queue:$num:head-unfetchable:$head"
        skipped=$((skipped + 1))
        continue
    fi
    head_sha="$(git rev-parse FETCH_HEAD)"

    # THE SHA THAT WILL BE GATED. Everything below is judged against this one
    # value, and the push re-reads it to prove it has not moved.
    base_sha="$(git rev-parse "$REMOTE/$TRUNK")"

    say "land-queue: #$num $head tier=full base=${base_sha:0:9} head=${head_sha:0:9}"

    # ── MERGE TARGET + CANDIDATE ─────────────────────────────────────────────
    git checkout -q --detach "$base_sha" 2>/dev/null || {
        say "skip:land-queue:$num:cannot-detach"; skipped=$((skipped + 1)); continue
    }
    _mlog="$(mktemp)"
    git -c user.name=land-queue -c user.email=land-queue@localhost \
        merge --no-ff -m "land($num): $head into $TRUNK" "$head_sha" > "$_mlog" 2>&1
    _mrc=$?
    if [ "$_mrc" -ne 0 ]; then
        # Name the conflicting PATHS, not the merge's prose. A queue that says
        # "conflict" and nothing else sends the author back to reproduce it.
        _conf="$(git diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ' ')"
        git merge --abort 2>/dev/null || true
        [ -n "$_conf" ] || _conf="(none reported — see the merge log)"
        say "evict:land-queue:$num:conflict:$_conf"
        pr_comment "$num" "Evicted from the landing queue: merging with \`$TRUNK\` at \`${base_sha:0:9}\` conflicts in: $_conf

Rebase or merge \`$TRUNK\` into \`$head\` and the queue will pick it up again. The queue continued with the next candidate."
        evicted=$((evicted + 1))
        rm -f "$_mlog"
        continue
    fi
    rm -f "$_mlog"
    merge_sha="$(git rev-parse HEAD)"

    # ── GATE THE MERGE RESULT ────────────────────────────────────────────────
    if [ "$DRY_RUN" -eq 1 ]; then
        say "dry-run: would gate ${merge_sha:0:9} then push to $TRUNK"
        continue
    fi
    _glog="$(mktemp)"
    # No pipeline: a `$GATE | tee` would hand us tee's status, which is the
    # 859-4jny bug one layer over.
    ( eval "$GATE" ) < /dev/null > "$_glog" 2>&1
    _grc=$?
    if [ "$_grc" -ne 0 ]; then
        _tail="$(tail -5 "$_glog")"
        say "evict:land-queue:$num:gate-failed:rc=$_grc"
        pr_comment "$num" "Evicted from the landing queue: the gate failed (rc=$_grc) on the merge of \`$head\` into \`$TRUNK\` at \`${base_sha:0:9}\`.

\`\`\`
$_tail
\`\`\`

The queue continued with the next candidate. Fix and the queue will pick it up again."
        evicted=$((evicted + 1))
        rm -f "$_glog"
        continue
    fi
    rm -f "$_glog"

    # ── THE TREE THAT SHIPS MUST BE THE TREE THAT GATED ──────────────────────
    # Read the target AGAIN. If it moved while we gated, the green verdict above
    # is about a tree nobody is pushing.
    git fetch -q "$REMOTE" "$TRUNK" 2>/dev/null || true
    base_now="$(git rev-parse "$REMOTE/$TRUNK")"
    if [ "$base_now" != "$base_sha" ]; then
        # ── ORDER 1335-2nzf: A PLAN-ONLY MOVE DOES NOT INVALIDATE THIS GATE ──
        #
        # "The SHA moved" and "the gate's verdict is now wrong" are different
        # questions, and comparing SHAs answers only the first. MEASURED, twice:
        # on 2026-09-22 three plan-lane pushes re-queued both candidates in a
        # drain, costing two ~20-minute FULL gates; the same night the LAND TOOL
        # adopted its stamp across two plan-only moves and landed on attempt 2.
        # With six hosts pushing fragments, every queue gate is a gate the fleet
        # is likely to lose, and nobody can be asked to stop appending to the
        # ledger for twenty minutes at a time.
        #
        # THE CLASSIFIER IS NOT NEW AND MUST NOT BE. `gate-stamp.sh classify`
        # takes paths on stdin and returns the sorted class set (765-dt8h), the
        # same taxonomy the stamp's scope, the pre-push lane and change-class.sh
        # already use. A fourth copy would be a fourth thing to drift — which is
        # why this asks the existing subcommand rather than matching paths here.
        #
        # ADOPT ONLY WHEN EVERY CLASS IN THE DELTA IS plan-ledger. Anything else
        # — a script, a spec, a crate, an unreadable answer — re-queues. The
        # failure direction is the same one the whole row family uses: an
        # uncertainty runs the gate again rather than skipping it.
        _delta_classes="$(git diff --name-only "$base_sha" "$base_now" 2>/dev/null \
                          | bash "$_SELF_DIR/gate-stamp.sh" classify 2>/dev/null)"
        _adoptable=1
        if [ -z "$_delta_classes" ]; then
            _adoptable=0          # empty answer is not "no classes"; re-queue
        else
            while IFS= read -r _c; do
                [ -n "$_c" ] || continue
                [ "$_c" = "plan-ledger" ] || { _adoptable=0; break; }
            done <<< "$_delta_classes"
        fi

        if [ "$_adoptable" -eq 1 ]; then
            # Re-merge onto the moved target. The gate's verdict still describes
            # the code, because nothing the gate compiles, lints or runs changed
            # — only ledger fragments did. A conflict here is a real answer and
            # falls through to the re-queue below.
            if git merge --no-ff -q -m "land($num): $head into $TRUNK (adopted over a plan-only move)" \
                 "$base_now" >/dev/null 2>&1; then
                merge_sha="$(git rev-parse HEAD)"
                base_sha="$base_now"
                say "adopt:land-queue:$num:plan-only-move:gated-on=${base_sha:0:9} classes=plan-ledger — the gate's verdict still describes this code"
            else
                git merge --abort 2>/dev/null || true
                say "requeue:land-queue:$num:plan-only-move-conflicts:${base_now:0:9}"
                requeued=$((requeued + 1))
                continue
            fi
        else
            say "requeue:land-queue:$num:target-moved:gated-on=${base_sha:0:9} now=${base_now:0:9} classes=$(printf '%s' "${_delta_classes:-unreadable}" | tr '\n' ',' | sed 's/,$//')"
            pr_comment "$num" "Re-queued, not landed: \`$TRUNK\` moved from \`${base_sha:0:9}\` to \`${base_now:0:9}\` while this candidate was gating, and the move touched classes \`$(printf '%s' "${_delta_classes:-unreadable}" | tr '\n' ',' | sed 's/,$//')\` — not ledger fragments alone, so the green verdict no longer describes the tree being pushed. Nothing was pushed. The queue will re-gate against the new target."
            requeued=$((requeued + 1))
            continue
        fi
    fi

    # ── PUSH, AND PROVE IT LANDED BY ASKING THE REMOTE ───────────────────────
    git push "$REMOTE" "HEAD:refs/heads/$TRUNK" >/dev/null 2>&1
    _prc=$?
    git fetch -q "$REMOTE" "$TRUNK" 2>/dev/null || true
    if git merge-base --is-ancestor "$merge_sha" "$REMOTE/$TRUNK" 2>/dev/null; then
        say "land:$num tier=full gate=green base=${base_sha:0:9} head=${head_sha:0:9} merge=${merge_sha:0:9}"
        say "  not-run: nothing — tier=full runs the whole gate"
        landed=$((landed + 1))
        continue
    fi
    say "requeue:land-queue:$num:push-did-not-land:rc=$_prc — the remote does not have ${merge_sha:0:9}"
    requeued=$((requeued + 1))
done 3<<< "$_cands"

say "ok:land-queue:$_n landed=$landed evicted=$evicted requeued=$requeued skipped=$skipped"
exit 0
