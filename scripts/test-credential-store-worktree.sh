#!/usr/bin/env bash
# @trace order:1409-65d5
#
# test-credential-store-worktree.sh — the repo-local credential store must
# resolve from a LINKED WORKTREE, not only from the main checkout.
#
# THE DEFECT (1409-65d5). check-credential-channel.sh's remedy configured the
# helper as `store --file=$(git rev-parse --git-dir)/.gh-credentials`. In the
# main checkout --git-dir answers the RELATIVE `.git`, so the helper became
# `store --file=.git/.gh-credentials`; in a linked worktree `.git` is a FILE and
# `git credential fill` fails:
#     fatal: unable to open .git/.gh-credentials: Not a directory
# (measured 2026-09-26, git 2.54). The checker's own probe used --git-dir too,
# which in a worktree is .git/worktrees/<name>, a store nobody seeded.
#
# HERMETIC, and it must stay so — this is the credential path:
#   - scratch repos only (git init + git worktree add under a mktemp dir);
#   - a FAKE token this file writes; the real store, keychain, gh and global
#     git config are never read (HOME is scratch, GIT_CONFIG_GLOBAL=/dev/null,
#     GIT_CONFIG_NOSYSTEM=1, GH_TOKEN/GITHUB_TOKEN unset, a failing stub `gh`
#     first on PATH);
#   - `git credential fill` against the scratch store; never a push.
#
# Grammar: `ok:credential-store-worktree:<n> arms` (rc 0) or
#          `FAIL:credential-store-worktree:<n> failed` (rc 1).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKER="$ROOT/scripts/check-credential-channel.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/cred-store-worktree.XXXXXX")"
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/home" "$T/bin"
printf '#!/bin/sh\nexit 1\n' > "$T/bin/gh"
chmod +x "$T/bin/gh"
export HOME="$T/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/usr/bin/false SSH_ASKPASS=/usr/bin/false
export PATH="$T/bin:$PATH"
unset GH_TOKEN GITHUB_TOKEN

FAKE="FAKE-TOKEN-1409-$$"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

# fill -> "found" when the store answered with the fake token, else git's error.
fill() {
    local out
    out="$(printf 'protocol=https\nhost=github.com\n\n' | git credential fill 2>&1)"
    case "$out" in
        (*"password=$FAKE"*) echo found ;;
        (*) printf '%s\n' "$out" | grep -m1 -E 'fatal|error' || echo none ;;
    esac
}

# repo <name> <helper-expression>: a scratch main checkout whose helper is
# configured the way an operator following the remedy would configure it.
repo() {
    git init -q "$T/$1" && git -C "$T/$1" commit -q --allow-empty -m init
    (
        cd "$T/$1" || exit 1
        git config --local --replace-all credential.helper ''
        git config --local --add credential.helper "store --file=$(eval "$2")/.gh-credentials"
        printf 'protocol=https\nhost=github.com\nusername=fake\npassword=%s\n\n' "$FAKE" \
            | git credential-store --file "$(eval "$2")/.gh-credentials" store
    )
    git -C "$T/$1" worktree add -q "$T/$1-wt1" -b wt1
    git -C "$T/$1" worktree add -q "$T/$1-wt2" -b wt2
}

# 1. The fix's form IS what the checker prints (so the arms below test the
#    remedy an operator actually receives, not a paraphrase of it).
NEW='git rev-parse --path-format=absolute --git-common-dir'
if grep -qF "store --file=\\\$($NEW)/.gh-credentials" "$CHECKER" \
   && grep -qF "credential-store --file \"\$($NEW)/.gh-credentials\" store" "$CHECKER"; then
    ok "the checker's printed remedies use the absolute common dir"
else
    bad "the checker's printed remedies do not use '$NEW'"
fi
if grep -qE 'rev-parse --git-dir' "$CHECKER"; then
    bad "check-credential-channel.sh still resolves a path with --git-dir"
else
    ok "no --git-dir left in check-credential-channel.sh"
fi

# 2. NEGATIVE CONTROL: the pre-1409 remedy, measured failing from a worktree.
repo old 'git rev-parse --git-dir'
r="$(cd "$T/old" && fill)"
[ "$r" = found ] && ok "pre-fix form: the main checkout resolves (it only ever worked here)" \
                 || bad "pre-fix form: even the main checkout failed: $r"
r="$(cd "$T/old-wt1" && fill)"
case "$r" in
    (*"Not a directory"*) ok "pre-fix form: a linked worktree FAILS with 'Not a directory' (the defect, reproduced)" ;;
    (*) bad "pre-fix form: expected 'Not a directory' from the worktree, got: $r" ;;
esac

# 3. The fix: every checkout resolves the ONE shared store.
repo new "$NEW"
for d in new new-wt1 new-wt2; do
    r="$(cd "$T/$d" && fill)"
    [ "$r" = found ] && ok "fixed form: $d resolves the shared store" \
                     || bad "fixed form: $d did not resolve: $r"
done

# 4. The checker's own probe sees the store FROM A WORKTREE (it looked in
#    .git/worktrees/<name> before).
v="$(cd "$T/new-wt1" && bash "$CHECKER" 2>/dev/null)"
[ "$v" = "unverified:gh-credentials-store" ] \
    && ok "checker probe from a worktree finds the store ($v)" \
    || bad "checker probe from a worktree: expected unverified:gh-credentials-store, got '$v'"

# 5. Migration: a host still carrying the relative helper is NAMED, and the
#    printed one-liner repairs it without re-seeding.
e="$(cd "$T/old" && bash "$CHECKER" 2>&1 >/dev/null)"
case "$e" in
    (*"note:credential-helper-relative-store:store --file=.git/.gh-credentials"*)
        ok "a relative helper is named (note:credential-helper-relative-store)" ;;
    (*) bad "a relative helper was not named on stderr" ;;
esac
mig="$(printf '%s\n' "$e" | sed -n 's/^    \(git config --local --replace-all credential.helper .*\)$/\1/p')"
if [ -n "$mig" ] && (cd "$T/old" && eval "$mig"); then
    r="$(cd "$T/old-wt1" && fill)"
    [ "$r" = found ] && ok "the printed migration makes the worktree resolve, credential kept" \
                     || bad "after the printed migration the worktree still fails: $r"
    e="$(cd "$T/old" && bash "$CHECKER" 2>&1 >/dev/null)"
    case "$e" in
        (*note:credential-helper-relative-store*) bad "the note persists after migrating" ;;
        (*) ok "after migrating, the note is gone" ;;
    esac
else
    bad "no runnable migration line was printed"
fi

if [ "$fail" -gt 0 ]; then
    echo "FAIL:credential-store-worktree:$fail failed"
    exit 1
fi
echo "ok:credential-store-worktree:$pass arms"
exit 0
