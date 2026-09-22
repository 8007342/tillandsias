#!/usr/bin/env bash
# push-plan-fragments-to-trunk.sh — push NEW plan fragments to origin/linux-next
# from ANY checkout, so a claim written on osx-next or windows-next is visible
# to plan_next on every host NOW, not at the next coordinator relay (1153-j2nm).
#
# WHY. MEASURED 2026-09-13: macneo closed 1127-apa8 on osx-next at ~08:40Z;
# lenovinha's plan_next on linux-next could see neither the claim nor the
# closure and closed the same row from scratch at ~09:50Z. Both verifications
# were sound; a fat-host cycle was spent because the claim was invisible. The
# claim event exists to prevent exactly that and could not, because
# methodology sends a platform host's plan edits to its platform branch, which
# reaches trunk once per coordination pass — 19 minutes to 2h02m measured on
# tlatoanis-macbook-air (1034-whsp). A claim that separates nobody for two
# hours is not a claim. 1140-d6ni was closed twice the same day the same way.
#
# WHAT IT DOES. Builds ONE commit whose parent is origin/linux-next and whose
# only change is the NEW fragment files you name — by default every
# plan/index.d/*.yaml and plan/loop_status.d/*.md that is present here
# (committed on this branch, staged, or untracked) and absent on trunk — and
# pushes that commit to refs/heads/linux-next. The commit is built through a
# temporary GIT_INDEX_FILE and plumbing (read-tree / update-index / write-tree
# / commit-tree), the salvage script's shape (872-c9nd): the working tree, the
# real index and the current branch are NOT touched. Your platform branch
# keeps its own copy of the fragment; when the coordinator relays the branch,
# git sees the same path added with the same bytes on both sides and merges
# it clean.
#
# WHAT GATES IT. The push runs this checkout's pre-push hook like any other
# push. With the outgoing diff being new fragments only and the parent being
# trunk's tip, the hook takes the plan-only lane (668-2xeh, 1152-y3bv), so no
# BUILD STAMP is needed — a checkout that has never run ./build.sh --check can
# push its claim. The hook's other local checks still run against THIS
# checkout (release-preflight, the fragment checkers, status-loss): a refusal
# from any of them surfaces as refused:fragments-to-trunk:push:<its first
# line>. BEFORE pushing, the fragments are checked against TRUNK'S fold
# (trunk's plan/index.yaml + plan/index.d + the new files):
#   - `tillandsias-plan check --strict-fragments` — the hook validates against
#     THIS checkout's fold, and a fragment that is coherent here (its packet
#     was filed on this branch) can be an event on a packet trunk has never
#     seen; that would red the coordinator's gate, so it is refused here with
#     the remedy (push the filing fragment too);
#   - a terminal event (completed/obsoleted) must fold to a terminal STATUS on
#     trunk: pushing the completion event without the status fragment would
#     leave trunk offering a closed row as ready — the 1127-apa8 shape,
#     reproduced through this tool — so that is refused as status-loss.
#
# VERDICTS (stdout, last line; the hook's own lines reach stderr):
#   ok:fragments-on-trunk:<sha>:<n>            origin/linux-next carries the n fragments
#   ok:fragments-to-trunk:dry-run:<sha>:<n>    --dry-run: built and validated, nothing pushed
#   skip:fragments-to-trunk:nothing-new        nothing here is absent from trunk (exit 0: the
#                                              verdict line, not the exit status, is the signal)
#   refused:fragments-to-trunk:scope:<path>    an EXPLICIT path that is not plan/index.d/*.yaml
#                                              or plan/loop_status.d/*.md directly under the dir
#   refused:fragments-to-trunk:exists:<path>   on trunk already with different bytes — fragments are
#                                              immutable; a changed copy is not a new fragment
#   refused:fragments-to-trunk:missing:<path>  not a file in this worktree
#   refused:fragments-to-trunk:loop-status:<path>  an explicit loop-status fragment that fails the
#                                              lane's grammar (one '## Cycle' heading, no other '##')
#   refused:fragments-to-trunk:trunk-fold:<…>  trunk's fold with these fragments fails check, or a
#                                              terminal event would fold to a non-terminal status
#   refused:fragments-to-trunk:trunk-checkout-ahead  run on a linux-next checkout with unpushed
#                                              commits: push the branch through the lane instead
#   refused:fragments-to-trunk:no-validator    no runnable tillandsias-plan (fail closed, as the lane does)
#   refused:fragments-to-trunk:push:<reason>   the hook or the remote refused; the first refusal line
#   refused:fragments-to-trunk:raced:<n>       origin/linux-next moved on every one of n attempts
#   refused:fragments-to-trunk:usage:<arg>     a flag this script does not take
# In the DEFAULT selection a candidate that cannot ride (a dotfile, a nested
# path, a wrong extension, a loop-status fragment failing the grammar) is
# skipped with a note on stderr, not refused — the claim must not be blocked
# by a stray .DS_Store. Nothing is pushed on any refused: or skip: verdict.
#
# RACES. Git hands the pre-push hook the remote's CURRENT tip; if trunk moved
# after this script's fetch, the hook refuses ("remote base … not present
# locally") before git ever prints "[rejected]". So a race is detected by
# STATE — origin/linux-next differs after a refetch — and the commit is
# rebuilt on the new tip, three attempts.
#
# Usage: scripts/push-plan-fragments-to-trunk.sh [--dry-run] [<path> ...]
#   Paths are relative to the repository root, whatever the cwd.
set -euo pipefail

_usage() {
    cat >&2 <<'USAGE'
usage: scripts/push-plan-fragments-to-trunk.sh [--dry-run] [<path> ...]
  Pushes NEW plan fragments (plan/index.d/*.yaml, plan/loop_status.d/*.md)
  to origin/linux-next from any checkout in one trunk-parented commit built
  with plumbing; the working tree, the index and the current branch are
  untouched. Default paths: every lane file present here (committed here,
  staged, or untracked) and absent on origin/linux-next. Paths are relative
  to the repository root.
  --dry-run   build and validate, print the would-be commit, push nothing.
USAGE
}

DRY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY=1; shift ;;
        -h|--help) _usage; exit 0 ;;
        --) shift; break ;;
        -*) _usage; echo "refused:fragments-to-trunk:usage:$1"; exit 2 ;;
        *) break ;;
    esac
done

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || { echo "refused:fragments-to-trunk:not-a-git-checkout"; exit 2; }
cd "$ROOT"
REMOTE="${TILLANDSIAS_TRUNK_REMOTE:-origin}"
TRUNK="${TILLANDSIAS_TRUNK_BRANCH:-linux-next}"
TRACK="refs/remotes/$REMOTE/$TRUNK"

# Scratch under target/ when it can be made (the agent scratchpad and /tmp are
# a quota'd tmpfs on at least one host); TMPDIR is the fallback.
_tmpbase="$ROOT/target/plan-scratch"
mkdir -p "$_tmpbase" 2>/dev/null || _tmpbase="${TMPDIR:-/tmp}"
tmp="$(mktemp -d "$_tmpbase/fragments-to-trunk.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT INT TERM

# Explicit paths, one per line, or empty for the default selection.
: > "$tmp/explicit"
EXPLICIT=0
if [ $# -gt 0 ]; then
    EXPLICIT=1
    for p in "$@"; do printf '%s\n' "${p#./}" >> "$tmp/explicit"; done
fi

# The validator is resolved HERE, in the checkout, where the probe can see
# it (the lesson of test-pre-push-plan-lane-after-merge.sh). Fail closed
# without one, exactly as the lane itself does.
# shellcheck source=plan-binary-probe.sh
. "$ROOT/scripts/plan-binary-probe.sh"
PLAN="$(resolve_plan_binary 2>/dev/null)" || PLAN=""
if [ -z "$PLAN" ]; then
    echo "fragments-to-trunk: no runnable tillandsias-plan, so the trunk-fold check cannot run;" >&2
    echo "  REMEDY: cargo build --release -p tillandsias-plan && bash scripts/check-plan-binary-current.sh" >&2
    echo "refused:fragments-to-trunk:no-validator"
    exit 1
fi
case "$PLAN" in ./*) PLAN="$ROOT/${PLAN#./}" ;; esac

# HOST RESOLUTION GOES THROUGH THE ONE RESOLVER, AND REFUSES RATHER THAN
# INVENTING (order 1337-3tk6). This used to be `hostname -s` with a literal
# "unknown" fallback. The forge image does not ship a `hostname` executable, so
# every ref this script pushed from a forge was attributed to `salvage/unknown/`
# — six such refs across nineteen days, every one forge-shaped, against roughly
# a hundred host-attributed refs from bare-metal hosts.
#
# THE FALLBACK WAS A PLACEHOLDER, NOT A SECOND RESOLVER. It did not try another
# source and it did not refuse; it minted a plausible-looking name and pushed
# under it. Meanwhile $HOSTNAME, /etc/hostname and `uname -n` all answered
# correctly in the same container.
#
# scripts/agent-identity.sh already solved exactly this, as order 743-mgf3, for
# exactly this reason — its `node-name` probe is hostname -s -> hostname ->
# uname -n -> /etc/hostname, domain-stripped and lowercased with bash builtins,
# and it is already shared with scripts/mo-full-attest.sh's host label. This
# script simply never adopted it. Calling it is the fix; a second hand-rolled
# chain would be a third copy to drift.
#
# AND IT REFUSES ON EMPTY. A salvage ref exists to be FOUND BY SOMEONE ELSE, so
# one that cannot name its origin host is half a recovery. Refusing loudly at
# the moment of creation, while the operator is present, beats discovering it
# when someone needs the ref.
# $ROOT, NOT BASH_SOURCE (1337-3tk6 follow-up; found by lenovinha-silverblue).
# Both scripts `cd "$ROOT"` above this line and BASH_SOURCE[0] is the INVOCATION
# path, so after the cd a relative invocation from anywhere but the repo root
# resolves this against the wrong directory and the script refuses with
# "agent-identity.sh node-name returned nothing" when it was never FOUND — a
# refusal naming the wrong cause, in the rescue path.
_ai="$ROOT/scripts/agent-identity.sh"
HOST="$([ -x "$_ai" ] && "$_ai" node-name 2>/dev/null || true)"
HOST="$(printf '%s' "$HOST" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9-')"
if [ -z "$HOST" ]; then
    echo "refused:host-unresolved: scripts/agent-identity.sh node-name returned nothing, so this push would be attributed to no host (1337-3tk6). Nothing pushed." >&2
    exit 2
fi
BRANCH="$(git symbolic-ref --short -q HEAD 2>/dev/null || echo detached)"
HEAD_SHORT="$(git rev-parse --short HEAD 2>/dev/null || echo none)"

_fetch_trunk() {
    if ! git fetch -q "$REMOTE" "+refs/heads/$TRUNK:$TRACK" 2>"$tmp/ferr"; then
        echo "refused:fragments-to-trunk:fetch:$(head -1 "$tmp/ferr" 2>/dev/null | tr -d '\n' | cut -c1-80)"
        exit 1
    fi
}

# A lane path is a *.yaml DIRECTLY under plan/index.d/ or a *.md DIRECTLY
# under plan/loop_status.d/ — the hook's own two patterns (`plan/index.d/?*.yaml`,
# `plan/loop_status.d/?*.md`) and its "nested below" refusal.
_in_lane() {
    local rest
    case "$1" in
        plan/index.d/*.yaml)      rest="${1#plan/index.d/}" ;;
        plan/loop_status.d/*.md)  rest="${1#plan/loop_status.d/}" ;;
        *) return 1 ;;
    esac
    case "$rest" in ''|.*|*/*) return 1 ;; esac
    return 0
}

# The lane's grammar for a loop-status fragment: a '## Cycle' heading and no
# other '## ' section (pre-push-local-gate.sh, the plan/loop_status.d arm).
_loop_status_ok() {
    grep -q '^## Cycle ' "$1" 2>/dev/null || return 1
    if grep -E '^## ' "$1" 2>/dev/null | grep -v '^## Cycle ' | grep -q .; then return 1; fi
    return 0
}

# Select the paths to carry, against base $1; writes $tmp/paths. An EXPLICIT
# path that cannot ride is a refusal (stdout verdict, exit); a DEFAULT
# candidate that cannot ride is skipped with a note. A path already on trunk
# byte-for-byte is dropped with a note either way (a re-run after a race must
# not fail on its own earlier success).
_select_paths() {
    local base="$1" p tb wb
    : > "$tmp/paths"
    if [ "$EXPLICIT" -eq 1 ]; then
        cp "$tmp/explicit" "$tmp/cand"
    else
        {
            git ls-files --others --exclude-standard -- plan/index.d plan/loop_status.d 2>/dev/null
            git diff --name-only --cached --diff-filter=A -- plan/index.d plan/loop_status.d 2>/dev/null
            git diff --name-only --diff-filter=A "$base" HEAD -- plan/index.d plan/loop_status.d 2>/dev/null
        } | sort -u > "$tmp/cand"
    fi
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        if ! _in_lane "$p"; then
            if [ "$EXPLICIT" -eq 1 ]; then
                echo "fragments-to-trunk: '$p' is not a plan/index.d/*.yaml or plan/loop_status.d/*.md directly under its directory; this lane carries fragments only" >&2
                echo "refused:fragments-to-trunk:scope:$p"; exit 1
            fi
            echo "fragments-to-trunk: note: '$p' is not a lane fragment (dotfile, nested, or wrong extension); skipped" >&2
            continue
        fi
        if [ ! -f "$p" ]; then
            [ "$EXPLICIT" -eq 1 ] && { echo "refused:fragments-to-trunk:missing:$p"; exit 1; }
            continue
        fi
        case "$p" in
            plan/loop_status.d/*)
                if ! _loop_status_ok "$p"; then
                    if [ "$EXPLICIT" -eq 1 ]; then
                        echo "fragments-to-trunk: '$p' fails the lane's loop-status grammar (exactly one '## Cycle' heading, no other '## ' section)" >&2
                        echo "refused:fragments-to-trunk:loop-status:$p"; exit 1
                    fi
                    echo "fragments-to-trunk: note: '$p' fails the lane's loop-status grammar (one '## Cycle' heading, no other '## '); skipped — fix it and re-run" >&2
                    continue
                fi ;;
        esac
        if git cat-file -e "$base:$p" 2>/dev/null; then
            tb="$(git rev-parse "$base:$p")"
            wb="$(git hash-object -- "$p")"
            if [ "$tb" = "$wb" ]; then
                echo "fragments-to-trunk: '$p' is already on $REMOTE/$TRUNK byte-for-byte; dropped" >&2
                continue
            fi
            echo "fragments-to-trunk: '$p' exists on $REMOTE/$TRUNK with different bytes — fragments are immutable, a changed copy is not a new fragment (write a new fragment instead)" >&2
            echo "refused:fragments-to-trunk:exists:$p"; exit 1
        fi
        printf '%s\n' "$p" >> "$tmp/paths"
    done < "$tmp/cand"
}

# Trunk's fold plus the new index.d fragments must (a) pass `check
# --strict-fragments` — the hook checks THIS checkout's fold, which can hold
# the packet a fragment names while trunk does not — and (b) fold every
# packet that receives a terminal EVENT here to a terminal STATUS, or trunk
# would offer a closed row as ready.
_trunk_fold_check() {
    local base="$1" p n pid got
    n="$(grep -c '^plan/index\.d/' "$tmp/paths" 2>/dev/null || true)"
    [ "${n:-0}" -gt 0 ] || return 0
    rm -rf "$tmp/fold"; mkdir -p "$tmp/fold/plan/index.d"
    if ! git cat-file -e "$base:plan/index.yaml" 2>/dev/null; then
        echo "refused:fragments-to-trunk:trunk-fold:$REMOTE/$TRUNK has no plan/index.yaml"; exit 1
    fi
    git show "$base:plan/index.yaml" > "$tmp/fold/plan/index.yaml"
    # The fold is index.yaml + index.d + the ARCHIVE + the schema: archived
    # packets are what live rows' depends_on edges resolve to, and a fold
    # without them reports every such edge unresolved. MEASURED by macbookair
    # 2026-09-14 on the real ledger — 96 unresolved referents, none of them a
    # fragment being relayed; the same tree with `git archive $base
    # plan/archive` extracted: ok, 944 packets. The first fixture never had an
    # archive, so the helper was green on one regime (the scratch) and refused
    # every relay from every host on the other.
    for d in plan/index.d plan/archive; do
        if [ -n "$(git ls-tree -d "$base" "$d" 2>/dev/null)" ]; then
            git archive "$base" "$d" | tar -x -f - -C "$tmp/fold"
        fi
    done
    if git cat-file -e "$base:plan/schema.yaml" 2>/dev/null; then
        git show "$base:plan/schema.yaml" > "$tmp/fold/plan/schema.yaml"
    fi
    while IFS= read -r p; do
        case "$p" in plan/index.d/*) cp -- "$p" "$tmp/fold/$p" ;; esac
    done < "$tmp/paths"
    if ! "$PLAN" --index "$tmp/fold/plan/index.yaml" check --strict-fragments > "$tmp/chk" 2>&1; then
        grep -v 'OpenSpec' "$tmp/chk" | sed 's/^/  /' >&2
        echo "fragments-to-trunk: trunk's fold cannot use these fragments — if one is an event on a packet filed on this branch, push its filing fragment too (the default selection carries every new fragment)" >&2
        echo "refused:fragments-to-trunk:trunk-fold:$(grep -v OpenSpec "$tmp/chk" | tail -1 | tr -d '\n' | cut -c1-120)"
        exit 1
    fi
    # (b) terminal events fold to terminal statuses ON TRUNK.
    while IFS= read -r p; do
        case "$p" in plan/index.d/*) ;; *) continue ;; esac
        "$PLAN" fragment-terminal-events "$p" 2>/dev/null | grep -v OpenSpec > "$tmp/tev" || true
        while IFS= read -r pid; do
            [ -n "$pid" ] || continue
            got="$("$PLAN" --index "$tmp/fold/plan/index.yaml" status "$pid" 2>/dev/null | head -1 | cut -f2)"
            case "$got" in
                completed|verified|done|obsoleted) ;;
                *)
                    echo "fragments-to-trunk: '$p' carries a terminal event for $pid, but trunk's fold with the selected fragments reads '${got:-<absent>}' — push the status fragment (set-field … status completed) with it, or trunk offers a closed row as ready" >&2
                    echo "refused:fragments-to-trunk:trunk-fold:status-loss:$pid"; exit 1 ;;
            esac
        done < "$tmp/tev"
    done < "$tmp/paths"
}

# One commit on $1 carrying exactly $tmp/paths, through a temporary index.
_build_commit() {
    local base="$1" p blob tree msg n list
    rm -f "$tmp/index"
    GIT_INDEX_FILE="$tmp/index" git read-tree "$base"
    while IFS= read -r p; do
        blob="$(git hash-object -w -- "$p")"
        GIT_INDEX_FILE="$tmp/index" git update-index --add --cacheinfo "100644,$blob,$p"
    done < "$tmp/paths"
    tree="$(GIT_INDEX_FILE="$tmp/index" git write-tree)"
    # 934-7jd4: never fail for want of a git identity (a builder container
    # derives 'user@toolbx.(none)' and commit-tree exits 128).
    if ! git var GIT_COMMITTER_IDENT >/dev/null 2>&1; then
        export GIT_AUTHOR_NAME="tillandsias" GIT_AUTHOR_EMAIL="plan@${HOST}" \
               GIT_COMMITTER_NAME="tillandsias" GIT_COMMITTER_EMAIL="plan@${HOST}"
    fi
    n="$(wc -l < "$tmp/paths" | tr -d ' ')"
    list="$(sed 's#^.*/##' "$tmp/paths" | tr '\n' ' ' | cut -c1-72)"
    msg="plan(${HOST}): ${n} fragment(s) to ${TRUNK} from ${BRANCH} — ${list}

Pushed by scripts/push-plan-fragments-to-trunk.sh (1153-j2nm) from ${BRANCH}
at ${HEAD_SHORT} on ${HOST}, so plan_next on every host sees these fragments
before the coordinator relays the branch. The parent is ${REMOTE}/${TRUNK}
and the only change is the new file(s) below, byte-identical to the copies
on ${BRANCH}, so the later relay merges them clean.

$(sed 's/^/  /' "$tmp/paths")"
    printf '%s' "$msg" | git commit-tree "$tree" -p "$base"
}

_fetch_trunk
# On a trunk checkout with unpushed commits the ordinary push through the
# lane is the tool; a side commit here would only make the branch non-ff.
if [ "$BRANCH" = "$TRUNK" ] && [ "$(git rev-list --count "$TRACK..HEAD" 2>/dev/null || echo 0)" -gt 0 ]; then
    echo "fragments-to-trunk: this checkout is on $TRUNK with unpushed commits; push the branch itself (git push $REMOTE HEAD:$TRUNK takes the plan-only lane for fragment-only commits)" >&2
    echo "refused:fragments-to-trunk:trunk-checkout-ahead"; exit 1
fi

attempt=0
while :; do
    attempt=$((attempt+1))
    base="$(git rev-parse "$TRACK")"
    _select_paths "$base"
    n="$(wc -l < "$tmp/paths" | tr -d ' ')"
    if [ "$n" -eq 0 ]; then
        echo "skip:fragments-to-trunk:nothing-new"; exit 0
    fi
    _trunk_fold_check "$base"
    commit="$(_build_commit "$base")"
    if [ "$DRY" -eq 1 ]; then
        git show --stat --format='%H %s' "$commit" | sed 's/^/  /' >&2
        echo "ok:fragments-to-trunk:dry-run:$commit:$n"; exit 0
    fi
    rc=0
    git push "$REMOTE" "$commit:refs/heads/$TRUNK" > "$tmp/push" 2>&1 || rc=$?
    cat "$tmp/push" >&2
    if [ "$rc" -eq 0 ]; then
        echo "ok:fragments-on-trunk:$commit:$n"; exit 0
    fi
    # A race is a STATE, not a wording: refetch and compare the tip.
    _fetch_trunk
    if [ "$(git rev-parse "$TRACK")" != "$base" ]; then
        if [ "$attempt" -lt 3 ]; then
            echo "fragments-to-trunk: $REMOTE/$TRUNK moved during attempt $attempt; rebuilding on the new tip" >&2
            continue
        fi
        echo "refused:fragments-to-trunk:raced:$attempt"; exit 1
    fi
    reason="$(grep -m1 -E 'refused|FAILED|not applicable|rejected|error:' "$tmp/push" | tr -d '\r\n' | cut -c1-120)"
    echo "fragments-to-trunk: the push was refused by the hook or the remote (nothing landed); its output is above" >&2
    echo "refused:fragments-to-trunk:push:${reason:-see the output above}"; exit 1
done
