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
#       7 push emitted nothing and hit its bound (1129: blocked credential
#         helper — the push hangs forever and the log stays zero-byte)
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
    # ORDER 1129: BOUND THE PUSH. `git push` has no timeout of its own, and a
    # credential helper that blocks makes it hang FOREVER — the outer land
    # timeout is the only thing that ends it, and what it produces is a
    # zero-byte push log, no verdict, and (because this script's own header
    # documents a pipeline-ending-in-tail bug elsewhere) a SUCCESS-SHAPED exit.
    # A reader sees "push", silence, and exit 0.
    #
    # MEASURED on macneo 2026-09-11, twice: 2362s and 2360s, both killed by the
    # outer bound rather than ending on their own. The helper was
    # `osxkeychain`, configured in /opt/homebrew/etc/gitconfig (NOT ~/.gitconfig
    # — someone looking there will not find it), blocked inside
    # SecKeychainItemCopyContent.
    #
    # THE CAUSE IS NOT A LOCKED KEYCHAIN, and the first version of this comment
    # said it was. Four probes on that host: show-keychain-info, list-keychains
    # and the item's METADATA all read fine, securityd responsive — only the
    # DECRYPT hung, with nothing on stdin (fd 0 was /dev/null). The keychain was
    # already unlocked, which leaves the stored item's own access policy.
    #
    # WHAT IS MEASURED AND WHAT IS NOT, kept separate on purpose. Measured: the
    # metadata/decrypt asymmetry, and that `timeout` DOES kill a blocked helper
    # (rc=124 at exactly the bound, no orphan, no zombie — so SIGTERM lands and
    # no -k is needed for the leaf process). NOT measured: that the fix is
    # approving the item from a GUI session. Nobody has executed that; it is
    # inference from how keychain ACLs normally behave. Note also that the
    # credential is an INTERNET password (srvr=github.com), so the
    # set-generic-password-partition-list recipe people reach for is probably
    # not even the right tool. So this names the CAUSE and points at the probes,
    # and declines to prescribe a cure it cannot stand behind.
    #
    # THE TREE PROPAGATES, measured on macneo against the genuinely ACL-blocked
    # helper — not a fake:
    #     GIT_TERMINAL_PROMPT=0 timeout 30 git push origin osx-next \
    #         > /tmp/treetest.log 2>&1 < /dev/null
    #     -> rc=124 at 31s, log 0 bytes, and afterwards NOTHING matching
    #        osxkeychain|remote-https|git push|git-credential survives.
    # So the bound reaches git push -> git-remote-https ->
    # git-credential-osxkeychain, all three die, and no `timeout -k` is needed.
    # Had the tree NOT propagated this guard would have been unfixable by
    # wording alone: it would return a verdict while a helper kept running.
    #
    # THE BOUND IS GENEROUS ON PURPOSE. A healthy push on that host took ~5s
    # (one derived data point, small plan/ commits, normal link) — 300s is 60x
    # that and still caught both stalls in a twentieth of the time. But 5s is
    # one measurement on one host and NOT a distribution, and refusing a
    # slow-but-healthy push would be worse than the hang it replaces, so the
    # bound is overridable: a big pack or a slow link raises it without patching
    # this script.
    _push_timeout="${TILLANDSIAS_PUSH_TIMEOUT:-300}"
    _t0=$(date +%s)
    # RESOLVE THE BOUNDER, AND ACCEPT gtimeout. macOS ships NO `timeout` in the
    # base system: on tlatoanis-macbook-neo it exists only via Homebrew
    # coreutils, and `env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin sh -c 'command
    # -v timeout'` finds nothing. So a bare `command -v timeout` answers about
    # the CALLER'S PATH, not the host — and a land invoked from a stripped
    # environment (the LaunchServices regime, 980-xcaf) would silently fall
    # through to the unbounded path on a host that has the tool installed.
    # check-host-tools.sh:199-201 already declares `timeout -> gtimeout` as an
    # accepted alternate on macOS; take either, and look in the Homebrew
    # prefixes a stripped PATH omits.
    _bounder=""
    for _cand in timeout gtimeout; do
        if command -v "$_cand" >/dev/null 2>&1; then _bounder="$_cand"; break; fi
    done
    if [ -z "$_bounder" ]; then
        for _pfx in /opt/homebrew/bin /usr/local/bin /home/linuxbrew/.linuxbrew/bin; do
            for _cand in timeout gtimeout; do
                [ -x "$_pfx/$_cand" ] && { _bounder="$_pfx/$_cand"; break 2; }
            done
        done
    fi
    if [ -n "$_bounder" ]; then
        "$_bounder" "$_push_timeout" git push origin "$BRANCH" > "$_plog" 2>&1
        rc=$?
    else
        # No coreutils timeout (some macOS hosts without gnu-coreutils): do not
        # pretend to bound it. Say so, so an unbounded push is a KNOWN state
        # rather than a silent one.
        # NAME IT rather than silently degrading. On a Mac without Homebrew
        # coreutils there is neither timeout nor gtimeout, so this defect stays
        # exactly as it was on the hosts most likely to hit it — the macOS lane
        # is where the keychain hang was measured. An honest message is much
        # better than silence, but it is not a fix, and the packet says so.
        echo "land: warn — no 'timeout' or 'gtimeout' found; push is UNBOUNDED on this host (1129)" >&2
        echo "land:        install GNU coreutils to bound it: brew install coreutils" >&2
        git push origin "$BRANCH" > "$_plog" 2>&1
        rc=$?
    fi
    _elapsed=$(( $(date +%s) - _t0 ))

    # THE HANG, NAMED. Distinguish it from a fast empty log: only a push that
    # BOTH produced nothing AND consumed the bound is this defect. A push that
    # returned quickly with an empty log is something else and must not borrow
    # this remedy.
    if [ ! -s "$_plog" ] && [ "$_elapsed" -ge "$_push_timeout" ]; then
        # THE VERDICT NAMES THE BOUND, NOT THE MEASURED ELAPSED. Measured on
        # macneo: a 30s bound returned at 31s, because timeout signals at the
        # bound and the shell's teardown lands in the next tick. A verdict
        # string that reads 300 on one host and 301 on another is one a fixture
        # cannot pin and a reader would file a bug about. The elapsed is still
        # reported, on the line below, where varying is harmless.
        echo "refused:land:push-emitted-nothing:$_push_timeout" >&2
        {
            echo "  git push produced NO output and hit the ${_push_timeout}s bound (elapsed ${_elapsed}s)."
            echo "  Nothing was pushed. The commit is safe locally; nothing was lost."
            echo "  FIRST SUSPECT: a blocked credential helper. It is the only part"
            echo "  of a push that can wait forever without printing anything."
            echo "    git config --get credential.helper"
            echo "    git config --show-origin --get credential.helper   # may be a"
            echo "      system gitconfig, not ~/.gitconfig"
            echo "  Probe it directly — this returns instantly when healthy:"
            echo "    printf 'protocol=https\nhost=github.com\n\n' | timeout 20 git credential-<helper> get"
            echo "  rc=124 there confirms it."
            echo "  ON macOS, DO NOT REACH FOR THE KEYCHAIN LOCK. Measured on a"
            echo "  host in this state: show-keychain-info, list-keychains and"
            echo "  the item METADATA all read fine and securityd was responsive;"
            echo "  only the DECRYPT hung. The keychain was already unlocked, so"
            echo "  unlocking it changes nothing."
            echo "  WHAT THAT LEAVES is the stored credential item's own access"
            echo "  policy: the decrypt is waiting for a confirmation that the"
            echo "  session running the land has no way to present or answer."
            echo "  CONFIRM IT ON YOUR OWN HOST before acting — run those four"
            echo "  probes; if metadata reads and decrypt hangs, this is it."
            echo "  THE FIX must come from a session that CAN answer that prompt,"
            echo "  and it is the machine owner's call to make: approving a"
            echo "  credential's access policy is not something a land should do"
            echo "  on someone's behalf. Then RE-RUN the land; it does not"
            echo "  self-recover and retrying headless hangs again."
            echo "  NOTE: 'git fetch works' proves nothing here. Anonymous read"
            echo "  never consults the helper, so fetch stays healthy while every"
            echo "  push hangs."
            echo "  If this host legitimately needs longer than ${_push_timeout}s:"
            echo "    TILLANDSIAS_PUSH_TIMEOUT=<seconds> $0 $BRANCH"
        } >&2
        rm -f "$_plog"; exit 7
    fi
    # END ORDER 1129 push bound — this marker is load-bearing: the mutation
    # control in test-land-push-bounded.sh strips from the ORDER banner to here
    # to rebuild the pre-fix (unbounded) push. If it moves, that arm refuses to
    # prove anything rather than passing vacuously.
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
        # A lost race says so specifically: non-fast-forward, fetch first,
        # stale info, or CANNOT LOCK REF.
        #
        # THE FOURTH PHRASING WAS MISSING AND IT IS THE ONE A BUSY TRUNK
        # PRODUCES. Measured on macuahuitl 2026-09-06, twice consecutively:
        #   ! [remote rejected] linux-next -> linux-next (cannot lock ref
        #     'refs/heads/linux-next': is at 405cae043 but expected 82cef6251)
        # That is a lost race stated as precisely as any of the three above —
        # the remote moved between the negotiation and the ref update — and
        # retrying is exactly what fixes it. Instead the loop refused as
        # non-retryable and told a coordinator to relay its own trunk work to a
        # work/ ref, which needs a trunk host to merge: self-defeating on the
        # one host that IS the trunk host.
        #
        # 1064-r8fv correctly NARROWED a bare `rejected` that also matched
        # pre-receive refusals, and then enumerated three race phrasings as
        # though they were all of them. Narrowing a pattern is not the same as
        # enumerating what it must still cover.
        if ! grep -qiE "non-fast-forward|fetch first|stale info|cannot lock ref" "$_plog"; then # sigpipe-ok: safe pipeline
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
