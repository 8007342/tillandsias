#!/usr/bin/env bash
# @trace spec:ci-release
# test-promote-stable-evidence-gate.sh — pin the promote-stable.sh evidence gate.
#
# WHY THIS EXISTS. On 2026-08-23 the gate was found to be structurally unable to
# see the evidence its own sibling skill produces. It required "e2e"|"smoke" AND
# "PASS" AND the version to co-occur on ONE line, because grep is line-scoped.
# What /smoke-curl-install-and-test-e2e actually writes is
#   plan/issues/smoke-e2e-findings-v<version>-<date>.md
# containing
#   ## Run 2026-08-17T17:58Z→18:06Z — **PASS** (tag v0.4.260817.1, build …)
# "smoke"/"e2e" are in the FILENAME; the verdict line never repeats them. So a
# real, dated PASS for v0.4.260817.1 sat in plan/ from 2026-08-17 while the gate
# reported "No e2e PASS evidence" — and because nothing was promoted, hosts then
# skipped running the e2e ("no release newer than last tested evidence"), so the
# stall fed itself.
#
# The fix widened WHERE the "this is e2e evidence" signal may come from (the
# filename) but NOT what counts as a verdict: a file must still assert PASS for
# THIS EXACT version. Case 3 is the one that matters — a correctly named file
# whose content is a FAIL must still be refused. Without it, the fix would have
# traded a false-negative gate for a false-positive one, which on a release gate
# is the strictly worse direction.
#
# Hermetic: fixture REPO_ROOT (the script derives it from BASH_SOURCE), stubbed
# gh + git on PATH. No network, no real repo, no promotion.
set -uo pipefail

REAL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/promote-stable-gate-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT INT TERM

pass=0; fail=0
VER="v0.4.260817.1"

# Stubs. `gh release view` must succeed (the release exists); everything else is
# a no-op so a gate that PASSES cannot actually promote anything from a test.
mkdir -p "$WORK/bin"
cat >"$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 ${2:-}" in
    "release view") exit 0 ;;
    "release edit") echo "stub-gh: would edit $3"; exit 0 ;;
esac
# `release view <tag> --json targetCommitish --jq ...`
if [ "$1" = "release" ] && [ "$2" = "view" ]; then echo "deadbeef"; fi
exit 0
STUB
cat >"$WORK/bin/git" <<'STUB'
#!/usr/bin/env bash
echo "stub-git: $*" >&2
exit 0
STUB
chmod +x "$WORK/bin/gh" "$WORK/bin/git"

# run_case <name> <expected-regex> -- then the caller has already populated
# $WORK/root/plan with the fixture evidence.
run_case() {
    local name="$1" expect="$2"
    local out rc
    out="$(PATH="$WORK/bin:$PATH" bash "$WORK/root/scripts/promote-stable.sh" "$VER" 2>/dev/null)"
    rc=$?
    local last; last="$(printf '%s\n' "$out" | grep -E '^(promoted|refused):' | tail -1)"
    if printf '%s' "$last" | grep -Eq "$expect"; then
        printf 'ok   %-52s -> %s\n' "$name" "${last:-<none>}"
        pass=$((pass + 1))
    else
        printf 'FAIL %-52s -> %s (expected %s, rc=%s)\n' "$name" "${last:-<none>}" "$expect" "$rc"
        fail=$((fail + 1))
    fi
}

fresh_root() {
    rm -rf "$WORK/root"
    mkdir -p "$WORK/root/scripts" "$WORK/root/plan/issues"
    cp "$REAL_ROOT/scripts/promote-stable.sh" "$WORK/root/scripts/"
}

# 1. THE REGRESSION CASE: the exact shape the e2e skill writes. Words "smoke"
#    and "e2e" only in the filename; PASS and version on a heading together.
fresh_root
cat >"$WORK/root/plan/issues/smoke-e2e-findings-${VER}-2026-08-17.md" <<EOF
# curl-install e2e findings

## Run 2026-08-17T17:58Z→18:06Z — **PASS** (tag ${VER}, build commit 0bba6525f)
EOF
run_case "real e2e-skill evidence shape (was BROKEN)" '^promoted:'

# 2. No evidence anywhere.
fresh_root
echo "nothing relevant here" >"$WORK/root/plan/issues/unrelated.md"
run_case "no evidence at all" '^refused:no-evidence:'

# 3. THE ONE THAT KEEPS THE FIX HONEST: right filename, FAIL verdict.
fresh_root
cat >"$WORK/root/plan/issues/smoke-e2e-findings-${VER}-2026-08-17.md" <<EOF
## Run 2026-08-17T17:58Z→18:06Z — **FAIL** (tag ${VER}) install aborted
EOF
run_case "correctly named file but FAIL verdict" '^refused:no-evidence:'

# 4. A PASS, but for a different version.
fresh_root
cat >"$WORK/root/plan/issues/smoke-e2e-findings-v0.4.260810.1-2026-08-10.md" <<'EOF'
## Run 2026-08-10 — **PASS** (tag v0.4.260810.1)
EOF
run_case "PASS exists but for a different version" '^refused:no-evidence:'

# 5. Backward compatibility: the old single-line shape must still pass.
fresh_root
echo "curl-install e2e smoke PASS for 0.4.260817.1 on silverblue" \
    >"$WORK/root/plan/issues/legacy-note.md"
run_case "legacy single-line evidence still accepted" '^promoted:'

# 6. Dot-escaping. Unescaped, 0.4.260817.1 as a regex also matches
#    0X4X260817X1 — on a release gate, accidental permissiveness is the wrong
#    way to be wrong. Filename carries the literal version (glob dots are
#    literal); only the CONTENT is the near-miss.
fresh_root
cat >"$WORK/root/plan/issues/smoke-e2e-findings-${VER}-2026-08-17.md" <<'EOF'
## Run — **PASS** (tag v0X4X260817X1)
EOF
run_case "regex dots do not match arbitrary chars" '^refused:no-evidence:'

printf '\n%s/%s passed\n' "$pass" "$((pass + fail))"
[ "$fail" -eq 0 ]
