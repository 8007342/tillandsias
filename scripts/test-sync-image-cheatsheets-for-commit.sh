#!/usr/bin/env bash
# @trace order:448, spec:cheatsheet-tooling
# test-sync-image-cheatsheets-for-commit.sh — fixture proof for the order-448
# commit-time cheatsheet sync guard.
#
# Branches:
#   1. a commit touching NOTHING authored is a silent no-op
#   2. a commit touching cheatsheets/ regenerates AND stages the derived tree
#      into the same commit (the whole point)
#   3. MUTATION: without the guard, the same commit leaves the derived copy
#      stale — proving arm 2 has teeth rather than agreeing with the status quo
#   4. a missing stager warns loudly and still exits 0 (never blocks a commit)
#   5. the guard never blocks: exit 0 on every path
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
GUARD="$ROOT/scripts/sync-image-cheatsheets-for-commit.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/cheatsheet-sync.XXXXXX")"
trap 'rm -rf "$W"' EXIT
fail=0

# A throwaway repo with the same SHAPE: an authored tree, a derived copy, and
# a stager that mirrors one onto the other. Hermetic — core.hooksPath is
# pinned per-repo because a global one replaces .git/hooks for every repo on
# the host (the 964-fwvh lesson; the forge sets exactly that).
repo="$W/repo"
mkdir -p "$repo/cheatsheets/runtime" "$repo/images/default/cheatsheets" "$repo/scripts"
git init -q -b main "$repo"
git -C "$repo" config user.name fixture
git -C "$repo" config user.email fixture@example.invalid
git -C "$repo" config core.hooksPath "$repo/.git/hooks"
cat > "$repo/scripts/stage-image-cheatsheets.sh" <<'STAGER'
#!/usr/bin/env bash
set -euo pipefail
R="$(git rev-parse --show-toplevel)"
rm -rf "$R/images/default/cheatsheets"
mkdir -p "$R/images/default/cheatsheets"
cp -r "$R/cheatsheets/." "$R/images/default/cheatsheets/"
echo "cheatsheet-image-stage:ok"
STAGER
chmod +x "$repo/scripts/stage-image-cheatsheets.sh"
cp "$GUARD" "$repo/scripts/sync-image-cheatsheets-for-commit.sh"
printf 'v1\n' > "$repo/cheatsheets/runtime/thing.md"
mkdir -p "$repo/images/default/cheatsheets/runtime"
printf 'v1\n' > "$repo/images/default/cheatsheets/runtime/thing.md"
printf 'other\n' > "$repo/README.md"
git -C "$repo" add -A && git -C "$repo" commit -qm baseline

run_guard() { ( cd "$repo" && bash scripts/sync-image-cheatsheets-for-commit.sh 2>/dev/null ); }

# ── 1. nothing authored staged -> silent no-op ──────────────────────────────
printf 'changed\n' > "$repo/README.md"
git -C "$repo" add README.md
got="$(run_guard)"; rc=$?
[ "$got" = "skip:no-authored-cheatsheet-change" ] && [ "$rc" -eq 0 ] \
    && echo "ok: unrelated commit is a no-op ($got)" \
    || { echo "FAIL branch1: got '$got' rc=$rc" >&2; fail=1; }
git -C "$repo" reset -q

# ── 2. authored edit -> derived tree regenerated AND staged ─────────────────
printf 'v2 authored\n' > "$repo/cheatsheets/runtime/thing.md"
git -C "$repo" add cheatsheets/runtime/thing.md
got="$(run_guard)"; rc=$?
case "$got" in
    ok:cheatsheet-image-synced:*) echo "ok: authored edit re-synced the derived tree ($got)" ;;
    *) echo "FAIL branch2: expected ok:cheatsheet-image-synced:<n>, got '$got' rc=$rc" >&2; fail=1 ;;
esac
staged="$(git -C "$repo" diff --cached --name-only -- images/default/cheatsheets/)"
[ -n "$staged" ] \
    && echo "ok: the derived copy is STAGED into this very commit ($staged)" \
    || { echo "FAIL branch2b: derived tree was regenerated but not staged" >&2; fail=1; }
git -C "$repo" commit -qm "authored + derived"
if [ "$(cat "$repo/images/default/cheatsheets/runtime/thing.md")" = "v2 authored" ]; then
    echo "ok: committed derived copy matches the authored source"
else
    echo "FAIL branch2c: derived copy did not follow the authored edit" >&2; fail=1
fi

# ── 3. MUTATION: the same commit WITHOUT the guard leaves drift ─────────────
# If this arm did not drift, arm 2 would be agreeing with the status quo rather
# than causing it, and the guard would be decorative.
printf 'v3 authored\n' > "$repo/cheatsheets/runtime/thing.md"
git -C "$repo" add cheatsheets/runtime/thing.md
git -C "$repo" commit -qm "authored only, guard NOT run"
if [ "$(cat "$repo/images/default/cheatsheets/runtime/thing.md")" = "v3 authored" ]; then
    echo "FAIL branch3: no drift without the guard — arm 2 proves nothing" >&2; fail=1
else
    echo "ok: MUTATION — without the guard the derived copy goes stale (arm 2 has teeth)"
fi

# ── 4. missing stager -> loud warn, still exit 0 ────────────────────────────
mv "$repo/scripts/stage-image-cheatsheets.sh" "$repo/scripts/stage-image-cheatsheets.sh.gone"
printf 'v4 authored\n' > "$repo/cheatsheets/runtime/thing.md"
git -C "$repo" add cheatsheets/runtime/thing.md
got="$(run_guard)"; rc=$?
[ "$got" = "warn:stager-missing" ] && [ "$rc" -eq 0 ] \
    && echo "ok: a missing stager warns and never blocks ($got rc=$rc)" \
    || { echo "FAIL branch4: expected warn:stager-missing rc=0, got '$got' rc=$rc" >&2; fail=1; }
stderr="$( ( cd "$repo" && bash scripts/sync-image-cheatsheets-for-commit.sh 2>&1 >/dev/null ) )"
case "$stderr" in
    *"refuse EVERY host's push"*) echo "ok: the warning names the consequence other hosts will see" ;;
    *) echo "FAIL branch4b: warning does not name the push refusal: $stderr" >&2; fail=1 ;;
esac

[ "$fail" -eq 0 ] || { echo "test-sync-image-cheatsheets-for-commit: FAILED" >&2; exit 1; }
echo "ok:cheatsheet-commit-sync:7"
echo "PASS: order-448 commit-time cheatsheet sync proven (incl. mutation)"
