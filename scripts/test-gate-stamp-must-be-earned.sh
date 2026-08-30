#!/usr/bin/env bash
# ORDER 940-f77j — a gate stamp must be EARNED, not merely written.
#
# build.sh reaches _write_gate_stamp only after every check passes, so its own
# stamps were always honest. The hole was that `gate-stamp.sh write` is a public
# entry point: the invariant lived in build.sh's control flow, not in the thing
# that writes the artifact. On 2026-08-29 an agent ran
#
#     ./build.sh --check; scripts/gate-stamp.sh write; git push
#
# with semicolons rather than `&&`. The gate exited 1 on a real violation, the
# next command stamped anyway, and a red tree landed on trunk under a stamp
# asserting it was green. The vulnerability was never the punctuation — a
# guarantee whose enforcement lives in every caller's shell is not enforced, it
# is documented.
#
# Arm 3 replays that sequence VERBATIM, semicolons included, because a control
# written with `&&` would pass against exactly the shell discipline the fix
# exists to stop depending on.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$SCRIPT_DIR/gate-stamp.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A throwaway repo: the token and stamp both live in ITS git dir, so nothing
# here can touch the real checkout's gate state.
export GIT_CONFIG_GLOBAL=/dev/null
git init -q "$WORK/repo"
cd "$WORK/repo"
git config user.email t@t; git config user.name t
printf 'hello\n' > file.txt
git add -A; git commit -qm init
GITDIR="$(git rev-parse --absolute-git-dir)"
TOKEN="$GITDIR/tillandsias-gate-pass-token"
STAMP_FILE="$GITDIR/tillandsias-gate-stamp"

issue_token() {  # what a GREEN build.sh does
    printf 'version 1\ndigest %s\ndispatch check\nissued now\n' \
        "$(bash "$STAMP" compute)" > "$TOKEN"
}

# ── arm 1: green gate -> token issued -> stamp accepted ─────────────────────
issue_token
bash "$STAMP" write --scope full --dispatch check >/dev/null \
    || fail "arm 1: a stamp backed by a matching pass token was refused"
[[ -f "$STAMP_FILE" ]] || fail "arm 1: accepted but wrote no stamp"
[[ ! -f "$TOKEN" ]] || fail "arm 1: the token was not consumed — it could authorise a second stamp"

# ── arm 2: red gate -> no token -> stamp refused ────────────────────────────
rm -f "$STAMP_FILE" "$TOKEN"
if out="$(bash "$STAMP" write --scope full --dispatch check 2>&1)"; then
    fail "arm 2: a stamp was written with no pass token at all: $out"
fi
grep -q "refused:no-gate-pass-token" <<<"$out" || fail "arm 2: wrong refusal: $out"
[[ ! -f "$STAMP_FILE" ]] || fail "arm 2: refused but wrote a stamp anyway"

# ── arm 3: THE INCIDENT, verbatim — red gate, then an unconditional write ───
#    Semicolons, exactly as typed on 2026-08-29. The false gate here exits 1.
rm -f "$STAMP_FILE" "$TOKEN"
set +e
out="$( { false; } ; bash "$STAMP" write --scope full --dispatch check 2>&1 )"
rc=$?
set -e
[[ $rc -ne 0 ]] || fail "arm 3: THE INCIDENT REPRODUCES — a red gate's stamp was accepted"
[[ ! -f "$STAMP_FILE" ]] || fail "arm 3: THE INCIDENT REPRODUCES — a stamp exists after a red gate"
grep -q "refused:" <<<"$out" || fail "arm 3: refused without saying so: $out"

# ── arm 4: STALE TOKEN — green gate, then the tree changes, then stamp ──────
#    A token keyed to a different tree is "a gate passed" wearing "this tree
#    passed" as a costume. Refusing only the missing-token case would leave the
#    door open at the hinge.
rm -f "$STAMP_FILE" "$TOKEN"
issue_token
printf 'edited after the gate ran\n' >> file.txt
if out="$(bash "$STAMP" write --scope full --dispatch check 2>&1)"; then
    fail "arm 4: a token issued for a DIFFERENT tree was accepted: $out"
fi
grep -q "refused:gate-pass-token-is-for-another-tree" <<<"$out" \
    || fail "arm 4: wrong refusal: $out"
[[ ! -f "$STAMP_FILE" ]] || fail "arm 4: refused but wrote a stamp anyway"
[[ ! -f "$TOKEN" ]] || fail "arm 4: a token that vouched for another tree was left live"

echo "ok: a gate stamp cannot be written without a pass token the gate itself issued (940-f77j)"
