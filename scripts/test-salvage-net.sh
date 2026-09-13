#!/usr/bin/env bash
# @trace order:874-w2gc, order:1148-3439
# test-salvage-net.sh — pin the salvage net END TO END: push, round-trip,
# same-day collision, deletion protection, exemption ordering, and the sweep
# that makes rescued work visible.
#
# The incident chain this pins: 872-c9nd (four hours of work deleted with a
# fresh clone while three cycles wrote prose about it), 874-s8vf (the net's
# first push was refused by a guard that ran before the exemption), 874-w2gc
# (a rescue nobody consumes is prose-with-extra-steps; a deletion nobody
# questions is the original incident with extra steps), and 1146-8j7i (a
# clean tree with an unpushed commit answered ok:salvage-not-needed and
# preserved nothing; a dangling symlink the substrate could not stage failed
# the WHOLE salvage instead of just that one path).
#
# Hermetic: every scenario runs against scratch repos and a local bare
# "origin"; the real checkout is never touched. Scenario filter: pass a name
# (roundtrip|collision|deletion|ordering|sweep|unpushed|symlink) to run one;
# default all.
set -uo pipefail

REAL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SALVAGE="$REAL_ROOT/scripts/salvage-dirty-worktree.sh"
SWEEP="$REAL_ROOT/scripts/sweep-salvage-refs.sh"
HOOK="$REAL_ROOT/scripts/hooks/pre-push-local-gate.sh"
ONLY="${1:-all}"
fail=0
ok()  { echo "ok: $1"; }
bad() { echo "FAIL: $1" >&2; fail=1; }
want() { [ "$ONLY" = all ] || [ "$ONLY" = "$1" ]; }

# A scratch work repo whose `origin` is a local bare — the salvage script's
# whole remote surface.
mk_fixture() {
    local d="$1"
    git init -q --bare "$d/origin.git"
    git init -q -b main "$d/work"
    ( cd "$d/work" \
        && git remote add origin "$d/origin.git" \
        && echo base > tracked.txt \
        && git add tracked.txt \
        && git -c user.email=t@t -c user.name=t commit -q -m seed \
        && git push -q origin main )
}

ZEROS="0000000000000000000000000000000000000000"
FAKESHA="1111111111111111111111111111111111111111"

# ── 1. round-trip: dirty content survives push and comes back intact ─────────
if want roundtrip; then
    D="$(mktemp -d "${TMPDIR:-/tmp}/salvage-net-test.XXXXXX")"
    mk_fixture "$D"
    echo edited > "$D/work/tracked.txt"
    echo brand-new > "$D/work/untracked.txt"
    out="$(TILLANDSIAS_SALVAGE_ROOT="$D/work" bash "$SALVAGE" fixture-slug | tail -1)"
    case "$out" in
        ok:salvaged:refs/heads/salvage/*/*-fixture-slug:*) ok "salvage push lands with the documented grammar" ;;
        *) bad "salvage verdict: $out" ;;
    esac
    sha="${out##*:}"
    # The worktree and the REAL index must be untouched by the salvage.
    dirt="$(git -C "$D/work" status --porcelain=v1 --untracked-files=all | sort | tr '\n' '|')"
    [ "$dirt" = " M tracked.txt|?? untracked.txt|" ] \
        && ok "salvage mutated neither worktree nor index" \
        || bad "worktree state changed under salvage: $dirt"
    # Round-trip: a third party fetches the ref and reads the exact dirt back.
    git init -q -b main "$D/reader"
    ( cd "$D/reader" && git remote add origin "$D/origin.git" && git fetch -q origin "+refs/heads/salvage/*:refs/salvage/*" )
    got_tracked="$(git -C "$D/reader" show "$sha:tracked.txt" 2>/dev/null)"
    got_untracked="$(git -C "$D/reader" show "$sha:untracked.txt" 2>/dev/null)"
    [ "$got_tracked" = edited ] && [ "$got_untracked" = brand-new ] \
        && ok "round-trip: modified AND untracked content both recovered byte-exact" \
        || bad "round-trip content: tracked=$got_tracked untracked=$got_untracked"
    rm -rf "$D"
fi

# ── 2. same-day collision: two salvages, same host, same day, BOTH land ──────
if want collision; then
    D="$(mktemp -d "${TMPDIR:-/tmp}/salvage-net-test.XXXXXX")"
    mk_fixture "$D"
    echo first > "$D/work/tracked.txt"
    out1="$(TILLANDSIAS_SALVAGE_ROOT="$D/work" bash "$SALVAGE" twice | tail -1)"
    echo second > "$D/work/tracked.txt"
    out2="$(TILLANDSIAS_SALVAGE_ROOT="$D/work" bash "$SALVAGE" twice | tail -1)"
    case "$out2" in
        ok:salvaged:*) ok "second same-day salvage lands instead of dying non-fast-forward" ;;
        *) bad "second salvage: $out2" ;;
    esac
    n="$(git -C "$D/origin.git" for-each-ref --format='%(refname)' refs/heads/salvage | wc -l | tr -d ' ')"
    [ "$n" = 2 ] && ok "both same-day refs exist on the remote (exit criterion 2)" \
                 || bad "expected 2 salvage refs on origin, found $n"
    ref1="${out1#ok:salvaged:}"; ref1="${ref1%:*}"
    ref2="${out2#ok:salvaged:}"; ref2="${ref2%:*}"
    [ "$ref1" != "$ref2" ] && ok "collision resolved by name, not by overwrite" \
                           || bad "both salvages used the same ref: $ref1"
    rm -rf "$D"
fi

# ── 3. deletion protection: the exemption no longer waves deletions through ──
if want deletion; then
    D="$(mktemp -d "${TMPDIR:-/tmp}/salvage-net-test.XXXXXX")"
    mkdir -p "$D/repo"; ( cd "$D/repo" && git init -q -b main . )
    REFLINE="(delete) $ZEROS refs/heads/salvage/host/20260101-x $FAKESHA"
    ( cd "$D/repo" && printf '%s\n' "$REFLINE" | bash "$HOOK" origin file:///dev/null >/dev/null 2>"$D/err" )
    rc=$?
    grep -q "874-w2gc" "$D/err" && [ "$rc" -ne 0 ] \
        && ok "deleting a salvage ref is refused, naming the decision (rc=$rc)" \
        || bad "deletion slipped through: rc=$rc err=$(head -1 "$D/err")"
    ( cd "$D/repo" && printf '%s\n' "$REFLINE" | TILLANDSIAS_SALVAGE_DELETE_OK=1 bash "$HOOK" origin file:///dev/null >/dev/null 2>&1 )
    rc=$?
    [ "$rc" -eq 0 ] && ok "the explicit override still permits a conscious deletion" \
                    || bad "override did not permit deletion: rc=$rc"
    # NEGATIVE CONTROL: a normal salvage UPDATE (non-zero local sha) must stay
    # exempt — protection that also blocks rescues would resurrect 874-s8vf.
    ( cd "$D/repo" && printf '%s\n' "refs/heads/x $FAKESHA refs/heads/salvage/host/20260101-x $ZEROS" | bash "$HOOK" origin file:///dev/null >/dev/null 2>&1 )
    rc=$?
    [ "$rc" -eq 0 ] && ok "a rescue push is still exempt (protection blocks only deletion)" \
                    || bad "rescue push refused by deletion protection: rc=$rc"
    rm -rf "$D"
fi

# ── 4. exemption ordering: salvage escapes a worktree-state guard that would
#       refuse it (exit criterion 4 — goes red if the exemption is reordered) ─
if want ordering; then
    D="$(mktemp -d "${TMPDIR:-/tmp}/salvage-net-test.XXXXXX")"
    mkdir -p "$D/repo/scripts" "$D/repo/cheatsheets"
    ( cd "$D/repo" && git init -q -b main . )
    cp "$REAL_ROOT/scripts/stage-image-cheatsheets.sh" "$D/repo/scripts/"
    echo stray > "$D/repo/cheatsheets/fixture.md"
    # COUNTERFACTUAL FIRST: prove this fixture's tree DOES make the cheatsheet
    # guard refuse a normal push — otherwise a pass below proves nothing.
    ( cd "$D/repo" && printf '%s\n' "refs/heads/main $FAKESHA refs/heads/main $ZEROS" | bash "$HOOK" origin file:///dev/null >/dev/null 2>"$D/err" )
    rc=$?
    { [ "$rc" -ne 0 ] && grep -qi cheatsheet "$D/err"; } \
        && ok "counterfactual: the cheatsheet guard refuses a NORMAL push from this tree" \
        || bad "fixture did not trip the guard (rc=$rc) — ordering test has no teeth"
    # THE PIN: the same tree, salvage-only refs — must exit 0, which is only
    # possible if the exemption runs BEFORE the guard that just refused.
    ( cd "$D/repo" && printf '%s\n' "refs/heads/x $FAKESHA refs/heads/salvage/host/20260101-x $ZEROS" | bash "$HOOK" origin file:///dev/null >/dev/null 2>&1 )
    rc=$?
    [ "$rc" -eq 0 ] && ok "salvage-only push exits 0 from the same tree — exemption is the first decision" \
                    || bad "salvage push refused (rc=$rc): the exemption is no longer the hook's first decision"
    rm -rf "$D"
fi

# ── 5. sweep: unseen refs become standing per-host ledger lines exactly once
#       (874-w2gc's original consumer contract); 1148-3439 re-points this at
#       plan/salvage-refs.d/<host>.md (never archived, no plan binary needed)
#       because --apply used to file through tillandsias-plan onto packet
#       874-s8vf, which the ledger refuses events on once archived — apply
#       filed NOTHING from that point on while report mode kept counting
#       fine, which is exactly the gap a pure argv-capture stub could not
#       have caught (it never modeled "the target packet is archived").
if want sweep; then
    D="$(mktemp -d "${TMPDIR:-/tmp}/salvage-net-test.XXXXXX")"
    mk_fixture "$D"

    # Two salvages from the SAME work tree, so the fixture gets both an
    # ancestry "on:" case and a "none" case without a second script.
    echo merged-dirt > "$D/work/tracked.txt"
    out_merged="$(TILLANDSIAS_SALVAGE_ROOT="$D/work" bash "$SALVAGE" ledger-merged | tail -1)"
    ref_merged="${out_merged#ok:salvaged:}"; ref_merged="${ref_merged%:*}"
    sha_merged="${out_merged##*:}"
    echo orphan-dirt > "$D/work/tracked.txt"
    out_orphan="$(TILLANDSIAS_SALVAGE_ROOT="$D/work" bash "$SALVAGE" ledger-orphan | tail -1)"
    ref_orphan="${out_orphan#ok:salvaged:}"; ref_orphan="${ref_orphan%:*}"
    sha_orphan="${out_orphan##*:}"

    # Give the fixture's OWN origin a linux-next branch that actually
    # contains sha_merged, so the ancestry check has a real "on:linux-next"
    # to find; sha_orphan is never referenced by any branch, so it must read
    # "none". Neither is on main: both are salvage commits descended FROM
    # main's tip, not ancestors of it.
    git -C "$D/origin.git" branch linux-next "$sha_merged"

    # Sweep root: its own throwaway repo whose "origin" IS the bare remote
    # above, so ls-remote sees the salvage refs and the branch just created.
    # No plan binary and no plan/index* ledger involved anywhere below — the
    # whole point of 1148-3439 is that the sweep no longer needs either.
    mkdir -p "$D/root"
    ( cd "$D/root" && git init -q -b main . >/dev/null 2>&1 )
    ( cd "$D/root" && git remote add origin "$D/origin.git" )
    ( cd "$D/root" && git fetch -q origin >/dev/null 2>&1 )
    mkdir -p "$D/state"
    printf '{"r":1}\n{"r":2}\n{"r":3}\n' > "$D/state/overlap-refusals.jsonl"
    env_sweep() {
        TILLANDSIAS_SALVAGE_ROOT="$D/root" \
        TILLANDSIAS_CYCLE_STATE_DIR="$D/state" \
            bash "$SWEEP" "$@"
    }
    env_checker() {
        TILLANDSIAS_SALVAGE_ROOT="$D/root" bash "$REAL_ROOT/scripts/check-salvage-refs-ledger.sh"
    }

    out="$(env_sweep | tail -1)"
    case "$out" in
        ok:salvage-sweep:refs=2:new=2:filed=0:refusals-new=3) ok "report mode counts without writing" ;;
        *) bad "report-mode verdict: $out" ;;
    esac
    if [ -d "$D/root/plan/salvage-refs.d" ] && [ -n "$(ls -A "$D/root/plan/salvage-refs.d" 2>/dev/null)" ]; then
        bad "report mode wrote to plan/salvage-refs.d"
    else
        ok "report mode never touched the salvage-refs ledger"
    fi

    out="$(env_sweep --apply | tail -1)"
    case "$out" in
        ok:salvage-sweep:refs=2:new=2:filed=2:refusals-new=3) ok "apply mode files both unseen refs (exit criterion 1)" ;;
        *) bad "apply-mode verdict: $out" ;;
    esac

    ledger_file=""
    for cand in "$D/root/plan/salvage-refs.d"/*.md; do
        [ -e "$cand" ] || continue
        ledger_file="$cand"
        break
    done
    if [ -n "$ledger_file" ]; then
        ok "apply mode created a per-host plan/salvage-refs.d/<host>.md file"
    else
        bad "no plan/salvage-refs.d/<host>.md file was created"
    fi

    line_merged="$(grep -F "$ref_merged" "$ledger_file" 2>/dev/null)"
    line_orphan="$(grep -F "$ref_orphan" "$ledger_file" 2>/dev/null)"
    printf '%s\n' "$line_merged" | grep -qF '| on:linux-next |' \
        && ok "the ref merged into linux-next gets ancestry verdict on:linux-next" \
        || bad "merged ref ancestry line wrong: $line_merged"
    printf '%s\n' "$line_orphan" | grep -qF '| none |' \
        && ok "the ref on no branch gets ancestry verdict none" \
        || bad "orphan ref ancestry line wrong: $line_orphan"
    printf '%s\n' "$line_merged" | grep -qE '^\| [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z \| [^|]+ \| [0-9a-f]{40} \| on:linux-next \| [0-9-]+ \|$' \
        && ok "the ledger line matches the five-field grammar" \
        || bad "ledger line does not match the documented grammar: $line_merged"

    out="$(env_sweep --apply | tail -1)"
    case "$out" in
        ok:salvage-sweep:refs=2:new=0:filed=0:refusals-new=0) ok "second sweep is idempotent; refusal cursor advanced" ;;
        *) bad "idempotence verdict: $out" ;;
    esac

    good_out="$(env_checker)"; good_rc=$?
    case "$good_out" in
        ok:salvage-refs-ledger:*)
            [ "$good_rc" -eq 0 ] && ok "check-salvage-refs-ledger.sh passes on the produced file" \
                                  || bad "checker exited $good_rc on a good file: $good_out" ;;
        *) bad "checker verdict on a good file: $good_out" ;;
    esac

    # NEGATIVE CONTROL: a line missing its ancestry field (four fields, not
    # five) must be refused, never silently accepted.
    printf '| 2026-01-01T00:00:00Z | refs/heads/salvage/x/y | %s | 0 |\n' "$sha_orphan" >> "$ledger_file"
    bad_out="$(env_checker)"; bad_rc=$?
    case "$bad_out" in
        violation:salvage-refs-ledger:*)
            [ "$bad_rc" -ne 0 ] && ok "check-salvage-refs-ledger.sh refuses a four-field line" \
                                 || bad "checker did not exit non-zero on a four-field line" ;;
        *) bad "checker did not name a violation on a four-field line: $bad_out" ;;
    esac

    rm -rf "$D"
fi

# ── 6. UNREACHABLE ORIGIN: the copy must still exist locally (1103-i7xq) ────
# THE ARM THIS FIXTURE NEVER HAD, and the reason the defect survived: every
# arm above gives the script a working local bare as `origin`, so the push
# always succeeds and the push-failure path was never executed. The script
# pushed the commit straight to origin and created no local ref, so a failed
# push left NO COPY — the object unreferenced and unreachable.
#
# That is inverted for this script's purpose. It exists because refusing to
# touch dirt protects it from the agent and not from a fresh clone (872-c9nd),
# and the hosts most likely to strand work are the ones that cannot push:
# macbookneo was credential-blocked for a full day (1025-a896), esmeraldinha's
# token went 401 mid-session.
if want unreachable-origin; then
    D="$(mktemp -d "${TMPDIR:-/tmp}/salvage-net-unreach.XXXXXX")"
    mk_fixture "$D"
    # Point origin at nothing. The dirt is what a stranded cycle would hold.
    ( cd "$D/work" && git remote set-url origin "$D/does-not-exist.git" )
    echo edited > "$D/work/tracked.txt"
    echo precious > "$D/work/untracked.txt"
    before="$(cd "$D/work" && find . -path ./.git -prune -o -type f -print | sort | xargs sha256sum | sha256sum)"
    out6="$(TILLANDSIAS_SALVAGE_ROOT="$D/work" bash "$SALVAGE" unreachable 2>/dev/null | tail -1)"
    rc6=$?
    after="$(cd "$D/work" && find . -path ./.git -prune -o -type f -print | sort | xargs sha256sum | sha256sum)"

    case "$out6" in
        ok:salvaged-local:refs/heads/salvage/*/*-unreachable:*)
            ok "an unreachable origin still salvages, with a distinct verdict" ;;
        ok:salvaged:*)
            bad "reported a plain salvage though the push could not have landed: $out6" ;;
        *)
            bad "unreachable-origin verdict: $out6" ;;
    esac

    # EXIT 0 IS PART OF THE FIX. A local copy is a real copy; exiting non-zero
    # tells the caller nothing was saved and is how a host abandons the one
    # thing standing between it and 872-c9nd.
    [ "$rc6" -eq 0 ] && ok "a local-only salvage exits 0" \
        || bad "local-only salvage exited $rc6, want 0"

    # THE CONTENT IS THE POINT, not the ref. Without this the arm passes on a
    # ref pointing at an empty tree.
    ref6="${out6#ok:salvaged-local:}"; ref6="${ref6%:*}"
    if git -C "$D/work" ls-tree -r --name-only "$ref6" 2>/dev/null | grep -qx untracked.txt; then
        ok "the untracked file is inside the local salvage commit"
    else
        bad "the local salvage ref does not contain the untracked file"
    fi

    # NEGATIVE CONTROL: a fix that reached for the worktree to recover from a
    # push failure would trade data loss for corruption.
    [ "$before" = "$after" ] \
        && ok "the worktree is byte-identical after a failed-push salvage" \
        || bad "the failed-push path MUTATED the worktree"

    rm -rf "$D"
fi

# ── 7. unpushed: a clean tree is not a SAFE tree (1146-8j7i) ─────────────────
# MEASURED (yolanda, 2026-09-13): 823-u5zf finished and gated green at
# 1d7b29bcc, a trunk merge then reds the gate, and every push after that is
# refused — the commit sits only on the host, on a tree with nothing dirty to
# salvage. Pre-fix, the script's only test was `git status --porcelain`; a
# clean-but-unpushed HEAD answered ok:salvage-not-needed, exit 0, having
# preserved nothing.
if want unpushed; then
    D="$(mktemp -d "${TMPDIR:-/tmp}/salvage-net-test.XXXXXX")"
    mk_fixture "$D"
    # NEGATIVE CONTROL FIRST: right after mk_fixture, HEAD is exactly what was
    # just pushed to origin/main — clean AND reachable. This must still be
    # ok:salvage-not-needed, or the positive arm below proves nothing (it
    # would just mean the script always pushes something).
    out0="$(TILLANDSIAS_SALVAGE_ROOT="$D/work" bash "$SALVAGE" negctrl | tail -1)"
    [ "$out0" = "ok:salvage-not-needed" ] \
        && ok "NEGATIVE CONTROL: clean tree, HEAD on origin, still ok:salvage-not-needed" \
        || bad "negative control verdict: $out0"

    # THE PIN: one more commit, made locally, never pushed.
    ( cd "$D/work" && echo more >> tracked.txt && git add tracked.txt \
        && git -c user.email=t@t -c user.name=t commit -q -m "finished, unpushed" )
    sha_unpushed="$(git -C "$D/work" rev-parse HEAD)"
    out="$(TILLANDSIAS_SALVAGE_ROOT="$D/work" bash "$SALVAGE" unpushed-slug | tail -1)"
    case "$out" in
        ok:salvaged-commits:refs/heads/salvage/*/*-unpushed-slug:*) ok "unpushed HEAD is pushed to the salvage ref with the documented grammar" ;;
        *) bad "unpushed verdict: $out" ;;
    esac
    ref="${out#ok:salvaged-commits:}"; ref="${ref%:*}"
    sha="${out##*:}"
    [ "$sha" = "$sha_unpushed" ] \
        && ok "the salvaged sha IS the unpushed HEAD, not some other commit" \
        || bad "salvaged sha ($sha) is not the unpushed HEAD ($sha_unpushed)"
    # THE ORIGIN CHECK (equivalent to `git merge-base --is-ancestor <sha>
    # origin/<ref>` after a fetch): asked directly of the bare origin, which
    # avoids inventing a remote-tracking name for a ref nobody fetches by
    # convention. is-ancestor of itself is true iff the object and the ref
    # both actually landed on origin.
    if git -C "$D/origin.git" cat-file -e "$sha" 2>/dev/null \
        && git -C "$D/origin.git" merge-base --is-ancestor "$sha" "$ref" 2>/dev/null; then
        ok "the unpushed commit reached the bare origin at $ref"
    else
        bad "the unpushed commit did not land on the bare origin at $ref"
    fi
    # A commits-only salvage stages nothing; the worktree must stay clean.
    dirt="$(git -C "$D/work" status --porcelain=v1 --untracked-files=all)"
    [ -z "$dirt" ] && ok "commits-only salvage left the worktree clean" \
                   || bad "worktree dirtied by a commits-only salvage: $dirt"
    rm -rf "$D"
fi

# ── 8. symlink: one unstageable path is SKIPPED, never fatal (1146-8j7i) ────
# MEASURED (yolanda, 2026-09-13, Git for Windows): a dangling symlink left in the
# worktree made `git add -A` fail for the WHOLE tree —
# `fail:salvage:add:error: open("dangling"): Function not implemented` —
# turning "preserve everything else" into "preserve nothing".
#
# Linux itself CAN stage a dangling symlink (see the counterfactual below);
# the failure is Git-for-Windows's (MSYS symlink emulation copies the target; a missing target leaves nothing to index), which WSL git on the same path does not share and this host cannot reproduce. Reaching for a
# filesystem trick to fake it (an unreadable directory, a FIFO) would be
# testing a DIFFERENT unstageable path than the one measured, on a mechanism
# git might handle differently. Instead this fixture drives the real
# skip/continue branch directly through TILLANDSIAS_SALVAGE_UNSTAGEABLE_GLOB,
# a seam salvage-dirty-worktree.sh consults ONLY when the caller sets it
# (unset in production, and not a general "skip whatever fails" fallback —
# it forces exactly the one named path down the same `git add -A -- <path>`
# failure branch a real ENOSYS would take). That is hermetic and does not
# weaken production: production still tries every path for real; only the
# fixture's chosen path is short-circuited to the failure outcome.
if want symlink; then
    D="$(mktemp -d "${TMPDIR:-/tmp}/salvage-net-test.XXXXXX")"
    mk_fixture "$D"
    echo edited > "$D/work/tracked.txt"
    ( cd "$D/work" && ln -s /nonexistent/target dangling )

    # COUNTERFACTUAL FIRST: prove THIS filesystem stages the dangling symlink
    # fine unaided — otherwise the skip below is not exercising anything.
    ( cd "$D/work" && git add -A -- dangling ) 2>/dev/null
    rc=$?
    ( cd "$D/work" && git reset -q -- dangling ) 2>/dev/null
    [ "$rc" -eq 0 ] && ok "counterfactual: this filesystem CAN stage the dangling symlink unaided" \
                    || bad "fixture's symlink is not stageable here — the skip test has no teeth"

    out="$(TILLANDSIAS_SALVAGE_ROOT="$D/work" TILLANDSIAS_SALVAGE_UNSTAGEABLE_GLOB='dangling' bash "$SALVAGE" symlink-slug)"
    verdict="$(printf '%s\n' "$out" | tail -1)"
    case "$verdict" in
        ok:salvaged:refs/heads/salvage/*/*-symlink-slug:*) ok "salvage still lands with one path skipped" ;;
        *) bad "symlink verdict: $verdict" ;;
    esac
    printf '%s\n' "$out" | grep -qx "skip:salvage:unstageable:dangling" \
        && ok "the unstageable path is named on stdout" \
        || bad "no skip:salvage:unstageable:dangling line in: $out"
    sha="${verdict##*:}"
    got_tracked="$(git -C "$D/work" show "$sha:tracked.txt" 2>/dev/null)"
    [ "$got_tracked" = edited ] \
        && ok "the ordinary modified file IS on the salvage ref despite the skip" \
        || bad "modified file missing from salvage commit: got=$got_tracked"
    if git -C "$D/work" ls-tree -r --name-only "$sha" 2>/dev/null | grep -qx dangling; then
        bad "the skipped path was staged into the salvage tree anyway"
    else
        ok "the skipped path is absent from the salvage tree"
    fi
    # Same guarantee as every other scenario, even through the new per-path
    # staging loop: the worktree and real index are untouched. Checked by
    # membership, not by a sorted join — glibc's UTF-8 collation gives
    # punctuation near-zero weight, so `sort` orders "?? dangling" before
    # " M tracked.txt" here despite the leading-byte comparison the roundtrip
    # scenario's own sorted string happens to rely on; a fixed join string
    # would be locale-fragile.
    dirt="$(git -C "$D/work" status --porcelain=v1 --untracked-files=all)"
    n_dirt="$(printf '%s\n' "$dirt" | grep -c .)"
    if [ "$n_dirt" = 2 ] \
        && printf '%s\n' "$dirt" | grep -qx ' M tracked.txt' \
        && printf '%s\n' "$dirt" | grep -qx '?? dangling'; then
        ok "the skip path left the worktree and real index untouched"
    else
        bad "worktree state changed under a skip: $dirt"
    fi
    rm -rf "$D"
fi

if [ "$fail" -eq 0 ]; then
    echo "ok:salvage-net-fixture:all"
    exit 0
fi
echo "fail:salvage-net-fixture"
exit 1
