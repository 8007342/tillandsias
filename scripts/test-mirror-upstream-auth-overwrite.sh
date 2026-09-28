#!/usr/bin/env bash
# @trace order:1461-8tyy, spec:git-mirror-service
#
# The mirror's published upstream-auth verdict is OVERWRITTEN by the next real
# upstream outcome, success included. It used to change only on the probe's
# schedule, so after the operator re-seeded an expired token the credential
# guard kept reading `denied` and a healthy worker idled (macuahuitl-forge,
# 2026-09-28). Drives the REAL images/git/relay-refs.sh and
# probe-upstream-auth.sh against a local bare upstream: no network, no Vault.
#
#   1 premise: `probe --record <mirror> denied permission` publishes denied
#   2 a successful relay push replaces it with authorized, exactly one ref
#   3 PRE-FIX CONTROL: trunk's relay-refs.sh, same setup -> denied stays
#   4 --record refuses an unknown state and publishes nothing
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/upstream-auth-overwrite.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
export HOME="$WORK/home"; mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$WORK/gitconfig"; : > "$GIT_CONFIG_GLOBAL"
pass=0; fail=0
ok()  { echo "ok:   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

PROBE="$WORK/probe-upstream-auth"
cp "$ROOT/images/git/probe-upstream-auth.sh" "$PROBE"; chmod +x "$PROBE"
verdicts() { git -C "$1" for-each-ref --format='%(refname)' refs/tillandsias/upstream-auth; }

# A mirror with origin = a local bare upstream, and one commit to relay.
setup() {
    local d="$1"
    git init -q --bare "$d/upstream"
    git init -q --bare "$d/mirror"
    git -C "$d/mirror" remote add origin "$d/upstream"
    git init -q "$d/client"
    git -C "$d/client" commit -q --allow-empty -m one
    git -C "$d/client" push -q "$d/mirror" HEAD:refs/heads/main
}
relay() { # relay <mirror> <relay-script>
    local new; new="$(git -C "$1" rev-parse refs/heads/main)"
    (cd "$1" && printf '%s %s refs/heads/main\n' "$new" "$new" \
        | AUTH_PROBE="$PROBE" SYNC_STATE=/nonexistent sh "$2" >/dev/null 2>&1)
}

# ── 1 + 2: the fix ───────────────────────────────────────────────────────────
A="$WORK/a"; mkdir -p "$A"; setup "$A"
"$PROBE" --record "$A/mirror" denied permission >/dev/null 2>&1
case "$(verdicts "$A/mirror")" in
    refs/tillandsias/upstream-auth/denied/permission/*) ok "1 premise: a recorded denied verdict is published" ;;
    *) bad "1 premise: no denied verdict: [$(verdicts "$A/mirror")]" ;;
esac
relay "$A/mirror" "$ROOT/images/git/relay-refs.sh"
pushed="$(git -C "$A/upstream" rev-parse -q --verify refs/heads/main 2>/dev/null || echo none)"
v="$(verdicts "$A/mirror")"
if [ "$pushed" != none ] && [ "$(grep -c . <<<"$v")" = 1 ] \
   && [[ "$v" == refs/tillandsias/upstream-auth/authorized/* ]]; then
    ok "2 a successful relay push overwrites denied with authorized (one ref)"
else
    bad "2 after a successful push: upstream=$pushed verdicts=[$v]"
fi

# ── 3: PRE-FIX CONTROL — trunk's relay leaves the stale denied ──────────────
if git -C "$ROOT" cat-file -e origin/linux-next:images/git/relay-refs.sh 2>/dev/null \
   && ! git -C "$ROOT" show origin/linux-next:images/git/relay-refs.sh | grep -q 'record_upstream_auth'; then
    B="$WORK/b"; mkdir -p "$B"; setup "$B"
    git -C "$ROOT" show origin/linux-next:images/git/relay-refs.sh > "$WORK/relay-prefix.sh"
    "$PROBE" --record "$B/mirror" denied permission >/dev/null 2>&1
    relay "$B/mirror" "$WORK/relay-prefix.sh"
    pushed="$(git -C "$B/upstream" rev-parse -q --verify refs/heads/main 2>/dev/null || echo none)"
    v="$(verdicts "$B/mirror")"
    if [ "$pushed" != none ] && [[ "$v" == refs/tillandsias/upstream-auth/denied/* ]]; then
        ok "3 control: the pre-fix relay pushed but left denied standing"
    else
        bad "3 control: pre-fix upstream=$pushed verdicts=[$v]"
    fi
else
    echo "skip: 3 control: trunk's relay already carries the fix (or no origin/linux-next)"
fi

# ── 4: --record refuses an unknown state ─────────────────────────────────────
C="$WORK/c"; mkdir -p "$C"; git init -q --bare "$C/mirror"
"$PROBE" --record "$C/mirror" bogus >/dev/null 2>&1; rc=$?
if [ "$rc" = 2 ] && [ -z "$(verdicts "$C/mirror")" ]; then
    ok "4 --record refuses an unknown state (rc=2) and publishes nothing"
else
    bad "4 --record bogus: rc=$rc verdicts=[$(verdicts "$C/mirror")]"
fi

echo "$([ "$fail" = 0 ] && echo ok || echo fail):mirror-upstream-auth-overwrite:${pass}/$((pass + fail))"
[ "$fail" = 0 ]
