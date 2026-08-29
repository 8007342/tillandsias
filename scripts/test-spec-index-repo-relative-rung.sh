#!/usr/bin/env bash
# @trace order:931-p26p, order:760-hzi4, spec:forge-environment-discoverability
#
# The repo-relative rung (4) must fix the Windows lane WITHOUT moving any host
# that already works.
#
# WHY THE NEGATIVE ARMS ARE THE POINT
#
# This rung was added to make two userlands on one machine agree. The risk it
# carries is the opposite of the bug it fixes: capturing resolution on hosts
# whose earlier rungs are correct today, silently relocating a working index on
# every Linux and macOS box in the fleet. So arms 1-3 assert that an earlier
# rung still wins, and only arm 4 asserts the new behaviour. If you ever find
# yourself relaxing arms 1-3 to make something pass, the change is wrong.
#
# Arms execute the EXTRACTED shell block, the same mechanism
# check-spec-index-resolution-agreement.sh uses, so this cannot drift into
# testing a paraphrase of the ladder.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()  { echo "ok: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)" || { echo "fail:spec-index-repo-relative-rung no tmpdir" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT

sed -n '/^# >>> BEGIN spec-index resolution (801-a2by)/,/^# <<< END spec-index resolution (801-a2by)/p' \
    "$ROOT/scripts/spec-index-ensure.sh" > "$WORK/block.sh"
[ -s "$WORK/block.sh" ] || { echo "fail:spec-index-repo-relative-rung block-not-extracted" >&2; exit 1; }

# A checkout-shaped fixture: plan/index.yaml is what discovery keys on.
FAKE_CO="$WORK/checkout"
mkdir -p "$FAKE_CO/plan" && : > "$FAKE_CO/plan/index.yaml"

# _root <env...> — resolve from inside the fake checkout and print the root.
_root() {
    ( cd "$FAKE_CO" && env -i HOME="$WORK/home" PATH="$PATH" PWD="$FAKE_CO" "$@" sh -c "
        . '$WORK/block.sh'
        _tillandsias_spec_index_paths | sed -n 1p
    " 2>/dev/null )
}

echo "== arm 1 (NEGATIVE): an explicit root still wins over the repo rung =="
got="$(_root FORGE_SPEC_INDEX_ROOT=/tmp/explicit TILLANDSIAS_SPEC_INDEX_NO_PODMAN=1)"
[ "$got" = "/tmp/explicit" ] \
    && ok "explicit FORGE_SPEC_INDEX_ROOT wins (got $got)" \
    || bad "explicit root was overridden by the repo rung: got '$got'"

echo "== arm 2 (NEGATIVE): a Linux-shaped host with a podman volume never reaches the rung =="
# Stub podman so the volume rung resolves, exactly as it does on a Linux box.
VOL="$WORK/volume"; mkdir -p "$VOL"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/podman" <<PODMAN
#!/usr/bin/env bash
echo "$VOL"
PODMAN
chmod +x "$WORK/bin/podman"
got="$( cd "$FAKE_CO" && env -i HOME="$WORK/home" PATH="$WORK/bin:$PATH" PWD="$FAKE_CO" sh -c "
    . '$WORK/block.sh'
    _tillandsias_spec_index_paths | sed -n 1p
" 2>/dev/null )"
[ "$got" = "$VOL" ] \
    && ok "podman volume still wins on a Linux-shaped host (got $got)" \
    || bad "the repo rung captured a host whose podman volume rung was valid: got '$got' want '$VOL'"

echo "== arm 3 (NEGATIVE): a non-writable checkout falls through to the HOME rung =="
RO_CO="$WORK/readonly"; mkdir -p "$RO_CO/plan" "$RO_CO/target"; : > "$RO_CO/plan/index.yaml"
chmod -w "$RO_CO/target" 2>/dev/null || true
if [ -w "$RO_CO/target" ]; then
    # chmod is a no-op on some filesystems (drvfs, core.fileMode=false). Say so
    # rather than reporting a pass the environment could not have produced.
    ok "SKIP(read-only bit not representable here): cannot stage a non-writable checkout"
else
    got="$( cd "$RO_CO" && env -i HOME="$WORK/home" PATH="$PATH" PWD="$RO_CO" XDG_CACHE_HOME="$WORK/xdg" \
        TILLANDSIAS_SPEC_INDEX_NO_PODMAN=1 sh -c "
        . '$WORK/block.sh'
        _tillandsias_spec_index_paths | sed -n 1p
    " 2>/dev/null )"
    [ "$got" = "$WORK/xdg/tillandsias/spec-index" ] \
        && ok "a read-only checkout falls through to XDG (got $got)" \
        || bad "a read-only checkout captured resolution: got '$got'"
    chmod +w "$RO_CO/target" 2>/dev/null || true
fi

echo "== arm 4 (POSITIVE): with no podman and no explicit root, the rung anchors to the checkout =="
got="$(_root XDG_CACHE_HOME="$WORK/xdg" TILLANDSIAS_SPEC_INDEX_NO_PODMAN=1)"
[ "$got" = "$FAKE_CO/target/tillandsias-spec-index" ] \
    && ok "repo-relative rung resolves under the checkout (got $got)" \
    || bad "expected '$FAKE_CO/target/tillandsias-spec-index', got '$got'"

echo "== arm 5 (THE BUG): two different HOMEs resolve to ONE root =="
# This is 931-p26p reduced to its essence — the producer and the reader differ
# only in $HOME, which is precisely the Windows lane's shape (Git Bash
# HOME=/c/Users/<user>, the MCP server HOME=/root).
a="$( cd "$FAKE_CO" && env -i HOME="$WORK/home-a" PATH="$PATH" PWD="$FAKE_CO" \
    TILLANDSIAS_SPEC_INDEX_NO_PODMAN=1 sh -c ". '$WORK/block.sh'; _tillandsias_spec_index_paths | sed -n 1p" 2>/dev/null )"
b="$( cd "$FAKE_CO" && env -i HOME="$WORK/home-b" PATH="$PATH" PWD="$FAKE_CO" \
    TILLANDSIAS_SPEC_INDEX_NO_PODMAN=1 sh -c ". '$WORK/block.sh'; _tillandsias_spec_index_paths | sed -n 1p" 2>/dev/null )"
if [ "$a" = "$b" ] && [ -n "$a" ]; then
    ok "two HOMEs, one root ($a)"
else
    bad "the divergence this rung exists to fix is still present: HOME-a -> '$a', HOME-b -> '$b'"
fi

echo "== arm 6 (CONTROL): without the rung, those same two HOMEs DIVERGE =="
# Without this, arm 5 would pass just as happily against a ladder that never
# consulted $HOME at all, and would prove nothing about the fix.
a="$( env -i HOME="$WORK/home-a" PATH="$PATH" sh -c 'echo "${XDG_CACHE_HOME:-$HOME/.cache}/tillandsias/spec-index"' )"
b="$( env -i HOME="$WORK/home-b" PATH="$PATH" sh -c 'echo "${XDG_CACHE_HOME:-$HOME/.cache}/tillandsias/spec-index"' )"
[ "$a" != "$b" ] \
    && ok "the old HOME-derived rung really does diverge ($a vs $b)" \
    || bad "control failed: the HOME rung did not diverge, so arm 5 proves nothing"

echo
echo "spec-index-repo-relative-rung: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || { echo "fail:spec-index-repo-relative-rung"; exit 1; }
echo "ok:spec-index-repo-relative-rung:$PASS"
