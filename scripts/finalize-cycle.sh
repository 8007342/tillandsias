#!/usr/bin/env bash
# finalize-cycle.sh — the whole Finalization sequence as ONE command.
#
# ORDER 997-pdgf, the first remedy the token-consciousness directive produced,
# and it is NOT one of the two the operator named. It came from a MEASUREMENT
# rather than an opinion: lenovinha-silverblue reported finalization as the
# expensive-by-repetition step — `record` refusing twice because the boundary
# was verified at the old HEAD, the guard's `verify` needing a STATE_DIR that
# lives behind a pointer file, and the real sequence running verify, record,
# commit, land, verify again, self. FOUR EXTRA EXCHANGES, all mechanical.
# macuahuitl corroborated it independently, having fumbled the STATE_DIR
# argument itself — passing the POINTER FILE instead of the directory it names,
# reading the resulting `boundary-state-missing` as the state being GONE, and
# nearly reporting that the cycle could not attest.
#
# IT COSTS EXCHANGES RATHER THAN SECONDS. That is the distinction
# context_cost_metrics.step_repetition exists to catch: the expensive step is
# rarely the slow one, it is the one paid many times — every cycle, every host.
#
# WHY THIS REMEDY AND NOT /compact OR /clear. This one is MECHANICAL and
# LOSSLESS: it removes exchanges without discarding anything a cycle might need.
# The context-discarding remedies remain candidates, unadopted, pending data and
# fleet agreement (methodology context_cost_metrics.candidate_remedies_NOT_ADOPTED).
#
# COMPOSES, NEVER REIMPLEMENTS. Every step below is the same command a host runs
# by hand today, in the same order, with the same verdicts. This script resolves
# the STATE_DIR — the one fumble that cost two hosts an exchange each — and
# refuses at the first failure. It weakens no proof: the marker is still emitted
# by `mo-full-attest.sh self`, which verifies remote convergence itself.
#
# usage: scripts/finalize-cycle.sh <branch> [commit-message-file]
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || { echo "MO-FULL: FAIL cannot cd to repo root" >&2; exit 1; }

case "${1:-}" in
    -h|--help|help)
        cat <<'USAGE'
usage: scripts/finalize-cycle.sh [branch] [commit-message-file]

The whole Finalization sequence as one command (997-pdgf): verify boundary,
record the attestation, commit the ledger, land (gate + push + prove), re-verify,
emit the terminal marker. Refuses at the first failure and never emits a marker
after one.

Run it only when the cycle's work is ALREADY COMMITTED — the first boundary
verify refuses an uncommitted tree, which is the exit contract, not a bug.
USAGE
        exit 0 ;;
esac

BRANCH="${1:-$(git symbolic-ref --short HEAD 2>/dev/null)}"
[ -n "$BRANCH" ] || { echo "MO-FULL: FAIL no branch" >&2; exit 1; }

# THE FUMBLE THIS SCRIPT EXISTS FOR. $GIT_DIR/boundary-state is a POINTER FILE
# containing the path of the state DIRECTORY — not the directory itself. Passing
# the pointer to the guard yields `blocked:boundary-state-missing:<the path it
# names>`, which reads as "the state is gone" and is not.
_state_dir() {
    local ptr; ptr="$(git rev-parse --git-dir 2>/dev/null)/boundary-state"
    [ -r "$ptr" ] || return 1
    local dir; dir="$(cat "$ptr" 2>/dev/null)"
    [ -n "$dir" ] && [ -d "$dir" ] || return 1
    printf '%s' "$dir"
}

_step() { printf 'finalize: %s\n' "$1"; }

SD="$(_state_dir)" || {
    echo "refused:finalize:no-boundary-state — the cycle never snapshotted a startup boundary, so it cannot attest. Run the guard's snapshot at Start Of Cycle." >&2
    exit 2
}

_step "verify boundary at the work head"
scripts/meta-orchestration-worktree-guard.sh verify "$SD" || {
    echo "refused:finalize:boundary-verify-failed — resolve by hand; do NOT re-snapshot to make this pass, which compares a tree against itself." >&2
    exit 3
}

# ORDER MATTERS AND I GOT IT WRONG THE FIRST TIME. `record` attests the WORK
# head and REFUSES unless that head is already durably on the remote — so the
# work must LAND BEFORE the record, not after. My first composition ran
# verify->record->commit->land and refused at `record` with "local HEAD ... is
# not durably on origin/<branch>". The refusal was correct and the script was
# wrong; it caught its own author on first use, which is why it was run against
# a real cycle before being trusted.
_step "land the work head (gate + push + prove)"
scripts/land-on-platform-branch.sh "$BRANCH" 4 || {
    echo "refused:finalize:work-land-failed — the marker is NOT emitted; a marker may never follow an unpushed commit." >&2
    exit 6
}

_step "re-verify boundary after landing"
scripts/meta-orchestration-worktree-guard.sh verify "$SD" || {
    echo "refused:finalize:boundary-verify-failed-post-land" >&2; exit 3; }

_step "record the attestation (attests the now-landed WORK head)"
rec="$(scripts/mo-full-attest.sh record 2>&1)"; rc=$?
printf '%s\n' "$rec"
[ "$rc" -eq 0 ] && printf '%s' "$rec" | grep -q '^MO-FULL: COMPLETE' || {
    echo "refused:finalize:record-failed — the ledger line was not written; do NOT emit a marker." >&2
    exit 4
}

if ! git diff --quiet -- plan/mo-full-attestations.d 2>/dev/null; then
    _step "commit the ledger record"
    if [ -n "${2:-}" ] && [ -r "${2}" ]; then
        git add plan/mo-full-attestations.d && git commit -q -F "$2" || {
            echo "refused:finalize:commit-failed" >&2; exit 5; }
    else
        git add plan/mo-full-attestations.d && git commit -q -m "record(mo-full): attest ${BRANCH} cycle" || {
            echo "refused:finalize:commit-failed" >&2; exit 5; }
    fi
fi

_step "land the ledger record"
scripts/land-on-platform-branch.sh "$BRANCH" 4 || {
    echo "refused:finalize:ledger-land-failed — the record is committed but unpushed; do NOT emit a marker." >&2
    exit 6
}

_step "re-verify boundary at the head containing the record"
scripts/meta-orchestration-worktree-guard.sh verify "$SD" || {
    echo "refused:finalize:boundary-verify-failed-post-record" >&2; exit 3; }

# Best-effort context proxy, emitted where a cycle actually ends so the
# measurement collects itself rather than depending on anyone remembering
# (997-pdgf). BYTES, NOT TOKENS. Never fails the cycle it measures.
{
    _t="${TILLANDSIAS_TRANSCRIPT:-}"
    [ -n "$_t" ] && scripts/cycle-metrics.sh --emit-context \
        host="$(scripts/agent-identity.sh node-name 2>/dev/null || echo unknown)" \
        cycle="$(date -u +%Y-%m-%dT%H:%MZ)" transcript="$_t"
} >/dev/null 2>&1 || true

_step "derive the terminal marker"
exec scripts/mo-full-attest.sh self
