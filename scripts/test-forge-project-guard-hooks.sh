#!/usr/bin/env bash
# @trace order:969-nhh7, spec:forge-environment-discoverability
# test-forge-project-guard-hooks.sh — fixture proof for the forge's project
# guard-hook installation.
#
# WHAT THIS PINS, and what it deliberately does NOT.
#
# It CANNOT prove a hook fires. Four fixtures on 2026-09-02 reported success
# while their spy hooks were never invoked, all for the same core.hooksPath
# reason, so a fixture-only proof of "the gate refused" is not evidence — the
# live negative control on 969-nhh7 is. What a fixture CAN prove is the
# property whose regression would silently undo the fix:
#
#   the guards go in REPO-LOCAL, and the GLOBAL hooks dir is left alone.
#
# That direction matters because the obvious implementation — install into the
# global dir the forge already uses — is KNOWN-BAD. Measured in a forge guest
# 2026-09-01: a global guard fires in every repo on the box including each /tmp
# fixture repo, `git commit` became impossible outside the checkout, six litmus
# suites failed as collateral, and build.sh --check died at the 877-mynm
# fixture; removing the global hook alone took it 6/5 -> 11/0.
#
# Branches:
#   1. a Tillandsias checkout gets repo-local core.hooksPath + the guards
#   2. the GLOBAL hooks dir is untouched (the anti-collateral invariant)
#   3. the agent trailer hook survives the repo-local shadowing
#   4. a non-Tillandsias repo is left completely alone (no installer present)
#   5. a path that is not a git checkout is a silent no-op, exit 0
#   6. the state line reports present/absent truthfully
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/images/default/lib-common.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/forge-guard-hooks.XXXXXX")"
trap 'rm -rf "$W"' EXIT
fail=0

# lib-common.sh hard-fails at source time outside the forge image (vendor CA
# bundle), so extract the two functions rather than sourcing it — the same
# constraint that put the inference probe in its own lib.
{ sed -n '/^install_project_guard_hooks() {$/,/^}$/p' "$LIB"
  sed -n '/^forge_hook_state_line() {$/,/^}$/p' "$LIB"; } > "$W/fns.sh"
[ -s "$W/fns.sh" ] || { echo "FAIL: could not extract the guard functions from $LIB" >&2; exit 1; }
trace_lifecycle() { :; }
# shellcheck disable=SC1090
. "$W/fns.sh"

export HOME="$W/home"
GLOBAL="$HOME/.cache/tillandsias/git-hooks"
mkdir -p "$GLOBAL"
printf '#!/bin/sh\n# TILLANDSIAS_AGENT trailer fixture\nexit 0\n' > "$GLOBAL/prepare-commit-msg"
printf '#!/bin/sh\n# experts-refresh-on-commit fixture\nexit 0\n' > "$GLOBAL/post-commit"
chmod +x "$GLOBAL"/*
global_before="$(cd "$GLOBAL" && ls | sort | tr '\n' ' ')"

# A checkout with the shape install-hooks.sh needs: the installer plus every
# hook source it composes.
proj="$W/proj"
mkdir -p "$proj/scripts/hooks"
git init -q -b linux-next "$proj"
git -C "$proj" config user.email f@x; git -C "$proj" config user.name f
cp "$ROOT/scripts/install-hooks.sh" "$proj/scripts/"
for h in pre-commit-openspec.sh pre-push-local-gate.sh pre-push-linux-next-merged.sh \
         pre-push-version-guard.sh pre-push-main-branch-affordance.sh \
         pre-push-no-stale-base-revert.sh \
         post-commit-dashboard-refresh.sh post-commit-expert-refresh.sh; do
    cp "$ROOT/scripts/hooks/$h" "$proj/scripts/hooks/"
done
cp "$ROOT/scripts/dev-host-experts.sh" "$proj/scripts/" 2>/dev/null || true
printf 'x\n' > "$proj/f.txt"; git -C "$proj" add -A; git -C "$proj" commit -qm base

# ── 1. the guards land, repo-local ──────────────────────────────────────────
install_project_guard_hooks "$proj" >/dev/null 2>&1 || { echo "FAIL: installer returned non-zero" >&2; fail=1; }
hp="$(git -C "$proj" config --get core.hooksPath || true)"
[ "$hp" = "$proj/.git/hooks" ] \
    && echo "ok: repo-local core.hooksPath set ($hp)" \
    || { echo "FAIL branch1: core.hooksPath is '$hp', expected $proj/.git/hooks" >&2; fail=1; }
for h in pre-commit pre-push; do
    [ -x "$proj/.git/hooks/$h" ] \
        && echo "ok: $h installed repo-local" \
        || { echo "FAIL branch1: $h missing from the repo-local hooks dir" >&2; fail=1; }
done

# ── 2. THE ANTI-COLLATERAL INVARIANT: global dir untouched ──────────────────
global_after="$(cd "$GLOBAL" && ls | sort | tr '\n' ' ')"
if [ "$global_before" = "$global_after" ]; then
    echo "ok: GLOBAL hooks dir untouched ($global_after)"
else
    echo "FAIL branch2: global hooks dir changed '$global_before' -> '$global_after' — a global guard fires in every repo on the box (2026-09-01 collateral)" >&2
    fail=1
fi
[ ! -e "$GLOBAL/pre-push" ] \
    && echo "ok: no pre-push leaked into the global dir" \
    || { echo "FAIL branch2b: a GLOBAL pre-push was installed — this is the known-bad form" >&2; fail=1; }

# ── 3. the trailer hook survives the repo-local shadowing ───────────────────
[ -x "$proj/.git/hooks/prepare-commit-msg" ] \
    && echo "ok: agent trailer hook carried across into the repo-local dir" \
    || { echo "FAIL branch3: repo-local hooksPath shadows the global dir, so commits here lose agent attribution" >&2; fail=1; }

# ── 4. a non-Tillandsias repo is left alone ─────────────────────────────────
other="$W/other"; mkdir -p "$other"; git init -q "$other"
install_project_guard_hooks "$other" >/dev/null 2>&1
[ -z "$(git -C "$other" config --get core.hooksPath || true)" ] \
    && echo "ok: a repo with no scripts/install-hooks.sh is untouched" \
    || { echo "FAIL branch4: a non-Tillandsias repo had its hooksPath rewritten" >&2; fail=1; }

# ── 5. not a checkout at all -> silent no-op, exit 0 ────────────────────────
install_project_guard_hooks "$W/nope" >/dev/null 2>&1 \
    && echo "ok: a missing checkout is a silent no-op (exit 0)" \
    || { echo "FAIL branch5: a missing checkout must not fail the launch" >&2; fail=1; }
install_project_guard_hooks "" >/dev/null 2>&1 \
    && echo "ok: an empty path is a silent no-op (exit 0)" \
    || { echo "FAIL branch5b: an unset project path must not fail the launch" >&2; fail=1; }

# ── 6. the state line tells the truth in both directions ────────────────────
line="$(forge_hook_state_line "$proj")"
case "$line" in
    "hooks: pre_push=present pre_commit=present dir="*) echo "ok: state line reports present ($line)" ;;
    *) echo "FAIL branch6: expected present/present, got '$line'" >&2; fail=1 ;;
esac
bare="$W/bare"; mkdir -p "$bare"; git init -q "$bare"
line="$(forge_hook_state_line "$bare")"
case "$line" in
    "hooks: pre_push=absent pre_commit=absent dir="*) echo "ok: state line reports absent for an unguarded checkout ($line)" ;;
    *) echo "FAIL branch6b: expected absent/absent, got '$line'" >&2; fail=1 ;;
esac

[ "$fail" -eq 0 ] || { echo "test-forge-project-guard-hooks: FAILED" >&2; exit 1; }
echo "ok:forge-project-guard-hooks:11"
echo "PASS: guards install repo-local, global dir untouched, state line honest"
