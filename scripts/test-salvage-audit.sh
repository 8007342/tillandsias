#!/usr/bin/env bash
# test-salvage-audit.sh — 1226-jb8y: the salvage audit finds refs, separates a
# stale snapshot from genuinely outstanding content, and refuses rather than
# reporting an empty result when it could not look.
#
# ARM 1 IS THE LOAD-BEARING ONE AND IT PINS A BUG THIS SCRIPT SHIPPED WITH.
# `git for-each-ref` takes a PREFIX, not a shell glob: the first version passed
# `refs/remotes/origin/salvage/*` and got ZERO refs, which printed as
# `skipped:salvage-audit:no-refs` — indistinguishable from "nothing is
# stranded". A lookup that silently finds nothing is the exact false negative
# this audit exists to prevent, committed inside the audit. If the ref lookup
# regresses, every other arm still passes.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/salvage-audit.sh"
pass=0; fail=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
[ -x "$CHECK" ] || { echo "skip:salvage-audit:no-check-script"; echo "salvage-audit: 0 passed, 0 failed (skipped)"; exit 0; }

have_refs=$(git -C "$ROOT" for-each-ref --format='%(refname)' refs/remotes/origin/salvage 2>/dev/null | wc -l)

TMPDIR_ARM2B="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_ARM2B"; git -C "$ROOT" update-ref -d "refs/remotes/${SALVAGE_PROBE_REMOTE:-origin}/arm2probe-1226/stale" 2>/dev/null || true' EXIT
out="$(timeout 300 bash "$CHECK" 2>&1)"
verdict="$(printf '%s' "$out" | tail -1)"

# ── ARM 1: the ref lookup actually finds refs when refs exist ────────────────
if [ "$have_refs" -eq 0 ]; then
    echo "skip: ARM 1 — this clone has no origin/salvage refs to audit"
else
    case "$verdict" in
        ok:salvage-audit:0r:*) bad "ARM 1: $have_refs salvage refs exist but the audit found 0 — the prefix-vs-glob false negative is back" ;;
        ok:salvage-audit:*)    ok "ARM 1: the ref lookup found refs ($have_refs SALVAGE refs present; ARM 1b covers the work/ surface)" ;;
        skipped:salvage-audit:no-refs:*) bad "ARM 1: $have_refs salvage refs exist and the audit reported no-refs — a silent empty lookup" ;;
        *) bad "ARM 1: unexpected verdict '$verdict'" ;;
    esac
fi

# ── ARM 1b: THE DEFAULT COVERS BOTH STRANDING SURFACES ──────────────────────
# Order 1227-fegu. The first version defaulted to salvage/* alone — the SMALLER
# half (12 refs against work/'s 24) and NOT the one the land tool's refusal text
# tells a blocked host to use. Pointing it at work/ the first time turned up an
# eleven-day-old ledger event absent from trunk. A default that silently covers
# one surface is this audit's own false-negative, one level up.
have_salv=$(git -C "$ROOT" for-each-ref --format='%(refname)' refs/remotes/origin/salvage 2>/dev/null | wc -l)
have_work=$(git -C "$ROOT" for-each-ref --format='%(refname)' refs/remotes/origin/work 2>/dev/null | wc -l)
if [ "$have_salv" -eq 0 ] && [ "$have_work" -eq 0 ]; then
    echo "skip: ARM 1b — this clone has neither salvage nor work refs"
else
    printf '%s' "$out" | grep -q 'patterns=.*salvage.*work' \
        && ok "ARM 1b: the default header names BOTH stranding surfaces" \
        || bad "ARM 1b: the default no longer names both namespaces — work/ is where a blocked host is TOLD to put a gated tree"
    # And it must actually AUDIT them, not merely name them: the ref count has to
    # account for both, or the header is decoration over a one-surface sweep.
    n_audited="$(printf '%s' "$verdict" | sed -n 's/^ok:salvage-audit:\([0-9]*\)r:.*/\1/p')"
    want=$((have_salv + have_work))
    if [ -n "$n_audited" ] && [ "$n_audited" -ge "$want" ]; then
        ok "ARM 1b: it audited $n_audited refs, covering salvage ($have_salv) + work ($have_work)"
    else
        bad "ARM 1b: audited ${n_audited:-?} refs but salvage+work is $want — one surface is being skipped"
    fi
fi

# ── ARM 2: direction is reported, not just difference ───────────────────────
# "differs" is not "outstanding": a file the branch touched after the snapshot
# is the branch moving on. Both labels must be reachable in the output grammar.
#
# ORDER 1226-jb8y, corrected 2026-09-19 (yoga). THIS ARM USED TO FAIL ON A
# HEALTHY REPOSITORY. Its positive test is `grep 'is-AHEAD'`, which matches
# `linux-next-is-AHEAD` — a STALE SNAPSHOT, the branch having moved past a ref
# — and does NOT match `ref-may-be-AHEAD`, a relay candidate. Checked: a line
# reading exactly `ref-may-be-AHEAD` returns 0 hits for `is-AHEAD`.
#
# So the arm required a stale ref to EXIST on whatever clone it ran on, while
# its only escape was `:0w:`, meaning nothing differs at all. The uncovered
# case is the healthy one: differences exist and every one is a relay
# candidate. Measured on yoga 2026-09-19 — 152 `ref-may-be-AHEAD`, 0 stale, and
# this arm FAILED while the audit was working perfectly.
#
# IT SELF-TRIGGERS, which is why it is worth correcting rather than tolerating:
# a relay land brings trunk level with the salvage refs, which REMOVES the
# stale snapshots, so the arm is likeliest to fail immediately after the fleet
# does the right thing — and on the relaying host's own gate.
#
# The FAIL is kept for the case it was written for: differences reported with
# NO direction label at all, which is the audit actually regressing.
_stale_n="$(printf '%s' "$out" | grep -c 'is-AHEAD' || true)"
# EVERY direction label counts, not just the relay one. The audit emits three:
# `<branch>-is-AHEAD` (stale), `ref-may-be-AHEAD` (relay candidate) and
# `ABSENT-from-<branch>` (the ref holds a file the branch lacks). This arm
# asserts that differences CARRY A DIRECTION, so a clone whose differences are
# all ABSENT is as labelled as one whose differences are all relay candidates —
# counting only the relay label would have failed it for the same wrong reason
# the original arm failed a healthy repository.
_relay_n="$(printf '%s' "$out" | grep -c -e 'ref-may-be-AHEAD' -e 'ABSENT-from-' || true)"
if [ "${_stale_n:-0}" -gt 0 ]; then
    ok "ARM 2: differing files carry a DIRECTION label, not a bare 'differs'"
elif printf '%s' "$verdict" | grep -q ':0w:'; then
    echo "skip:salvage-audit:nothing-differs — no direction label to check on this clone"
elif [ "${_relay_n:-0}" -gt 0 ]; then
    # Differences exist and all of them are labelled. The label just is not the
    # stale one, because no ref is stale. That is a healthy repository, not a
    # regressed audit, and ARM 2b below exercises the stale path regardless.
    echo "skip:salvage-audit:no-stale-snapshot:${_relay_n}-labelled-differences"
else
    bad "ARM 2: files reported as differing with no direction label"
fi

# ── ARM 2b: the stale path is CONSTRUCTED, not hoped for ────────────────────
# ARM 2 above can only observe the stale label when the live repository happens
# to contain a stale ref. That made the positive path untested on exactly the
# clones where it mattered. Here it is built: a scratch remote-tracking ref
# pinned to an older commit, audited against a newer one, so every host
# exercises `linux-next-is-AHEAD` on every run.
_probe_ref="refs/remotes/${SALVAGE_PROBE_REMOTE:-origin}/arm2probe-1226/stale"
# BUILDING A STALE SNAPSHOT TAKES THREE PROPERTIES, and the first two attempts
# here each had only one of them — recorded because the audit was right both
# times and the PROBE was empty, which is the failure this arm exists to make
# impossible for the audit itself.
#
#   1. The ref must have DIVERGED. salvage-audit.sh STEP 1 is
#      `git diff --name-only "$BRANCH...$ref"` — THREE dots — which lists what
#      the REF changed since the merge base. An ancestor changed nothing, so a
#      ref pinned at HEAD~5 yields `0w:0f`. Attempt 1 failed this way.
#   2. The diverging change must touch a file the BRANCH ALSO HAS, or STEP 3
#      labels it ABSENT-from-<branch> instead of a direction.
#   3. The ref's TIP DATE must be OLDER than the branch's last edit of that
#      file, because STEP 3 compares those two timestamps to choose
#      `<branch>-is-AHEAD` over `ref-may-be-AHEAD`. A commit created now is
#      newer than any branch edit, so the probe commit is dated deliberately.
#
# Built with plumbing (hash-object / write-tree / commit-tree) against a
# TEMPORARY index, so the working tree and the real index are never touched.
_probe_file="VERSION"
_probe_tip="$(git -C "$ROOT" rev-list -n1 HEAD -- "$_probe_file" 2>/dev/null || true)"
_probe_base="$(git -C "$ROOT" rev-parse --verify -q "${_probe_tip}^" 2>/dev/null || true)"
_probe_new="$(git -C "$ROOT" rev-parse --verify -q HEAD 2>/dev/null || true)"
_branch_edit="$(git -C "$ROOT" log -1 --format=%ct HEAD -- "$_probe_file" 2>/dev/null || echo 0)"
_probe_commit=""
if [ -n "$_probe_base" ] && [ -n "$_probe_new" ] && [ "${_branch_edit:-0}" -gt 0 ]; then
    _tmpidx="$TMPDIR_ARM2B/index"
    _blob="$(printf 'arm2probe-1226\n' | git -C "$ROOT" hash-object -w --stdin 2>/dev/null || true)"
    if [ -n "$_blob" ]; then
        GIT_INDEX_FILE="$_tmpidx" git -C "$ROOT" read-tree "$_probe_base" 2>/dev/null
        GIT_INDEX_FILE="$_tmpidx" git -C "$ROOT" update-index --cacheinfo "100644,$_blob,$_probe_file" 2>/dev/null
        _tree="$(GIT_INDEX_FILE="$_tmpidx" git -C "$ROOT" write-tree 2>/dev/null || true)"
        if [ -n "$_tree" ]; then
            _when=$(( _branch_edit - 60 ))
            _probe_commit="$(GIT_AUTHOR_DATE="$_when +0000" GIT_COMMITTER_DATE="$_when +0000" \
                GIT_AUTHOR_NAME=arm2probe GIT_AUTHOR_EMAIL=arm2probe@invalid \
                GIT_COMMITTER_NAME=arm2probe GIT_COMMITTER_EMAIL=arm2probe@invalid \
                git -C "$ROOT" commit-tree "$_tree" -p "$_probe_base" -m 'arm2probe-1226 stale snapshot' 2>/dev/null || true)"
        fi
    fi
fi
if [ -z "$_probe_commit" ]; then
    bad "ARM 2b: could not construct a stale snapshot — the positive path is UNTESTED, which is the condition this arm exists to remove"
else
    git -C "$ROOT" update-ref "$_probe_ref" "$_probe_commit"
    _out2b="$(timeout 120 bash "$CHECK" --branch "$_probe_new" --pattern 'refs/heads/arm2probe-1226/' 2>&1)"
    git -C "$ROOT" update-ref -d "$_probe_ref" 2>/dev/null || true
    _hit2b="$(printf '%s' "$_out2b" | grep -c 'is-AHEAD' || true)"
    if [ "${_hit2b:-0}" -gt 0 ]; then
        ok "ARM 2b: a CONSTRUCTED stale snapshot is labelled is-AHEAD — the positive path ran on this host"
    else
        bad "ARM 2b: a constructed stale snapshot was NOT labelled is-AHEAD; last line was: $(printf '%s' "$_out2b" | tail -1)"
    fi
fi

# ── ARM 3: it says ancestry is not the test ─────────────────────────────────
# A ref relayed by cherry-pick is never an ancestor and is fully landed. If this
# script ever starts using ancestry, this line is what should disappear first.
printf '%s' "$out" | grep -qi 'ANCESTRY IS NOT USED' \
    && ok "ARM 3: the output states that ancestry is not the integration test" \
    || bad "ARM 3: the ancestry disclaimer is gone — a cherry-picked relay will read as stranded"

# ── ARM 4: an unresolvable branch refuses, it does not report nothing ────────
out2="$(timeout 60 bash "$CHECK" --branch refs/heads/no-such-branch-1226 2>&1 | tail -1)"
case "$out2" in
    fail:salvage-audit:bad-branch:*) ok "ARM 4: an unresolvable branch refuses instead of reporting nothing stranded" ;;
    *) bad "ARM 4: wanted fail:salvage-audit:bad-branch:*, got '$out2'" ;;
esac

# ── ARM 5: a pattern matching nothing is SKIPPED, not zero-outstanding ──────
out3="$(timeout 60 bash "$CHECK" --pattern refs/heads/no-such-prefix-1226/ 2>&1 | tail -1)"
case "$out3" in
    skipped:salvage-audit:no-refs:*) ok "ARM 5: a pattern matching nothing is skipped, not reported as clean" ;;
    *) bad "ARM 5: wanted skipped:salvage-audit:no-refs:*, got '$out3'" ;;
esac

# ── ARM 6: argument handling refuses and does not hang ──────────────────────
out4="$(timeout 10 bash "$CHECK" --no-such-flag 2>&1 | tail -1)"
case "$out4" in
    fail:salvage-audit:unknown-argument:*) ok "ARM 6: an unknown argument examines nothing" ;;
    *) bad "ARM 6: wanted fail:salvage-audit:unknown-argument:*, got '$out4'" ;;
esac
for flag in --branch --pattern --remote; do
    timeout 10 bash "$CHECK" "$flag" >/tmp/.sa-$$ 2>&1; rc=$?
    v="$(tail -1 /tmp/.sa-$$ 2>/dev/null)"; rm -f /tmp/.sa-$$
    if [ "$rc" -eq 124 ]; then
        bad "ARM 6: '$flag' with no value HUNG (rc=124)"
    elif case "$v" in fail:salvage-audit:missing-value:*) true ;; *) false ;; esac; then
        ok "ARM 6: '$flag' with no value refuses and terminates"
    else
        bad "ARM 6: '$flag' wanted fail:salvage-audit:missing-value:*, got '$v' (rc=$rc)"
    fi
done

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then
    echo "ok:salvage-audit-fixture"
    echo "PASS: salvage-audit $pass/$total (1226-jb8y)"
    exit 0
fi
echo "FAIL: salvage-audit $pass/$total (1226-jb8y)"
exit 1
