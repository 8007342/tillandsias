#!/usr/bin/env bash
# @trace order:2143-z5uj, spec:ci-release
#
# land-admit.sh — landing pipeline P6: the ADMISSION LANE. Decides cheaply,
# before any train gate, whether one PR may enter the landing queue, and
# records the answer on the PR keyed to its HEAD SHA.
#
# Design: plan/issues/landing-pipeline-p6-p8-design-2026-11-20-yoga.md, with
# the coordinator's answers of 2026-11-20:
#   - admission is keyed to the PR HEAD sha. Trunk moving does NOT void it (the
#     queue re-checks merge conflicts when it builds each train); a new head,
#     including a PR-side merge of linux-next, does, and re-admission is cheap.
#
# CHECKS, cheapest first; the first refusal wins and is the one verdict line:
#   1 ref shape   work/<NNNN-xxxx>          else hold:admit:#N:ref-shape
#   2 draft       not a draft               else hold:admit:#N:draft
#   3 lane        a ledger-only diff (gate-stamp classify = plan-ledger only)
#                 is lane=plan and skips 4-5: the plan lane gates it (operator
#                 ruling 2026-11-20, plan-only PRs land through plan checks)
#   4 native-lint check-native-lint-attested.sh on the head tree; rc 1 (today)
#                 or rc 3 (--hold, #1222) => label needs:native-lint,
#                 hold:native-lint:<pkg>:<sha>. The PR stays queued.
#   5 floor       the --floor gate on the head tree (operator ruling: --floor
#                 replaces the worker-side --preflight for work/* refs)
#                 else evicted:floor:#N:<rc>
#
# This is NOT the gate. A train still gates the union tree at its class tier.
# Admission only keeps a train from spending a full gate on a member that a
# minute's check would have refused.
#
# OUTPUT: exactly one verdict line on stdout:
#   admitted:#N:<sha12>:lane=<full|plan>
#   hold:admit:#N:<ref-shape|draft|no-head>
#   hold:native-lint:<pkg>:<sha12>
#   evicted:floor:#N:rc=<rc>
#   could-not-run:host:<reason>:#N
# rc 0 admitted, 1 hold/evicted, 3 could-not-run.
#
# RECORD: on admit, a PR comment ending in the machine line
#   <!-- land-admit:admitted pr=<n> head=<sha> lane=<full|plan> -->
# plus the label land:admitted (best effort). admitted_head <pr> below is
# how the queue asks "is this exact head admitted?" — a newer head answers no.
#
# Usage: land-admit.sh [--dry-run] <pr-number>
#        land-admit.sh --admitted-head <pr-number>   print the admitted sha or nothing
# Env:   TILLANDSIAS_LAND_ADMIT_GH         gh binary (default gh)
#        TILLANDSIAS_LAND_ADMIT_FLOOR      floor command, run in the head tree
#                                          (default: ./build.sh --floor)
#        TILLANDSIAS_LAND_ADMIT_LINT       native-lint command, run in the head
#                                          tree (default: scripts/check-native-lint-attested.sh)
#        TILLANDSIAS_LAND_ADMIT_REPO       checkout to judge in (default: this one)
#        TILLANDSIAS_LAND_ADMIT_REMOTE     remote (default origin)
#        TILLANDSIAS_TRUNK_BRANCH          trunk (default linux-next)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GH="${TILLANDSIAS_LAND_ADMIT_GH:-gh}"
REPO="${TILLANDSIAS_LAND_ADMIT_REPO:-$ROOT}"   # the checkout judged (fixtures point it at a scratch repo)
REMOTE="${TILLANDSIAS_LAND_ADMIT_REMOTE:-origin}"
TRUNK="${TILLANDSIAS_TRUNK_BRANCH:-linux-next}"
FLOOR="${TILLANDSIAS_LAND_ADMIT_FLOOR:-./build.sh --floor}"
LINT="${TILLANDSIAS_LAND_ADMIT_LINT:-bash scripts/check-native-lint-attested.sh}"

say() { printf '%s\n' "$*"; }
cnr() { say "could-not-run:host:$1:#${PR:-?}"; exit 3; }

# shellcheck source=scripts/plan-binary-probe.sh
. "$ROOT/scripts/plan-binary-probe.sh" 2>/dev/null || true
PLAN="$(cd "$ROOT" && resolve_plan_binary 2>/dev/null)" || { PR=""; cnr no-plan-binary; }
case "$PLAN" in /*) ;; */*) PLAN="$ROOT/${PLAN#./}" ;; esac

admitted_head() {  # <pr> — newest admission marker's head sha, or nothing
    "$GH" pr view "$1" --json comments 2>/dev/null \
        | "$PLAN" json get -r '.comments[].body' 2>/dev/null \
        | grep -o "<!-- land-admit:admitted pr=$1 head=[0-9a-f]* lane=[a-z]* -->" \
        | tail -n 1 | sed -n 's/.* head=\([0-9a-f]*\) .*/\1/p'
}

DRY_RUN=0
case "${1:-}" in
    --admitted-head) admitted_head "${2:?--admitted-head needs a PR number}"; exit 0 ;;
    --dry-run) DRY_RUN=1; shift ;;
esac
PR="${1:-}"
case "$PR" in ''|*[!0-9]*) say "usage: land-admit.sh [--dry-run] <pr-number>" >&2; exit 2 ;; esac

view="$("$GH" pr view "$PR" --json headRefName,isDraft,headRefOid 2>/dev/null)" || cnr gh-pr-view-failed
ref="$(printf '%s' "$view" | "$PLAN" json get -r '.headRefName' 2>/dev/null)"
draft="$(printf '%s' "$view" | "$PLAN" json get -r '.isDraft' 2>/dev/null)"
head="$(printf '%s' "$view" | "$PLAN" json get -r '.headRefOid' 2>/dev/null)"

# 1 ref shape
if ! grep -Eqx 'work/[0-9]{4}-[a-z0-9]{4}' <<<"$ref"; then
    say "hold:admit:#$PR:ref-shape"
    say "  why: the queue takes only work/<NNNN-xxxx> refs; this PR's head is '${ref:-?}'" >&2
    exit 1
fi
# 2 draft
if [ "$draft" = "true" ]; then
    say "hold:admit:#$PR:draft"
    say "  remedy: gh pr ready $PR when it is meant to land" >&2
    exit 1
fi
case "$head" in [0-9a-f]*) ;; *) say "hold:admit:#$PR:no-head"; exit 1 ;; esac
short="${head:0:12}"

git -C "$REPO" fetch -q "$REMOTE" "$TRUNK" "$ref" 2>/dev/null || cnr fetch-failed
git -C "$REPO" cat-file -e "$head^{commit}" 2>/dev/null || cnr head-not-fetched
base="$(git -C "$REPO" merge-base "$REMOTE/$TRUNK" "$head" 2>/dev/null)" || cnr no-merge-base

# 3 lane — an empty or unreadable classification is NOT plan-only.
lane=full
classes="$(git -C "$REPO" diff --name-only "$base" "$head" 2>/dev/null \
           | bash "$ROOT/scripts/gate-stamp.sh" classify 2>/dev/null | sort -u)"
[ "$classes" = "plan-ledger" ] && lane=plan

record() {
    local body
    body="$(printf 'land-admit: admitted head %s on lane %s.\n\n<!-- land-admit:admitted pr=%s head=%s lane=%s -->\n' \
            "$short" "$lane" "$PR" "$head" "$lane")"
    if [ "$DRY_RUN" -eq 1 ]; then say "  dry-run: would comment and label #$PR" >&2; return 0; fi
    "$GH" pr comment "$PR" --body "$body" >/dev/null 2>&1 \
        || say "  advisory: admission comment failed on #$PR; the queue will re-admit" >&2
    "$GH" pr edit "$PR" --add-label land:admitted >/dev/null 2>&1 || true
    "$GH" pr edit "$PR" --remove-label needs:native-lint >/dev/null 2>&1 || true
}

if [ "$lane" = plan ]; then
    record; say "admitted:#$PR:$short:lane=plan"; exit 0
fi

# 4-5 run in a detached worktree of the head, never in this checkout.
mkdir -p "$REPO/target"; WT="$(mktemp -d "$REPO/target/land-admit.XXXXXX")" || cnr no-scratch
rmdir "$WT"
cleanup() { git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1 || rm -rf "$WT"; }
trap cleanup EXIT
git -C "$REPO" worktree add -q --detach "$WT" "$head" 2>/dev/null || cnr worktree-add-failed

# 4 native-lint
lint_out="$(cd "$WT" && TILLANDSIAS_NATIVE_LINT_BASE="$base" $LINT 2>/dev/null)"; lrc=$?
case "$lrc" in
    0) ;;
    1|3)
        pkg="$(printf '%s\n' "$lint_out" | sed -n 's/^refused:native-lint:[a-z]*:\([^ ]*\).*/\1/p' | head -n 1)"
        [ "$DRY_RUN" -eq 1 ] || "$GH" pr edit "$PR" --add-label needs:native-lint >/dev/null 2>&1 || true
        say "hold:native-lint:${pkg:-unknown}:$short"
        exit 1 ;;
    *) cnr "native-lint-rc-$lrc" ;;
esac

# 5 floor. The default names a build.sh mode that may not exist yet on the
# head (--floor is the 2026-11-20 ruling's name); a missing mode is the host's
# inability to judge, never the PR's red.
if [ -z "${TILLANDSIAS_LAND_ADMIT_FLOOR:-}" ] && ! grep -q -- '--floor)' "$WT/build.sh" 2>/dev/null; then
    cnr floor-mode-absent
fi
( cd "$WT" && $FLOOR ) >"$WT.floor.log" 2>&1; frc=$?
if [ "$frc" -ne 0 ]; then
    say "evicted:floor:#$PR:rc=$frc"
    tail -n 5 "$WT.floor.log" | sed 's/^/  /' >&2
    rm -f "$WT.floor.log"
    exit 1
fi
rm -f "$WT.floor.log"

record
say "admitted:#$PR:$short:lane=full"
exit 0
