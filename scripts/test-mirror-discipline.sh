#!/usr/bin/env bash
# @trace spec:git-mirror-service, spec:branch-discipline
# @trace order:1443-uit6
#
# test-mirror-discipline.sh — the enclave mirror enforces the project's seeded
# branch discipline (.tillandsias/branch-discipline.yaml) at pre-receive.
#
# HERMETIC. A scratch bare repository gets images/git/pre-receive-hook.sh and a
# stub relay that records whether it ran. Nothing touches this checkout, a real
# mirror, or GitHub. Every arm pushes with --no-verify, the invocation a client
# hook cannot stop.
#
# Arms:
#   1 ENFORCED     level-2 seed, default_branch enforced: a push to main is
#                  REJECTED before the relay runs, with the seed's message
#   2 FLOOR        (negative control) NO seed: a push to main is accepted and
#                  relayed with no discipline warning (1363-xp2v ruling)
#   3 WARN GRAMMAR ref_grammar warn: feature-x is accepted WITH a warning;
#                  work/1443-uit6 is accepted WITHOUT one
#   4 ENF GRAMMAR  ref_grammar enforced: feature-x is REJECTED; work/ and
#                  salvage/ refs are accepted
#   5 RELAY        (negative control) a fast-forward to the integration branch
#                  still relays exactly as before
#   6 UNREADABLE   a seed that is not YAML applies nothing and says so
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/images/git/pre-receive-hook.sh"
[ -r "$HOOK" ] || { echo "blocked:mirror-discipline:no-hook"; exit 2; }
command -v ruby >/dev/null 2>&1 || { echo "skip:mirror-discipline:no-ruby (the mirror image ships ruby)"; exit 0; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/mirror-discipline.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
FAIL=0
ok()  { printf 'ok:   %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; FAIL=1; }

seed() {   # <default_branch enforcement> <ref_grammar enforcement>
    cat <<EOF
version: 1
level: 2
enforcement:
  default_branch: $1
  ref_grammar: $2
default_branch: main
integration:
  linux: linux-next
  forge: linux-next
work_ref: "work/[0-9]{3,4}-[a-z0-9]{4}"
salvage_ref: "salvage/<host>/<yyyymmdd>-<slug>"
messages:
  default_branch_denied: "push to {default} denied: this project uses branch {integration} for integration and {work_ref} for work; switch to the corresponding branch and rebase to remote"
EOF
}

# new_mirror <name> <seed text or empty>: a bare mirror whose main and
# linux-next carry the seed; prints the client work dir.
new_mirror() {
    local d="$tmp/$1" text="$2"
    git init -q --bare -b main "$d/mirror.git"
    mkdir -p "$d/mirror.git/hooks"
    cp "$HOOK" "$d/mirror.git/hooks/pre-receive"; chmod +x "$d/mirror.git/hooks/pre-receive"
    printf '#!/bin/sh\ncat >/dev/null\n: > "%s/relayed"\nexit 0\n' "$d" > "$d/mirror.git/hooks/tillandsias-relay-refs"
    chmod +x "$d/mirror.git/hooks/tillandsias-relay-refs"
    mkdir -p "$d/nohooks"
    git -C "$d/mirror.git" config core.hooksPath "$d/nohooks"
    git init -q -b main "$d/work"
    git -C "$d/work" config user.email f@f; git -C "$d/work" config user.name f
    git -C "$d/work" remote add origin "$d/mirror.git"
    echo base > "$d/work/base"
    if [ -n "$text" ]; then mkdir -p "$d/work/.tillandsias"; printf '%s\n' "$text" > "$d/work/.tillandsias/branch-discipline.yaml"; fi
    git -C "$d/work" add -A; git -C "$d/work" commit -qm base
    # Populate the mirror WITHOUT the hook, as an existing mirror already is,
    # then install it: only the arm's own push is under test.
    git -C "$d/work" push -q --no-verify origin main main:linux-next
    git -C "$d/mirror.git" config core.hooksPath "$d/mirror.git/hooks"
    rm -f "$d/relayed"
    printf '%s' "$d"
}
push() {   # <dir> <refspec>; sets out and rc
    rm -f "$1/relayed"
    out="$(git -C "$1/work" push --no-verify origin "$2" 2>&1)"; rc=$?
}
commit() { echo "$2" > "$1/work/$2"; git -C "$1/work" add -A; git -C "$1/work" commit -qm "$2"; }

# First population bypasses the hook: install it only after seeding.
new_mirror_seeded() {
    local d
    d="$(new_mirror "$@" 2>/dev/null)"
    printf '%s' "$d"
}

# ── ARM 1 ────────────────────────────────────────────────────────────────
d="$(new_mirror_seeded a1 "$(seed enforced warn)")"
commit "$d" c1; push "$d" main
if [ "$rc" -ne 0 ] && [ ! -e "$d/relayed" ] \
   && grep -q 'push to main denied: this project uses branch linux-next for integration and work/<order> for work' <<<"$out"; then
    ok "ARM1 enforced default branch: push to main rejected before the relay, with the seed's message"
else bad "ARM1 rc=$rc relayed=$([ -e "$d/relayed" ] && echo yes || echo no) out='$(tr '\n' '|' <<<"$out")'"; fi

# ── ARM 2 ────────────────────────────────────────────────────────────────
d="$(new_mirror_seeded a2 "")"
commit "$d" c2; push "$d" main
if [ "$rc" -eq 0 ] && [ -e "$d/relayed" ] && ! grep -qE 'branch-discipline|denied|branch grammar|WARNING' <<<"$out"; then
    ok "ARM2 floor: with no seed a push to main is accepted and relayed, silently"
else bad "ARM2 rc=$rc out='$(tr '\n' '|' <<<"$out")'"; fi

# ── ARM 3 ────────────────────────────────────────────────────────────────
d="$(new_mirror_seeded a3 "$(seed enforced warn)")"
commit "$d" c3; push "$d" HEAD:refs/heads/feature-x
out_fx="$out"; rc_fx=$rc
push "$d" HEAD:refs/heads/work/1443-uit6
if [ "$rc_fx" -eq 0 ] && grep -q "outside this project's branch grammar" <<<"$out_fx" \
   && [ "$rc" -eq 0 ] && ! grep -q 'WARNING' <<<"$out"; then
    ok "ARM3 grammar warn: feature-x accepted with a warning, work/1443-uit6 accepted without one"
else bad "ARM3 feature-x rc=$rc_fx warned=$(grep -c WARNING <<<"$out_fx"); work rc=$rc out='$(tr '\n' '|' <<<"$out")'"; fi

# ── ARM 4 ────────────────────────────────────────────────────────────────
d="$(new_mirror_seeded a4 "$(seed enforced enforced)")"
commit "$d" c4; push "$d" HEAD:refs/heads/feature-x
rc_fx=$rc; out_fx="$out"
push "$d" HEAD:refs/heads/work/1443-uit6; rc_w=$rc
push "$d" HEAD:refs/heads/salvage/lenovinha/20260928-x; rc_s=$rc
if [ "$rc_fx" -ne 0 ] && grep -q 'blocked:branch-discipline:ref-grammar:feature-x' <<<"$out_fx" \
   && [ "$rc_w" -eq 0 ] && [ "$rc_s" -eq 0 ]; then
    ok "ARM4 grammar enforced: feature-x rejected; work/ and salvage/ refs accepted"
else bad "ARM4 feature-x rc=$rc_fx work rc=$rc_w salvage rc=$rc_s"; fi

# ── ARM 5 ────────────────────────────────────────────────────────────────
d="$(new_mirror_seeded a5 "$(seed enforced enforced)")"
commit "$d" c5; push "$d" HEAD:refs/heads/linux-next
if [ "$rc" -eq 0 ] && [ -e "$d/relayed" ]; then
    ok "ARM5 a fast-forward to the integration branch relays as before"
else bad "ARM5 rc=$rc out='$(tr '\n' '|' <<<"$out")'"; fi

# ── ARM 6 ────────────────────────────────────────────────────────────────
d="$(new_mirror_seeded a6 "level: [unterminated")"
commit "$d" c6; push "$d" main
if [ "$rc" -eq 0 ] && grep -q 'present but unreadable' <<<"$out"; then
    ok "ARM6 an unparseable seed is reported and applies nothing"
else bad "ARM6 rc=$rc out='$(tr '\n' '|' <<<"$out")'"; fi

[ "$FAIL" -eq 0 ] && { echo "PASS: mirror-discipline (1443-uit6)"; exit 0; }
echo "FAILED: mirror-discipline (1443-uit6)"; exit 1
