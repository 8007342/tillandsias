#!/usr/bin/env bash
# @trace order:898-zhf3
#
# The release runbook must not tell you to push the tag before the back-merge.
#
# WHAT THIS PINS, and why a prose file gets a fixture at all.
#
# `skills/merge-to-main-and-release/SKILL.md` step 5 used to read: create the
# tag, `git push origin "${new_tag}"`, and only afterwards back-merge — with an
# explicit "Run this AFTER the tag push, never before".
#
# THAT ORDER IS UNEXECUTABLE on any host that has run scripts/install-hooks.sh.
# MEASURED on macuahuitl 2026-08-26 while cutting v0.4.260826.1:
#
#   ✗ pre-push refused: release preflight says blocked:version-not-monotonic
#     ERROR: Version 0.4.260817.1 is LESS than latest release v0.4.260826.1
#     REMEDY: git fetch origin && git merge origin/main
#
# The guard is RIGHT. `git tag` creating the tag LOCALLY is enough for
# verify-version-monotonic.sh to resolve it as "latest release" and compare it
# against the branch's still-pre-release VERSION. So the tag push requires the
# back-merge, and the back-merge was prescribed after the tag push. Circular.
#
# The pressure at that moment is toward `git push --no-verify` — the one exit
# the hook's own text warns against, on the one ref where bypassing the gate
# publishes a release.
#
# WHY AN ORDER ASSERTION RATHER THAN A WALKTHROUGH. Executing a real cut needs a
# remote, a protected `main`, a PR merge and a workflow dispatch; a fixture that
# needs all that will not run in `--check` and so will not run. Precedent for
# pinning an ORDERING inside a file by line number is already in-tree:
# openspec/litmus-tests/litmus-build-sh-darwin-install-refusal.yaml asserts the
# Darwin refusal appears before `_bump_build_version` the same way.
#
# WHAT THIS CANNOT CATCH, stated so nobody reads it as more than it is: it
# proves the runbook does not PRESCRIBE the deadlocked order. It does not prove
# a cut succeeds. Only a real release does that, and one did — v0.4.260826.1
# was cut in the corrected order with the tag verified unmoved either side.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DOC="${TILLANDSIAS_RELEASE_SKILL:-$ROOT/skills/merge-to-main-and-release/SKILL.md}"
pass=0; fail=0
ok()  { printf 'ok: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1" >&2; fail=$((fail + 1)); }

if [ ! -f "$DOC" ]; then
    echo "skip:release-runbook-tag-order:no-skill-file"
    exit 0
fi

# Line of the back-merge, and line of the tag push. Both are matched on the
# COMMAND, not on surrounding prose, so rewording the section cannot silently
# change what this asserts.
merge_ln="$(grep -n '^git merge origin/main' "$DOC" | head -1 | cut -d: -f1)"
tagpush_ln="$(grep -n '^git push origin "\${new_tag}"' "$DOC" | head -1 | cut -d: -f1)"

# ── arm 1: both commands are still present ──────────────────────────────────
# If either disappears the assertion below would vacuously pass on an empty
# comparison, which is the failure mode this whole packet is about.
if [ -n "$merge_ln" ] && [ -n "$tagpush_ln" ]; then
    ok "both the back-merge and the tag push are present in the runbook (lines $merge_ln, $tagpush_ln)"
else
    bad "runbook no longer contains both commands (merge=${merge_ln:-absent} tag-push=${tagpush_ln:-absent}) — this fixture cannot assert an order it cannot find"
fi

# ── arm 2: THE DEFECT — the back-merge must come FIRST ──────────────────────
if [ -n "$merge_ln" ] && [ -n "$tagpush_ln" ]; then
    if [ "$merge_ln" -lt "$tagpush_ln" ]; then
        ok "back-merge precedes the tag push — the executable order"
    else
        bad "the runbook prescribes pushing the tag at line $tagpush_ln BEFORE the back-merge at line $merge_ln; the pre-push hook refuses that with blocked:version-not-monotonic (898-zhf3)"
    fi
fi

# ── arm 3: NEGATIVE CONTROL — the old instruction must not have come back ────
# Rewording is fine; reinstating the imperative is not.
#
# The `[*_]*` is not decoration. The original read "Run this **after** the tag
# push, never before" and a plain-substring pattern SILENTLY PASSED against it —
# caught only by running this fixture against the pre-fix file from git, which
# is why the falsification run is mandatory and not a formality. A negative
# control that cannot match the text it was written for is worse than absent.
if grep -qiE 'after[*_]* the tag push, never before' "$DOC"; then
    bad "the runbook still carries 'after the tag push, never before' — the instruction that created the deadlock"
else
    ok "the 'after the tag push, never before' instruction is gone"
fi

# ── arm 4: the tag-did-not-move check is prescribed ─────────────────────────
# The reordering TRADES on that property, so the runbook must tell the operator
# to verify it rather than trusting the argument in the comment.
if grep -qF 'git rev-list -n1 "${new_tag}"' "$DOC"; then
    ok "the runbook prescribes verifying the tag did not move"
else
    bad "the runbook reorders the pushes without telling anyone to verify the tag still points at main's bump-merge — that is the property the reordering depends on"
fi

printf 'release-runbook-tag-order: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
printf 'ok:release-runbook-tag-order:%d\n' "$pass"
