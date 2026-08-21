#!/usr/bin/env bash
# freshness: auditor=linux-macuahuitl-opus5-20260821T1300Z date=2026-08-21 verdict=new scope=843-arch-answerable — the acceptance test yesterday's archival attempt lacked.
#
# WHAT THIS ESTABLISHES, and why the two checks that already exist do not.
#
# scripts/archive-plan-packets.sh --check asserts two LEDGER-SHAPE properties:
# the ready set is byte-identical across a sweep, and the sweep orphans no
# fragment events. Both are true statements about rows. Neither can see a
# CAPABILITY loss — that after archiving, `status <archived-id>` and the
# `answer` path return `unsupported: no packet in the ledger matches any
# token` for all 550 archived packets. A ledger-shape assertion looks at the
# ledger; this defect lives in the query engine's reach over it.
#
# So this check runs the real sweep against a full COPY of the tree and then
# runs the crate's own suite INSIDE that copy. The suite's fixtures resolve
# through `env!("CARGO_MANIFEST_DIR")/../..`, which in the copy is the copy —
# so the same 200+ assertions that pass against the live ledger are re-asked
# against the POST-ARCHIVE one. That is the whole trick, and it is the reason
# this file is a tree copy and not a plan/ copy.
#
# THE LIVE LEDGER IS NEVER TOUCHED. The sweep rewrites plan/index.yaml in
# place; it runs only ever against the copy under $WORK.
#
# COST: 6s measured on linux-mutable 2026-08-21 with a warm $WORK/target, which
# is why it is wired into archive-plan-packets.sh --check rather than left as a
# thing to remember. The FIRST run on a host pays a cold cargo build (~90s);
# $WORK/target is deliberately kept between runs so that is paid once per boot
# rather than once per invocation.
#
# Exit codes are three-valued, like `plan grade`:
#   0 — the sweep ran and the post-archive suite is green;
#   1 — the sweep ran and something is RED (this is the regression);
#   2 — the check could not run (no plan binary, no toolchain, bad copy).
# 1 and 2 are kept apart because "the suite disagreed" and "the suite never
# ran" call for completely different actions, and conflating them is how a
# gate rots into a no-op that reports success.
#
# Verdict grammar: one line, ok:<name>:<detail> or fail:<name>:<detail>.
set -u

NAME="archive-answerability"
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$(dirname "$DIR")"

KEEP=0
for arg in "$@"; do
    case "$arg" in
        --keep) KEEP=1 ;;
        *) echo "fail:${NAME}:unknown-argument:${arg}"; exit 2 ;;
    esac
done

# A STABLE work root, not a mktemp one. The cargo target dir under it survives
# between runs, and cargo's fingerprints embed absolute source paths — a fresh
# mktemp every run means a fresh full rebuild every run, which turns a check
# anyone can afford to run into one nobody does. The tree itself is wiped and
# recopied each time, so the input is still pristine; only the compiler cache
# persists.
WORK="${TILLANDSIAS_ARCHIVE_CHECK_WORK:-${TMPDIR:-/tmp}/tillandsias-archive-answerability}"
TREE="$WORK/tree"
LOG="$WORK/log"
rm -rf "$TREE" "$LOG"
if ! mkdir -p "$TREE" "$LOG"; then
    echo "fail:${NAME}:cannot-create-workdir:$WORK"; exit 2
fi
# Only the tree and the logs are transient; $WORK/target is the cache.
_cleanup() { [ "$KEEP" -eq 1 ] || rm -rf "$TREE"; }
trap _cleanup EXIT

# ---------------------------------------------------------------- copy tree
# Everything except build outputs and agent scratch. `git ls-files` would miss
# untracked-but-needed files and would not carry modes; a pruned copy is both
# simpler and more faithful. `.git` IS copied — gitref.rs shells out to git.
#
# THE PRUNE LIST IS LOAD-BEARING, and getting it wrong is not a slow copy, it
# is a dead host. The first draft of this script pruned only target*/ and .git,
# on the strength of a `du -sh ./*` that said the rest of the tree was 75 MB.
# That glob does not match dotfiles: `.claude/` holds this repo's agent
# worktrees and is SIXTY GIGABYTES. Copying it into a 32 GB tmpfs filled /tmp,
# and every subsequent shell died before it could print why. Hence both halves
# of what follows — the explicit dot-directory prunes, and a measured budget
# that refuses rather than discovers the next .claude the hard way.
TAR_PRUNE=(
    --exclude=./target
    --exclude=./target-musl
    --exclude=./target-guest
    --exclude=./.claude
    --exclude=./.opencode
    --exclude=./plan_tmp
    --exclude=./plan_tmp_bak
    --exclude=./node_modules
)

BUDGET_KB=$(( 1024 * 1024 ))   # 1 GiB
# du must be asked from INSIDE the root with `.` as the operand, exactly as tar
# is. The patterns are `./target`-shaped, and those match the member names du
# prints only when the operand is `.`; hand du the absolute path instead and
# every pattern silently misses, which is how this guard first reported 187 GB
# for a 188 MB copy. Same anchoring as tar, deliberately — the two must agree
# about what is being copied or the budget is measuring a different tree.
COPY_KB="$(cd "$REPO_ROOT" && du -sk "${TAR_PRUNE[@]}" . 2>/dev/null | awk '{print $1}')"
: "${COPY_KB:=0}"
if [ "$COPY_KB" -gt "$BUDGET_KB" ]; then
    echo "fail:${NAME}:copy-would-be-${COPY_KB}KB-over-budget-${BUDGET_KB}KB — refusing to fill $WORK; widen the prune list"
    exit 1
fi

if ! tar -C "$REPO_ROOT" "${TAR_PRUNE[@]}" -cf - . 2>"$LOG/copy.err" \
     | tar -C "$TREE" -xf - 2>>"$LOG/copy.err"; then
    echo "fail:${NAME}:tree-copy-failed:see-$LOG/copy.err"
    KEEP=1
    exit 1
fi

if [ ! -f "$TREE/plan/index.yaml" ]; then
    echo "fail:${NAME}:copy-missing-plan-index"
    exit 1
fi

# The archiver resolves the plan binary by EXECUTION through the shared probe
# (never a hardcoded target/ path — a build gate enforces this). The copy has
# no target/ of its own, so hand it the one already built beside the live
# tree. Resolution happens HERE, against the real repo, and is exported.
# shellcheck source=scripts/plan-binary-probe.sh
. "$DIR/plan-binary-probe.sh"
if ! PLAN_BIN="$(resolve_plan_binary)"; then
    echo "fail:${NAME}:no-runnable-plan-binary — the archiver decides closure from the fold and cannot run without one"
    exit 1
fi
case "$PLAN_BIN" in
    /*) ;;
    *) PLAN_BIN="$REPO_ROOT/${PLAN_BIN#./}" ;;
esac
export TILLANDSIAS_PLAN_BIN="$PLAN_BIN"

# ------------------------------------------------- ready set, BEFORE the sweep
# Recorded from the COPY, so the comparison is like-for-like with the after.
if ! "$PLAN_BIN" --index "$TREE/plan/index.yaml" ready > "$WORK/ready_before.txt" 2>"$LOG/ready_before.err"; then
    echo "fail:${NAME}:ready-listing-failed-before-sweep"
    KEEP=1
    exit 1
fi
READY_BEFORE="$(wc -l < "$WORK/ready_before.txt" | tr -d ' ')"

# ---------------------------------------------------------------- the sweep
# The copy's own archive script, so REPO_ROOT inside it is the copy.
if ! ( cd "$TREE" && ./scripts/archive-plan-packets.sh ) >"$LOG/sweep.out" 2>&1; then
    echo "fail:${NAME}:sweep-failed:see-$LOG/sweep.out"
    KEEP=1
    exit 1
fi

ARCHIVED_ROWS="$(grep -c 'packet_id:' "$TREE"/plan/archive/*.yaml 2>/dev/null | awk -F: '{s+=$NF} END {print s+0}')"

# ------------------------------------------------- ready set, AFTER the sweep
if ! "$PLAN_BIN" --index "$TREE/plan/index.yaml" ready > "$WORK/ready_after.txt" 2>"$LOG/ready_after.err"; then
    echo "fail:${NAME}:ready-listing-failed-after-sweep"
    KEEP=1
    exit 1
fi
READY_AFTER="$(wc -l < "$WORK/ready_after.txt" | tr -d ' ')"

if ! diff -u "$WORK/ready_before.txt" "$WORK/ready_after.txt" > "$WORK/ready_diff.txt"; then
    echo "fail:${NAME}:sweep-changed-the-ready-set:${READY_BEFORE}->${READY_AFTER}"
    sed -n '1,20p' "$WORK/ready_diff.txt"
    KEEP=1
    exit 1
fi

# ------------------------------------------------ THE CAPABILITY ASSERTION
# The crate suite, re-asked against the post-archive ledger. --offline so a
# missing network is a missing network and not a mystery; the registry cache
# beside the live tree already holds every dependency.
(
    cd "$TREE" || exit 3
    CARGO_TARGET_DIR="$WORK/target" cargo test --offline -p tillandsias-plan --lib
) >"$LOG/cargo-test.out" 2>&1
TEST_STATUS=$?

SUMMARY="$(grep -E '^test result:' "$LOG/cargo-test.out" | tail -1)"

# "THE SUITE DISAGREED" AND "THE SUITE NEVER RAN" ARE DIFFERENT ANSWERS, and
# collapsing them is how a gate rots into a no-op — the same distinction
# run_grade keeps between its exit 1 and exit 2. Without a `test result:` line
# there is no measurement here at all: cargo could not resolve --offline
# against a cold registry, the toolchain is missing, the copy does not build.
# Reporting that as "post-archive suite red" would send the next reader hunting
# for an archival regression that was never observed; reporting it as ok would
# be worse. Exit 2 — this check could not run.
if [ -z "$SUMMARY" ]; then
    echo "fail:${NAME}:suite-did-not-run — cargo produced no 'test result:' line (rc=$TEST_STATUS); this is a HARNESS failure, not an archival regression"
    tail -20 "$LOG/cargo-test.out"
    KEEP=1
    exit 2
fi

# Parsed off `passed;` / `failed;` and NOT off the `ok.` / `FAILED.` prefix.
# Keying on `ok\. \([0-9]*\) passed` reads zero on exactly the runs that matter
# — a red summary says "FAILED. 196 passed; 7 failed" — so the mutation control
# reported `0-passed-7-failed` for a run in which 196 tests passed. A verdict
# that misreports the failing case is worse than one that omits the number.
PASSED="$(sed -n 's/.*result: [^ ]* \([0-9][0-9]*\) passed.*/\1/p' <<<"$SUMMARY")"
FAILED="$(sed -n 's/.*passed; \([0-9][0-9]*\) failed.*/\1/p' <<<"$SUMMARY")"
: "${PASSED:=?}"
: "${FAILED:=?}"
TOTAL="?"
if [ "$PASSED" != "?" ] && [ "$FAILED" != "?" ]; then
    TOTAL=$(( PASSED + FAILED ))
fi

if [ "$TEST_STATUS" -ne 0 ]; then
    echo "fail:${NAME}:post-archive-suite-red:${PASSED}-passed-${FAILED}-failed-after-archiving-${ARCHIVED_ROWS}-packets"
    echo "--- failing tests ---"
    grep -E '^(failures:|    [a-z].*::)' "$LOG/cargo-test.out" | sed -n '1,40p'
    echo "--- first failure detail ---"
    sed -n '/^failures:$/,/^test result:/p' "$LOG/cargo-test.out" | sed -n '1,60p'
    KEEP=1
    exit 1
fi

echo "ok:${NAME}:${PASSED}/${TOTAL} after archiving ${ARCHIVED_ROWS} packets, ready set unchanged at ${READY_AFTER}"
exit 0
