#!/usr/bin/env bash
# @trace spec:forge-as-only-runtime
# Order 444: no agent-harness launch write may land on a TRACKED checkout
# path. OpenCode's npm install regenerated the TRACKED
# .opencode/package-lock.json on every launch, dirtying the shared checkout
# (cross-forge dirt, 2026-07-20). This guard makes the invariant executable:
#
#   1. Every KNOWN launch artifact (manifest below) must be UNTRACKED and
#      GITIGNORED (so it can never be accidentally re-added).
#   2. The harness entrypoints are grepped for write idioms into per-harness
#      checkout dirs; any write target not covered by the manifest/gitignore
#      fails loud demanding a manifest entry — new launch artifacts must be
#      declared, not discovered as dirt.
#
# Output grammar (last line, falsifiable):
#   ^ok:launch-artifacts-untracked$
#   ^fail:(tracked|unignored|unmanifested)-launch-artifact:.*$   (exit 1)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Checkout-relative paths harness launches write on every start.
LAUNCH_ARTIFACTS=(
    ".opencode/package-lock.json"
    ".opencode/node_modules"
    ".forge-startup-context.md"
)

fail() { echo "$1" >&2; echo "$2"; exit 1; }

for p in "${LAUNCH_ARTIFACTS[@]}"; do
    if git ls-files --error-unmatch "$p" >/dev/null 2>&1; then
        fail "Launch artifact '$p' is TRACKED — every forge start would dirty the checkout (order 444)." \
             "fail:tracked-launch-artifact:$p"
    fi
    if ! git check-ignore -q "$p"; then
        fail "Launch artifact '$p' is not gitignored — a routine 'git add -A' would re-track it (order 444)." \
             "fail:unignored-launch-artifact:$p"
    fi
done

# Discovery: write idioms in the forge entrypoints that target per-harness
# dirs inside the checkout. Redirections/installs into .opencode/.codex/
# .claude/.gemini must resolve to a manifested-or-ignored path. Comments are
# stripped; matches report file:line so the remedy is one grep away.
unmanifested=""
while IFS= read -r hit; do
    file="${hit%%:*}"
    rest="${hit#*:}"
    line="${rest%%:*}"
    # Extract the .<harness>/... token that is being written.
    token="$(printf '%s\n' "$hit" | grep -oE '\.(opencode|codex|claude|gemini)/[A-Za-z0-9._/-]+' | head -n 1)"
    [ -n "$token" ] || continue
    covered=0
    for p in "${LAUNCH_ARTIFACTS[@]}"; do
        case "$token" in "$p"|"$p"/*) covered=1; break;; esac
    done
    if [ "$covered" -eq 0 ] && git check-ignore -q "$token" 2>/dev/null; then
        covered=1
    fi
    if [ "$covered" -eq 0 ]; then
        unmanifested="${unmanifested}${file}:${line} writes ${token}\n"
    fi
done < <(grep -nE '(^|[^#])((>|>>)[[:space:]]*"?\$?[A-Za-z_{}"]*/?\.(opencode|codex|claude|gemini)/|npm (install|ci)[^#]*\.(opencode|codex|claude|gemini)/)' \
            images/default/entrypoint-forge-*.sh images/default/lib-common.sh 2>/dev/null \
         | sed 's/[[:space:]]*#.*$//')

if [ -n "$unmanifested" ]; then
    printf '%b' "$unmanifested" >&2
    echo "Add the path(s) to LAUNCH_ARTIFACTS in this script AND .gitignore, or stop writing into the checkout (order 444)." >&2
    first="$(printf '%b' "$unmanifested" | head -n 1 | grep -oE '\.(opencode|codex|claude|gemini)/[A-Za-z0-9._/-]+' | head -n 1)"
    echo "fail:unmanifested-launch-artifact:${first:-unknown}"
    exit 1
fi

echo "ok:launch-artifacts-untracked"
exit 0
