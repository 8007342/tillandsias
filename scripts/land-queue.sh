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
# the land-queue fixtures (scripts/lua/test-land-queue-*.lua) move it from inside the stub gate rather than
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
#   TILLANDSIAS_LAND_QUEUE_GH_LIST_LIMIT=N  (default 500) rows asked of `gh pr list`;
#       a capture that long is refused as possibly truncated (1959-tdn5)
#
# Exit: 0 the run completed (landed, evicted and re-queued counts on stdout)
#       1 could not read the queue (gh missing, unauthenticated, bad JSON)
#       2 the working tree is dirty — this script rewrites HEAD and refuses to
#         do that over uncommitted work
#       3 another landing is in flight (the lock is held)
#       4 held on a trunk red: hold:trunk-red:<test> (2118-tpmy); nobody evicted
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
#
# ORDER 2152-lqrf (build speed, operator ruling 2026-11-21: a land takes
# minutes): OFF BY DEFAULT. The door's roster is built FROM the gate's own steps
# and deciders (build.sh _preflight_roster), so on every candidate the gate
# passes it re-ran work the gate runs anyway — the duplicate preflight the
# build-speed investigation measured. Its only gain was evicting a red ~20 min
# earlier; admission (land-admit.sh, P6) is where a cheap early refusal now
# lives. Set TILLANDSIAS_LAND_QUEUE_PREFLIGHT='./build.sh --preflight' to restore.
PREFLIGHT="${TILLANDSIAS_LAND_QUEUE_PREFLIGHT-}"
# ORDER 1992-lqpb: rebuild tillandsias-plan from the MERGE RESULT and let
# check-plan-binary-current.sh install it, before the preflight and the gate.
# A stale ~/.local/bin/tillandsias-plan otherwise failed fixtures inside the
# gate (test-pre-push-plan-lane-fails-closed-without-binary, a plan-lane
# refusal) and the queue evicted an innocent candidate; the fix was a hand
# rebuild. A refresh that fails stops the run with no eviction. Set to the
# empty string to disable (the fixture's default).
PLAN_REFRESH="${TILLANDSIAS_LAND_QUEUE_PLAN_REFRESH-cargo build -q --release -p tillandsias-plan && bash scripts/check-plan-binary-current.sh}"
# ORDER 2152-lqrf (build speed): THE REFRESH IS SKIPPED WHEN ITS INPUTS DID NOT
# CHANGE. The inputs are what CARGO says they are: the dep-info file it writes
# beside the binary lists every source the build read, out-of-crate
# include_str! files included, so the key cannot drift from the build the way a
# hand-kept path list would. Key = git blob ids of those files + Cargo.lock +
# rust-toolchain.toml + the binary itself, stamped after each successful
# refresh. A missing dep-info, binary or listed file means no key, and the
# refresh runs as before. Not covered: RUSTFLAGS or toolchain installs changing
# under an unchanged rust-toolchain.toml.
PLAN_DEPINFO="${TILLANDSIAS_LAND_QUEUE_PLAN_DEPINFO:-${CARGO_TARGET_DIR:-target}/release/tillandsias-plan.d}"
PLAN_REFRESH_STAMP="${TILLANDSIAS_LAND_QUEUE_PLAN_REFRESH_STAMP:-${CARGO_TARGET_DIR:-target}/land-queue-plan-refresh.key}"
# ORDER 2143-z5uj, operator ruling 2026-11-20: a plan-ledger-only candidate
# lands on the plan-lane checks with no build-check. 1 (default) is on; 0 sends
# every candidate through the full gate. PLAN_LANE_CHECK is what the plan lane
# runs instead of GATE: the binary's own check parses every fragment and
# validates the ledger, exactly as the plan-only push lane does.
PLAN_ONLY_LANE="${TILLANDSIAS_LAND_QUEUE_PLAN_ONLY_LANE:-1}"
PLAN_LANE_CHECK="${TILLANDSIAS_LAND_QUEUE_PLAN_LANE_CHECK-\"\$PLAN\" check}"
# ORDER 2118-tpmy (operator 2026-11-20, P11): THE HOST DOOR, asked before every
# candidate. could-not-run:host:<cause> is about THIS host, so nobody is evicted
# and the run goes on. A missing router sidecar is staged first (the gate's own
# preamble stages it, so a fresh queue checkout would otherwise never pass).
# Set either to the empty string to disable (the fixture's default).
HOST_DOOR="${TILLANDSIAS_LAND_QUEUE_HOST_DOOR-\"\$PLAN\" script run scripts/lua/land-queue-host-door.lua}"
SIDECAR_STAGE="${TILLANDSIAS_LAND_QUEUE_SIDECAR_STAGE-[ -e images/router/tillandsias-router-sidecar ] || bash scripts/build-sidecar.sh}"
# ORDER 2118-tpmy: before an evicted:<test> red evicts, the bare trunk is gated
# once; the same failing test there is hold:trunk-red:<test>: the queue holds
# and reports, nobody is evicted. Remembered per trunk base (bounded: one trunk
# gate per base). 0 disables.
TRUNK_RED_CHECK="${TILLANDSIAS_LAND_QUEUE_TRUNK_RED_CHECK:-1}"
TRUNK_RED_MEMO="${TILLANDSIAS_LAND_QUEUE_TRUNK_RED_MEMO:-$ROOT/.git/tillandsias-land-queue-trunk-red}"
REMOTE="${TILLANDSIAS_LAND_QUEUE_REMOTE:-origin}"
TRUNK="${TILLANDSIAS_TRUNK_BRANCH:-linux-next}"
LOCKDIR="${TILLANDSIAS_LAND_QUEUE_LOCK:-$ROOT/.git/tillandsias-land-queue.lock}"
# A work ref's grammar, from methodology/multi-host-development.yaml's
# creation_regex. A PR whose head is not one of these is not a queue entry.
WORK_RE='^work/[0-9]{3,4}-[a-z0-9]{4}$'

LIMIT=0
DRY_RUN=0
DAILY_FULL=0
STATUS=0
STATUS_PR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --limit)   LIMIT="${2:-0}"; shift 2 ;;
        --limit=*) LIMIT="${1#*=}"; shift ;;
        --base)    TRUNK="${2:-$TRUNK}"; shift 2 ;;
        --base=*)  TRUNK="${1#*=}"; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --daily-full) DAILY_FULL=1; shift ;;
        --status) STATUS=1; shift ;;
        --pr)      # read-only: it always implies --status, and never runs the queue
            STATUS=1; STATUS_PR="${2:-}"; STATUS_PR="${STATUS_PR#\#}"
            [[ "$STATUS_PR" =~ ^[0-9]{1,7}$ ]] || { echo "fail:land-queue:pr-needs-a-number:${2:-}" >&2; exit 1; }
            shift 2 ;;
        *) echo "fail:land-queue:unknown-argument:$1" >&2; exit 1 ;;
    esac
done

landed=0; evicted=0; requeued=0; skipped=0; _held=0  # the 2118-tpmy trunk-red FLAG (0|1); the freeze check's path list is _frz_paths (2152-lqrf: one name for both erased a hold)

say() { printf '%s\n' "$*"; }
# ORDER 2238-gpxz: WHERE A LAND'S WALL CLOCK GOES. One line per stage of each
# candidate, seconds since the previous mark: merge+door (merge, sidecar, host
# door), plan-refresh, preflight, gate, post-gate+push (a flaky re-run, the
# trunk-red check, the push and its retries). Measured
# 2026-11-22 on macuahuitl: the gate averaged ~13 min while a land took ~30, and
# nothing said where the other ~17 went. A stage a candidate never reaches
# prints nothing, so the last line names where it stopped.
_lq_mark() { say "timing:land-queue:#$1:$2=$((SECONDS - ${_LQ_T:-$SECONDS}))s"; _LQ_T=$SECONDS; }

# ORDER 2416-57a6: A NEW GATE STEP WHOSE PREFIX IS TAKEN MOVES INSIDE ITS OWN
# LANDING. allocate-gate-step-prefix.sh (1162-qbrx) renames the added step to a
# free slot; its only caller was land-on-platform-branch.sh, so two refs adding
# one prefix both landed through this queue (960 collided 2026-11-26). Called on
# the merge commit just made: <base> is the trunk it merged onto, <exclude> the
# tree before this member (a train's earlier members keep their slots). The
# renames are folded into that merge commit, so a train stays one merge per
# member. rc 1 = the allocator refused; the tree is as the merge left it.
_lq_alloc_steps() { # <num> <base> [<exclude>]
    [ -f "$_SELF_DIR/allocate-gate-step-prefix.sh" ] || return 0
    local _a=(--base "$2") _o _rc=0
    [ -z "${3:-}" ] || _a+=(--exclude "$3")
    _o="$(bash "$_SELF_DIR/allocate-gate-step-prefix.sh" "${_a[@]}" 2>&1)" || _rc=$?
    _lq_alloc_verdict="${_o##*$'\n'}"
    case "$_lq_alloc_verdict" in
        ok:gate-step-prefix:reallocated:*)
            git -c user.name=land-queue -c user.email=land-queue@localhost commit -q --amend --no-edit >/dev/null 2>&1 || {
                git reset -q --hard HEAD 2>/dev/null; _lq_alloc_verdict="refused:gate-step-prefix:amend-failed"; return 1; }
            printf '%s\n' "$_o" | sed -n "s/^gate-step-prefix: /gate-step-prefix:#$1: /p"
            return 0 ;;
        ok:*) return 0 ;;
    esac
    [ "$_rc" -ne 0 ] || _lq_alloc_verdict="refused:gate-step-prefix:no-verdict"
    return 1
}

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
# plan_refresh_key — the content key of the plan binary's build inputs, or
# nothing (rc 1) when it cannot be formed. See PLAN_DEPINFO above (2152-lqrf).
plan_refresh_key() {
    local d="$PLAN_DEPINFO" bin deps f
    bin="${d%.d}"
    [ -f "$d" ] && [ -f "$bin" ] || return 1
    # Make syntax: "<target>: dep dep \<newline> dep"; a space inside a path is
    # "\ ". Join continuations, drop the target, split on unescaped spaces.
    # One awk for BSD and GNU alike (no sed \n or \x escapes).
    deps="$(awk '{ l = l $0; if (sub(/\\$/, "", l)) { l = l " "; next }; exit }
        END { sub(/^[^:]*: */, "", l); gsub(/\\ /, "\037", l); n = split(l, a, " ")
              for (i = 1; i <= n; i++) { gsub("\037", " ", a[i]); print a[i] } }' "$d")"
    [ -n "$deps" ] || return 1
    {
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            # A build script's rerun-if-changed DIRECTORY is listed as the dir:
            # key every file under it (sorted, so the order is stable).
            if [ -d "$f" ]; then find "$f" -type f 2>/dev/null | LC_ALL=C sort; continue; fi
            [ -f "$f" ] || return 1
            printf '%s\n' "$f"
        done <<< "$deps"
        for f in Cargo.lock rust-toolchain.toml "$bin"; do [ -f "$f" ] && printf '%s\n' "$f"; done
    } > "$_RUNDIR/plan-refresh-inputs" || return 1
    git hash-object --stdin-paths < "$_RUNDIR/plan-refresh-inputs" 2>/dev/null \
        | git hash-object --stdin 2>/dev/null
}

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
# ORDER 2209-dfix: A HELD LOCK IS SAID FIRST, AND ON BOTH STREAMS. The 03:42
# timer --daily-full on macuahuitl (2026-11-22) exited with nothing in its log
# while run 28 held the lock: a live queue leaves the checkout mid-merge, so the
# dirty-tree refusal (or the in-flight skip) is what a second caller meets, and
# neither named the holder where the timer looks. --daily-full now WAITS for the
# holder (up to TILLANDSIAS_LAND_QUEUE_DAILY_LOCK_WAIT_S, default 3 h), saying
# so; any other caller is told who holds it and exits 3.
_lock_holder() { local _h; _h="$(cat "$LOCKDIR/pid" 2>/dev/null || true)"; [ -n "$_h" ] && kill -0 "$_h" 2>/dev/null && printf '%s\n' "$_h"; }

# ── ORDER 2248-jihs: `--status` — WHAT IS THE QUEUE DOING, WITHOUT THE LOCK ──
# One line, read-only, never takes or waits on the lock:
#   queue:gating:#N work/<ref> phase=<p> elapsed=<s> train=<members|-> waiting=<n>
#   queue:idle last-land=<sha> <age>s
# The running queue writes the gating line to $_RUNDIR/current at the start of
# every phase (and $_LOGROOT/current-run names that dir), so a reader asks the
# file, not the process. The same line is published to
# refs/tillandsias/queue/status (a commit whose message is the line) so a host
# that is not the lander can read it with `git fetch`. Publishing is
# best-effort and bounded (20 s); TILLANDSIAS_LAND_QUEUE_STATUS_PUBLISH=0 or
# --dry-run turns it off.
_LQ_LOGROOT0="${TILLANDSIAS_LAND_QUEUE_LOGDIR:-$ROOT/target/land-queue-logs}"
_lq_idle_line() {
    local _l _now
    _l="$(git log -1 --format='%H %ct' --grep='^land(' "$REMOTE/$TRUNK" 2>/dev/null)"
    _now="$(date +%s)"
    if [ -n "$_l" ]; then printf 'queue:idle last-land=%s %ss\n' "${_l%% *}" "$((_now - ${_l#* }))"
    else printf 'queue:idle last-land=none\n'; fi
}
_lq_render() { # <stored line with started=<epoch>> -> the line with elapsed=<s>
    local _st; _st="$(printf '%s' "$1" | sed -n 's/.* started=\([0-9]*\).*/\1/p')"
    [ -n "$_st" ] || { printf '%s\n' "$1"; return; }
    printf '%s\n' "$1" | sed "s/ started=[0-9]*/ elapsed=$(( $(date +%s) - _st ))/"
}
_lq_publish() { # <line> [more lines, as the commit's body]
    [ "${TILLANDSIAS_LAND_QUEUE_STATUS_PUBLISH:-1}" = 1 ] && [ "${DRY_RUN:-0}" -eq 0 ] || return 0
    local _t _c
    _t="$(git hash-object -t tree -w /dev/null 2>/dev/null)" || return 0
    _c="$(printf '%s\n' "$1" ${2:+"" "$2"} | git -c user.name=land-queue -c user.email=land-queue@localhost commit-tree "$_t" 2>/dev/null)" || return 0
    timeout 20 git push -q "$REMOTE" "+$_c:refs/tillandsias/queue/status" </dev/null >/dev/null 2>&1 || true
}
# The lines after the first (2288-vx6k): what `--status` adds and the published commit's body
# carries. They READ files only: $_RUNDIR/next (the queue order left, one number a
# line), $_RUNDIR/bundle (the open train), bundles.log, and the shadow's own lock dir.
_lq_more() { # <run dir or empty> -> queue:next, queue:bundle, queue:shadow
    local _d="$1" _l _n _p _pr _bl="${TILLANDSIAS_LAND_QUEUE_BUNDLE_LOG:-$(dirname "${TILLANDSIAS_LAND_QUEUE_TRAIN_LOG:-$_LQ_LOGROOT0/trains.log}")/bundles.log}"
    local _sk="${TILLANDSIAS_LAND_QUEUE_SHADOW_LOCK:-${XDG_RUNTIME_DIR:-$_LQ_LOGROOT0}/tillandsias-shadow.lock}" _sl="${TILLANDSIAS_LAND_QUEUE_SHADOW_LOG:-$_LQ_LOGROOT0/shadow-intake.log}"
    _n=""; [ -z "$_d" ] || _n="$(tr '\n' ',' < "$_d/next" 2>/dev/null)"
    [ -z "$_d" ] || printf 'queue:next %s\n' "${_n:+#${_n%,}}" | sed 's/,/,#/g; s/ $/ -/'
    if [ -n "$_d" ] && [ -s "$_d/bundle" ]; then _lq_render "$(cat "$_d/bundle")"
    else
        _l="$(grep '^bundle:' "$_bl" 2>/dev/null | tail -n 1)"
        printf 'queue:bundle open=- last=%s\n' "${_l:--}"
    fi
    _p="$(cat "$_sk/pid" 2>/dev/null)"; _pr="$(cat "$_sk/current" 2>/dev/null)"
    if [ -n "$_p" ] && kill -0 "$_p" 2>/dev/null; then
        _l=running; [ ! -e "$_sk/stop" ] || _l=stopping
        printf 'queue:shadow %s pr=%s' "$_l" "${_pr:+#$_pr}" | sed 's/pr=$/pr=-/'
    else printf 'queue:shadow idle pr=-'; fi
    printf ' log=%s lines=%s\n' "$_sl" "$(grep -c '^shadow:accept:' "$_sl" 2>/dev/null || [ -e "$_sl" ] || echo 0)"
}
_lq_pr() { # <run dir or empty> <pr> -> one line: is MY PR gating?
    local _cur _i
    _cur="$(cat "$1/current" 2>/dev/null)"
    case "$_cur" in "queue:gating:#$2 "*) printf 'queue:pr:#%s gating %s\n' "$2" "$(_lq_render "$_cur" | sed 's/^[^ ]* //')"; return ;; esac
    case ",$(sed -n 's/.* train=\([^ ]*\).*/\1/p' <<<"$_cur")," in *",#$2,"*) printf 'queue:pr:#%s gating in-train %s\n' "$2" "$(_lq_render "$_cur" | sed 's/^[^ ]* //')"; return ;; esac
    _i="$(grep -nxF -- "$2" "$1/next" 2>/dev/null | cut -d: -f1)"; _i="${_i%%$'\n'*}"
    if [ -n "$_i" ]; then printf 'queue:pr:#%s waiting position=%s of=%s\n' "$2" "$_i" "$(grep -c . "$1/next")"
    elif [ -n "$_cur" ]; then printf 'queue:pr:#%s not-in-this-run (read once per candidate; landed, evicted, held, a draft, or opened since)\n' "$2"
    else printf 'queue:pr:#%s idle (no run is holding the queue)\n' "$2"; fi
}
_lq_phase() { # <num> <ref> <phase> [train members]
    local _w _line
    _w="$(printf '%s' "${_cands:-}" | grep -c .)"
    _line="queue:gating:#$1 $2 phase=$3 started=$(date +%s) train=${4:--} waiting=$_w"
    printf '%s\n' "$_line" > "$_RUNDIR/current" 2>/dev/null || true
    printf '%s\n' "$_RUNDIR" > "$_LOGROOT/current-run" 2>/dev/null || true
    # The numbers still to come, in queue order: read-only for --status. Not the one gating,
    # not the train's members, not what this run already took.
    printf '%s' "${_cands:-}" | cut -f1 | while IFS= read -r _w; do
        case " ${_seen:-} $1 " in *" $_w "*) continue ;; esac
        case ",${4:-}," in *",#$_w,"*) continue ;; esac
        [ -n "$_w" ] && printf '%s\n' "$_w"
    done > "$_RUNDIR/next" 2>/dev/null || true
    if [ -n "${4:-}" ]; then printf 'queue:bundle open=%s members=%s heavy=%s base=%s phase=%s started=%s\n' "${t_id:--}" "$4" "${heavy_n:--}" "${base:0:9}" "$3" "$(date +%s)" > "$_RUNDIR/bundle" 2>/dev/null || true
    else rm -f "$_RUNDIR/bundle" 2>/dev/null; fi
    _lq_publish "$(_lq_render "$_line")" "$(_lq_more "$_RUNDIR" | sed "s/ log=[^ ]*//")"
}
_lq_idle() {
    local _line; _line="$(_lq_idle_line)"
    rm -f "$_LOGROOT/current-run" 2>/dev/null || true
    _lq_publish "$_line" "$(_lq_more "" | sed "s/ log=[^ ]*//")"
}
if [ "$STATUS" -eq 1 ]; then
    _sd=""; _lock_holder >/dev/null && _sd="$(cat "$_LQ_LOGROOT0/current-run" 2>/dev/null)"
    if [ -n "$STATUS_PR" ]; then _lq_pr "$_sd" "$STATUS_PR"; exit 0; fi
    if _h0="$(_lock_holder)"; then
        _cur="$(cat "$(cat "$_LQ_LOGROOT0/current-run" 2>/dev/null)/current" 2>/dev/null)"
        if [ -n "$_cur" ]; then _lq_render "$_cur"
        else say "queue:gating:? phase=reading-queue holder=$_h0"; fi
    else
        _lq_idle_line
    fi
    _lq_more "$_sd"
    exit 0
fi
if _h0="$(_lock_holder)"; then
    if [ "$DAILY_FULL" -eq 1 ]; then
        _wmax="${TILLANDSIAS_LAND_QUEUE_DAILY_LOCK_WAIT_S:-10800}"; _w=0
        say "land-queue:daily-full:waiting-for-lock:$_h0 (up to ${_wmax}s)" | tee /dev/stderr
        while _h0="$(_lock_holder)"; do
            [ "$_w" -ge "$_wmax" ] && { say "skip:land-queue:daily-full:lock-held:$_h0 — waited ${_w}s" | tee /dev/stderr; exit 3; }
            sleep 30; _w=$((_w + 30))
        done
    else
        say "skip:land-queue:in-flight:$_h0 — one landing at a time, by design" | tee /dev/stderr
        exit 3
    fi
fi
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
    [ -n "${_LOGROOT:-}" ] && _lq_idle  # ORDER 2248-jihs: the status line says idle once the lander is gone
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
#
# ORDER 1959-tdn5: `gh pr list` WITHOUT --limit RETURNS ITS NEWEST 30. Measured
# on macuahuitl 2026-11-02 with 30+ open PRs (drafts count): the oldest ready
# PR, #679, was simply not in the capture, so the queue it drained was a
# smaller queue than existed and the oldest work never landed. So every list
# call names its limit, and a capture EXACTLY as long as the limit is refused
# as possibly truncated rather than landed from — a bigger constant is cheap;
# a silently partial queue is the bug this script exists to remove.
GH_LIST_LIMIT="${TILLANDSIAS_LAND_QUEUE_GH_LIST_LIMIT:-500}"
# ORDER 2143-z5uj: THE QUEUE IS RE-READ BEFORE EVERY CANDIDATE, not once per
# run. A run gates for ~20 min per candidate, so a list read at the start is
# stale by the second: a PR labelled `land:priority` mid-run waited behind
# every lower number, and a PR closed mid-run was still gated. read_queue
# answers 0 with _cands set, or 1 after naming why (a failed READ is never an
# empty queue). <first> = 1 also names drafts and holds, once per run.
#
# ORDER, operator 2026-11-20: `land:priority` first, then PR number. A
# `land:hold` PR is never a candidate and is named every run; it replaces
# draft-as-hold, so a draft is still skipped but the advisory names the label.
# ── ORDER 2174-dail: SMALL GATES PIGGYBACK ON A DAILY FULL RUN ──────────────
# Operator, 2026-11-22: "I approve the small gates piggybacking into a daily
# run for proof." A land gate may SKIP a gate step whose STEP_INPUTS (the class
# selector's grammar, 2118-tnut; never STEP_READS) no change touches — but only
# against a PROOF: a green, unskipped full gate on a trunk commit, published by
# `land-queue.sh --daily-full` as refs/attest/daily-full/<epoch> -> <commit>.
#   - the newest proof must be under DAILY_MAX_AGE_S (24 h) old, an ancestor of
#     the base being gated, and newer than any red daily run
#     (refs/attest/daily-red/<epoch>); otherwise EVERY step runs;
#   - the changed-path set is taken against the PROVED commit
#     (TILLANDSIAS_CLASS_BASE), so changes that landed after the proof count;
#   - the proof's epoch is the "last full gate" the selector's freshness test
#     reads (TILLANDSIAS_FULL_GATE_MARKER), never this host's local marker;
#   - main and release trunks never skip;
#   - every skipped step is named on the land's not-run: line.
# ORDER 2174-dail (coordinator 2026-11-22): A GATE NEVER SEES THE QUEUE'S KNOBS. The
# host's TILLANDSIAS_LAND_QUEUE_* settings (BATCH_K=4 on macuahuitl) reached the
# gate, then the land-queue fixture, then its inner queues, and redded run 26's train;
# ARM 22's stamp leak was the same class. Called first in every gate subshell, so
# the queue keeps its settings and the gate (and its fixtures) inherits none.
# 2215-trad: nor GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE — a caller inside a git hook exports them, and a
# fixture following them writes the REAL .git/config (calmecacpilli 2026-11-22, #1338).
_gate_clean_env() { local _v; for _v in $(compgen -v TILLANDSIAS_LAND_QUEUE_); do unset "$_v"; done; unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY; }
DAILY_SKIP="${TILLANDSIAS_LAND_QUEUE_DAILY_SKIP:-1}"
DAILY_NS="refs/attest/daily-full"
DAILY_RED_NS="refs/attest/daily-red"
DAILY_MAX_AGE_S="${TILLANDSIAS_LAND_QUEUE_DAILY_MAX_AGE_S:-86400}"
_daily_why=""; _daily_proof=""; _daily_note=""
_newest_attest() { # <namespace> -> "<epoch> <sha>" of the newest, or nothing
    local _r _s _e _best=""
    while read -r _r _s; do
        _e="${_r##*/}"
        case "$_e" in ''|*[!0-9]*) continue ;; esac
        if [ -z "$_best" ] || [ "$_e" -gt "${_best%% *}" ]; then _best="$_e $_s"; fi
    done < <(git for-each-ref --format='%(refname) %(objectname)' "$1/" 2>/dev/null)
    [ -n "$_best" ] && printf '%s\n' "$_best"
}
daily_proof() { # <base sha> -> sets _daily_proof="<epoch> <sha>", or rc 1 with _daily_why set (no subshell: both must reach the caller)
    local _g _red _age
    _daily_why=""; _daily_proof=""
    [ "$DAILY_SKIP" = 1 ] || { _daily_why="daily-skip-off"; return 1; }
    case "$TRUNK" in main|release|release/*) _daily_why="trunk-$TRUNK-always-full"; return 1 ;; esac
    git fetch -q "$REMOTE" "+$DAILY_NS/*:$DAILY_NS/*" "+$DAILY_RED_NS/*:$DAILY_RED_NS/*" 2>/dev/null || true
    _g="$(_newest_attest "$DAILY_NS")" || { _daily_why="no-daily-run"; return 1; }
    _red="$(_newest_attest "$DAILY_RED_NS")" || _red=""
    if [ -n "$_red" ] && [ "${_red%% *}" -gt "${_g%% *}" ]; then _daily_why="daily-run-red:${_red#* }"; return 1; fi
    _age=$(( $(date -u +%s) - ${_g%% *} ))
    [ "$_age" -le "$DAILY_MAX_AGE_S" ] || { _daily_why="daily-run-stale:$((_age / 3600))h"; return 1; }
    git merge-base --is-ancestor "${_g#* }" "$1" 2>/dev/null || { _daily_why="daily-run-not-on-$TRUNK"; return 1; }
    _daily_proof="$_g"
}
# gate_env_for <base sha> — exports what the gate's class selector reads, and
# sets _daily_note. With no proof the marker points at a file that does not
# exist, so the selector reads "never" and skips nothing (fail closed).
# _ungated_paths <proof sha> <base sha> — the paths changed by trunk commits since the
# proof that ran NO gate: the single-parent first-parent ones (the plan-only lane). A land
# is a merge the queue made after gating its own diff, so its paths need no re-judging.
_ungated_paths() {
    local _c
    for _c in $(git rev-list --first-parent --no-merges "$1..$2" 2>/dev/null); do
        git diff-tree --no-commit-id --name-only -r "$_c" 2>/dev/null
    done | LC_ALL=C sort -u
}
gate_env_for() {
    local _p
    if daily_proof "$1"; then
        _p="$_daily_proof"
        printf '%s\n' "${_p%% *}" > "$_RUNDIR/daily-full-marker"
        # ORDER 2429-u3rp: the changed set is the CANDIDATE's diff against the trunk it is
        # gated on, plus what reached trunk ungated since the proof. Diffing against the
        # proof itself counted every land of the day (436 paths, every class, measured
        # 2026-11-27), so the scoped tier never skipped a step.
        _ungated_paths "${_p#* }" "$1" > "$_RUNDIR/ungated-paths"
        export TILLANDSIAS_CLASS_BASE="$1" TILLANDSIAS_CLASS_UNGATED_PATHS="$_RUNDIR/ungated-paths" TILLANDSIAS_FULL_GATE_MARKER="$_RUNDIR/daily-full-marker"
        _daily_note="against $TRUNK ${1:0:9} + $(grep -c . "$_RUNDIR/ungated-paths") ungated path(s) since daily proof ${_p#* }"
    else
        rm -f "$_RUNDIR/no-daily-proof"
        unset TILLANDSIAS_CLASS_BASE TILLANDSIAS_CLASS_UNGATED_PATHS
        export TILLANDSIAS_FULL_GATE_MARKER="$_RUNDIR/no-daily-proof"
        _daily_note="full: $_daily_why"
    fi
}
# not_run_line <gate log> — the land's not-run: line, naming every skipped step.
# _land_trailers <pr> <lane> — ORDER 2431-2yic: the land commit names its lane, so an
# audit needs no host's run logs (a week of plan-only lands read as gated, 2026-11-27).
# Message only: the gate stamp is a digest of the tree, and the tree is unchanged.
# Idempotent (replace), so a push retry that re-adopts and comes back here is safe.
_land_trailers() {
    local _msg _sk=0 _gb
    _msg="$(git log -1 --format=%B HEAD 2>/dev/null)" || return 0
    local -a _t=(--trailer "Lane: $2")
    if [ "$2" = full ]; then
        [ -f "$_RUNDIR/pr-$1-skips" ] && _sk="$(grep -c . "$_RUNDIR/pr-$1-skips" 2>/dev/null)" || true
        case "$_daily_note" in "full:"*|"") _gb=full ;; *) _gb=daily-proof ;; esac
        _t+=(--trailer "Gate-Skipped: ${_sk:-0}" --trailer "Gate-Base: $_gb")
    fi
    _msg="$(printf '%s\n' "$_msg" | git interpret-trailers --if-exists replace "${_t[@]}")" || return 0
    git -c user.name=land-queue -c user.email=land-queue@localhost commit -q --amend -m "$_msg" >/dev/null 2>&1 \
        || say "advisory:land-queue:$1:lane-trailer-not-written — the landing proceeds without it"
    # The landing is PROVED by merge_sha reaching the remote, so it must name the amended commit.
    merge_sha="$(git rev-parse HEAD)"
}
not_run_line() {
    local _sk
    _sk="$(grep -o 'skip:class-selector:[^ ]*' "$1" 2>/dev/null | sed 's/^skip:class-selector://' | LC_ALL=C sort -u | tr '\n' ' ')"
    if [ -n "$_sk" ]; then
        printf '  not-run: %s(class-selector skip, %s)\n' "$_sk" "$_daily_note"
    else
        printf '  not-run: nothing — tier=full runs the whole gate (%s)\n' "${_daily_note:-full}"
    fi
}
# daily_full_run — gate the trunk tip with the selector OFF and publish the result.
# Returns 0 (green proof published), 1 (red published), 3 (could not run). Used by
# --daily-full and, since 2432-ik2d, by an idle run whose newest proof is stale.
daily_full_run() {
    git fetch -q "$REMOTE" "$TRUNK" || { say "could-not-run:host:daily-full:fetch-failed"; return 3; }
    _dsha="$(git rev-parse "$REMOTE/$TRUNK")"
    git checkout -q --detach "$_dsha" || { say "could-not-run:host:daily-full:checkout-failed"; return 3; }
    rm -f "$_RUNDIR/no-daily-proof"
    ( _gate_clean_env; export TILLANDSIAS_CLASS_SELECTOR=off TILLANDSIAS_FULL_GATE_MARKER="$_RUNDIR/no-daily-proof"
      # 2270-7gp6: the salvage-audit fixture's live 334-ref audit runs here, once a day.
      # 2272-cuxh: and the preflight door's own fixture (~14 min on a mid-tier host).
      export TILLANDSIAS_SALVAGE_AUDIT_LIVE=1 TILLANDSIAS_FRONT_DOOR_LIVE=1; eval "$GATE" ) \
        < /dev/null > "$_RUNDIR/daily-full-gate.log" 2>&1
    _drc=$?
    _dns="$DAILY_NS"; [ "$_drc" -eq 0 ] || _dns="$DAILY_RED_NS"
    _dref="$_dns/$(date -u +%s)"
    if [ "$DRY_RUN" -eq 1 ]; then
        say "dry-run: would publish $_dref -> ${_dsha:0:9} (gate rc=$_drc)"
    elif ! git push -q "$REMOTE" "$_dsha:$_dref" 2>/dev/null; then
        say "could-not-run:host:daily-full:push-failed:$_dref (gate rc=$_drc; log $_RUNDIR/daily-full-gate.log)"
        return 3
    fi
    if [ "$_drc" -eq 0 ]; then
        say "ok:land-queue:daily-full:${_dsha:0:9}:$_dref — land gates may skip unchanged steps against it for ${DAILY_MAX_AGE_S}s"
        return 0
    fi
    say "red:land-queue:daily-full:${_dsha:0:9}:rc=$_drc:$_dref — scoped lands freeze back to full until a green daily run (log $_RUNDIR/daily-full-gate.log)"
    return 1
}
if [ "$DAILY_FULL" -eq 1 ]; then
    daily_full_run; exit $?
fi
# ORDER 2432-ik2d: AN IDLE QUEUE CUTS A STALE PROOF. Only a manual --daily-full did,
# and a day without one froze every scoped land (2429-u3rp) without a word. Crons are
# operator-only, so the queue does it on an EMPTY run, never with work waiting, never
# in a dry run, never when a red daily run is newer (that needs a person, not a retry),
# and never on main/release (daily_proof refuses those first). 0 turns it off.
DAILY_AUTO="${TILLANDSIAS_LAND_QUEUE_DAILY_AUTO:-1}"
daily_auto_cut() {
    [ "$DAILY_AUTO" = 1 ] && [ "$DRY_RUN" -ne 1 ] || return 0
    git fetch -q "$REMOTE" "$TRUNK" 2>/dev/null || return 0
    if daily_proof "$(git rev-parse "$REMOTE/$TRUNK")"; then return 0; fi
    case "$_daily_why" in
        no-daily-run|daily-run-stale:*|daily-run-not-on-*) ;;
        *) say "daily-full:auto:not-cut:$_daily_why"; return 0 ;;
    esac
    say "daily-full:auto:cutting:$_daily_why — the queue is idle, so it proves trunk now (scoped lands are FULL until a fresh green proof exists)"
    daily_full_run
}

read_queue() { # <first>
    local _qjson _qrc _qlen _all _prio _hold _drafts n h
    _qjson="$(mktemp)"
    "$GH" pr list --base "$TRUNK" --state open --limit "$GH_LIST_LIMIT" \
          --json number,headRefName,isDraft,labels > "$_qjson" 2>/dev/null
    _qrc=$?
    if [ "$_qrc" -ne 0 ]; then
        say "fail:land-queue:cannot-read-queue:gh-exit-$_qrc — this is NOT an empty queue"
        rm -f "$_qjson"; return 1
    fi
    if ! "$PLAN" json get -e 'type == "array"' < "$_qjson" >/dev/null 2>&1; then
        say "fail:land-queue:queue-not-an-array — gh exited 0 with output that is not a PR list"
        rm -f "$_qjson"; return 1
    fi
    _qlen="$("$PLAN" json get -r 'length' < "$_qjson" 2>/dev/null)"
    if [ -n "$_qlen" ] && [ "$_qlen" -ge "$GH_LIST_LIMIT" ] 2>/dev/null; then
        say "fail:land-queue:queue-may-be-truncated:$_qlen-of-limit-$GH_LIST_LIMIT — gh returned as many PRs as asked for, so the oldest may be missing; raise TILLANDSIAS_LAND_QUEUE_GH_LIST_LIMIT or close PRs (1959-tdn5)"
        rm -f "$_qjson"; return 1
    fi
    # Two values per ready PR on alternating lines, paired by `paste - -` and
    # ordered by number: the subset has no sort_by or string interpolation.
    _all="$("$PLAN" json get -r '.[] | select(.isDraft | not) | .number, .headRefName' < "$_qjson" | paste - - | sort -n)"
    _prio=" $("$PLAN" json get -r '.[] | select(.labels[]?.name == "land:priority") | .number' < "$_qjson" | sort -u | tr '\n' ' ')"
    _hold=" $("$PLAN" json get -r '.[] | select(.labels[]?.name == "land:hold") | .number' < "$_qjson" | sort -u | tr '\n' ' ')"
    if [ "$1" -eq 1 ]; then
        # ORDER 2100-vkpg: A DRAFT IS SKIPPED, AND SKIPPING IT SILENTLY IS HOW 18
        # DRAFTS SAT FOR WEEKS. Name every draft and every hold, every run.
        _drafts="$("$PLAN" json get -r '.[] | select(.isDraft) | .number, .headRefName' < "$_qjson" | paste - - | sort -n)"
        if [ -n "$_drafts" ]; then
            while read -r n h; do
                say "advisory:land-queue:ignored-draft:#$n:$h — drafts never land; un-draft (gh pr ready $n), or to hold it label it land:hold (2143-z5uj), or close it with a tombstone (2100-vkpg)"
            done <<< "$_drafts"
        fi
        while IFS=$'\t' read -r n h; do
            [ -n "$n" ] || continue
            case "$_hold" in *" $n "*) say "hold:land-queue:#$n:$h — labelled land:hold; remove the label to queue it" ;; esac
        done <<< "$_all"
    fi
    rm -f "$_qjson"
    _cands=""
    while IFS=$'\t' read -r n h; do
        [ -n "$n" ] || continue
        case "$_hold" in *" $n "*) continue ;; esac
        case "$_prio" in *" $n "*) _cands="${_cands}${n}	${h}"$'\n' ;; esac
    done <<< "$_all"
    while IFS=$'\t' read -r n h; do
        [ -n "$n" ] || continue
        case "$_hold" in *" $n "*) continue ;; esac
        case "$_prio" in *" $n "*) continue ;; esac
        _cands="${_cands}${n}	${h}"$'\n'
    done <<< "$_all"
    return 0
}
read_queue 1 || exit 1

if [ -z "$_cands" ]; then
    say "ok:land-queue:0 landed=0 evicted=0 requeued=0 skipped=0 — the queue is empty"
    daily_auto_cut || true   # 2432-ik2d: its own verdict line says what it did
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
# next_candidate — sets num/head to the next candidate, or answers 1. Pass 1
# RE-READS the queue (2143-z5uj) and takes the first entry not yet seen this
# run, so a mid-run land:priority label or close takes effect at the next
# candidate. A re-read that fails keeps the list already held: a transient gh
# error must not end a run that is mid-way through landing. Pass 2 walks the
# deferred list as recorded.
_seen=" "
_first_pick=1
next_candidate() {
    local n h
    if [ "$_pass" -eq 1 ]; then
        if [ "$_first_pick" -eq 0 ]; then
            read_queue 0 || say "advisory:land-queue:re-read-failed — continuing on the list read before"
        fi
        _first_pick=0
        while IFS=$'\t' read -r n h; do
            [ -n "$n" ] || continue
            case "$_seen" in *" $n "*) continue ;; esac
            _seen="$_seen$n "
            num="$n"; head="$h"; return 0
        done <<< "$_cands"
        return 1
    fi
    while IFS=$'\t' read -r n h; do
        [ -n "$n" ] || continue
        _p2="${_p2#*$'\n'}"
        num="$n"; head="$h"; return 0
    done <<< "$_p2"
    return 1
}
# ── ORDER 2153-trn1: THE BATCH TRAIN — ONE GATE, ONE MERGE COMMIT ─────────────
# Operator ruling 2026-11-20 (trains gate the union tree once) and the
# build-speed ruling 2026-11-21. Up to BATCH_K ready full-lane candidates are
# merged onto the trunk in queue order (a member that conflicts with the union
# so far is left out, for the one-at-a-time loop). The union passes the SAME
# doors the loop asks per candidate, asked ONCE of the union: freeze, carried
# obligations (--landing over base..union reads every member's commits), native
# lint, host door, plan refresh, preflight. Each is at least as strict on the
# union as on any member, since any member's violation reds it.
#
# GREEN: the union's tree lands as ONE commit whose first parent is the trunk
# and whose other parents are the member heads, so every first-parent commit on
# the trunk is a tree that gated (and GitHub marks each member merged).
# RED, or any door refusing: the train is ABANDONED and nobody is evicted by
# it; the members go through the one-at-a-time loop below, whose own gates
# attribute the red. That fallback is the honest simple form of the design's
# halving bisect: it costs one gate per member after a red train, never an
# innocent eviction. A per-train line goes to TRAIN_LOG so the flake rate can be
# measured before K is widened (coordinator 2026-11-20).
# BATCH_K < 2 (the default until the coordinator sets it: 4 for full trains)
# leaves the queue exactly as it was.
# ── SHADOW INTAKE (bundle landing phase 0): INTAKE'S VERDICT BESIDE THE GATE'S ──
# Off unless TILLANDSIAS_LAND_QUEUE_SHADOW_INTAKE names the command (run in a shadow
# tree as `<cmd> <base>`, e.g. `./build.sh --intake --changed`). Each gated candidate
# is remembered (number, base, head, the gate's verdict) and scripts/lua/shadow-
# intake.lua measures them DETACHED after this run ends: its own lock, worktree and
# target dir, low priority, bounded. A land run that starts meanwhile asks it to stop
# at its next PR. It changes, delays and evicts nothing (coordinator 2026-11-24).
SHADOW_INTAKE="${TILLANDSIAS_LAND_QUEUE_SHADOW_INTAKE:-}"
SHADOW_LOG="${TILLANDSIAS_LAND_QUEUE_SHADOW_LOG:-$_LOGROOT/shadow-intake.log}"
SHADOW_LOCK="${TILLANDSIAS_LAND_QUEUE_SHADOW_LOCK:-${XDG_RUNTIME_DIR:-$_LOGROOT}/tillandsias-shadow.lock}"
SHADOW_TREE="${TILLANDSIAS_LAND_QUEUE_SHADOW_TREE:-${XDG_CACHE_HOME:-$HOME/.cache}/tillandsias/shadow-intake/$(basename "$ROOT")}"
_shadow_q=()
[ ! -d "$SHADOW_LOCK" ] || : > "$SHADOW_LOCK/stop" 2>/dev/null || true
shadow_note() { # <num> <base> <head> <gate verdict> <via>
    [ -n "$SHADOW_INTAKE" ] && [ "$DRY_RUN" -eq 0 ] || return 0
    _shadow_q+=("$1:$2:$3:$4:$5")
}
shadow_launch() {
    [ "${#_shadow_q[@]}" -gt 0 ] || return 0
    local _pri=()
    command -v nice >/dev/null 2>&1 && _pri=(nice -n 10)
    command -v ionice >/dev/null 2>&1 && _pri+=(ionice -c3)
    command -v setsid >/dev/null 2>&1 && _pri+=(setsid)  # its own session: it outlives a parent that is killed
    mkdir -p "$(dirname "$SHADOW_LOG")" 2>/dev/null
    ( trap '' HUP; trap - EXIT; exec env SHADOW_CMD="$SHADOW_INTAKE" SHADOW_TREE="$SHADOW_TREE" SHADOW_LOG="$SHADOW_LOG" SHADOW_LOCK="$SHADOW_LOCK" SHADOW_KEEP="$_RUNDIR" SHADOW_PLAN="$PLAN" \
        SHADOW_PR_S="${TILLANDSIAS_LAND_QUEUE_SHADOW_PR_S:-1200}" SHADOW_RUN_S="${TILLANDSIAS_LAND_QUEUE_SHADOW_RUN_S:-1200}" \
        ${_pri[@]+"${_pri[@]}"} "$PLAN" script run "$_SELF_DIR/lua/shadow-intake.lua" -- "${_shadow_q[@]}" ) </dev/null >"$_RUNDIR/shadow.out" 2>&1 &
    say "shadow-intake: ${#_shadow_q[@]} candidate(s) handed to a detached run, log $SHADOW_LOG"
}
BATCH_K="${TILLANDSIAS_LAND_QUEUE_BATCH_K:-1}"
TRAIN_LOG="${TILLANDSIAS_LAND_QUEUE_TRAIN_LOG:-$_LOGROOT/trains.log}"
# bundles.log (bundle landing phase 1): the successor line, beside trains.log, one
# per train. `heavy=` counts members whose own diff gate-changed cannot scope (its
# exit-10 rule, printed `heavy:` by --list --intake; no second path list). A probe
# that does not answer makes it `-`, never a 0 nobody measured. `cause=` is the
# trains.log result. green = the gate was green (promoted= says whether it landed);
# red = the gate answered rc=1; aborted = any other rc, the host's state and never a
# verdict on the tree (2234-a964); abandoned = the train stopped at a named door.
BUNDLE_LOG="${TILLANDSIAS_LAND_QUEUE_BUNDLE_LOG:-$(dirname "$TRAIN_LOG")/bundles.log}"
HEAVY_PROBE="${TILLANDSIAS_LAND_QUEUE_HEAVY_PROBE-timeout 60 bash \"$_SELF_DIR/gate-changed.sh\" --list --intake}"
heavy_probe() { # <base> -> heavy | light | unknown, of the worktree against base
    local _o
    [ -n "$HEAVY_PROBE" ] || { echo unknown; return; }
    _o="$(TILLANDSIAS_GATE_CHANGED_ROOT="$ROOT"; export TILLANDSIAS_GATE_CHANGED_ROOT; eval "$HEAVY_PROBE \"\$1\"" </dev/null 2>/dev/null)"
    if grep -q '^heavy:' <<<"$_o"; then echo heavy
    elif grep -q '^select:intake ' <<<"$_o"; then echo light
    else echo unknown; fi
}
# HEAVY_MAX (2281-xx62, phase 2): a train takes at most this many members the probe
# does not answer `light` for; a further one is put back for the one-at-a-time loop,
# exactly like a conflicting member, and the next light candidate may still join.
# `unknown` counts toward the cap: nobody measured it light. 0 = no heavy member.
# A value that is not a whole number falls back to 2, said aloud.
HEAVY_MAX="${TILLANDSIAS_BUNDLE_HEAVY_MAX:-2}"
[[ "$HEAVY_MAX" =~ ^[0-9]{1,4}$ ]] || { [ "$BATCH_K" -ge 2 ] 2>/dev/null && say "train:heavy-max-unreadable:'$HEAVY_MAX' — using 2"; HEAVY_MAX=2; }
HEAVY_MAX=$((10#$HEAVY_MAX))
bundle_log() { # <base> <union> <result> <gate_s>; try_batch's nums/heavy_n/t_id are in scope
    local _v _p=- _t
    case "$3" in
        landed:*) _v=green; _p="${3#landed:}" ;;
        green:*) _v=green ;;
        red:rc=1|red:rc=1:*) _v=red ;;
        red:*) _v=aborted ;;
        *) _v=abandoned ;;
    esac
    _t="$(git rev-parse --short=9 "$2^{tree}" 2>/dev/null)"
    printf 'bundle:%s:%s members=%s heavy=%s base=%s tree=%s gate_s=%s reason=train promoted=%s cause=%s ids=%s ts=%s\n' \
        "$_v" "$t_id" "${#nums[@]}" "$heavy_n" "${1:0:9}" "${_t:--}" "$4" "$_p" "${3// /_}" "$ids" \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$BUNDLE_LOG" 2>/dev/null || true
}
train_log() { # <members> <base> <union> <result> <gate_s>
    mkdir -p "$(dirname "$TRAIN_LOG")" 2>/dev/null
    printf '%s members=%s base=%s union=%s result=%s gate_s=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${2:0:9}" "${3:0:9}" "$4" "$5" >> "$TRAIN_LOG" 2>/dev/null || true
    bundle_log "$2" "$3" "$4" "$5"
}
# ── TRAIN DIAGNOSIS (2289-bxzm, bundle landing phase 1): WHOSE RED IS IT, BY FAILING STEP ──
# A red train used to cost one whole gate per member. Now the steps the gate log NAMES
# are re-run alone: on the identical union (green = flake), on the bare trunk (red =
# trunk-red, and only the whole bare-trunk gate confirms it, as for a single), then on
# the per-member merge commits in order; the first red names the culprit. A train still
# evicts nobody: the culprit leaves it and its OWN gate judges it, and the rest (or, for
# a flake, the same members) ride ONE more train. Anything not judged alone (an unnamed
# red, a litmus, a step neither red nor green) falls back to one at a time, as before.
TRAIN_DIAGNOSE="${TILLANDSIAS_LAND_QUEUE_TRAIN_DIAGNOSE:-1}"
TRAIN_STEP_S="${TILLANDSIAS_LAND_QUEUE_TRAIN_STEP_S:-900}"
_train_try=1; _train_drop=" "; _train_again=0

# trunk_red <base> <checkout back to> <test> <gate cmd> <log>: rc 0 when the BARE trunk's
# whole gate names the same test red. One gate per base, remembered (2118-tpmy).
trunk_red() {
    local memo v trc
    [ "$TRUNK_RED_CHECK" = 1 ] || return 1
    memo="$(cat "$TRUNK_RED_MEMO" 2>/dev/null)"
    if [ "${memo%% *}" = "$1" ]; then v="${memo#* }"
    else
        git checkout -q --detach "$1" 2>/dev/null
        ( _gate_clean_env; eval "$4" ) < /dev/null > "$5" 2>&1; trc=$?
        git checkout -q --detach "$2" 2>/dev/null
        v=green
        if [ "$trc" -ne 0 ] \
           && grep -qF -e "$3" -e "red-twice:${3##*/}:" \
              <<<"$(grep -E '^[[:space:]]*(FAIL|\[FAIL\]|refused:|violation:|blocked:|red-twice:|red-script:)' "$5" 2>/dev/null)"; then
            v="red $3"
        fi
        printf '%s %s\n' "$1" "$v" > "$TRUNK_RED_MEMO" 2>/dev/null || true
        rm -f "$5"
    fi
    [ "$v" = "red $3" ]
}
# gate_named_steps <gate log>: "<path>" or "<path> twice" per step the log names red.
# The gate's own `red-script:<path>` (build.sh _error) decides, the LAST one: earlier ones
# can be a nested gate inside a passing fixture. Only without one is the old guess read.
gate_named_steps() {
    local rb last
    last="$(sed -n "s/^red-script:\(scripts\/[A-Za-z0-9_.\/-]*\)$/\1/p" "$1" 2>/dev/null | tail -n 1)"
    if [ -n "$last" ]; then
        if grep -qF "red-twice:${last##*/}:" "$1"; then echo "$last twice"; else echo "$last"; fi
        return
    fi
    { grep -E '^[[:space:]]*(FAIL|\[FAIL\]|refused:|violation:|blocked:)' "$1" 2>/dev/null \
          | grep -oE 'scripts/[A-Za-z0-9_./-]+\.(sh|lua)|litmus:[A-Za-z0-9_-]+'
      sed -n 's/^red-twice:\([A-Za-z0-9_.-]*\):.*/\1/p' "$1" 2>/dev/null | while IFS= read -r rb; do
          git ls-files -- "scripts/$rb" "scripts/lua/$rb" | sed -n 's/$/ twice/; 1p'
      done
    } | sort -r | awk '!s[$1]++'
}
# train_step_cmd <test>: how THE GATE runs it, as a command line; rc 1 when it does not.
# A log line can name any script and some are actors, so only a test-*/check-* that this
# tree's gate itself runs (one step file, or an inline call) is ever executed.
train_step_cmd() {
    local f hit="" n=0
    [[ "$1" =~ ^scripts/(lua/)?(test|check)-[A-Za-z0-9_.-]+\.(sh|lua)$ ]] || return 1
    for f in scripts/gate-steps.d/*.step; do
        [ -f "$f" ] || continue
        if grep -qxE "STEP_(SCRIPT|LUA)=\"${1//./\\.}\"" "$f"; then hit="$f"; n=$((n + 1)); fi
    done
    if [ "$n" -eq 1 ]; then
        f="${hit##*/}"; printf './build.sh --gate-steps . --gate-step %s' "${f%%-*}"; return 0
    fi
    [ "$n" -eq 0 ] || return 1
    grep -qE "^[^#]*(_run bash|_run_lua_decider) \"(\\\$SCRIPT_DIR/)?${1//./\\.}\"" build.sh 2>/dev/null || return 1
    case "$1" in *.lua) printf '"$PLAN" script run %s' "$1" ;; *) printf 'bash %s' "$1" ;; esac
}
# train_step <tree> <test> <log> <tests absent here are: green|unjudged> -> green|red|unjudged
train_step() {
    local cmd rc key
    git checkout -q --detach "$1" 2>/dev/null || { echo unjudged; return; }
    [ -e "$2" ] || { echo "$4"; return; }
    cmd="$(train_step_cmd "$2")" || { echo unjudged; return; }
    # the plan binary runs every Lua step: it must be this tree's
    if [ -n "$PLAN_REFRESH" ]; then
        key="$(plan_refresh_key)" || key=""
        if [ -z "$key" ] || [ "$key" != "$(cat "$PLAN_REFRESH_STAMP" 2>/dev/null)" ]; then
            ( eval "$PLAN_REFRESH" ) < /dev/null > "$3.refresh" 2>&1 || { echo unjudged; return; }
            if key="$(plan_refresh_key)"; then printf '%s\n' "$key" > "$PLAN_REFRESH_STAMP" 2>/dev/null || true; fi
        fi
    fi
    command -v timeout >/dev/null 2>&1 && cmd="timeout $TRAIN_STEP_S $cmd"
    ( _gate_clean_env; eval "$cmd" ) < /dev/null > "$3" 2>&1; rc=$?
    case "$rc" in 0) echo green ;; 1) echo red ;; *) echo unjudged ;; esac
}
# train_diagnose <gate log>: sets _td (flaky | trunk-red=<test> | culprit=#a,#b | unjudged:<why>)
# and _td_drop. try_batch's base/union/nums/ids are in scope. Leaves HEAD on the union.
train_diagnose() {
    local t twice v i k="" steps n=0 red=0 log="$_RUNDIR/train-step"
    local -a chain=()
    _td=""; _td_drop=""
    steps="$(gate_named_steps "$1")"
    [ -n "$steps" ] || { _td=unjudged:no-step-named; return; }
    [ "$(grep -c . <<<"$steps")" -le 6 ] || { _td=unjudged:too-many-steps; return; }
    while IFS= read -r t; do chain+=("$t"); done < <(git rev-list --first-parent --reverse "$base..$union")
    [ "${#chain[@]}" -eq "${#nums[@]}" ] || { _td=unjudged:chain-is-not-one-merge-per-member; return; }
    while IFS=' ' read -r t twice; do
        n=$((n + 1))
        _lq_phase "${nums[0]}" train "train-diagnose:$t" "$ids"
        v="$(train_step "$union" "$t" "$log-$n-union.log" unjudged)"
        [ "$v" != unjudged ] || { _td="unjudged:$t"; break; }
        if [ "$v" = green ] && [ -z "$twice" ]; then say "train:step:$t union=green on a re-run"; continue; fi
        # red-twice then green alone is not a flake to wave through, nor a step that bisects
        [ "$v" = red ] || { _td="unjudged:$t:red-twice-in-the-gate-green-alone"; break; }
        red=1
        v="$(train_step "$base" "$t" "$log-$n-base.log" green)"
        if [ "$v" = red ]; then
            if trunk_red "$base" "$union" "$t" "$GATE" "$log-$n-trunk-gate.log"; then _td="trunk-red=$t"
            else _td="unjudged:$t:red-alone-on-trunk-but-not-in-its-gate"; fi
            break
        fi
        [ "$v" = green ] || { _td="unjudged:$t:base"; break; }
        k=""
        for i in "${!chain[@]}"; do
            if [ "$i" -eq $((${#chain[@]} - 1)) ]; then v=red  # the union: already red
            else v="$(train_step "${chain[$i]}" "$t" "$log-$n-member-$i.log" green)"; fi
            case "$v" in
                red) k="$i"; break ;;
                unjudged) _td="unjudged:$t:#${nums[$i]}"; break 2 ;;
            esac
        done
        say "train:step:$t base=green first-red=#${nums[$k]}"
        case " $_td_drop" in *" ${nums[$k]} "*) ;; *) _td_drop="$_td_drop${nums[$k]} " ;; esac
    done <<< "$steps"
    git checkout -q --detach "$union" 2>/dev/null
    if [ -n "$_td" ]; then _td_drop=""; return; fi
    if [ "$red" -eq 0 ]; then _td=flaky
    else _td="culprit=#$(printf '%s' "${_td_drop% }" | sed 's/ /,#/g')"; fi
}
try_batch() {
    [ "$BATCH_K" -ge 2 ] 2>/dev/null || return 0
    [ "$DRY_RUN" -eq 1 ] && return 0
    local base union n h hs lm mb pre ids="" carried="" out err rc key t0 gs c now
    local heavy_n=0 heavy_cap=0 tier t_id; t_id="train-$(date +%s)"; [ "$_train_try" -eq 1 ] || t_id="$t_id-2"
    local -a nums=() heads=() parents=()
    git fetch -q "$REMOTE" "$TRUNK" 2>/dev/null || return 0
    base="$(git rev-parse "$REMOTE/$TRUNK" 2>/dev/null)" || return 0
    git checkout -q --detach "$base" 2>/dev/null || return 0
    while IFS=$'\t' read -r n h; do
        [ -n "$n" ] || continue
        [ "${#nums[@]}" -lt "$BATCH_K" ] || break
        case "$_train_drop" in *" $n "*) continue ;; esac
        [[ "$h" =~ $WORK_RE ]] || continue
        git fetch -q "$REMOTE" "$h" 2>/dev/null || continue
        hs="$(git rev-parse FETCH_HEAD)"
        lm="$(last_eviction "$n")"
        if [ -n "$lm" ] && [ "$(marker_field "$lm" head)" = "$hs" ]; then continue; fi
        mb="$(git merge-base "$base" "$hs" 2>/dev/null)" || continue
        if [ "$PLAN_ONLY_LANE" = 1 ] && delta_plan_only "$mb" "$hs"; then continue; fi  # the plan lane is already cheap
        pre="$(git rev-parse HEAD)"
        if git -c user.name=land-queue -c user.email=land-queue@localhost \
                merge --no-ff -q --no-edit -m "train: #$n $h" "$hs" >/dev/null 2>&1; then
            if ! _lq_alloc_steps "$n" "$base" "$pre"; then
                say "train:skip:#$n $_lq_alloc_verdict — goes one at a time"
                git reset -q --hard "$pre"
                continue
            fi
            tier="$(heavy_probe "$pre")"
            if [ "$tier" != light ]; then
                if [ "$heavy_cap" -ge "$HEAVY_MAX" ]; then
                    say "train:heavy-deferred:#$n tier=$tier max=$HEAVY_MAX — goes one at a time"
                    git reset -q --hard "$pre"
                    continue
                fi
                heavy_cap=$((heavy_cap + 1))
            fi
            nums+=("$n"); heads+=("$hs"); ids="$ids#$n,"
            say "train:accept:#$n tier=$tier"
            case "$tier" in
                heavy) say "train:heavy:#$n"; [ "$heavy_n" = - ] || heavy_n=$((heavy_n + 1)) ;;
                light) ;;
                *) say "train:heavy-unknown:#$n"; heavy_n=- ;;
            esac
        else
            git merge --abort >/dev/null 2>&1 || true
            git reset -q --hard "$pre"
        fi
    done <<< "$_cands"
    ids="${ids%,}"
    if [ "${#nums[@]}" -lt 2 ]; then git checkout -q --detach "$base" 2>/dev/null; return 0; fi
    union="$(git rev-parse HEAD)"
    say "train: ${#nums[@]} members $ids base=${base:0:9} union=${union:0:9}"
    _lq_phase "${nums[0]}" train train-checks "$ids"
    abandon() { say "train:abandoned:$1 — members $ids go one at a time"; train_log "$ids" "$base" "$union" "abandoned:$1" -; git checkout -q --detach "$base" 2>/dev/null; }
    # freeze
    if [ -n "$(freeze_held_paths "$base" "$union" | head -n 1)" ]; then
        out="$(freeze_markers "$REMOTE" "$TRUNK")" || { abandon freeze-unknown; return 0; }
        [ -z "$out" ] || { abandon frozen; return 0; }
    fi
    # carried obligations over every member's commits
    if [ -f methodology/convergence.yaml ]; then
        out="$(mktemp "${TMPDIR:-/tmp}/land-queue-train-carried.XXXXXX")"; err="$(mktemp "${TMPDIR:-/tmp}/land-queue-train-carried.XXXXXX")"
        env TILLANDSIAS_REPO_ROOT="$ROOT" TILLANDSIAS_CARRIED_BASE="$base" TILLANDSIAS_CARRIED_HEAD="$union" \
            "$PLAN" script run "$_SELF_DIR/lua/check-carried-obligations.lua" -- --landing \
            < /dev/null > "$out" 2> "$err"; rc=$?
        carried="$(sed -n 's/^carried:\([^:]*\):\([^:]*\):\{0,1\}\(.*\)$/Carried: \1 \2 \3/p' "$out" | sed 's/ *$//')"
        rm -f "$out" "$err"
        [ "$rc" -eq 0 ] || { abandon "carried-rc-$rc"; return 0; }
    fi
    # native lint (a recorded unlinted debt is a per-member decision: abandon)
    if [ -f "$_SELF_DIR/check-native-lint-attested.sh" ]; then
        out="$(env -u TILLANDSIAS_NATIVE_LINT_UNATTESTED -u TILLANDSIAS_NATIVE_LINT_BASE \
            bash "$_SELF_DIR/check-native-lint-attested.sh" --base "$base" < /dev/null 2>/dev/null)"; rc=$?
        [ "$rc" -eq 0 ] || { abandon "native-lint-rc-$rc"; return 0; }
        case "$out" in *override:native-lint:*) abandon native-lint-debt; return 0 ;; esac
    fi
    # host door
    if [ -n "$HOST_DOOR" ]; then
        if [ -n "$SIDECAR_STAGE" ]; then ( eval "$SIDECAR_STAGE" ) < /dev/null > "$_RUNDIR/train-sidecar.log" 2>&1 || true; fi
        out="$( ( eval "$HOST_DOOR" ) < /dev/null 2>/dev/null | grep -m 1 -E '^(ok:host-door|could-not-run:host:)' )"
        case "$out" in ok:host-door*) ;; *) abandon "host-door:${out:-no-answer}"; return 0 ;; esac
    fi
    # plan refresh (same dep-info key as the loop, 2152-lqrf)
    if [ -n "$PLAN_REFRESH" ]; then
        key="$(plan_refresh_key)" || key=""
        if [ -n "$key" ] && [ "$key" = "$(cat "$PLAN_REFRESH_STAMP" 2>/dev/null)" ]; then
            say "plan-refresh:skipped:inputs-unchanged:train:${key:0:12}"
        else
            ( eval "$PLAN_REFRESH" ) < /dev/null > "$_RUNDIR/train-plan-refresh.log" 2>&1 || { abandon plan-refresh-failed; return 0; }
            if key="$(plan_refresh_key)"; then
                mkdir -p "$(dirname "$PLAN_REFRESH_STAMP")" 2>/dev/null
                printf '%s\n' "$key" > "$PLAN_REFRESH_STAMP" 2>/dev/null || true
            fi
        fi
    fi
    if [ -n "$PREFLIGHT" ]; then
        ( _gate_clean_env; eval "$PREFLIGHT" ) < /dev/null > "$_RUNDIR/train-preflight.log" 2>&1 || { abandon preflight-red; return 0; }
    fi
    # THE ONE GATE
    t0=$SECONDS
    gate_env_for "$base"
    _lq_phase "${nums[0]}" train train-gate "$ids"
    ( _gate_clean_env; eval "$GATE" ) < /dev/null > "$_RUNDIR/train-gate.log" 2>&1; rc=$?
    gs=$((SECONDS - t0))
    if [ "$rc" -ne 0 ]; then
        _td=""
        if [ "$rc" -eq 1 ] && [ "$_train_try" -eq 1 ] && [ "$TRAIN_DIAGNOSE" = 1 ]; then train_diagnose "$_RUNDIR/train-gate.log"; cp -f "$_RUNDIR/train-gate.log" "$_RUNDIR/train-gate-1.log" 2>/dev/null; fi
        case "$_td" in
            trunk-red=*)
                say "hold:trunk-red:${_td#trunk-red=} — trunk ${base:0:9} fails it too; no member of $ids is evicted; the queue holds until trunk is fixed (log: $_RUNDIR/train-gate.log)"
                _held=1 ;;
            flaky)
                say "train:red:flaky — every named step is green on the identical union; members $ids ride one more train"
                _train_again=1 ;;
            culprit=*)
                say "train:red:$_td — it leaves the train and its own gate judges it; the rest ride one more train"
                _train_drop="$_train_drop$_td_drop"; _train_again=1 ;;
            *)
                say "train:red:rc=$rc${_td:+:$_td} — nobody is evicted by a train; members $ids go one at a time (log: $_RUNDIR/train-gate.log)" ;;
        esac
        train_log "$ids" "$base" "$union" "red:rc=$rc${_td:+:$_td}" "$gs"
        git checkout -q --detach "$base" 2>/dev/null
        return 0
    fi
    # The tree that ships is the tree that gated: re-read the trunk.
    git fetch -q "$REMOTE" "$TRUNK" 2>/dev/null
    now="$(git rev-parse "$REMOTE/$TRUNK" 2>/dev/null)"
    parents=(-p "$base")
    for hs in "${heads[@]}"; do parents+=(-p "$hs"); done
    # 2431-2yic: the lane, in the trailer block (with Carried: when there is one).
    c="$(printf 'land-train(%s): %d members into %s, one gate on the union\n\n%s%sLane: train\n' "$ids" "${#nums[@]}" "$TRUNK" "$carried" "${carried:+$'\n'}" \
        | GIT_AUTHOR_NAME=land-queue GIT_AUTHOR_EMAIL=land-queue@localhost \
          GIT_COMMITTER_NAME=land-queue GIT_COMMITTER_EMAIL=land-queue@localhost \
          git commit-tree "$union^{tree}" "${parents[@]}")" || { abandon commit-tree-failed; return 0; }
    # ORDER 2215-trad: A PLAN-ONLY MOVE DOES NOT VOID A TRAIN. Run 29's 4-member
    # train gated ~25 min and pushed nothing because ledger fragments moved
    # $TRUNK mid-gate; with an active fleet that is nearly every train. The
    # singles' adopt rule applies unchanged: when EVERY class between the gated
    # base and the new tip is plan-ledger (delta_plan_only, the same classifier),
    # merge the train onto the new tip and push without re-gating. Any other
    # class, an unreadable answer, or a conflict still sends members one at a time.
    if [ "$now" != "$base" ]; then
        if git merge-base --is-ancestor "$base" "$now" 2>/dev/null && delta_plan_only "$base" "$now" \
            && git checkout -q --detach "$c" 2>/dev/null \
            && GIT_AUTHOR_NAME=land-queue GIT_AUTHOR_EMAIL=land-queue@localhost \
               GIT_COMMITTER_NAME=land-queue GIT_COMMITTER_EMAIL=land-queue@localhost \
               git merge --no-ff -q -m "land-train($ids): adopted over a plan-only move ${base:0:9}..${now:0:9}" "$now" >/dev/null 2>&1; then
            c="$(git rev-parse HEAD)"
            say "train:adopt:plan-only-move:gated-on=${base:0:9} now=${now:0:9} classes=plan-ledger — the gate's verdict still describes this code"
        else
            git merge --abort 2>/dev/null || true
            say "train:target-moved:gated-on=${base:0:9} now=${now:0:9} classes=$(printf '%s' "${_delta_classes:-unreadable}" | tr '\n' ',' | sed 's/,$//') — nothing pushed; members $ids go one at a time"
            train_log "$ids" "$base" "$union" "green:target-moved" "$gs"
            git checkout -q --detach "$base" 2>/dev/null
            return 0
        fi
    fi
    git push -q "$REMOTE" "$c:refs/heads/$TRUNK" >/dev/null 2>&1
    git fetch -q "$REMOTE" "$TRUNK" 2>/dev/null
    if ! git merge-base --is-ancestor "$c" "$REMOTE/$TRUNK" 2>/dev/null; then
        say "train:push-did-not-land — nothing landed; members $ids go one at a time"
        train_log "$ids" "$base" "$union" "green:push-did-not-land" "$gs"
        git checkout -q --detach "$base" 2>/dev/null
        return 0
    fi
    train_log "$ids" "$base" "$union" "landed:${c:0:9}" "$gs"
    local i=0
    for n in "${nums[@]}"; do
        say "land:$n tier=full gate=green train=${c:0:9} base=${base:0:9} head=${heads[$i]:0:9}"
        not_run_line "$_RUNDIR/train-gate.log"
        shadow_note "$n" "$base" "${heads[$i]}" green train
        landed=$((landed + 1)); _seen="$_seen$n "; i=$((i + 1))
    done
    git checkout -q --detach "$c" 2>/dev/null
    return 0
}
try_batch
if [ "$_train_again" -eq 1 ] && [ "$_held" -eq 0 ]; then _train_try=2; try_batch; fi

for _pass in 1 2; do
[ "$_held" -eq 0 ] || break  # a train found the trunk red
if [ "$_pass" -eq 2 ]; then
    [ -n "$_deferred" ] || break
    _p2="$_deferred"; _deferred=""
fi
while next_candidate; do
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

    _LQ_T=$SECONDS  # ORDER 2238-gpxz: the clock _lq_mark reads
    _lq_phase "$num" "$head" merge+door
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
    if ! _lq_alloc_steps "$num" "$base_sha"; then
        say "evict:land-queue:$num:$_lq_alloc_verdict"
        pr_comment "$num" "Evicted from the landing queue: a gate step this PR adds shares a numeric prefix with one on \`$TRUNK\` at \`${base_sha:0:9}\`, and the queue could not move it to a free slot (\`$_lq_alloc_verdict\`).

Renumber the step in \`scripts/gate-steps.d/\` to a free prefix and push; the queue will pick it up again.$(evict_marker "$num" "$head_sha" "$base_sha" "gate-step-prefix")"
        evicted=$((evicted + 1))
        continue
    fi
    merge_sha="$(git rev-parse HEAD)"

    # ── A FROZEN TARGET HOLDS CODE (1255-s4im) ───────────────────────────────
    # Asked BEFORE the gate, so no gate is spent on a landing the freeze would
    # refuse, and asked of ORIGIN by the tool itself: the pre-push hook refuses
    # this only on a host whose hook is armed. A candidate that carries only
    # paths the freeze exempts (ledger, docs, skills, cheatsheets) still lands —
    # that is how coordination keeps moving during a cut. HOLD is not EVICT: the
    # candidate is fine, the branch is closed; it lands after the freeze clears.
    _frz_paths="$(freeze_held_paths "$base_sha" "$merge_sha" | head -n 1)"
    if [ -n "$_frz_paths" ]; then
        _frc=0; _fm="$(freeze_markers "$REMOTE" "$TRUNK")" || _frc=$?
        if [ "$_frc" -ne 0 ]; then
            say "hold:land-queue:$num:freeze-unknown — git ls-remote $REMOTE failed, and this candidate carries held code ($_frz_paths); not gating into a branch whose freeze state is unknown"
            skipped=$((skipped + 1))
            continue
        fi
        if [ -n "$_fm" ]; then
            say "hold:land-queue:$num:frozen:$(printf '%s\n' "$_fm" | head -n 1 | cut -f2) — carries held code ($_frz_paths); it lands after the freeze clears"
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
        # ORDER 2152-t5p9: refused:carried:paid-but-taken-by:<ref>:<item> has no
        # backlog in field 3 — the guard keys waivers by BACKLOG name, so take it
        # from the guard's own waiver line, never from the verdict.
        if [ "$_cb" = paid-but-taken-by ]; then
            _ck=paid-but-taken
            _cb="$(printf '%s\n' "$_cwaiver" | awk '{print $2}')"
            [ -n "$_cb" ] || _cb='<backlog>'
            [ -n "$_cwaiver" ] || _cwaiver="Carried-Waiver: <backlog> conflict:<item> (#<pr>)"
        fi
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
    # ── ORDER 2143-z5uj: A PLAN-LEDGER-ONLY CANDIDATE TAKES THE PLAN LANE ────
    # Operator ruling 2026-11-20: a PR whose whole merge delta classifies as
    # plan-ledger lands through the plan-lane checks (fragment parse and
    # `tillandsias-plan check`) with NO build-check. #1166 took 53 min of full
    # gate for ledger fragments. The classifier is the same one the adopt path
    # trusts (delta_plan_only); an unreadable answer is NOT plan-only.
    _lane=full
    if [ "$PLAN_ONLY_LANE" = 1 ] && delta_plan_only "$base_sha" "$merge_sha"; then
        _lane=plan-only
        say "land-queue: #$num lane=plan-only — every changed path is plan-ledger; plan-lane checks only, no build-check"
    fi
    # ── ORDER 2118-tpmy: THE HOST DOOR ──────────────────────────────────────
    if [ -n "$HOST_DOOR" ] && [ "$_lane" = full ]; then
        if [ -n "$SIDECAR_STAGE" ]; then
            ( eval "$SIDECAR_STAGE" ) < /dev/null > "$_RUNDIR/pr-$num-sidecar.log" 2>&1 || true
        fi
        _hd="$( ( eval "$HOST_DOOR" ) < /dev/null 2>/dev/null | grep -m 1 -E '^(ok:host-door|could-not-run:host:)' )"
        case "$_hd" in
            ok:host-door*) ;;
            could-not-run:host:*)
                say "$_hd — #$num is not evicted for this host's state; next candidate"
                skipped=$((skipped + 1))
                continue ;;
            *)
                say "could-not-run:host:door-did-not-answer — #$num is not evicted; next candidate"
                skipped=$((skipped + 1))
                continue ;;
        esac
    fi
    _lq_mark "$num" merge+door
    _lq_phase "$num" "$head" plan-refresh
    # ── ORDER 1992-lqpb: A CURRENT PLAN BINARY BEFORE ANY DOOR ───────────────
    # The binary's state is this HOST's, never the candidate's: a refresh that
    # cannot make it current stops the run and evicts nobody.
    # ORDER 2152-lqrf: and it is skipped when cargo's own input list hashes the
    # same as at the last successful refresh (see PLAN_DEPINFO).
    _rkey=""
    if [ -n "$PLAN_REFRESH" ] && [ "$_lane" = full ]; then
        _rkey="$(plan_refresh_key)" || _rkey=""
    fi
    if [ -n "$PLAN_REFRESH" ] && [ "$_lane" = full ] && [ -n "$_rkey" ] \
        && [ "$_rkey" = "$(cat "$PLAN_REFRESH_STAMP" 2>/dev/null)" ]; then
        say "plan-refresh:skipped:inputs-unchanged:#$num:${_rkey:0:12}"
    elif [ -n "$PLAN_REFRESH" ] && [ "$_lane" = full ]; then
        _rlog="$_RUNDIR/pr-$num-plan-refresh.log"
        ( eval "$PLAN_REFRESH" ) < /dev/null > "$_rlog" 2>&1
        _rrc=$?
        # Stamp only a SUCCESSFUL refresh, keyed AFTER it (the build rewrote the
        # dep-info and the binary). A failed stamp write only costs a rebuild.
        if [ "$_rrc" -eq 0 ] && _rkey="$(plan_refresh_key)"; then
            mkdir -p "$(dirname "$PLAN_REFRESH_STAMP")" 2>/dev/null
            printf '%s\n' "$_rkey" > "$PLAN_REFRESH_STAMP" 2>/dev/null || true
        fi
        if [ "$_rrc" -ne 0 ]; then
            # ORDER 2143-z5uj: SKIP THIS CANDIDATE, DO NOT END THE RUN. The refresh
            # builds from the merge of THIS candidate, so another candidate's merge
            # may refresh cleanly; ending the run stalled the whole queue on one.
            say "could-not-run:host:plan-binary-stale:#$num:rc=$_rrc — the plan binary could not be refreshed from the merge of #$num; nothing is evicted for this host's state; next candidate (log: $_rlog)"
            say "remedy: cargo build --release -p tillandsias-plan && bash scripts/check-plan-binary-current.sh, then run the queue again"
            skipped=$((skipped + 1))
            continue
        fi
        rm -f "$_rlog"
    fi
    _lq_mark "$num" plan-refresh
    _lq_phase "$num" "$head" preflight
    # ── ORDER 1765-q7rg: THE PREFLIGHT DOOR BEFORE THE FULL GATE ─────────────
    # The tree-only deciders answer in about a minute; a decider-level red
    # (exit 1) here is the same red the full gate would reach after ~21 min.
    # A stale plan binary on THIS host also exits 1 but says nothing about the
    # candidate, and any other code is the door failing to run: both go on to
    # the full gate, which decides as it always did.
    if [ -n "$PREFLIGHT" ] && [ "$_lane" = full ]; then
        _plog="$_RUNDIR/pr-$num-preflight.log"
        ( _gate_clean_env; eval "$PREFLIGHT" ) < /dev/null > "$_plog" 2>&1
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

    _lq_mark "$num" preflight
    _lq_phase "$num" "$head" gate
    _glog="$_RUNDIR/pr-$num-gate.log"
    # No pipeline: a `$GATE | tee` would hand us tee's status, which is the
    # 859-4jny bug one layer over.
    # 2174-dail: the class selector may skip unchanged steps only against a daily proof.
    gate_env_for "$base_sha"
    _sh_base="$base_sha"
    _gcmd="$GATE"
    [ "$_lane" = plan-only ] && _gcmd="$PLAN_LANE_CHECK"
    ( _gate_clean_env; eval "$_gcmd" ) < /dev/null > "$_glog" 2>&1
    _grc=$?
    _lq_mark "$num" gate
    _lq_phase "$num" "$head" post-gate+push
    grep -o 'skip:class-selector:[^ ]*' "$_glog" > "$_RUNDIR/pr-$num-skips" 2>/dev/null || : > "$_RUNDIR/pr-$num-skips"  # 2174-dail: the gate log is removed on a green land
    # ── ORDER 2143-z5uj: A RED IN A TEST THE CANDIDATE DID NOT TOUCH IS RE-RUN
    # ONCE, ON THE IDENTICAL TREE, BEFORE IT EVICTS ANYONE. Measured 2026-11-20:
    # eight evictions in one day were one SIGPIPE flake class in fixtures the
    # evicted PRs never touched, each a ~20-min gate plus a requeue. The failing
    # tests are named from the gate's verdict lines (a scripts/ path, or
    # litmus:<name>); a candidate whose diff touches one of them, or a red that
    # names no test at all, is judged on the first run as before, so an
    # unknown red is never waved through. Green on the re-run prints
    # flaky:<test> and lands; red prints evicted:<test> (fleet vocabulary,
    # 2026-11-20).
    _flaky_test=""
    if [ "$_grc" -eq 1 ] && [ "$_lane" = full ] && ! grep -q '^flaky:' "$_glog" 2>/dev/null; then
        _ftests="$(grep -E '^[[:space:]]*(FAIL|\[FAIL\]|refused:|violation:|blocked:)' "$_glog" 2>/dev/null \
                   | grep -oE 'scripts/[A-Za-z0-9_./-]+\.(sh|lua)|litmus:[A-Za-z0-9_-]+' | sort -u)"
        # ORDER 2277-7trt: red-twice:<test file>:... is the step runner saying it ran
        # that step twice on this tree and both were red (2276-5pzy). Its test joins
        # the named ones, and when EVERY named test is one of those the re-run below
        # would spend a gate on a question already answered twice. The trunk-red
        # check after it still runs.
        _rtwice=""
        while IFS= read -r _rb; do
            [ -n "$_rb" ] || continue
            _rtwice="$_rtwice$(git ls-files -- "scripts/$_rb" "scripts/lua/$_rb" | head -n 1)"$'\n'
        done <<< "$(sed -n 's/^red-twice:\([A-Za-z0-9_.-]*\):.*/\1/p' "$_glog" 2>/dev/null | sort -u)"
        _rtwice="$(grep . <<<"$_rtwice")"
        _ftests="$(printf '%s\n%s\n' "$_ftests" "$_rtwice" | grep . | sort -u)"
        _fdiff="$(git diff --name-only "$base_sha" "$merge_sha" 2>/dev/null)"
        _touched=0
        if [ -n "$_ftests" ]; then
            while IFS= read -r _t; do
                case "$_t" in
                    litmus:*) _tp="openspec/litmus-tests/litmus-${_t#litmus:}.yaml" ;;
                    *) _tp="$_t" ;;
                esac
                grep -qxF "$_tp" <<<"$_fdiff" && { _touched=1; break; }
            done <<< "$_ftests"
            if [ "$_touched" -eq 0 ]; then
                _flaky_test="$(head -n 1 <<<"$_ftests")"
                if [ -n "$_rtwice" ] && [ -z "$(grep -vxF -- "$_rtwice" <<<"$_ftests")" ]; then
                    say "land-queue: #$num red-twice in $_flaky_test, already run twice on this tree — not re-running the gate"
                else
                    say "land-queue: #$num red in $_flaky_test, which its diff does not touch — re-running the gate once on the identical tree"
                    ( _gate_clean_env; eval "$_gcmd" ) < /dev/null > "$_glog.rerun" 2>&1
                    _grc=$?
                fi
                if [ "$_grc" -eq 0 ]; then
                    say "flaky:$_flaky_test — #$num red then green on the identical tree ${merge_sha:0:9}; landing"
                    mv -f "$_glog" "$_glog.first-red"
                else
                    [ ! -e "$_glog.rerun" ] || mv -f "$_glog.rerun" "$_glog"
                    # ORDER 2118-tpmy: RED TWICE. Is it the trunk's red? The bare
                    # trunk is gated once per base; the same failing test there
                    # holds the queue instead of evicting a candidate for it.
                    _trunk_red=""
                    trunk_red "$base_sha" "$merge_sha" "$_flaky_test" "$_gcmd" "$_glog.trunk" && _trunk_red="$_flaky_test"
                    if [ -n "$_trunk_red" ]; then
                        shadow_note "$num" "$_sh_base" "$head_sha" trunk-red single
                        say "hold:trunk-red:$_trunk_red — trunk ${base_sha:0:9} fails it too; #$num is not evicted; the queue holds until trunk is fixed (full log: $_glog)"
                        rm -f "$_glog.rerun"
                        _held=1
                        break 2
                    fi
                    say "evicted:$_flaky_test — #$num red twice on the identical tree ${merge_sha:0:9}"
                fi
                rm -f "$_glog.rerun"
            fi
        fi
    fi
    if [ "$_lane" = full ]; then
        if [ "$_grc" -eq 0 ]; then _sh_g=green; [ -z "$_flaky_test" ] || _sh_g=flaky
        elif grep -q '^flaky:' "$_glog" 2>/dev/null; then _sh_g=flaky
        elif [ "$_grc" -eq 1 ]; then _sh_g=red; else _sh_g=aborted; fi
        shadow_note "$num" "$_sh_base" "$head_sha" "$_sh_g" single
    fi
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
        # ORDER 2234-a964: rc=255 (podman/crun could not start the gate, a host
        # going down) or 128+ (a signal) is THIS HOST's state, not a verdict on
        # the tree, so it is could-not-run:host like the host door (ARM 34):
        # nobody is evicted, nobody is commented, the run goes on. Measured on
        # macuahuitl run 29: crun "join keyctl: Disk quota exceeded" from leaked
        # builder exec sessions evicted 14 PRs with rc=255.
        if [ "$_grc" -ge 128 ]; then
            say "could-not-run:host:gate-aborted:rc=$_grc — #$num is not evicted; next candidate (log: $_glog)"
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
    _frz_paths="$(freeze_held_paths "$base_sha" "$merge_sha" | head -n 1)"
    if [ -n "$_frz_paths" ]; then
        _frc=0; _fm="$(freeze_markers "$REMOTE" "$TRUNK")" || _frc=$?
        if [ "$_frc" -ne 0 ] || [ -n "$_fm" ]; then
            say "requeue:land-queue:$num:frozen-mid-gate:$( [ "$_frc" -ne 0 ] && echo "freeze-unknown" || printf '%s\n' "$_fm" | head -n 1 | cut -f2) — the gate was green but $TRUNK froze while it ran and this carries held code ($_frz_paths); nothing was pushed"
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
        _land_trailers "$num" "$_lane"
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
        _lq_mark "$num" post-gate+push
        not_run_line "$_RUNDIR/pr-$num-skips"
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
done
done

shadow_launch
if [ "$_held" -eq 1 ]; then
    say "hold:land-queue:$_n landed=$landed evicted=$evicted requeued=$requeued skipped=$skipped — held on a trunk red (2118-tpmy)"
    exit 4
fi
say "ok:land-queue:$_n landed=$landed evicted=$evicted requeued=$requeued skipped=$skipped"
exit 0
