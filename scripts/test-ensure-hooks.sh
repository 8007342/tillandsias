#!/usr/bin/env bash
# @trace order:1255-s4im
#
# Fixture for scripts/ensure-hooks.sh. Hermetic: scratch repos built from a
# COPY of this tree's scripts/ (so the bytes under test are the working tree's,
# not the last commit's), HOME and the global git config redirected into the
# scratch dir, system config ignored. The live checkout's hooks are never read
# or written.
#
# Arms:
#   1. RED->GREEN: a fresh clone has no hook and a code push is ACCEPTED; after
#      ensure-hooks with NO cargo on PATH the hook is installed and the same
#      push is REFUSED — and the refusal names the no-cargo route (the remedy
#      fix in pre-push-main-branch-affordance.sh).
#   2. idempotent: a second run is ok:hooks and leaves the hook byte-identical.
#   3. an older marker of ours is upgraded.
#   4. a FOREIGN pre-push is refused (exit 3) and left byte-identical.
#   5. NEGATIVE CONTROL: a local core.hooksPath (the forge's shared dir) holding
#      our current hook is ok — no false gap; an empty one is installed INTO
#      that dir, not .git/hooks.
#   6. a global core.hooksPath is refused and nothing is written there.
#   7. --prelude: silent and inert for a non-GitHub origin; with
#      TILLANDSIAS_ENSURE_HOOKS=1 it installs with stdout EMPTY; silent on ok;
#      a refusal goes to stderr and still exits 0; =0 disables it.
set -u

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/ensure-hooks.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fails=0; passes=0
ok()  { echo "ok:   $1"; passes=$((passes + 1)); }
bad() { echo "FAIL: $1" >&2; fails=$((fails + 1)); }

export HOME="$TMP/home" GIT_CONFIG_GLOBAL="$TMP/home/.gitconfig" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME"; : > "$GIT_CONFIG_GLOBAL"
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
unset TILLANDSIAS_ENSURE_HOOKS TILLANDSIAS_PLAN_BIN

# A PATH with no Rust toolchain: only the system dirs.
NOTC_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
no_cargo=1
PATH="$NOTC_PATH" command -v cargo >/dev/null 2>&1 && no_cargo=0

WANT="$(sed -n 's/^PREPUSH_MARKER="# \(tillandsias-pre-push-v[0-9][0-9]*\)"$/\1/p' "$SRC/scripts/install-hooks.sh")"
[ -n "$WANT" ] || { echo "FAIL: no PREPUSH_MARKER in install-hooks.sh" >&2; exit 1; }

# seed <name>: a bare remote holding a minimal tree (scripts/ copied from the
# working tree plus one code file), and a fresh clone of it at $TMP/<name>/wc.
seed() {
    local d="$TMP/$1"
    mkdir -p "$d/src"
    cp -R "$SRC/scripts" "$d/src/scripts"
    rm -f "$d/src/scripts/".mutant-* "$d/src/scripts/"*/.mutant-* 2>/dev/null
    mkdir -p "$d/src/crates/x/src"; echo "// code" > "$d/src/crates/x/src/lib.rs"
    git -C "$d/src" init -q -b linux-next
    git -C "$d/src" add -A && git -C "$d/src" commit -q -m seed
    # --no-local: a local clone HARDLINKS objects, and on macOS git intermittently
    # aborts it ("hardlink different from source") — measured once in three runs.
    # A scaffold that fails must say so, not surface as a subject failure.
    git clone -q --no-local --bare "$d/src" "$d/bare.git" \
        && git clone -q --no-local "$d/bare.git" "$d/wc" \
        || { echo "FAIL: scaffold $1 — could not clone the scratch repo" >&2; exit 1; }
    printf '%s' "$d/wc"
}
hooks_dir() { git -C "$1" rev-parse --path-format=absolute --git-path hooks; }
ensure() { # ensure <wc> [args...] -> OUT ERR RC
    local wc="$1"; shift
    OUT="$(cd "$wc" && PATH="$NOTC_PATH" bash scripts/ensure-hooks.sh "$@" 2>"$TMP/err")"; RC=$?
    ERR="$(cat "$TMP/err")"
}
sum() { cksum < "$1" 2>/dev/null; }

# ── 1. RED -> GREEN ─────────────────────────────────────────────────────────
wc="$(seed red)" || exit 1
n="$(ls "$(hooks_dir "$wc")" | grep -vc '\.sample$')"
echo "// change 1" >> "$wc/crates/x/src/lib.rs"; git -C "$wc" commit -q -am "code 1"
if [ "$n" = "0" ] && git -C "$wc" push -q origin linux-next >/dev/null 2>&1; then
    ok "arm 1 red: a fresh clone has 0 hooks and a code push is ACCEPTED"
else
    bad "arm 1 red: hooks=$n, or the hookless push was refused"
fi
ensure "$wc"
echo "// change 2" >> "$wc/crates/x/src/lib.rs"; git -C "$wc" commit -q --no-verify -am "code 2"
push_out="$(cd "$wc" && PATH="$NOTC_PATH" git push origin linux-next 2>&1)"; push_rc=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "installed:hooks:$WANT" ] \
   && grep -qF "# $WANT" "$(hooks_dir "$wc")/pre-push" && [ "$push_rc" -ne 0 ]; then
    ok "arm 1 green: installed with no cargo on PATH (no_cargo=$no_cargo); the same push is now REFUSED (rc=$push_rc)"
else
    bad "arm 1 green: rc=$RC out=[$OUT] push_rc=$push_rc"
fi
if [ "$no_cargo" -eq 1 ]; then
    if grep -qF "toolbox run --container tillandsias-builder cargo build --release -p tillandsias-plan" <<<"$push_out"; then
        ok "arm 1 remedy: the no-plan-binary refusal names the container route on a host with no cargo"
    else
        bad "arm 1 remedy: no container route in the refusal: $push_out"
    fi
else
    echo "note: arm 1 remedy not asserted — cargo is on the system PATH of this host"
fi

# ── 2. idempotent ───────────────────────────────────────────────────────────
before="$(sum "$(hooks_dir "$wc")/pre-push")"
ensure "$wc"
if [ "$RC" -eq 0 ] && [ "$OUT" = "ok:hooks:$WANT" ] && [ "$(sum "$(hooks_dir "$wc")/pre-push")" = "$before" ]; then
    ok "arm 2: second run is ok:hooks:$WANT and the hook is byte-identical"
else
    bad "arm 2: rc=$RC out=[$OUT]"
fi

# ── 3. an older marker of ours is upgraded ──────────────────────────────────
wc="$(seed upgrade)" || exit 1; h="$(hooks_dir "$wc")/pre-push"; mkdir -p "$(dirname "$h")"
printf '#!/usr/bin/env bash\n# tillandsias-pre-push-v7\nexit 0\n' > "$h"; chmod +x "$h"
ensure "$wc"
if [ "$RC" -eq 0 ] && [ "$OUT" = "upgraded:hooks:tillandsias-pre-push-v7->$WANT" ] && grep -qF "# $WANT" "$h"; then
    ok "arm 3: v7 upgraded to $WANT"
else
    bad "arm 3: rc=$RC out=[$OUT] err=[$ERR]"
fi

# ── 4. a foreign pre-push is refused and untouched ──────────────────────────
wc="$(seed foreign)" || exit 1; h="$(hooks_dir "$wc")/pre-push"; mkdir -p "$(dirname "$h")"
printf '#!/bin/sh\n# the operator'"'"'s own hook\nexit 0\n' > "$h"; chmod +x "$h"
before="$(sum "$h")"
ensure "$wc"
if [ "$RC" -eq 3 ] && [ "$OUT" = "refused:hooks:foreign-pre-push:$h" ] && [ "$(sum "$h")" = "$before" ] \
   && grep -q '  why: ' <<<"$ERR" && grep -q '  remedy: ' <<<"$ERR"; then
    ok "arm 4: a foreign pre-push is refused (exit 3, why/remedy) and left byte-identical"
else
    bad "arm 4: rc=$RC out=[$OUT] err=[$ERR]"
fi

# ── 5. NEGATIVE CONTROL: local core.hooksPath ───────────────────────────────
wc="$(seed shared)" || exit 1; shared="$TMP/shared/hooks"; mkdir -p "$shared"
git -C "$wc" config core.hooksPath "$shared"
ensure "$wc"
first_out="$OUT"; first_rc="$RC"
ensure "$wc"
if [ "$first_rc" -eq 0 ] && [ "$first_out" = "installed:hooks:$WANT" ] && [ -f "$shared/pre-push" ] \
   && [ ! -f "$wc/.git/hooks/pre-push" ] && [ "$RC" -eq 0 ] && [ "$OUT" = "ok:hooks:$WANT" ]; then
    ok "arm 5: a local hooksPath is honoured (installed there, not .git/hooks) and then reads ok — no false gap"
else
    bad "arm 5: first=[$first_out/$first_rc] second=[$OUT/$RC] shared=$(ls "$shared")"
fi

# ── 6. a global core.hooksPath is refused ───────────────────────────────────
wc="$(seed global)" || exit 1; gdir="$TMP/global-hooks"; mkdir -p "$gdir"
git config --global core.hooksPath "$gdir"
ensure "$wc"
git config --global --unset core.hooksPath
# (git canonicalises the dir: /var vs /private/var on macOS, so match the tail.)
if [ "$RC" -eq 3 ] && [[ "$OUT" == refused:hooks:global-hooks-path:*/global-hooks ]] && [ -z "$(ls "$gdir")" ]; then
    ok "arm 6: a global hooksPath is refused and nothing is written there"
else
    bad "arm 6: rc=$RC out=[$OUT] gdir=$(ls "$gdir")"
fi

# ── 7. --prelude ────────────────────────────────────────────────────────────
wc="$(seed prelude)" || exit 1; h="$(hooks_dir "$wc")/pre-push"
ensure "$wc" --prelude
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ] && [ ! -f "$h" ]; then
    ok "arm 7a: --prelude is silent and inert when origin is not the GitHub repo (fixtures stay hookless)"
else
    bad "arm 7a: rc=$RC out=[$OUT] err=[$ERR] hook=$([ -f "$h" ] && echo present)"
fi
OUT="$(cd "$wc" && PATH="$NOTC_PATH" TILLANDSIAS_ENSURE_HOOKS=1 bash scripts/ensure-hooks.sh --prelude 2>"$TMP/err")"; RC=$?; ERR="$(cat "$TMP/err")"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && grep -qF "installed:hooks:$WANT" <<<"$ERR" && [ -f "$h" ]; then
    ok "arm 7b: with TILLANDSIAS_ENSURE_HOOKS=1 the prelude installs, stdout EMPTY, verdict on stderr"
else
    bad "arm 7b: rc=$RC out=[$OUT] err=[$ERR]"
fi
OUT="$(cd "$wc" && PATH="$NOTC_PATH" TILLANDSIAS_ENSURE_HOOKS=1 bash scripts/ensure-hooks.sh --prelude 2>"$TMP/err")"; RC=$?; ERR="$(cat "$TMP/err")"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ]; then
    ok "arm 7c: the prelude is completely silent when the hook is already current"
else
    bad "arm 7c: rc=$RC out=[$OUT] err=[$ERR]"
fi
printf '#!/bin/sh\nexit 0\n' > "$h"
OUT="$(cd "$wc" && PATH="$NOTC_PATH" TILLANDSIAS_ENSURE_HOOKS=1 bash scripts/ensure-hooks.sh --prelude 2>"$TMP/err")"; RC=$?; ERR="$(cat "$TMP/err")"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && grep -qF "refused:hooks:foreign-pre-push:" <<<"$ERR"; then
    ok "arm 7d: a prelude refusal goes to stderr and still exits 0 (never fails the caller)"
else
    bad "arm 7d: rc=$RC out=[$OUT] err=[$ERR]"
fi
rm -f "$h"
OUT="$(cd "$wc" && PATH="$NOTC_PATH" TILLANDSIAS_ENSURE_HOOKS=0 bash scripts/ensure-hooks.sh --prelude 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ ! -f "$h" ]; then
    ok "arm 7e: TILLANDSIAS_ENSURE_HOOKS=0 disables the prelude"
else
    bad "arm 7e: rc=$RC out=[$OUT]"
fi

echo "test-ensure-hooks: $passes passed, $fails failed"
[ "$fails" -eq 0 ]
