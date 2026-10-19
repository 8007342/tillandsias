#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "usage: $0 snapshot|re-snapshot|verify STATE_DIR" >&2
    exit 2
}

# EVERY REFUSAL SAYS WHY AND WHAT CLEARS IT (order 1247-b46r, 1247-amcu). The
# token or error: line before it is unchanged — finalize-cycle.sh and the
# fixtures match those — and this goes to stderr beside it.
_afford() { printf '  why: %s\n  remedy: %s\n' "$1" "$2" >&2; }
GUARD_CMD="scripts/meta-orchestration-worktree-guard.sh"

# Cycle-scoped stamps, kept in the git dir so they are per-checkout, never
# committed, and reachable by a later step that was not told the state dir
# (order 717-3bvv). `boundary-state` records WHICH state dir this cycle
# snapshotted; `boundary-verified` records the HEAD that a successful verify
# observed. Together they answer the question the guard could not answer
# before: was a boundary recorded and verified for THIS cycle?
stamp_path() {
    local git_dir
    git_dir="$(git rev-parse --git-dir 2>/dev/null)" || return 1
    printf '%s/%s\n' "$git_dir" "$1"
}

hash_path() {
    local path="$1"
    if [[ -L "$path" ]]; then
        printf 'symlink:'
        readlink "$path" | git hash-object --stdin
    elif [[ -f "$path" ]]; then
        printf 'file:'
        git hash-object --no-filters -- "$path"
    elif [[ -d "$path" ]]; then
        echo "error: dirty directory/submodule is unsupported: $path" >&2
        _afford "the guard records file bytes, and $path is a nested repository or submodule whose state it cannot capture" \
            "commit it, or move it out of the worktree, then snapshot into a new directory"
        return 2
    elif [[ ! -e "$path" && ! -L "$path" ]]; then
        printf 'missing\n'
    else
        echo "error: dirty special file is unsupported: $path" >&2
        _afford "$path is a socket, fifo or device, and the guard can only record file bytes" \
            "remove it or move it out of the worktree, then snapshot into a new directory"
        return 2
    fi
}

capture() {
    local destination="$1" path
    git status --porcelain=v1 -z --untracked-files=all >"$destination/status.z"
    git diff --binary >"$destination/worktree.diff"
    git diff --cached --binary >"$destination/index.diff"
    {
        git diff --name-only -z
        git diff --cached --name-only -z
        git ls-files --others --exclude-standard -z
    } >"$destination/paths.z"
    : >"$destination/hashes"
    while IFS= read -r -d '' path; do
        hash_path "$path" >>"$destination/hashes"
    done <"$destination/paths.z"
}

# differing_paths STARTUP CURRENT SCRATCH -> the paths whose status entry or
# recorded bytes differ between two captures, space-separated on one line, so
# "worktree differs" can say WHERE (order 1247-b46r). A diagnostic only: it
# never decides the verdict, the cmp chain in verify does.
differing_paths() {
    local startup="$1" current="$2" scratch="$3" side
    mkdir -p "$scratch" || return 0
    for side in startup current; do
        local d="$startup"
        [[ "$side" = current ]] && d="$current"
        # A status line is "XY path"; a hash line is "path<TAB>hash".
        tr '\0' '\n' <"$d/status.z" >"$scratch/$side.status" || return 0
        tr '\0' '\n' <"$d/paths.z" >"$scratch/$side.paths" || return 0
        paste "$scratch/$side.paths" "$d/hashes" >"$scratch/$side.hashes" || return 0
        sort -u "$scratch/$side.status" "$scratch/$side.hashes" >"$scratch/$side.listing" || return 0
    done
    comm -3 "$scratch/startup.listing" "$scratch/current.listing" >"$scratch/differ" || return 0
    awk '{
            sub(/^\t/, "")
            t = index($0, "\t")
            if (t > 0) p = substr($0, 1, t - 1)
            else if ($0 ~ /^[ MADRCUT?!][ MADRCUT?!] /) p = substr($0, 4)
            else p = $0
            if (p != "" && !(p in seen)) { seen[p] = 1; printf "%s%s", (n++ ? " " : ""), p }
         }' "$scratch/differ" || return 0
}

load_state() {
    [[ $# -eq 1 ]] || usage
    state_dir="$(cd "$1" 2>/dev/null && pwd -P)" || {
        # NAME THE PROCESS FAULT, do not describe the symptom (order 717-3bvv).
        #
        # A cycle that never ran `snapshot` used to arrive here and read
        # "state directory does not exist: /tmp/…Wxg6hS" — the path from the
        # PREVIOUS cycle, already removed on its own successful exit. An agent
        # who reads that as a stale temp path is reading it correctly, and the
        # guard goes silent about the worktree precisely when the tree is dirty
        # and the stakes are highest. So distinguish the two cases by the
        # cycle-scoped stamp rather than by the directory's absence.
        local stamp
        stamp="$(stamp_path boundary-state 2>/dev/null || true)"
        if [[ -z "$stamp" || ! -f "$stamp" ]]; then
            echo "blocked:no-snapshot-taken"
            if [[ -z "$stamp" ]]; then
                _afford "$PWD is not inside a git checkout, so no boundary can have been recorded here" \
                    "run the guard from the worktree it guards"
            else
                # The remedy is only honest BEFORE the cycle's work: a snapshot
                # taken after it would baseline the cycle's own edits, which is
                # the move 717-3bvv exists to forbid. Say so in the remedy.
                _afford "no snapshot was taken in this checkout ($stamp does not exist), so $1 is not a boundary this cycle recorded and there is nothing to compare the tree against" \
                    "before the cycle changes anything, run $GUARD_CMD snapshot <a new directory outside this worktree>, then verify against that directory. If the cycle has already done work, report the skipped snapshot instead: a snapshot now would baseline the cycle's own edits"
            fi
            exit 3
        fi
        local current requested
        current="$(cat "$stamp")"
        # SUPERSEDED IS NOT MISSING (order 771-wwzi). Both land here — the
        # requested directory is gone either way — but the causes are opposite
        # and the remedies are too, so one verdict for both is a diagnosis the
        # reader has to guess at.
        #
        # 771-wwzi was filed believing a CONCURRENT FORK had deleted the
        # parent's boundary. Measured 2026-08-17, that cannot happen: stamps
        # live under `git rev-parse --git-dir`, which in a linked worktree is
        # .git/worktrees/<name>, so each worktree only ever retires a directory
        # ITS OWN stamp names. Two worktrees snapshotting concurrently leave
        # both boundaries intact (pinned in the fixture).
        #
        # What actually happened is this branch: the cycle ran `snapshot` a
        # SECOND time — re-baselining after unexpected dirt — which retired the
        # first boundary exactly as 725-bu54 intends, while the caller still
        # held the first path in a pointer file. It then read
        # `boundary-state-missing:<a path it had never seen>` and concluded its
        # boundary had been destroyed by another agent. Naming both paths and
        # the cause ends that misreading.
        requested="$1"
        local retired_stamp superseded=0
        retired_stamp="$(stamp_path boundary-retired 2>/dev/null || true)"
        if [[ -n "$retired_stamp" && -f "$retired_stamp" ]] \
            && grep -Fqx "$requested" "$retired_stamp"; then
            superseded=1
        fi
        if [[ "$superseded" -eq 1 ]]; then
            echo "blocked:boundary-superseded:$current"
            {
                echo "  the boundary you asked about was retired by a LATER snapshot in this"
                echo "  same worktree (the 725-bu54 retire-previous step), not by another agent."
                echo "    requested: $1"
                echo "    current:   $current"
                echo "  Verify against the current boundary, or re-snapshot if this cycle needs a"
                echo "  fresh baseline. A concurrent worktree cannot reach this stamp."
            } >&2
            exit 3
        fi
        echo "blocked:boundary-state-missing:$current"
        if [[ -f "$current/repo-root" && -f "$current/startup/status.z" ]]; then
            _afford "$1 is not a boundary this worktree recorded or retired; this cycle's boundary is $current" \
                "verify against it: $GUARD_CMD verify $current"
        else
            _afford "$1 is not a boundary this worktree recorded, and this cycle's boundary $current is gone too: something outside this guard removed it" \
                "this cycle has nothing left to verify against, so report it as unverified, and snapshot into a new directory at the start of the next cycle"
        fi
        exit 3
    }
    [[ -f "$state_dir/repo-root" && -f "$state_dir/startup/status.z" ]] || {
        echo "error: invalid boundary state: $state_dir" >&2
        local named
        named="$(cat "$(stamp_path boundary-state 2>/dev/null)" 2>/dev/null || true)"
        if [[ -n "$named" && "$named" != "$state_dir" ]]; then
            _afford "$state_dir has no repo-root or startup/status.z, so snapshot did not write it" \
                "verify against the boundary this cycle recorded: $GUARD_CMD verify $named"
        else
            _afford "$state_dir has no repo-root or startup/status.z, so snapshot did not write it, or did not finish (a refused capture leaves it half-written)" \
                "pass the directory this cycle's snapshot was given; if the snapshot was refused, clear its cause and snapshot into a new directory"
        fi
        exit 2
    }
    repo_root="$(cat "$state_dir/repo-root")"
    cd "$repo_root"
}

mode="${1:-}"
shift || true

case "$mode" in
    snapshot)
        [[ $# -eq 1 ]] || usage
        repo_root="$(cd "$(git rev-parse --show-toplevel)" && pwd -P)"
        mkdir -p "$1"
        state_dir="$(cd "$1" && pwd -P)"
        case "$state_dir/" in
            "$repo_root/"*)
                echo "error: boundary state must live outside the worktree" >&2
                _afford "$state_dir is inside the worktree $repo_root, so the snapshot would capture its own files as the cycle's dirt" \
                    "snapshot into a new directory outside this worktree, e.g. \${TMPDIR:-/tmp}/meta-orchestration-boundary.<cycle>"
                exit 2
                ;;
        esac
        [[ ! -e "$state_dir/startup" && ! -e "$state_dir/repo-root" ]] || {
            echo "error: boundary state already initialized: $state_dir" >&2
            _afford "$state_dir already holds a boundary, and writing over it would erase the startup state it recorded" \
                "snapshot into a new, empty directory. To re-anchor this one after landing startup dirt you were licensed to land, use $GUARD_CMD re-snapshot $state_dir"
            exit 2
        }
        mkdir -p "$state_dir/startup" "$state_dir/tmp"
        printf '%s\n' "$repo_root" >"$state_dir/repo-root"
        cd "$repo_root"
        capture "$state_dir/startup"
        # RETIRE THE PREVIOUS CYCLE'S BOUNDARY HERE, not at the end of the
        # cycle that created it (order 725-bu54).
        #
        # Finalization used to remove the state dir on its way out, which
        # treated its first completion as THE end of the cycle. An
        # operator-driven loop does not have one exit: the cycle continues
        # whenever the operator asks for more, and the second Finalization then
        # found its own boundary gone and could not attest. That happened twice
        # in one night, and cost a valid marker.
        #
        # Retiring at the START of the NEXT cycle fixes it without weakening
        # what 717-3bvv guarantees. The boundary being verified is still the
        # one taken BEFORE any work — re-verification after more commits
        # compares against cycle start, which is strictly what the guard is
        # for. The alternative, re-snapshotting when the tree looks clean, is
        # exactly the "snapshot at the end and call it a startup boundary" move
        # that guarantee exists to forbid.
        #
        # It also matches the project's stated posture: everything safe to
        # destroy and relaunch, with cleanup owned by the next start rather
        # than by a previous exit that may never come.
        previous_stamp="$(stamp_path boundary-state)"
        if [[ -f "$previous_stamp" ]]; then
            previous_dir="$(cat "$previous_stamp")"
            # Remove ONLY a path this guard recorded, that still looks like a
            # boundary, and that lives outside the worktree. A stale or edited
            # stamp must not become an arbitrary rm -rf.
            if [[ -n "$previous_dir" && "$previous_dir" != "$state_dir" \
                && -f "$previous_dir/repo-root" && -d "$previous_dir/startup" ]]; then
                case "$previous_dir/" in
                    "$repo_root/"*) : ;;   # never inside the worktree
                    *)
                        rm -rf "$previous_dir"
                        # Remember WHAT WE RETIRED (order 771-wwzi), so a later
                        # verify against that path can say "superseded" as a
                        # fact rather than infer it from "not the current one".
                        # A caller naming a path that was never a boundary is a
                        # different fault and must keep its own verdict.
                        # Bounded to the last 20: this is a diagnostic tail, not
                        # an audit log, and an unbounded file in the git dir is
                        # a slow leak.
                        _mo_retired="$(stamp_path boundary-retired)"
                        printf '%s\n' "$previous_dir" >>"$_mo_retired"
                        if [[ "$(wc -l <"$_mo_retired")" -gt 20 ]]; then
                            tail -n 20 "$_mo_retired" >"$_mo_retired.trim" \
                                && mv "$_mo_retired.trim" "$_mo_retired"
                        fi
                        ;;
                esac
            fi
        fi

        # Open the cycle's boundary: record where it lives and clear any
        # verification left by the previous cycle, so a stale stamp can never
        # satisfy this one.
        printf '%s\n' "$state_dir" >"$(stamp_path boundary-state)"

        # ORDER 974-uk95. A NEW CYCLE HAS RECORDED NOTHING YET.
        #
        # `mo-full-attest.sh self` refuses a COMPLETE marker unless this cycle
        # wrote a durable ledger record, and it decides that by reading the
        # stamp `record` leaves behind. Clearing it here is what makes the
        # question "did THIS cycle record" rather than "has this checkout ever
        # recorded" — without it, one successful record would license every
        # later cycle's marker forever, which is the original defect with a
        # longer fuse.
        #
        # Snapshot is the right hook for the same reason it retires the previous
        # boundary directory: cleanup is owned by the next start, not by a
        # previous exit that may never come.
        rm -f "$(stamp_path mo-full-recorded)" 2>/dev/null || true
        rm -f "$(stamp_path boundary-verified)"
        ;;
    re-snapshot)
        # Re-anchor the boundary after the cycle intentionally LANDED startup
        # dirt it was licensed to land. Sole caller today: meta-orchestration
        # step 4b, after scripts/check-resumable-claim-dirt.sh returned
        # resumable: and the agent reviewed and committed that claim's diff.
        # Order 540 also called it after committing launch-generated opsx dirt;
        # 1440-w8g8 retired that path (the dirt is refused, never committed).
        # Re-anchoring is safe only when the caller proved what the prior dirty
        # set was and landed exactly that.
        load_state "$@"
        mkdir -p "$state_dir/tmp"
        capture "$state_dir/startup"
        echo "ok: startup boundary re-anchored"
        ;;
    verify)
        load_state "$@"
        current="$state_dir/current"
        rm -rf "$current"
        mkdir -p "$current"
        capture "$current"
        cmp "$state_dir/startup/status.z" "$current/status.z" >/dev/null &&
            cmp "$state_dir/startup/paths.z" "$current/paths.z" >/dev/null &&
            cmp "$state_dir/startup/hashes" "$current/hashes" >/dev/null &&
            cmp "$state_dir/startup/worktree.diff" "$current/worktree.diff" >/dev/null &&
            cmp "$state_dir/startup/index.diff" "$current/index.diff" >/dev/null || {
                echo "error: worktree differs from startup boundary" >&2
                differing="$(differing_paths "$state_dir/startup" "$current" "$state_dir/tmp")"
                # Never prescribe a restore: the meta-orchestration skill forbids
                # a cycle to delete or restore worktree paths, and re-snapshotting
                # would baseline the change this exists to catch.
                _afford "these paths differ from the startup boundary in $state_dir: ${differing:-<none by path; the staged or unstaged diff differs>}" \
                    "if they are this cycle's own edits, commit them and verify again. If they were startup dirt, the cycle changed bytes it was not licensed to touch: put the startup bytes back (the boundary's startup/worktree.diff and index.diff hold them) or report it. Do not re-snapshot to clear this; that would baseline the change"
                exit 1
            }
        # Record WHICH head this verification observed. mo-full-attest.sh reads
        # it and refuses to print a marker unless it names the HEAD being
        # attested, so a verification from an earlier cycle — or from before the
        # cycle's own commits — cannot stand in for this one.
        git rev-parse HEAD >"$(stamp_path boundary-verified)" 2>/dev/null || true
        echo "ok: startup worktree boundary preserved"
        ;;
    *) usage ;;
esac
