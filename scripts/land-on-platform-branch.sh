#!/usr/bin/env bash
# @trace order:859-4jny, spec:ci-release
#
# land-on-platform-branch.sh — rebase, gate, push, and PROVE the commit landed.
#
# WHY THIS EXISTS. On a slow host ./build.sh --check takes minutes, a rebase
# invalidates the gate stamp, and origin moves inside that window — so the
# pre-push hook refuses with "The gate validated a different tree than the one
# you are pushing" and the whole cycle must repeat. Measured on pirria (4 Alder
# Lake-N cores, order 855-wrr3): origin/linux-next moved TWICE between gate
# start and push in one session, and a later commit needed three attempts.
# Retrying is REQUIRED to land at all, so every slow host writes this loop.
#
# THE TWO BUGS THAT LOOP ACQUIRES, both hit for real before this file existed:
#
#   1. `if git push ... | tee LOG | tail -3; then` tests the exit status of
#      TAIL, not of git push. A pipeline's status is its LAST command, so a
#      rejected push reads as success.
#   2. Grepping the output for "<branch> -> <branch>" ALSO matches the
#      rejection line: `! [rejected]  linux-next -> linux-next (fetch first)`.
#
# Together they reported "LANDED" for a push that was refused, and the agent
# reported that onward. NEITHER a zero exit status NOR a ref-update line in the
# output is sufficient evidence that a commit landed; this script asks the
# REMOTE, with `git merge-base --is-ancestor` against a freshly fetched ref.
#
# Usage:
#   scripts/land-on-platform-branch.sh [branch] [max-attempts]
#   scripts/land-on-platform-branch.sh linux-next 4
#
# Exit: 0 landed (verified against origin) | 1 dirty tree | 2 rebase conflict
#       3 gate failed | 4 attempts exhausted | 5 auth failed
#       6 push failed for a reason retrying cannot fix
set -uo pipefail

BRANCH="${1:-$(git rev-parse --abbrev-ref HEAD)}"
TRUNK="${TILLANDSIAS_TRUNK_BRANCH:-linux-next}"
ATTEMPTS="${2:-4}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "refused:land:dirty-worktree — commit or stash first" >&2
    exit 1
fi

for attempt in $(seq 1 "$ATTEMPTS"); do
    echo "land: attempt $attempt/$ATTEMPTS — fetch + integrate onto origin/$BRANCH"
    git fetch -q origin "$BRANCH" || { echo "land:fetch-failed" >&2; exit 4; }

    # WHICH INTEGRATION (order 991-85bh, macbook 2026-09-03). methodology
    # integration_strategy case 1 sanctions REBASE for same-branch catch-up, and
    # that is right when your unpushed commits are ordinary ones. But
    # pull_merge_cadence.pre_push_gate REQUIRES merging origin/linux-next before
    # EVERY push of a non-linux-next branch, so a platform branch's unpushed set
    # routinely CONTAINS MERGE COMMITS by mandate. Rebasing those onto a moved
    # remote conflicts immediately: measured on osx-next diverged 35/3 with two
    # macOS hosts landing concurrently, `refused:land:rebase-conflict` every time,
    # while a plain merge landed first try. The two rules are each correct alone
    # and compose badly. So: merge when the unpushed set carries a merge commit,
    # rebase otherwise, and fall back to merge rather than refusing.
    _unpushed_merges="$(git rev-list --merges --count "origin/$BRANCH..HEAD" 2>/dev/null || echo 0)"
    _integrated=0
    if [ "${_unpushed_merges:-0}" -gt 0 ]; then
        echo "land: attempt $attempt — unpushed set has $_unpushed_merges merge commit(s); MERGING (rebase would replay them)"
        if git merge --no-edit "origin/$BRANCH" >/dev/null 2>&1; then
            _integrated=1
        else
            git merge --abort >/dev/null 2>&1
            echo "refused:land:merge-conflict — resolve by hand" >&2
            exit 2
        fi
    else
        if git rebase "origin/$BRANCH" >/dev/null 2>&1; then
            _integrated=1
        else
            git rebase --abort >/dev/null 2>&1
            echo "land: attempt $attempt — rebase conflicted; retrying as a merge before refusing" >&2
            if git merge --no-edit "origin/$BRANCH" >/dev/null 2>&1; then
                _integrated=1
            else
                git merge --abort >/dev/null 2>&1
                echo "refused:land:rebase-and-merge-conflict — resolve by hand" >&2
                exit 2
            fi
        fi
    fi
    [ "$_integrated" -eq 1 ] || { echo "refused:land:not-integrated" >&2; exit 2; }

    # ORDER 1064-r8fv: MERGE TRUNK TOO, or this tool cannot land on a platform
    # branch AT ALL.
    #
    # Everything above integrates onto origin/$BRANCH. The pre-push guard
    # (scripts/hooks/pre-push-linux-next-merged.sh) requires the branch to
    # contain origin/LINUX-NEXT's current head, which is a DIFFERENT ref on
    # every platform branch — so the loop could retry to exhaustion and never
    # satisfy it. The comment forty lines above already names
    # pull_merge_cadence.pre_push_gate as the reason the unpushed set carries
    # merge commits; the code read the rule and then integrated the wrong ref.
    #
    # MEASURED ON YOLANDA 2026-09-05: four consecutive refusals landing
    # 1055-6yp8 from windows-next, three of them
    # blocked:linux-next-not-merged, with the tool reporting
    # `refused:land:push-failed — not a lost race, so retrying cannot help`.
    # That verdict is TRUE and it is the wrong shape: the cause was fixable in
    # one command, and "retrying cannot help" reads as a dead end rather than
    # "merge trunk and come back".
    #
    # WHY IT WENT UNNOTICED: on linux-next itself $BRANCH and linux-next are the
    # same ref, so the merge above already satisfies the guard and the tool
    # works. It fails only where it was needed most — the slow platform hosts it
    # was written for.
    if [ "$BRANCH" != "$TRUNK" ]; then
        git fetch -q origin "$TRUNK" || { echo "land:fetch-failed:$TRUNK" >&2; exit 4; }
        if git merge-base --is-ancestor "origin/$TRUNK" HEAD 2>/dev/null; then
            echo "land: attempt $attempt — origin/$TRUNK already contained"
        else
            echo "land: attempt $attempt — merging origin/$TRUNK (mandated before every non-$TRUNK push)"
            if ! git merge --no-edit "origin/$TRUNK" >/dev/null 2>&1; then
                git merge --abort >/dev/null 2>&1
                echo "refused:land:trunk-merge-conflict — resolve origin/$TRUNK by hand" >&2
                exit 2
            fi
        fi
    fi

    # ORDER 1056-5344. The plan-only lane may accept a push whose head is a
    # UNION of two separately-green sides that were never gated together, and
    # it records that debt in .git/tillandsias-union-ungated. This gate is what
    # pays it. The gate below is therefore MANDATORY whenever that marker
    # exists — asserted rather than assumed, because the whole point of writing
    # the debt down is that a future "skip the gate when nothing changed"
    # shortcut must not silently inherit it.
    _um="$(git rev-parse --absolute-git-dir 2>/dev/null)/tillandsias-union-ungated"
    if [ -s "$_um" ]; then
        echo "land: head carries un-gated union debt ($(wc -l < "$_um" | tr -d ' ') record(s)); the gate below is mandatory (1056-5344)"
    fi

    # ORDER 1033-iycs: CAPTURE THE GATE, AND NAME WHAT FAILED.
    #
    # This line read `./build.sh --check >/dev/null 2>&1` and the refusal was
    # four words plus "run ./build.sh --check to see why" — no step, no reason,
    # no log. In THIS FILE, whose header (lines 14-24) records that discarding
    # the PUSH's output reported LANDED for a refused push. The lesson was
    # applied to the push call and not to the gate call two lines above it.
    #
    # WHY "RE-RUN IT" IS NOT A REMEDY. macbookair hit this landing 997-e4v2 on
    # osx-next: the standalone re-run on the same commit graph, no edits
    # between, returned GATE_EXIT=0 and the retry landed clean. So the remedy
    # text re-runs a DIFFERENT invocation against a tree this script's own
    # integrate step may have moved, and the one instance became irreproducible
    # by construction. Whether the gate is non-deterministic — 1022-y7kc cause 8,
    # 765-tkq2 memoisation — cannot be asked until a refusal carries its
    # evidence, and "re-run it" hides how often this happens.
    #
    # PER ATTEMPT, because the loop runs the gate up to $ATTEMPTS times against
    # different trees; one log overwritten each pass would answer the wrong
    # question. Under $GIT_DIR so it survives the worktree and is not something
    # a later `git clean` removes.
    _gate_log="$(git rev-parse --absolute-git-dir 2>/dev/null)/tillandsias-land-gate-attempt-${attempt}.log"
    echo "land: attempt $attempt — gate (./build.sh --check, log: $_gate_log)"
    if ! ./build.sh --check > "$_gate_log" 2>&1; then
        # The FIRST failing step, not the last line: build.sh prints its verdict
        # after the failure, so a tail shows the summary and not the cause. The
        # error line is what the reader needs and it is what a re-run would have
        # shown them minutes later.
        # ANCHORED, AND `ok` ROWS EXCLUDED. The first cut matched `violation:`
        # and `refused:` ANYWHERE in a line, and the gate is full of fixtures
        # whose EXPECTED output contains those tokens — the very first real
        # refusal this fix caught named
        # `ok   no evidence at all -> refused:no-evidence:...`, a passing arm,
        # as the cause. A marker inside an `ok` row is a fixture quoting the
        # verdict it asserts, not a failure.
        #
        # SEVERITY COMES FROM THE COLOUR, AND STRIPPING IT FIRST THREW THAT
        # AWAY. Second instance, macuahuitl 2026-09-05: this named
        # `[build] standing declared-closure debt: violation:...` — a `_warn`,
        # advisory by design under 885-92iu, whose own comment says it refuses
        # nothing. The real failure was ~60 lines further down (a fixture's
        # `FAIL: expected measured-clean`). The advisory clears both earlier
        # defences: it is anchored at column zero once ANSI is stripped, and it
        # is not an `ok` row. It contains `violation:` because it is CORRECTLY
        # REPORTING A VIOLATION COUNT THAT IS NOT A GATE FAILURE.
        #
        # Anchoring and the `ok` exclusion were both attempts to rebuild, by
        # pattern, information deleted one line earlier: build.sh's `_error` is
        # RED (0;31) and `_warn` is YELLOW (0;33), so the log already says which
        # lines are failures. Match `[build]` lines on SEVERITY and the whole
        # class disappears rather than being enumerated.
        #
        # Fixture output (`FAIL:`, bare `violation:`) is NOT coloured by
        # build.sh — it is the fixture's own stdout — so the text heuristic
        # still owns those lines. Two rules for two sources, not one rule
        # stretched over both.
        _fallback_note=""
        if grep -qa "$(printf '\033\[')" "$_gate_log" 2>/dev/null; then
            _first_fail="$(awk '
                # A [build] line is a failure only if _error painted it red.
                # Strip the escapes for DISPLAY once severity has been read off
                # them — the reader wants the sentence, not the colour bytes.
                /^\033\[0;31m\[build\]/ {
                    line = $0
                    gsub(/\033\[[0-9;]*m/, "", line)
                    print line
                    exit
                }
                /^\033\[0;3[23]m\[build\]/ { next }   # _warn / _info: advisory
                {
                    line = $0
                    gsub(/\033\[[0-9;]*m/, "", line)
                    if (line ~ /^ok[: \t]/) next
                    if (line ~ /^(FAIL[: ]|violation:|refused:)/) { print line; exit }
                }
            ' "$_gate_log" 2>/dev/null | cut -c1-200)"
        else
            # NO COLOUR IN THE LOG (piped through a stripper, TERM=dumb, NO_COLOR,
            # a CI that filters escapes). Severity is genuinely unavailable, so
            # fall back to the text heuristic — and SAY SO, because an unnamed
            # fallback that silently answers a weaker question is the
            # could-not-run-reported-as-clean shape of 1024-c3h3.
            _fallback_note="  (log carries no colour, so severity was unavailable; matched by text — an advisory line quoting a violation count can appear here)"
            _first_fail="$(grep -m1 -E '^(FAIL[: ]|violation:|refused:|\[build\] .*(refused|failed|violation))' \
                "$_gate_log" 2>/dev/null | cut -c1-200)"
        fi
        echo "refused:land:gate-failed — the gate refused; its output is at $_gate_log" >&2
        if [ -n "$_first_fail" ]; then
            echo "  first failing line: $_first_fail" >&2
            [ -n "$_fallback_note" ] && echo "$_fallback_note" >&2
        else
            echo "  (no violation/refusal line matched; read the log — the gate may have died rather than refused)" >&2
        fi
        echo "  Do NOT re-run ./build.sh --check to diagnose this: it is a DIFFERENT" >&2
        echo "  invocation against a tree this script's integrate step may have moved," >&2
        echo "  which is how the 997-e4v2 instance became irreproducible (1033-iycs)." >&2
        exit 3
    fi
    # The gate just built this exact tree, union included, so the debt is paid.
    if [ -s "$_um" ]; then rm -f "$_um"; fi

    echo "land: attempt $attempt — push"
    # No pipeline: the exit status must be git push's own. KEEP THE OUTPUT — an
    # earlier version discarded it, so a push that failed for a NON-RETRYABLE
    # reason left no diagnostic and this loop retried it to exhaustion, burning a
    # full gate run each time. Measured 2026-08-23: an expired GitHub token cost
    # four gate cycles and reported "origin moved" for all of them.
    _plog="${TMPDIR:-/tmp}/land-push.$$.log"
    git push origin "$BRANCH" > "$_plog" 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
        # Retrying only helps a LOST RACE. Anything else must refuse at once and
        # carry its remedy: an error read mid-incident should say what to do.
        if grep -qiE "authentication failed|invalid username or token|could not read Username|Permission denied \(publickey\)" "$_plog"; then
            echo "refused:land:auth-failed — git cannot authenticate to origin." >&2
            sed -n '1,3p' "$_plog" >&2
            echo "  The commit is safe locally; nothing was lost. Re-authenticate, then re-run:" >&2
            echo "    gh auth refresh -h github.com && gh auth setup-git" >&2
            echo "    scripts/land-on-platform-branch.sh $BRANCH" >&2
            rm -f "$_plog"; exit 5
        fi
        # RETRYING ONLY HELPS A LOST RACE, and "rejected" alone does not mean
        # one. ORDER 1064-r8fv: this pattern used to carry a bare `rejected`,
        # which also matches `! [remote rejected] ... (pre-receive hook
        # declined)` — a server-side REFUSAL that will be refused identically
        # forever. Found by this order's own fixture, whose arm 3 rejects a push
        # with a pre-receive hook and got exit 4 (attempts exhausted) where the
        # honest answer is exit 6: the loop burned a full gate run per attempt
        # on a push that could never succeed. That is the same shape the header
        # of this file warns about — matching a substring that appears in the
        # rejection line too — one layer down.
        #
        # A lost race says so specifically: non-fast-forward, fetch first, or
        # stale info. Nothing else is retryable.
        if ! grep -qiE "non-fast-forward|fetch first|stale info" "$_plog"; then # sigpipe-ok: safe pipeline
            echo "refused:land:push-failed — not a lost race, so retrying cannot help:" >&2
            sed -n '1,6p' "$_plog" >&2
            # ORDER 1064-r8fv. NAME THE LANE, DO NOT TAKE IT. A refusal that
            # says only "retrying cannot help" reads as a dead end; four
            # consecutive refusals on yolanda ended in a hand-rolled loop
            # because the message named no way forward. It is deliberately a
            # HINT and not an action: this tool must never retarget a push on
            # its own — work landed on a ref the author did not look at is the
            # failure mode this fleet spends its time removing, and the choice
            # of lane belongs to whoever is watching.
            echo "  If this is a gate or merge policy your host cannot satisfy, push the" >&2
            echo "  GATED tree to a relay ref and ask a trunk host to merge it:" >&2
            echo "      git push origin HEAD:refs/heads/work/<order>" >&2
            echo "  That ref matches no platform pattern, so the mandated-merge guard" >&2
            echo "  does not apply; the local gate stamp still does." >&2
            rm -f "$_plog"; exit 6
        fi
    fi
    rm -f "$_plog"

    # The only proof that counts: ask the remote.
    git fetch -q origin "$BRANCH" 2>/dev/null
    if git merge-base --is-ancestor HEAD "origin/$BRANCH" 2>/dev/null; then
        echo "ok:land:$(git rev-parse --short HEAD):attempt-$attempt"
        exit 0
    fi
    echo "land: push did not land (rc=$rc); origin moved — retrying"
done

echo "refused:land:attempts-exhausted:$ATTEMPTS — origin is moving faster than this host gates" >&2
exit 4
