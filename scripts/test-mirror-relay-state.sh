#!/usr/bin/env bash
# @trace order:1310-rec6, spec:git-mirror-service
#
# test-mirror-relay-state.sh — 1310-rec6 step 2: the mirror decides BROKEN in
# its own terms, by the layer that failed, with hysteresis, and never on a
# stale tracking ref.
#
# HERMETIC: a scratch bare "upstream" and a scratch bare "mirror" whose origin
# is that upstream, host git only. The relay is a stub doing a plain non-forced
# push, so the classification reads REAL git output. Backoff is zeroed.
#
# Arms:
#   1 STALE TRACKING  (negative control, the lenovinha linux-next measurement)
#                     a head ahead of a stale tracking ref, already on upstream:
#                     the retry succeeds, the state is ok, NOT broken
#   2 TRANSPORT       unreachable upstream: tick 1 degraded, tick 2 broken
#                     (hysteresis), and one ok tick after the fix restores ok
#   3 CREDENTIAL      upstream refuses with an authentication failure: classed
#                     credential even though git also prints "remote rejected"
#   4 REJECTION       upstream refuses ONE ref: never broken (state ok), and the
#                     same ref on 3 consecutive ticks publishes a stuck-ref
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUB="$ROOT/images/git/publish-relay-state.sh"
FAIL=0
ok()  { printf 'ok:   %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; FAIL=1; }
W="$(mktemp -d "${TMPDIR:-/tmp}/relay-state.XXXXXX")"; trap 'rm -rf "$W"' EXIT
export HOME="$W/home" GIT_CONFIG_NOSYSTEM=1 RELAY_STATE_BACKOFF="0 0 0"; mkdir -p "$HOME"
git config --global user.email f@f; git config --global user.name f; git config --global init.defaultBranch main

cat > "$W/relay" <<'EOF'
#!/bin/sh
# stub relay: read "<old> <new> <ref>" and push that ref, non-forced
read -r _o _n ref
exec git push origin "$ref:$ref"
EOF
chmod +x "$W/relay"; export RELAY_REF="$W/relay"

setup() {   # <name>: upstream U with one commit, mirror M cloned from it
    local d="$W/$1"; mkdir -p "$d"
    git init -q --bare "$d/U"; mkdir -p "$d/U/hooks"; git -C "$d/U" config core.hooksPath "$d/U/hooks"
    git init -q "$d/w"; git -C "$d/w" commit -q --allow-empty -m base; git -C "$d/w" push -q "$d/U" main
    git clone -q --bare "$d/U" "$d/M"
    git -C "$d/M" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
    git -C "$d/M" fetch -q origin
    printf '%s' "$d"
}
advance_mirror() {   # <d>: a new commit on the mirror's main (not on upstream)
    git -C "$1/w" commit -q --allow-empty -m "next-$RANDOM"; git -C "$1/w" push -q "$1/M" main
}
state() { git -C "$1/M" for-each-ref --format='%(refname)' refs/tillandsias/relay-state | sed 's#refs/tillandsias/relay-state/##; s#/[0-9]*$##'; }
stuck() { git -C "$1/M" for-each-ref --format='%(refname)' refs/tillandsias/relay-state-stuck | grep -c .; }
tick()  { sh "$PUB" "$1/M" >/dev/null 2>&1; }

# ── ARM 1 ────────────────────────────────────────────────────────────────
d="$(setup a1)"
git -C "$d/w" commit -q --allow-empty -m landed; git -C "$d/w" push -q "$d/U" main; git -C "$d/w" push -q "$d/M" main
# tracking still stale: main is "ahead" of refs/remotes/origin/main, yet upstream has it
[ "$(git -C "$d/M" rev-list --count refs/remotes/origin/main..refs/heads/main)" -gt 0 ] || bad "ARM1 setup: tracking was not stale"
tick "$d"; s1="$(state "$d")"
[ "$s1" = "ok/none/0" ] && ok "ARM1 negative control: a head ahead of a STALE tracking ref, already upstream, is ok ($s1), not broken" \
    || bad "ARM1 stale tracking read as '$s1'"

# ── ARM 2 ────────────────────────────────────────────────────────────────
d="$(setup a2)"; advance_mirror "$d"
git -C "$d/M" remote set-url origin "$W/nowhere.git"
tick "$d"; s1="$(state "$d")"; tick "$d"; s2="$(state "$d")"
git -C "$d/M" remote set-url origin "$d/U"; tick "$d"; s3="$(state "$d")"
[ "$s1" = "degraded/transport/1" ] && [ "$s2" = "broken/transport/1" ] && [ "$s3" = "ok/none/0" ] \
    && ok "ARM2 transport: degraded on tick 1, broken on tick 2 (hysteresis), ok after one good tick" \
    || bad "ARM2 ticks: '$s1' then '$s2' then '$s3'"

# ── ARM 3 ────────────────────────────────────────────────────────────────
d="$(setup a3)"; advance_mirror "$d"
printf '#!/bin/sh\necho "remote: Invalid username or password."\necho "fatal: Authentication failed for upstream"\nexit 1\n' > "$d/U/hooks/pre-receive"; chmod +x "$d/U/hooks/pre-receive"
tick "$d"; tick "$d"; s2="$(state "$d")"
[ "$s2" = "broken/credential/1" ] && ok "ARM3 an authentication refusal is classed credential (not rejection) and is broken on tick 2" \
    || bad "ARM3 credential refusal read as '$s2'"

# ── ARM 4 ────────────────────────────────────────────────────────────────
d="$(setup a4)"; advance_mirror "$d"
printf '#!/bin/sh\necho "refusing this ref by policy"\nexit 1\n' > "$d/U/hooks/pre-receive"; chmod +x "$d/U/hooks/pre-receive"
tick "$d"; a="$(state "$d"):$(stuck "$d")"; tick "$d"; b="$(state "$d"):$(stuck "$d")"; tick "$d"; c="$(state "$d"):$(stuck "$d")"
[ "$a" = "ok/none/0:0" ] && [ "$b" = "ok/none/0:0" ] && [ "$c" = "ok/none/0:1" ] \
    && ok "ARM4 a rejected ref never makes the mirror broken; on the 3rd consecutive tick it publishes one stuck-ref" \
    || bad "ARM4 ticks: '$a' '$b' '$c'"

[ "$FAIL" -eq 0 ] && { echo "PASS: mirror-relay-state (1310-rec6)"; exit 0; }
echo "FAILED: mirror-relay-state (1310-rec6)"; exit 1
