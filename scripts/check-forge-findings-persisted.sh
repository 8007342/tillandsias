#!/bin/bash
# freshness: refreshed 2026-08-15 linux-immutable-20260814
set -uo pipefail
# @trace spec:meta-orchestration
# @trace order:741-3y48, order:737-zcj5
#
# check-forge-findings-persisted.sh: refuse to let a cycle end with findings
# that only exist on a filesystem about to be destroyed (order 741-3y48).
#
# WHY THIS EXISTS. On 2026-08-15 an in-forge review agent did everything right.
# It broke the MCP health probe in both directions, minted three order tokens,
# wrote three well-formed fragments into plan/index.d/, and confirmed the ledger
# accepted them — `tillandsias-plan check` -> ok, 857 packets, ids unique. Then
# the forge tore down.
#
# The forge's checkout is a `git clone` from the enclave mirror into a
# container-local directory (lib-common.sh: checkout_forge_seed_branch). It is
# ephemeral BY DESIGN — that is the project's Erlang-style stance and it is
# correct. But nothing gave the durable OUTPUT a separate path off that
# substrate, so all three fragments died with the container:
#
#   git status --porcelain (host)                        -> clean
#   git ls-tree origin/linux-next plan/index.d/ | grep 741 -> nothing
#
# They reached the ledger only because the agent ALSO printed a human-readable
# summary, the launching host happened to be reading stdout, and re-filed them by
# hand. Unattended — the normal case for `./repeat --agent opencode` and every
# litmus-launched forge cycle — four real defects would have vanished silently
# while every outer launcher returned zero.
#
# That is 737-zcj5's shape one level up. There, an outage left no artifact
# because recording depended on an agent choosing to. Here the agent DID choose
# to, wrote a valid artifact, and the substrate discarded it anyway. A cycle
# cannot fix that by being more careful; it needs something that refuses.
#
# WHAT COUNTS AS A FINDING. The append-only plan surfaces an agent files into:
#   plan/index.d/                 packet fragments
#   plan/loop_status.d/           cycle status fragments
#   plan/issues/                  dated issue markdown
#   plan/mo-full-attestations.d/  per-host attestation ledger
#
# VERDICT GRAMMAR (pinned by litmus:forge-findings-persistence-shape):
#   ^(ok:(no-findings|findings-persisted)|unpersisted:[a-z-]+(,[a-z-]+)*|skip:[a-z0-9-]+)$
#
#   ok:no-findings          nothing pending — this cycle filed nothing, or
#                           everything it filed is already on the remote
#   ok:findings-persisted   --since was given, findings landed in that range,
#                           and every one of them is on the remote
#   unpersisted:uncommitted findings exist in the worktree and are not committed
#   unpersisted:unpushed    findings are committed but the branch is ahead of its
#                           remote — one teardown from being lost
#   unpersisted:no-remote-tracking  a finding exists but no remote-tracking ref
#                           can prove it landed (detached HEAD, upstream-less
#                           branch, or an upstream pointing at a LOCAL ref)
#   skip:<reason>           the probe could not decide (not a repo, no remote)
#
# Exit: 0 ok, 1 unpersisted, 3 skip.
#
# NEGATIVE CONTROL, and it is the hard requirement. A cycle that legitimately
# files nothing MUST print `ok:no-findings` and create no artifact. A guard that
# nags every clean cycle is one every agent learns to ignore, which is the exact
# failure mode this milestone keeps repairing.
#
# THIS GUARD IS A GATE, not advisory — unlike check-mcp-expert-health.sh. A
# missing expert makes reads costlier; an unpersisted finding is WORK ALREADY
# DONE being thrown away, and it is unrecoverable once the container exits.
#
# Testability seam: TILLANDSIAS_FINDINGS_REMOTE_REF overrides the remote ref the
# comparison uses, so fixtures need no network.

# THE WHOLE plan/ TREE, not an enumeration (order 743-rhr4). The first version
# listed four directories, and an in-forge adversarial review immediately filed a
# finding into `plan/forge-improvements/proposals/` — a surface
# `advance-work-from-plan` explicitly instructs in-forge agents to use — committed
# it, never pushed it, and got `ok:no-findings`. Green while losing work.
#
# Enumerating surfaces is a losing game: skills reference plan/issues,
# plan/diagnostics, plan/forge-improvements, plan/steps and plan/localwork today,
# and any new one silently falls outside the gate. The whole tree is the honest
# superset, and git's own ignore rules already exclude generated content, so
# widening this cannot create the false alarms the negative control forbids.
FINDING_PATHS="plan"

usage() {
    echo "usage: check-forge-findings-persisted.sh [--since <ref>]" >&2
    exit 2
}

# Hermetic scenario fixtures. Each builds a throwaway repo with a real bare
# remote, so the persisted/unpersisted distinction is exercised against actual
# git state rather than a mock — the whole point of this guard is that it sees
# what `git status` cannot.
fixture() {
    _fx_fail=0
    _fx_self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    _fx_dir="$(mktemp -d)"

    git init -q -b linux-next "$_fx_dir/repo" 2>/dev/null
    git init -q --bare "$_fx_dir/remote" 2>/dev/null
    (
        cd "$_fx_dir/repo" || exit 1
        git config user.email fixture@localhost
        git config user.name fixture
        mkdir -p plan/index.d
        printf 'packets: []\n' >plan/index.d/base.yaml
        git add -A && git commit -qm base
        git remote add origin "$_fx_dir/remote"
        git push -q origin linux-next
        git branch --set-upstream-to=origin/linux-next -q
    ) >/dev/null 2>&1

    _fx_expect() {
        _n="$1"; _want_v="$2"; _want_rc="$3"
        _got_v="$(cd "$_fx_dir/repo" && bash "$_fx_self" ${4:-})"
        _got_rc=$?
        if [ "$_got_v" = "$_want_v" ] && [ "$_got_rc" = "$_want_rc" ]; then
            echo "ok: $_n ($_got_v rc=$_got_rc)"
        else
            echo "FAIL: $_n expected '$_want_v' rc=$_want_rc, got '$_got_v' rc=$_got_rc"
            _fx_fail=1
        fi
    }

    # NEGATIVE CONTROL FIRST: a cycle that files nothing must be silent.
    _fx_expect "negative-control-clean-cycle-is-silent" "ok:no-findings" 0

    printf 'packets: [{packet_id: fixture-finding}]\n' >"$_fx_dir/repo/plan/index.d/finding.yaml"
    _fx_expect "uncommitted-finding-fails-loud" "unpersisted:uncommitted" 1

    (cd "$_fx_dir/repo" && git add plan/index.d/finding.yaml && git commit -qm "file a finding") >/dev/null 2>&1
    # The case `git status` calls clean and a teardown would destroy.
    _fx_expect "committed-but-unpushed-fails-loud" "unpersisted:unpushed" 1

    (cd "$_fx_dir/repo" && git push -q origin linux-next) >/dev/null 2>&1
    _fx_expect "pushed-finding-passes" "ok:no-findings" 0
    _fx_expect "pushed-finding-with-since-reports-persisted" "ok:findings-persisted" 0 "--since HEAD~1"

    # ── 743-rhr4: a surface the first version did not enumerate ───────────────
    # `advance-work-from-plan` tells in-forge agents to file proposals here. The
    # enumerated gate returned ok:no-findings for a committed, unpushed one.
    mkdir -p "$_fx_dir/repo/plan/forge-improvements/proposals"
    printf '# proposal\n' >"$_fx_dir/repo/plan/forge-improvements/proposals/2026-08-15-x.md"
    ( cd "$_fx_dir/repo" && git add -A && git commit -qm "file a proposal" ) >/dev/null 2>&1
    _fx_expect "REGRESSION uncovered-surface-forge-improvements-is-caught" "unpersisted:unpushed" 1
    ( cd "$_fx_dir/repo" && git push -q origin linux-next ) >/dev/null 2>&1
    _fx_expect "…and passes once pushed" "ok:no-findings" 0

    # ── 743-yej2: @{upstream} pointed at a LOCAL branch ───────────────────────
    # A local ref that already contains the finding commits made the gate green
    # while the work existed only on container-local refs.
    printf '# proposal 2\n' >"$_fx_dir/repo/plan/forge-improvements/proposals/2026-08-15-y.md"
    ( cd "$_fx_dir/repo" \
        && git add -A && git commit -qm "second proposal" \
        && git branch -f decoy HEAD \
        && git branch --set-upstream-to=decoy -q ) >/dev/null 2>&1
    # The poisoned upstream is rejected, and the origin/<branch> fallback then
    # supplies a MORE precise reason than no-remote-tracking. Refusing is the
    # requirement; `unpushed` is the accurate diagnosis when a real remote
    # counterpart exists to compare against.
    _fx_expect "REGRESSION local-branch-upstream-is-not-trusted" "unpersisted:unpushed" 1
    ( cd "$_fx_dir/repo" && git branch --set-upstream-to=origin/linux-next -q && git push -q origin linux-next ) >/dev/null 2>&1
    _fx_expect "…and passes once a real remote-tracking ref is restored" "ok:no-findings" 0

    # Poisoned upstream with NO origin counterpart to fall back to — the shape
    # where trusting @{upstream} blindly produced a green verdict over work that
    # lived only on container-local refs.
    printf '# proposal on an unpublished branch\n' >"$_fx_dir/repo/plan/forge-improvements/proposals/2026-08-15-w.md"
    ( cd "$_fx_dir/repo" \
        && git checkout -q -b never-pushed \
        && git add -A && git commit -qm "finding on an unpublished branch" \
        && git branch --set-upstream-to=decoy -q ) >/dev/null 2>&1
    _fx_expect "REGRESSION poisoned-upstream-with-no-remote-counterpart-refuses" "unpersisted:no-remote-tracking" 1
    ( cd "$_fx_dir/repo" && git checkout -q linux-next ) >/dev/null 2>&1

    # ── 743-yej2 (second half): detached HEAD carrying a committed finding ────
    # Previously `skip:no-remote-ref` exit 3 — a non-refusal every caller reads
    # as success, for a finding one teardown from gone.
    printf '# proposal 3\n' >"$_fx_dir/repo/plan/forge-improvements/proposals/2026-08-15-z.md"
    ( cd "$_fx_dir/repo" \
        && git checkout -q --detach HEAD \
        && git add -A && git commit -qm "detached proposal" ) >/dev/null 2>&1
    _fx_expect "REGRESSION detached-head-with-committed-finding-refuses" "unpersisted:no-remote-tracking" 1
    ( cd "$_fx_dir/repo" && git checkout -q linux-next ) >/dev/null 2>&1

    # A project with no plan surfaces at all is not a Tillandsias checkout and
    # must never be told it has unpersisted findings.
    rm -rf "$_fx_dir/repo/plan"
    _fx_expect "off-tillandsias-project-has-no-findings" "ok:no-findings" 0

    rm -rf "$_fx_dir"
    [ "$_fx_fail" = 0 ] && echo "ok: all forge-findings-persistence scenarios passed"
    return "$_fx_fail"
}

if [ "${1:-}" = "fixture" ]; then
    fixture
    exit $?
fi

SINCE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --since) SINCE="${2:-}"; [ -n "$SINCE" ] || usage; shift 2 ;;
        -h|--help) usage ;;
        *) usage ;;
    esac
done

git rev-parse --git-dir >/dev/null 2>&1 || { echo "skip:not-a-git-repo"; exit 3; }

# Only consider paths that actually exist in this checkout — an off-Tillandsias
# project has none of them and must not be told it has unpersisted findings.
existing=""
for p in $FINDING_PATHS; do
    [ -e "$p" ] && existing="${existing:+$existing }$p"
done
if [ -z "$existing" ]; then
    echo "ok:no-findings"
    exit 0
fi

reasons=""

# 1. Uncommitted: anything status-visible under a finding path, tracked or not.
# shellcheck disable=SC2086
if [ -n "$(git status --porcelain --untracked-files=all -- $existing 2>/dev/null)" ]; then
    reasons="uncommitted"
fi

# 2. Unpushed: committed, but the commits touching finding paths are not on the
# remote. `git status` is blind to this — a committed fragment looks identical to
# a pushed one, and that is precisely how the 2026-08-15 loss would have read as
# clean if the agent had committed but not pushed.
branch="$(git symbolic-ref --short HEAD 2>/dev/null || true)"
remote_ref="${TILLANDSIAS_FINDINGS_REMOTE_REF:-}"
if [ -z "$remote_ref" ] && [ -n "$branch" ]; then
    # The upstream must be a REMOTE-TRACKING ref (order 743-yej2). `@{upstream}`
    # can legally point at another LOCAL branch, and the first version trusted it
    # blindly: pointing it at a local branch that already contained the finding
    # commits produced `ok:no-findings` while the work existed only on
    # container-local refs — precisely the loss this gate exists to prevent,
    # wearing a green verdict. Resolve it and require refs/remotes/.
    upstream_full="$(git rev-parse --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
    case "$upstream_full" in
        refs/remotes/*) remote_ref="$upstream_full" ;;
        *) : ;;
    esac
    if [ -z "$remote_ref" ] && git rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null 2>&1; then
        remote_ref="refs/remotes/origin/$branch"
    fi
fi

if [ -z "$remote_ref" ]; then
    if [ -n "$reasons" ]; then
        echo "unpersisted:$reasons"
        exit 1
    fi
    # No remote-tracking ref. If the repo HAS a remote, persistence is simply
    # unproven — and for a GATE that must be a refusal, not a pass. A detached
    # HEAD or an upstream-less branch carrying a committed finding previously
    # returned `skip:no-remote-ref` (exit 3), which every caller treats as
    # not-a-failure: the finding was one teardown from gone and the gate shrugged.
    if [ -n "$(git remote 2>/dev/null)" ]; then
        echo "unpersisted:no-remote-tracking"
        exit 1
    fi
    # Genuinely remote-less repo (a scratch clone, never a forge): nothing to
    # prove and nowhere to prove it.
    echo "skip:no-remote"
    exit 3
fi

# shellcheck disable=SC2086
ahead="$(git rev-list --count "$remote_ref..HEAD" -- $existing 2>/dev/null || echo 0)"
case "$ahead" in
    ''|*[!0-9]*) ahead=0 ;;
esac
if [ "$ahead" -gt 0 ]; then
    reasons="${reasons:+$reasons,}unpushed"
fi

if [ -n "$reasons" ]; then
    echo "unpersisted:$reasons"
    exit 1
fi

# Clean. Distinguish "filed and persisted" from "filed nothing" only when the
# caller supplied the cycle's start ref; without it, silence is the honest
# answer and the negative control requires it.
if [ -n "$SINCE" ] && git rev-parse --verify --quiet "$SINCE" >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    landed="$(git rev-list --count "$SINCE..HEAD" -- $existing 2>/dev/null || echo 0)"
    case "$landed" in
        ''|*[!0-9]*) landed=0 ;;
    esac
    if [ "$landed" -gt 0 ]; then
        echo "ok:findings-persisted"
        exit 0
    fi
fi

echo "ok:no-findings"
exit 0
