#!/usr/bin/env bash
# test-pre-push-honours-a-live-freeze.sh — 1176-9vqn: a release freeze is a
# marker on origin that the pre-push hook consults for CODE pushes to the
# branch the marker names, and plan-only pushes stay admitted.
#
# Hermetic: a bare remote plus a working copy under target/plan-scratch, with
# the REAL hook installed as .git/hooks/pre-push so each arm exercises the path
# git actually drives.
#
# WHY EACH ARM MINTS A GATE STAMP FIRST (with GATE_STAMP_REQUIRE_TOKEN=0, the
# sanctioned off-switch for the guard that stops a RED gate from stamping). The freeze check sits AFTER the
# gate-stamp dispatch, which is where it belongs: a code push with no valid
# stamp is already refused for the stamp, so the freeze check exists to hold
# pushes that would otherwise be ADMITTED. A scratch repo has never run
# ./build.sh --check, so without `gate-stamp.sh write` every code arm would
# refuse for the stamp and the freeze would never be reached — the arm would
# pass while testing nothing.
#
# Arms:
#   1. round-trip of scripts/release-freeze.sh: status/set/set-again/clear/clear-again.
#   2. a CODE push to the frozen branch is REFUSED and the refusal NAMES the
#      marker ref and the branch; MUTANT (content-built) proves teeth.
#   3. NEGATIVE CONTROL: a plan-only push under the same live marker is ADMITTED,
#      both with a fresh stamp (the exempt-path logic) and with none (the
#      plan-only lane, which exits before the freeze check).
#   4. NEGATIVE CONTROL: a code push to a branch the marker does not name is ADMITTED.
#   5. the fetch-failure trade: an unreachable remote WARNS and ADMITS, naming
#      the check, rather than blocking every offline push.
#   6. usage refusals from the freeze tool, and a branch name it will not accept.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/hooks/pre-push-local-gate.sh"
FREEZE="$ROOT/scripts/release-freeze.sh"
pass=0; fail=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
for f in "$GUARD" "$FREEZE" "$ROOT/scripts/gate-stamp.sh"; do
    [ -f "$f" ] || { echo "FAIL: missing $f"; echo "FAIL: pre-push-honours-a-live-freeze 0/1 (1176-9vqn)"; exit 1; }
done

_tmpbase="$ROOT/target/plan-scratch"; mkdir -p "$_tmpbase" 2>/dev/null || _tmpbase="${TMPDIR:-/tmp}"
W="$(mktemp -d "$_tmpbase/live-freeze.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM
export GIT_TERMINAL_PROMPT=0
G() { git -c user.email=t@t -c user.name=t "$@"; }

git init -q --bare "$W/bare.git"
git init -q -b linux-next "$W/wc"
cd "$W/wc" || exit 2
git remote add origin "$W/bare.git"
git config core.hooksPath .git/hooks
git config core.autocrlf false
mkdir -p scripts/hooks plan/index.d crates/demo
cp "$GUARD" scripts/hooks/pre-push-local-gate.sh
cp "$FREEZE" scripts/release-freeze.sh
for f in gate-stamp.sh plan-binary-probe.sh common.sh; do cp "$ROOT/scripts/$f" "scripts/$f" 2>/dev/null || true; done
chmod +x scripts/*.sh scripts/hooks/*.sh 2>/dev/null || true
printf 'packets: []\n' > plan/index.yaml
printf 'fn main() {}\n' > crates/demo/main.rs
printf 'base\n' > README.md
G add -A >/dev/null; G commit -q -m base
git push -q -u origin linux-next
git push -q origin linux-next:windows-next
printf '#!/bin/sh\nexec bash scripts/hooks/pre-push-local-gate.sh "$@"\n' > .git/hooks/pre-push
chmod +x .git/hooks/pre-push

freeze() { bash scripts/release-freeze.sh "$@"; }
stamp()  { GATE_STAMP_REQUIRE_TOKEN=0 bash scripts/gate-stamp.sh write >/dev/null 2>&1; }   # the token guard exists so a RED gate cannot stamp; a fixture minting a stamp is its sanctioned off-switch
tip()    { git ls-remote "$W/bare.git" "refs/heads/$1" | cut -f1; }

# ── ARM 1: the freeze tool's round-trip ────────────────────────────────────
out="$(freeze status linux-next 2>/dev/null | tail -1)"
[ "$out" = "ok:freeze-none:linux-next" ] && ok "ARM 1: status on an unfrozen branch reads ok:freeze-none" || bad "ARM 1a: '$out'"
out="$(freeze set linux-next "the v0.0.0 cut" 2>/dev/null | tail -1)"
case "$out" in
    ok:freeze-set:refs/tillandsias/freeze/linux-next/*/*) ok "ARM 1: set mints refs/tillandsias/freeze/<branch>/<host>/<epoch> on the remote" ;;
    *) bad "ARM 1b: '$out'" ;;
esac
MARKER="${out#ok:freeze-set:}"
out="$(freeze status linux-next 2>/dev/null | tail -1)"
case "$out" in
    frozen:linux-next:by=*:since=*:age=*s) ok "ARM 1: status reports frozen with who and how long ('${out:0:44}…')" ;;
    *) bad "ARM 1c: '$out'" ;;
esac
out="$(freeze set linux-next 2>/dev/null | tail -1)"
case "$out" in ok:freeze-already:*) ok "ARM 1: setting a live freeze again is ok:freeze-already, not a second marker" ;; *) bad "ARM 1d: '$out'" ;; esac
[ "$(git ls-remote "$W/bare.git" 'refs/tillandsias/freeze/*' | wc -l | tr -d ' ')" = "1" ] \
    && ok "ARM 1: exactly one marker exists on the remote" || bad "ARM 1e: marker count wrong"

# ── ARM 2: a CODE push to the frozen branch is REFUSED ─────────────────────
printf 'fn main() { /* code */ }\n' > crates/demo/main.rs
G add -A >/dev/null; G commit -q -m "feat: code under a freeze"
stamp
[ "$(bash scripts/gate-stamp.sh verify 2>/dev/null)" = "ok:gate-fresh" ] \
    && ok "ARM 2 PRECONDITION: the scratch holds a fresh full-scope stamp, so the push reaches the freeze check rather than refusing for the stamp" \
    || bad "ARM 2 PRECONDITION: no fresh stamp — every code arm below would pass while testing nothing"
before="$(tip linux-next)"
rc=0; out="$(G push origin linux-next 2>&1)" || rc=$?
if [ "$rc" -ne 0 ] && [ "$(tip linux-next)" = "$before" ]; then
    named_marker=0; named_branch=0
    printf '%s\n' "$out" | grep -qF "$MARKER" && named_marker=1
    printf '%s\n' "$out" | grep -qE "'linux-next' is FROZEN" && named_branch=1
    if [ "$named_marker" -eq 1 ] && [ "$named_branch" -eq 1 ]; then
        ok "ARM 2: the code push is refused, the branch does not move, and the refusal NAMES the marker and the branch"
    else
        bad "ARM 2: refused but under-explained (marker named=$named_marker branch named=$named_branch)"
    fi
else
    bad "ARM 2: rc=$rc, tip moved=$([ "$(tip linux-next)" = "$before" ] && echo no || echo yes)"
fi
# MUTANT, built from CONTENT: drop the call site and the same push must be admitted.
sed '/^enforce_release_freeze "\$_freeze_remote"$/d' scripts/hooks/pre-push-local-gate.sh > "$W/mutant.sh"
if cmp -s "$W/mutant.sh" scripts/hooks/pre-push-local-gate.sh; then
    bad "ARM 2 MUTANT SETUP: the strip is a no-op — the call site no longer matches"
else
    cp scripts/hooks/pre-push-local-gate.sh "$W/hook.swap"
    cp "$W/mutant.sh" scripts/hooks/pre-push-local-gate.sh
    stamp
    rc=0; G push -q origin linux-next >/dev/null 2>&1 || rc=$?
    cp "$W/hook.swap" scripts/hooks/pre-push-local-gate.sh
    if [ "$rc" -eq 0 ] && [ "$(tip linux-next)" != "$before" ]; then
        ok "ARM 2 MUTANT: without the call the identical push lands under the live freeze — the check has teeth"
        G push -q origin "+$before:refs/heads/linux-next" >/dev/null 2>&1   # restore for the arms below
    else
        bad "ARM 2 MUTANT: rc=$rc — the mutant did not take, so ARM 2 proves nothing"
    fi
fi

# ── ARM 3: NEGATIVE CONTROL — plan-only pushes are admitted, both paths ────
G reset -q --hard origin/linux-next
printf 'packets: []\n' > plan/index.d/20200101t000000z-fixture.yaml
G add -A >/dev/null; G commit -q -m "plan(fixture): a ledger record during the freeze"
stamp
before="$(tip linux-next)"
rc=0; out="$(G push origin linux-next 2>&1)" || rc=$?
if [ "$rc" -eq 0 ] && [ "$(tip linux-next)" != "$before" ]; then
    ok "ARM 3 (negative control): a plan-only push WITH a fresh stamp is admitted under the live freeze — the exempt-path logic"
else
    bad "ARM 3a: rc=$rc"; printf '%s\n' "$out" | grep -m2 -E 'FROZEN|refused' | sed 's/^/      /'
fi
printf 'packets: []\n' > plan/index.d/20200101t000001z-fixture.yaml
G add -A >/dev/null; G commit -q -m "plan(fixture): a second ledger record, no stamp"
rm -f "$(git rev-parse --absolute-git-dir)/tillandsias-gate-stamp"
before="$(tip linux-next)"
rc=0; out="$(G push origin linux-next 2>&1)" || rc=$?
if [ "$rc" -eq 0 ] && [ "$(tip linux-next)" != "$before" ]; then
    ok "ARM 3 (negative control): a plan-only push with NO stamp is admitted under the live freeze — the lane exits before the freeze check"
else
    bad "ARM 3b: rc=$rc"; printf '%s\n' "$out" | grep -m2 -E 'FROZEN|refused' | sed 's/^/      /'
fi

# ── ARM 4: NEGATIVE CONTROL — a branch the marker does not name ────────────
G checkout -q -B windows-next origin/windows-next
printf 'fn main() { /* platform code */ }\n' > crates/demo/main.rs
G add -A >/dev/null; G commit -q -m "feat: code on a branch no marker names"
stamp
before="$(tip windows-next)"
rc=0; out="$(G push origin windows-next 2>&1)" || rc=$?
if [ "$rc" -eq 0 ] && [ "$(tip windows-next)" != "$before" ]; then
    ok "ARM 4 (negative control): a code push to a branch the marker does not name is admitted"
else
    bad "ARM 4: rc=$rc"; printf '%s\n' "$out" | grep -m2 -E 'FROZEN|refused' | sed 's/^/      /'
fi

# ── ARM 5: the fetch-failure trade — warn and ADMIT, never block ───────────
# Driven by piping the ref line the way git does, with origin pointed at a path
# that does not exist: ls-remote fails, and the hook must not block on it.
G checkout -q linux-next 2>/dev/null || G checkout -q -B linux-next origin/linux-next
printf 'fn main() { /* code, unreachable remote */ }\n' > crates/demo/main.rs
G add -A >/dev/null; G commit -q -m "feat: code while origin is unreachable"
stamp
git remote set-url origin "$W/does-not-exist.git"
rc=0
out="$(printf 'refs/heads/linux-next %s refs/heads/linux-next %s\n' "$(git rev-parse HEAD)" "$(git rev-parse HEAD~1)" \
    | bash scripts/hooks/pre-push-local-gate.sh origin "$W/does-not-exist.git" 2>&1)" || rc=$?
git remote set-url origin "$W/bare.git"
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'release-freeze check could not reach'; then
    ok "ARM 5: an unreachable remote WARNS and admits, naming the check — the push's own failure is the backstop, and an offline host is not stranded"
else
    bad "ARM 5: rc=$rc, warned=$(printf '%s\n' "$out" | grep -c 'could not reach')"
fi

# ── ARM 6: clearing, and the tool's refusals ───────────────────────────────
out="$(freeze clear linux-next 2>/dev/null | tail -1)"
[ "$out" = "ok:freeze-cleared:1" ] && ok "ARM 6: clear removes the marker" || bad "ARM 6a: '$out'"
out="$(freeze status linux-next 2>/dev/null | tail -1)"
[ "$out" = "ok:freeze-none:linux-next" ] && ok "ARM 6: the branch reads unfrozen again" || bad "ARM 6b: '$out'"
out="$(freeze clear linux-next 2>/dev/null | tail -1)"
[ "$out" = "ok:freeze-cleared:0" ] && ok "ARM 6: clearing an unfrozen branch is 0, not an error" || bad "ARM 6c: '$out'"
G reset -q --hard origin/linux-next; stamp
before="$(tip linux-next)"
printf 'fn main() { /* code after the all-clear */ }\n' > crates/demo/main.rs
G add -A >/dev/null; G commit -q -m "feat: code after the all-clear"; stamp
rc=0; G push -q origin linux-next >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] && [ "$(tip linux-next)" != "$before" ] \
    && ok "ARM 6: with the freeze cleared the same code push lands — the marker's lifetime is the freeze's lifetime" || bad "ARM 6d: rc=$rc"
out="$(freeze --bogus 2>/dev/null | tail -1)"; rc=$?
[ "$rc" -eq 2 ] && [ "$out" = "refused:freeze:usage:--bogus" ] && ok "ARM 6: an unknown flag is refused with exit 2" || bad "ARM 6e: rc=$rc '$out'"
out="$(freeze set work/1176-9vqn 2>/dev/null | tail -1)"; rc=$?
[ "$rc" -eq 2 ] && [ "${out#refused:freeze:usage:branch}" != "$out" ] \
    && ok "ARM 6: a branch name with a slash is refused rather than mis-parsed back out of the ref" || bad "ARM 6f: rc=$rc '$out'"
out="$(freeze set no-such-branch 2>/dev/null | tail -1)"
[ "$out" = "refused:freeze:no-such-branch:no-such-branch" ] && ok "ARM 6: freezing a branch the remote does not have is refused" || bad "ARM 6g: '$out'"

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then
    echo "ok:pre-push-refuses-code-under-a-live-freeze"
    echo "PASS: pre-push-honours-a-live-freeze $pass/$total (1176-9vqn)"
    exit 0
fi
echo "FAIL: pre-push-honours-a-live-freeze $pass/$total (1176-9vqn)"
exit 1
