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
# The freeze predicate and marker read, shared with the hook, release-freeze.sh
# and release-preflight (1255-s4im).
# shellcheck source=lib-freeze-paths.sh
. "$_SELF_DIR/lib-freeze-paths.sh"

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
# ORDER 1844-92bz: queue gates build WITHOUT incremental compilation. A
# candidate's verdict must not depend on what an earlier gate left in the
# shared incremental cache; four candidates in one night were evicted at link
# by a mixed cache (see build.sh). Non-incremental units are also cacheable by
# sccache, so consecutive candidates share compiled dependencies. A caller can
# still set it to 1.
export TILLANDSIAS_CARGO_INCREMENTAL="${TILLANDSIAS_CARGO_INCREMENTAL:-0}"
# ORDER 1765-q7rg: the ~1-min decider door run on the merge result BEFORE the
# ~21-min gate. Set to the empty string to disable (the fixture's default).
PREFLIGHT="${TILLANDSIAS_LAND_QUEUE_PREFLIGHT-./build.sh --preflight}"
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
# THIS script's CHECKOUT ROOT, not the caller's cwd (1461-5rm6): the fixture
# runs it from scratch repositories with no target/, and resolve_plan_binary's
# `./target/...` arm reads the cwd. Resolved inside the root, then made
# absolute, so a later cd cannot orphan a relative path. An exported
# TILLANDSIAS_PLAN_BIN still wins (the probe's first arm).
_lq_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/plan-binary-probe.sh
. "$_lq_root/scripts/plan-binary-probe.sh" 2>/dev/null || true
PLAN="$(cd "$_lq_root" && resolve_plan_binary 2>/dev/null)" || { say "fail:land-queue:no-plan-binary — the queue is read with tillandsias-plan json get"; exit 1; }
case "$PLAN" in /*) ;; */*) PLAN="$_lq_root/${PLAN#./}" ;; esac

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

# ── ORDER 1765-q7rg: THE QUEUE REMEMBERS ITS OWN EVICTIONS ON THE PR ─────────
# Every eviction comment ends with one machine line naming the head it evicted,
# the trunk base it merged onto and why. The PR's comments are remote state the
# queue already writes and trusts, so a later run can ask "did I already reject
# exactly this head?" without a local cache that another host would not have.
#   <!-- land-queue:evicted pr=<n> head=<sha> base=<sha> reason=<token> -->
# reason is gate-failed | preflight-failed | flaky | carried-<kind>:<backlog>
# | conflict:<path>,<path>,...  (no spaces, so the line splits on them).
evict_marker() {  # <pr> <head sha> <base sha> <reason>
    printf '\n\n<!-- land-queue:evicted pr=%s head=%s base=%s reason=%s -->\n' "$1" "$2" "$3" "$4"
}
# last_eviction <pr> — the newest marker line on the PR, or nothing. A failed
# read is nothing: the queue then gates as it always did.
last_eviction() {
    "$GH" pr view "$1" --json comments 2>/dev/null \
        | "$PLAN" json get -r '.comments[].body' 2>/dev/null \
        | grep -o "<!-- land-queue:evicted pr=$1 head=[0-9a-f]* base=[0-9a-f]* reason=[^ ]* -->" \
        | tail -n 1
}
marker_field() {  # <marker line> <field>
    printf '%s\n' "$1" | sed -n "s/.* $2=\([^ ]*\) .*/\1/p"
}

# gate_failed_comment <gate log> <rc> <head> <trunk> <base sha> — the body of a
# gate-failed eviction comment, on stdout.
#
# ORDER 1602-3ave: the body quoted only `tail -5` of the gate log, and a failing
# fixture's FAIL lines sit ABOVE the gate's closing summary. #319's run-17
# eviction could not name its failing arm. The log already holds stderr (the
# gate runs `> "$_glog" 2>&1`), so the verdict lines are there to quote: the
# first 20 distinct lines that read as one (FAIL, [FAIL], refused:, violation:,
# blocked:), colour codes and indentation stripped, ahead of the same tail.
# Factored so test-land-queue-eviction-comment.lua can build it from a planted
# log without a real gate.
gate_failed_comment() {
    local glog="$1" rc="$2" head="$3" trunk="$4" base="$5" fails="" tail5
    # BEGIN-FAIL-LINES
    fails="$(awk '
        { line = $0; gsub(/\033\[[0-9;]*m/, "", line); sub(/^[ \t]+/, "", line) }
        # A sum of single-pattern tests, not an alternation: no "|" for the pipe-site counter to misread.
        { verdict = (line ~ /^FAIL/) + (line ~ /^\[FAIL\]/) + (line ~ /^refused:/) + (line ~ /^violation:/) + (line ~ /^blocked:/) + (line ~ /^flaky:/) }
        verdict && !(line in seen) && n < 20 { seen[line] = 1; n++; print line }
    ' "$glog" 2>/dev/null)"
    # END-FAIL-LINES
    tail5="$(tail -5 "$glog")"
    printf 'Evicted from the landing queue: the gate failed (rc=%s) on the merge of `%s` into `%s` at `%s`.\n\n' "$rc" "$head" "$trunk" "${base:0:9}"
    if [ -n "$fails" ]; then
        printf 'Failing lines (first 20 distinct, from the gate log):\n\n```\n%s\n```\n\nLast lines of the gate log:\n\n' "$fails"
    fi
    printf '```\n%s\n```\n\nThe queue continued with the next candidate. Fix and the queue will pick it up again.\n' "$tail5"
}

# delta_plan_only <from> <to> — 0 when every path changed between the two commits
# classifies as plan-ledger (a move that cannot invalidate a gate verdict). Sets
# _delta_classes. An empty or unreadable answer is NOT plan-only (re-queue).
# Shared by the first adopt and the post-refusal push retry (1839-fuvg).
delta_plan_only() {
    local _c
    _delta_classes="$(git diff --name-only "$1" "$2" 2>/dev/null \
                      | bash "$_SELF_DIR/gate-stamp.sh" classify 2>/dev/null)"
    [ -n "$_delta_classes" ] || return 1
    while IFS= read -r _c; do
        [ -n "$_c" ] || continue
        [ "$_c" = "plan-ledger" ] || return 1
    done <<< "$_delta_classes"
    return 0
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

# ── ORDER 1839-fuvg: GATE LOGS OF EVICTED CANDIDATES ARE KEPT ────────────────
# Every eviction used to be diagnosed from a 5-line excerpt because the gate log
# was a temp file deleted on the way out. They now live in a per-run directory
# under the checkout's (gitignored) target/, and the evict line and PR comment
# name the path. Retention is bounded: only the newest N run directories stay.
# @trace order:1839-fuvg
_LOGROOT="${TILLANDSIAS_LAND_QUEUE_LOGDIR:-$ROOT/target/land-queue-logs}"
_LOGKEEP="${TILLANDSIAS_LAND_QUEUE_LOG_KEEP:-10}"
_RUNDIR="$_LOGROOT/$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$_RUNDIR" 2>/dev/null || _RUNDIR="$(mktemp -d "${TMPDIR:-/tmp}/land-queue-logs.XXXXXX")"
{ ls -1d "$_LOGROOT"/*/ 2>/dev/null | sort | awk -v k="$_LOGKEEP" '{a[NR]=$0} END{for(i=1;i<=NR-k;i++)print a[i]}' | while IFS= read -r _old; do
    [ "${_old%/}" = "$_RUNDIR" ] || rm -rf "${_old%/}"
  done; } 2>/dev/null || true

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
_deferred=""
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
# ORDER 1765-q7rg: TWO PASSES. Pass 1 is the queue; pass 2 re-gates, once, the
# candidates pass 1 deferred for a flaky: verdict, at the back of the run. A
# second flaky: in pass 2 evicts. --limit counts pass-1 candidates only.
for _pass in 1 2; do
if [ "$_pass" -eq 2 ]; then
    [ -n "$_deferred" ] || break
    _cands="$_deferred"; _deferred=""
fi
while IFS=$'\t' read -r num head <&3; do
    [ -n "$num" ] || continue
    if [ "$_pass" -eq 1 ]; then
        if [ "$LIMIT" -gt 0 ] && [ "$_n" -ge "$LIMIT" ]; then break; fi
        _n=$((_n + 1))
    fi

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

    # ── ORDER 1765-q7rg: A HEAD THIS QUEUE ALREADY REJECTED IS NOT RE-GATED ──
    # Measured: ~44 min in one session (#488, #498) re-gating heads the queue
    # had just evicted, onto a trunk that had moved only in the ledger. When
    # the PR's newest eviction marker names THIS head and the trunk delta since
    # that eviction's base is empty or plan-ledger only — the 1335-2nzf adopt
    # classifier, never a time window — the verdict would be the same, so skip.
    # A conflict is not skipped here (the merge is cheap and answers it again,
    # and the auto-draft below acts on a repeat); neither is a flaky eviction,
    # whose whole meaning is that the same head may pass.
    _last="$(last_eviction "$num")"
    _last_head="$(marker_field "$_last" head)"
    _last_base="$(marker_field "$_last" base)"
    _last_reason="$(marker_field "$_last" reason)"
    if [ -n "$_last" ] && [ "$_last_head" = "$head_sha" ]; then
        case "$_last_reason" in
            gate-failed|preflight-failed|carried-*|native-lint-*)
                # An allow-list: a conflict, a flaky or aborted gate, or any reason a
                # later change adds is re-gated, never skipped.
                _sdelta=""; _sclasses=""; _stale=0
                if git cat-file -e "$_last_base^{commit}" 2>/dev/null; then
                    _sdelta="$(git diff --name-only "$_last_base" "$base_sha" 2>/dev/null)"
                    [ -n "$_sdelta" ] || _sclasses="unchanged-base"
                    if [ -z "$_sdelta" ]; then
                        _stale=1
                    else
                        _sclasses="$(printf '%s\n' "$_sdelta" | bash "$_SELF_DIR/gate-stamp.sh" classify 2>/dev/null)"
                        if [ -n "$_sclasses" ]; then
                            _stale=1
                            while IFS= read -r _c; do
                                [ -n "$_c" ] || continue
                                [ "$_c" = "plan-ledger" ] || { _stale=0; break; }
                            done <<< "$_sclasses"
                        fi
                    fi
                fi
                if [ "$_stale" -eq 1 ]; then
                    say "skip:land-queue:$num:stale-head:${head_sha:0:9}:last=$_last_reason:since=${_last_base:0:9}:classes=$(printf '%s' "${_sclasses:-none}" | tr '\n' ',' | sed 's/,$//') — evicted at this head and trunk moved only in the ledger; push a new head to re-enter"
                    skipped=$((skipped + 1))
                    continue
                fi
                ;;
        esac
    fi

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
        _creason="conflict:$(printf '%s' "$_conf" | sed 's/ *$//' | tr ' ' ',')"
        # ORDER 1765-q7rg: THE SECOND IDENTICAL CONFLICT AT AN UNCHANGED HEAD
        # DRAFTS THE PR. The queue re-merges it every run and gets the same
        # answer; only the author can change it, so take it out of the queue
        # (a draft is not a candidate) and say so where the author will look.
        _drafted=""
        if [ "$_last_head" = "$head_sha" ] && [ "$_last_reason" = "$_creason" ]; then
            if [ "$DRY_RUN" -eq 1 ]; then
                say "dry-run: would convert #$num to draft"
            elif "$GH" pr ready "$num" --undo >/dev/null 2>&1; then
                _drafted=1
                say "draft:land-queue:$num:repeat-conflict:${head_sha:0:9}"
            else
                say "advisory:land-queue:$num:draft-failed — the PR stays in the queue"
            fi
        fi
        pr_comment "$num" "Evicted from the landing queue: merging with \`$TRUNK\` at \`${base_sha:0:9}\` conflicts in: $_conf

Rebase or merge \`$TRUNK\` into \`$head\` and the queue will pick it up again. The queue continued with the next candidate.${_drafted:+

This is the second identical conflict at this unchanged head (\`${head_sha:0:9}\`), so the queue converted this PR to a **draft**. Resolve the conflict, push, and mark it ready for review to re-enter the queue.}$(evict_marker "$num" "$head_sha" "$base_sha" "$_creason")"
        evicted=$((evicted + 1))
        rm -f "$_mlog"
        continue
    fi
    rm -f "$_mlog"
    merge_sha="$(git rev-parse HEAD)"

    # ── A FROZEN TARGET HOLDS CODE (1255-s4im) ───────────────────────────────
    # Asked BEFORE the gate, so no gate is spent on a landing the freeze would
    # refuse, and asked of ORIGIN by the tool itself: the pre-push hook refuses
    # this only on a host whose hook is armed. A candidate that carries only
    # paths the freeze exempts (ledger, docs, skills, cheatsheets) still lands —
    # that is how coordination keeps moving during a cut. HOLD is not EVICT: the
    # candidate is fine, the branch is closed; it lands after the freeze clears.
    _held="$(freeze_held_paths "$base_sha" "$merge_sha" | head -n 1)"
    if [ -n "$_held" ]; then
        _frc=0; _fm="$(freeze_markers "$REMOTE" "$TRUNK")" || _frc=$?
        if [ "$_frc" -ne 0 ]; then
            say "hold:land-queue:$num:freeze-unknown — git ls-remote $REMOTE failed, and this candidate carries held code ($_held); not gating into a branch whose freeze state is unknown"
            skipped=$((skipped + 1))
            continue
        fi
        if [ -n "$_fm" ]; then
            say "hold:land-queue:$num:frozen:$(printf '%s\n' "$_fm" | head -n 1 | cut -f2) — carries held code ($_held); it lands after the freeze clears"
            skipped=$((skipped + 1))
            continue
        fi
    fi

    # ── WHAT THE CANDIDATE OWES ITS CARRIED OBLIGATIONS (1577-568c) ──────────
    # methodology/convergence.yaml carried_obligations escalates only on a
    # MEASURED stall, so every landing records, per backlog, whether it paid,
    # waived, owed nothing or stayed silent: one `Carried: <backlog> <state>
    # [<item-or-reason>]` trailer each on the land commit, which makes the tally
    # one `git log --first-parent --format=%(trailers:key=Carried,valueonly)`.
    # Asked BEFORE the gate, so no gate is spent on a candidate this evicts.
    # The guard is THIS script's sibling; the rule it reads is the merged tree's.
    #
    # A guard that cannot judge (no runner, no backlog table) is NOT an
    # eviction: the obligation is gentle and the gate runs the same guard. The
    # land commit then carries no Carried trailer and says so here.
    # A tree with no rule (methodology/convergence.yaml absent) is not asked:
    # the runner writes its audit under the repo root, and a repo that does not
    # ignore it would then read dirty to the next landing.
    _cout="$(mktemp)"; _cerr="$(mktemp)"
    if [ -f methodology/convergence.yaml ]; then
        env TILLANDSIAS_REPO_ROOT="$ROOT" TILLANDSIAS_CARRIED_BASE="$base_sha" \
            TILLANDSIAS_CARRIED_HEAD="$head_sha" TILLANDSIAS_CARRIED_REF="$head" \
            "$PLAN" script run "$_SELF_DIR/lua/check-carried-obligations.lua" -- --landing \
            < /dev/null > "$_cout" 2> "$_cerr"
        _crc=$?
    else
        printf 'skip:carried-obligations:no-rule-in-tree\n' > "$_cout"
        _crc=0
    fi
    _carried="$(sed -n 's/^carried:\([^:]*\):\([^:]*\):\{0,1\}\(.*\)$/Carried: \1 \2 \3/p' "$_cout" | sed 's/ *$//')"
    _cverdict="$(tail -n 1 "$_cout")"
    _cwaiver="$(grep '^Carried-Waiver: ' "$_cerr" | head -n 1)"
    rm -f "$_cout" "$_cerr"
    if [ "$_crc" -eq 1 ]; then
        # violation:carried:<backlog>:<silent|waiver-not-a-trailer>
        _cb="$(printf '%s' "$_cverdict" | cut -d: -f3)"
        _ck="$(printf '%s' "$_cverdict" | cut -d: -f4)"
        _cdue="$(printf '%s\n' "$_carried" | grep "^Carried: $_cb due " | head -n 1 | sed "s/^Carried: $_cb due //")"
        say "evict:land-queue:$num:carried-$_ck:$_cb"
        say "  add to the LAST paragraph of a commit on $head: ${_cwaiver:-Carried-Waiver: $_cb <reason>}  (or port ${_cdue:-one item})"
        pr_comment "$num" "Evicted from the landing queue: \`$head\` touches the \`$_cb\` carried-obligation area and neither pays an item nor carries a waiver trailer git can read ($_ck). See methodology/convergence.yaml → carried_obligations.

Pay it: port ${_cdue:-one item} to scripts/lua/ and delete the .sh. Or waive it with this line in the LAST paragraph of a commit message on \`$head\` (git reads trailers only there):

\`\`\`
${_cwaiver:-Carried-Waiver: $_cb <reason>}
\`\`\`

The queue continued with the next candidate.$(evict_marker "$num" "$head_sha" "$base_sha" "carried-$_ck:$_cb")"
        evicted=$((evicted + 1))
        continue
    fi
    if [ "$_crc" -eq 0 ] && [ -n "$_carried" ]; then
        git -c user.name=land-queue -c user.email=land-queue@localhost \
            commit -q --amend -m "land($num): $head into $TRUNK" -m "$_carried" >/dev/null 2>&1 \
            || say "advisory:land-queue:$num:carried-trailer-not-written — the landing proceeds without it"
        merge_sha="$(git rev-parse HEAD)"
    else
        say "advisory:land-queue:$num:carried-unjudged:rc=$_crc:${_cverdict:-no-verdict} — no Carried trailer on this landing"
    fi

    # ── A CFG-GATED PLATFORM CRATE NEEDS A NATIVE LINT (1235-rfub) ───────────
    # The gate below compiles crates/tillandsias-macos-tray as STUBS on this
    # host and cannot lint it, so a macOS-only clippy hard error passes it
    # (d44909353 reddened trunk for every Mac that way). The relay tool has
    # refused such a change since 2026-09-28, but every landing now comes
    # through THIS queue, which never asked: on 2026-10-21 land(594) put a new
    # tray source on trunk with no Native-Lint attestation in its range.
    # Asked of the merge against the gated base, so the range is exactly the
    # candidate's commits. The env override is STRIPPED: one exported reason
    # would excuse every candidate in the run. The per-candidate override is a
    # `Native-Lint-Unattested: <reason>` trailer on the work ref, and the debt
    # is repeated on the land commit so a first-parent log tallies it.
    if [ -f "$_SELF_DIR/check-native-lint-attested.sh" ]; then
        _nlout="$(mktemp "${TMPDIR:-/tmp}/land-queue-native-lint.XXXXXX")"; _nlerr="$(mktemp "${TMPDIR:-/tmp}/land-queue-native-lint.XXXXXX")"
        env -u TILLANDSIAS_NATIVE_LINT_UNATTESTED -u TILLANDSIAS_NATIVE_LINT_BASE \
            bash "$_SELF_DIR/check-native-lint-attested.sh" --base "$base_sha" \
            < /dev/null > "$_nlout" 2> "$_nlerr"
        _nlrc=$?
        _nlverdict="$(head -n 1 "$_nlout")"
        _nlwhy="$(cat "$_nlerr")"
        _nldebt="$(sed -n 's/^override:native-lint:unattested://p' "$_nlout")"
        rm -f "$_nlout" "$_nlerr"
        if [ "$_nlrc" -ne 0 ]; then
            # refused:native-lint:<unattested|stale>:<pkg>
            _nlkind="$(printf '%s' "$_nlverdict" | cut -d: -f3)"
            _nlpkg="$(printf '%s' "$_nlverdict" | cut -d: -f4)"
            say "evict:land-queue:$num:native-lint-${_nlkind:-unjudged}:${_nlpkg:-rc=$_nlrc}"
            say "  accountable: the AUTHORING darwin host — run scripts/attest-native-lint.sh on $head there and push it"
            pr_comment "$num" "Evicted from the landing queue: \`$head\` changes a cfg-gated platform crate that this gate compiles as stubs and cannot lint, and no host attested a native lint of exactly this content (\`${_nlverdict:-no verdict, rc=$_nlrc}\`, order 1235-rfub).

**Accountable: the authoring host of the crate's platform (darwin for \`tillandsias-macos-tray\`).** On that host, check out \`$head\`, run \`scripts/attest-native-lint.sh\` (it runs \`cargo clippy -p <crate> --all-targets -- -D warnings\` and commits a \`Native-Lint:\` trailer only if it passes), and push. The queue picks the new head up.

With no such host available the land waits, or add this line to the LAST paragraph of a commit message on \`$head\` to land it as recorded, unlinted debt:

\`\`\`
Native-Lint-Unattested: <reason>
\`\`\`

\`\`\`
$_nlwhy
\`\`\`$(evict_marker "$num" "$head_sha" "$base_sha" "native-lint-${_nlkind:-unjudged}:${_nlpkg:-rc=$_nlrc}")"
            evicted=$((evicted + 1))
            continue
        fi
        if [ -n "$_nldebt" ]; then
            _nltr=()
            while IFS= read -r _d; do
                [ -n "$_d" ] && _nltr+=(--trailer "Native-Lint-Unattested: $_d")
            done <<< "$_nldebt"
            git -c user.name=land-queue -c user.email=land-queue@localhost \
                commit -q --amend --no-edit "${_nltr[@]}" >/dev/null 2>&1 \
                || say "advisory:land-queue:$num:native-lint-debt-trailer-not-written — the candidate's own trailer still records it"
            merge_sha="$(git rev-parse HEAD)"
            say "debt:land-queue:$num:native-lint-unattested:$(printf '%s' "$_nldebt" | head -n 1) — lands UNLINTED on the candidate's named reason"
        fi
    fi

    # ── GATE THE MERGE RESULT ────────────────────────────────────────────────
    if [ "$DRY_RUN" -eq 1 ]; then
        say "dry-run: would gate ${merge_sha:0:9} then push to $TRUNK"
        continue
    fi
    # ── ORDER 1765-q7rg: THE PREFLIGHT DOOR BEFORE THE FULL GATE ─────────────
    # The tree-only deciders answer in about a minute; a decider-level red
    # (exit 1) here is the same red the full gate would reach after ~21 min.
    # A stale plan binary on THIS host also exits 1 but says nothing about the
    # candidate, and any other code is the door failing to run: both go on to
    # the full gate, which decides as it always did.
    if [ -n "$PREFLIGHT" ]; then
        _plog="$_RUNDIR/pr-$num-preflight.log"
        ( eval "$PREFLIGHT" ) < /dev/null > "$_plog" 2>&1
        _prc_pf=$?
        if [ "$_prc_pf" -eq 1 ] && ! grep -q 'refused:preflight:stale-plan-binary' "$_plog"; then
            say "evict:land-queue:$num:preflight-failed:rc=1 — full log kept at $_plog"
            pr_comment "$num" "$(gate_failed_comment "$_plog" 1 "$head" "$TRUNK" "$base_sha" | sed '1s/the gate failed/the preflight door (`build.sh --preflight`) refused/')

Full preflight log kept on the landing host at \`$_plog\`.$(evict_marker "$num" "$head_sha" "$base_sha" preflight-failed)"
            evicted=$((evicted + 1))
            continue
        elif [ "$_prc_pf" -ne 0 ]; then
            say "advisory:land-queue:$num:preflight-not-decisive:rc=$_prc_pf — running the full gate"
        fi
        rm -f "$_plog"
    fi

    _glog="$_RUNDIR/pr-$num-gate.log"
    # No pipeline: a `$GATE | tee` would hand us tee's status, which is the
    # 859-4jny bug one layer over.
    ( eval "$GATE" ) < /dev/null > "$_glog" 2>&1
    _grc=$?
    if [ "$_grc" -ne 0 ]; then
        # ORDER 1765-q7rg: A flaky:<step>:<verdicts> line is the step runner's
        # word that a host-state step disagreed with itself twice on this host
        # (STEP_HOST_STATE). The first such red re-queues the candidate ONCE at
        # the back of this run; a second evicts like any red.
        _flaky="$(grep -m 1 '^flaky:' "$_glog" 2>/dev/null)"
        if [ -n "$_flaky" ] && [ "$_pass" -eq 1 ]; then
            say "requeue:land-queue:$num:$_flaky — re-gating once at the back of the queue"
            _deferred="${_deferred}${num}	${head}"$'\n'
            requeued=$((requeued + 1))
            rm -f "$_glog"
            continue
        fi
        say "evict:land-queue:$num:gate-failed:rc=$_grc${_flaky:+:$_flaky} — full gate log kept at $_glog"
        # Only rc=1 is the gate's verdict on the tree. Any other code (255 is a host
        # going down mid-run, 137 a kill) says nothing about the candidate, so it
        # is recorded as gate-aborted, which the stale-head skip never acts on.
        if [ -n "$_flaky" ]; then _greason=flaky
        elif [ "$_grc" -eq 1 ]; then _greason=gate-failed
        else _greason="gate-aborted:rc=$_grc"; fi
        pr_comment "$num" "$(gate_failed_comment "$_glog" "$_grc" "$head" "$TRUNK" "$base_sha")

Full gate log kept on the landing host at \`$_glog\`.$(evict_marker "$num" "$head_sha" "$base_sha" "$_greason")"
        evicted=$((evicted + 1))
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
        _adoptable=1
        delta_plan_only "$base_sha" "$base_now" || _adoptable=0

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

    # ── A FREEZE SET WHILE THIS GATED IS NOT PUSHED THROUGH (1255-s4im) ──────
    # The gate takes 40 minutes and a cut can freeze the branch inside that
    # window. The hook re-asks at push on a hooked host; the tool re-asks here
    # so the answer does not depend on which host runs the queue. Recomputed
    # from the CURRENT base, because an adopt above may have moved it.
    _held="$(freeze_held_paths "$base_sha" "$merge_sha" | head -n 1)"
    if [ -n "$_held" ]; then
        _frc=0; _fm="$(freeze_markers "$REMOTE" "$TRUNK")" || _frc=$?
        if [ "$_frc" -ne 0 ] || [ -n "$_fm" ]; then
            say "requeue:land-queue:$num:frozen-mid-gate:$( [ "$_frc" -ne 0 ] && echo "freeze-unknown" || printf '%s\n' "$_fm" | head -n 1 | cut -f2) — the gate was green but $TRUNK froze while it ran and this carries held code ($_held); nothing was pushed"
            requeued=$((requeued + 1))
            continue
        fi
    fi

    # ── PUSH, AND PROVE IT LANDED BY ASKING THE REMOTE ───────────────────────
    # ORDER 1839-fuvg: the push's own output is KEPT (it was >/dev/null, so a
    # hook refusal and a lost race both read "push-did-not-land:rc=1"), and a
    # push refused because the remote moved by ledger fragments alone is
    # re-fetched, re-adopted and retried (bounded) instead of re-gated.
    _pushtry=1; _pushmax=3; _landed_ok=0; _pout=""
    while :; do
        _pout="$(git push "$REMOTE" "HEAD:refs/heads/$TRUNK" 2>&1)"
        _prc=$?
        git fetch -q "$REMOTE" "$TRUNK" 2>/dev/null || true
        if git merge-base --is-ancestor "$merge_sha" "$REMOTE/$TRUNK" 2>/dev/null; then
            _landed_ok=1; break
        fi
        [ "$_pushtry" -lt "$_pushmax" ] || break
        _base_again="$(git rev-parse "$REMOTE/$TRUNK" 2>/dev/null)" || break
        [ "$_base_again" != "$base_sha" ] || break          # not a race: a real refusal
        delta_plan_only "$base_sha" "$_base_again" || break # moved by more than the ledger
        git merge --no-ff -q -m "land($num): $head into $TRUNK (adopted over a plan-only move)" \
            "$_base_again" >/dev/null 2>&1 || { git merge --abort 2>/dev/null || true; break; }
        merge_sha="$(git rev-parse HEAD)"
        base_sha="$_base_again"
        _pushtry=$((_pushtry + 1))
        say "adopt:land-queue:$num:plan-only-move-at-push:attempt=$_pushtry gated-on=${base_sha:0:9} — push refused while $TRUNK moved by ledger fragments only; re-adopted and retrying"
    done
    if [ "$_landed_ok" -eq 1 ]; then
        say "land:$num tier=full gate=green base=${base_sha:0:9} head=${head_sha:0:9} merge=${merge_sha:0:9}"
        say "  not-run: nothing — tier=full runs the whole gate"
        landed=$((landed + 1))
        continue
    fi
    say "requeue:land-queue:$num:push-did-not-land:rc=$_prc — the remote does not have ${merge_sha:0:9}"
    printf '%s\n' "$_pout" | tail -n 20 | sed 's/^/  push-output: /'
    pr_comment "$num" "Re-queued, not landed: the push of \`${merge_sha:0:9}\` to \`$TRUNK\` was refused (rc=$_prc) after a green gate. The push command said:

\`\`\`
$(printf '%s\n' "$_pout" | tail -n 20)
\`\`\`

The queue will re-gate on its next pass."
    requeued=$((requeued + 1))
done 3<<< "$_cands"
done

say "ok:land-queue:$_n landed=$landed evicted=$evicted requeued=$requeued skipped=$skipped"
exit 0
