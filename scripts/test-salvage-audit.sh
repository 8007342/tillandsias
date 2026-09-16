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
if printf '%s' "$out" | grep -q 'is-AHEAD'; then
    ok "ARM 2: differing files carry a DIRECTION label, not a bare 'differs'"
else
    if printf '%s' "$verdict" | grep -q ':0w:'; then
        echo "skip: ARM 2 — nothing differs on this clone, so no direction label to check"
    else
        bad "ARM 2: files reported as differing with no direction label"
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
