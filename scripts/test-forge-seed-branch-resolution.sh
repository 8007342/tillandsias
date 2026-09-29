#!/usr/bin/env bash
# @trace order:1362-u8ww, spec:git-mirror-service
#
# test-forge-seed-branch-resolution.sh — a forge clone never takes its branch
# from the mirror's HEAD. Measured on pirria 2026-09-22: a cloud launch cloned a
# mirror whose HEAD named work/1325-ygq5 (that host's own work branch) and the
# "remote" project opened there. The clone transports now RESOLVE an unset seed
# (the discipline seed's integration branch, else its default_branch, else
# main/master) and print which they chose.
#
# HERMETIC: scratch bare "mirrors" and clones; the functions under test are
# extracted verbatim from images/default/lib-common.sh (the idiom
# test-forge-clone-wait-is-bounded.sh uses), trace_lifecycle is stubbed.
#
#   1  THE CLOSURE: two mirrors whose HEADs name DIFFERENT branches (a stray
#      work branch, and main) seed the SAME named branch — the discipline
#      seed's integration.forge — and the forge prints it with its reason
#   2  no discipline seed: the remote default by convention (main), named
#   3  an explicit TILLANDSIAS_FORGE_SEED_BRANCH still wins (unchanged)
#   4  nothing resolvable: a LOUD warning naming the mirror's HEAD, the clone
#      stays where it is, and the status is 0 (never hard-fails a launch)
#   5  the HOST-MOUNT call (no `resolve`) is still a no-op: the user's own tree
#      is never switched
#   6  PRE-FIX CONTROL: trunk's checkout_forge_seed_branch leaves a clone of
#      the stray-HEAD mirror on the stray work branch
#
# Pre-fix: FAILS at arm 1 (the clone stays on the mirror HEAD's work branch).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/images/default/lib-common.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/forge-seed-resolution.XXXXXX")"
trap 'rm -rf "$W"' EXIT
pass=0
fail=0
ok() { echo "ok:   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail + 1)); }

printf '[user]\n\tname = t\n\temail = t@example.invalid\n[init]\n\tdefaultBranch = main\n' >"$W/gitconfig"
export GIT_CONFIG_GLOBAL="$W/gitconfig" GIT_CONFIG_NOSYSTEM=1
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL TILLANDSIAS_FORGE_SEED_BRANCH

FUNCS="$(awk '/^resolve_forge_seed_branch\(\) \{/,/^\}/' "$LIB"; awk '/^checkout_forge_seed_branch\(\) \{/,/^\}/' "$LIB")"
case "$FUNCS" in *resolve_forge_seed_branch*checkout_forge_seed_branch*) ;; *)
    bad "arm 1: resolve_forge_seed_branch is not in $LIB"; echo "FAIL: forge-seed-branch-resolution 0/1 (1362-u8ww)"; exit 1 ;; esac

# mirror <name> <head-branch> <with-seed:yes|no> [branches...]
mirror() {
    local name="$1" head="$2" seed="$3" src="$W/src-$1"
    shift 3
    git init -q -b main "$src"
    if [ "$seed" = yes ]; then
        mkdir -p "$src/.tillandsias"
        printf 'version: 1\nlevel: 2\ndefault_branch: main\nintegration:\n  linux: linux-next\n  forge: linux-next\n  macos: osx-next\n' >"$src/.tillandsias/branch-discipline.yaml"
    fi
    echo base >"$src/README"
    git -C "$src" add -A && git -C "$src" commit -q -m base
    local b
    for b in "$@"; do git -C "$src" branch -q "$b"; done
    git clone -q --bare "$src" "$W/$name.git"
    git -C "$W/$name.git" symbolic-ref HEAD "refs/heads/$head"
}
# forge <mirror> [resolve|""] [env...] -> "<branch after>|<output>"
forge() {
    local m="$1" arg="$2" c="$W/clone-$1-$RANDOM"
    shift 2
    git clone -q "$W/$m.git" "$c"
    out="$(cd "$c" && env "$@" bash -c 'trace_lifecycle() { :; }; eval "$1"; checkout_forge_seed_branch $2; echo "rc=$?"' _ "$FUNCS" "$arg" 2>&1)"
    printf '%s|%s' "$(git -C "$c" symbolic-ref --short -q HEAD)" "$out"
}

# ── 1 ───────────────────────────────────────────────────────────────────────
mirror stray work/1325-ygq5 yes linux-next osx-next work/1325-ygq5
mirror other main yes linux-next osx-next work/9999-abcd
r1="$(forge stray resolve)"
r2="$(forge other resolve)"
if [ "${r1%%|*}" = linux-next ] && [ "${r2%%|*}" = linux-next ] &&
    grep -qF "[forge] Seed branch: 'linux-next' — the discipline seed's integration.forge" <<<"$r1"; then
    ok "arm 1: mirrors with HEAD=work/1325-ygq5 and HEAD=main both seed linux-next, and say why"
else
    bad "arm 1: stray -> [${r1%%|*}] other -> [${r2%%|*}] out=[${r1#*|}]"
fi

# ── 2 ───────────────────────────────────────────────────────────────────────
mirror noseed work/1325-ygq5 no linux-next work/1325-ygq5
r="$(forge noseed resolve)"
if [ "${r%%|*}" = main ] && grep -qF "the remote default by convention (origin/main exists" <<<"$r"; then
    ok "arm 2: with no discipline seed the remote default by convention (main) is chosen and named"
else
    bad "arm 2: -> [${r%%|*}] [${r#*|}]"
fi

# ── 3 ───────────────────────────────────────────────────────────────────────
r="$(forge stray resolve TILLANDSIAS_FORGE_SEED_BRANCH=osx-next)"
[ "${r%%|*}" = osx-next ] && ok "arm 3: an explicit TILLANDSIAS_FORGE_SEED_BRANCH still wins" || bad "arm 3: -> [${r%%|*}] [${r#*|}]"

# ── 4 ───────────────────────────────────────────────────────────────────────
src="$W/src-bare"
git init -q -b work/x "$src"; echo x >"$src/f"; git -C "$src" add -A; git -C "$src" commit -q -m x
git clone -q --bare "$src" "$W/nothing.git"
r="$(forge nothing resolve)"
if [ "${r%%|*}" = work/x ] && grep -q "WARNING: no seed branch could be resolved" <<<"$r" &&
    grep -q "MIRROR'S HEAD" <<<"$r" && grep -q "rc=0" <<<"$r"; then
    ok "arm 4: nothing resolvable -> a loud warning naming the mirror's HEAD, the clone stays, rc 0"
else
    bad "arm 4: -> [${r%%|*}] [${r#*|}]"
fi

# ── 5 ───────────────────────────────────────────────────────────────────────
r="$(forge stray "")"
[ "${r%%|*}" = work/1325-ygq5 ] && ! grep -q "Seed branch" <<<"$r" &&
    ok "arm 5: the host-mount call (no resolve) does not switch the tree" || bad "arm 5: -> [${r%%|*}] [${r#*|}]"

# ── 6 ───────────────────────────────────────────────────────────────────────
OLD="$(git -C "$ROOT" show origin/linux-next:images/default/lib-common.sh 2>/dev/null | awk '/^checkout_forge_seed_branch\(\) \{/,/^\}/')"
case "$OLD" in *resolve_forge_seed_branch*) OLD="" ;; esac
if [ -n "$OLD" ]; then
    c="$W/clone-prefix"
    git clone -q "$W/stray.git" "$c"
    (cd "$c" && bash -c 'trace_lifecycle() { :; }; eval "$1"; checkout_forge_seed_branch resolve' _ "$OLD" >/dev/null 2>&1)
    [ "$(git -C "$c" symbolic-ref --short -q HEAD)" = work/1325-ygq5 ] &&
        ok "arm 6: PRE-FIX CONTROL: trunk's function leaves the clone on the mirror HEAD's work branch" ||
        bad "arm 6: the pre-fix function did not reproduce the defect"
else
    echo "skip: arm 6: origin/linux-next already carries the resolver (pre-fix control needs a pre-fix trunk)"
fi

total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: forge-seed-branch-resolution $pass/$total (1362-u8ww)"
    exit 0
fi
echo "FAIL: forge-seed-branch-resolution $pass/$total (1362-u8ww)"
exit 1
