#!/usr/bin/env bash
# @trace order:1173-a5ng
# @trace order:1148-3439 (the ledger and its sweep)
#
# REGIME: hermetic, in a throwaway git repository. Every arm builds its own repo
# under a temp dir, points the checker at it with TILLANDSIAS_SALVAGE_ROOT, and
# creates a local branch standing in for trunk via TILLANDSIAS_SALVAGE_TRUNK_REF.
# No arm touches this checkout's ledger, contacts origin, or deletes a ref —
# origin is deliberately unreachable in the fixture repo, which is also what
# makes "the ref is absent from the remote" true without deleting anything.
#
# NO ABSOLUTE TIMESTAMP IS ENCODED HERE beyond the ledger grammar's own required
# ISO field, which is data inside a fixture-built line, not a comparison against
# now.
#
# THE RACE THIS PINS (1173-a5ng), measured on yolanda 2026-09-13: the coordinator
# marked a line at 6857ce7f6 (20:29Z) and deleted the ref at 20:31Z; yolanda's
# land, gating a tree merged BEFORE that commit, refused at ~20:35Z while trunk
# carried the marker the whole time. Mark-land-delete protects a gate that merges
# trunk AFTER the marker; it does nothing for one already running on an older
# snapshot, and on a floor host a gate runs for an hour.
set -uo pipefail

REAL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$REAL_ROOT/scripts/check-salvage-refs-ledger.sh"
[ -x "$CHECK" ] || { echo "could-not-run:salvage-refs-ledger:missing-checker"; exit 3; }

pass=0; fail=0
ok()  { printf 'ok:   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail+1)); }

W="$(mktemp -d "${TMPDIR:-/tmp}/salvage-ledger.XXXXXX")" || exit 3
trap 'rm -rf "$W"' EXIT

REF='salvage/yolanda/20260913-1172-dyvd'
_line() { # _line <marked:0|1>
    # The grammar is | utc | ref | sha | ancestry | files |, and getting it
    # wrong is how the first run of this fixture reported the FALLBACK broken
    # when what was broken was the test data: the checker said "malformed sha"
    # about a field holding a ref. Read the grammar from the checker's header,
    # never from memory of the column order.
    local l="| 2026-09-13T20:29:00Z | $REF | 0123456789abcdef0123456789abcdef01234567 | on:linux-next | 3 |"
    [ "$1" = "1" ] && l="$l deleted"
    printf '%s\n' "$l"
}

# One repo per case, so no arm inherits another's state — the failure mode that
# made an earlier fixture of mine pass for the wrong reason.
_repo() { # _repo <local-marked> <trunk-marked> -> prints the repo path
    local d; d="$(mktemp -d "$W/repo.XXXXXX")"
    git -C "$d" init -q 2>/dev/null
    # A REAL, REACHABLE origin holding NO salvage refs. The first version of
    # this fixture created no remote at all and assumed that made the ref
    # "absent"; it made `git ls-remote` FAIL, so the checker took its
    # origin-unreachable skip and the reachability half — the entire subject —
    # never ran. Every arm passed or failed for a reason unrelated to the fix.
    # An unreachable remote and an empty one are different facts, which is the
    # same distinction this whole packet is about.
    git init -q --bare "$d.origin" 2>/dev/null
    git -C "$d" remote add origin "$d.origin" 2>/dev/null
    git -C "$d" config user.email t@example.invalid
    git -C "$d" config user.name t
    mkdir -p "$d/plan/salvage-refs.d"
    # TRUNK's copy first, committed on a branch that stands in for origin/linux-next.
    _line "$2" > "$d/plan/salvage-refs.d/yolanda.md"
    git -C "$d" add -A >/dev/null 2>&1
    git -C "$d" commit -qm trunk >/dev/null 2>&1
    git -C "$d" branch -f trunk-stand-in >/dev/null 2>&1
    # Then the LOCAL working copy, which is what the checker reads directly.
    _line "$1" > "$d/plan/salvage-refs.d/yolanda.md"
    printf '%s' "$d"
}

_run_check() { # _run_check <repo>
    ( cd "$1" && TILLANDSIAS_SALVAGE_ROOT="$1" \
        TILLANDSIAS_SALVAGE_TRUNK_REF="trunk-stand-in" \
        bash "$CHECK" 2>"$W/err" )
}

# ── 1. THE CASE THE ROW EXISTS FOR: unmarked locally, marked on trunk ───────
d="$(_repo 0 1)"
out="$(_run_check "$d")"; rc=$?
if [ "$rc" = "0" ] && case "$out" in *":marker-on-trunk:$REF"*) true ;; *) false ;; esac; then
    ok "unmarked locally + marked on trunk -> ok:...:marker-on-trunk:<ref>, exit 0"
else
    bad "the behind-tree case did not resolve (rc=$rc): $out"
fi
if /usr/bin/grep -qi 'MERGE TRUNK' "$W/err"; then
    ok "the verdict says on stderr what to do about it (merge trunk)"
else
    bad "nothing on stderr tells the reader to merge trunk: $(head -2 "$W/err" | tr '\n' ' ')"
fi

# ── 2. NEGATIVE CONTROL: unmarked in BOTH copies still refuses ──────────────
#    The outstanding-rescue semantics must not move. This is the arm that fails
#    if the fallback is widened into "trunk has the line" rather than "trunk has
#    the MARKER".
d="$(_repo 0 0)"
out="$(_run_check "$d")"; rc=$?
if [ "$rc" != "0" ] && case "$out" in *violation:salvage-refs-ledger:*) true ;; *) false ;; esac; then
    ok "NC: absent from the remote and unmarked in BOTH copies still refuses"
else
    bad "NC: a genuinely outstanding rescue was forgiven (rc=$rc): $out — the fallback is too wide"
fi

# ── 3. marked locally: unchanged, and never consults trunk at all ───────────
d="$(_repo 1 0)"
out="$(_run_check "$d")"; rc=$?
if [ "$rc" = "0" ] && case "$out" in *marker-on-trunk*) false ;; ok:salvage-refs-ledger:*) true ;; *) false ;; esac; then
    ok "a locally marked line passes as before, without the trunk token"
else
    bad "a locally marked line changed behaviour (rc=$rc): $out"
fi

# ── 4. TRUNK'S COPY UNREADABLE IS NOT FORGIVENESS ──────────────────────────
#    `git show <ref>:<path>` on a missing ref exits non-zero and writes ZERO
#    bytes — identical to "read it, no marker" if the rc is discarded. The
#    checker must refuse here, not wave the line through.
d="$(_repo 0 1)"
out="$( cd "$d" && TILLANDSIAS_SALVAGE_ROOT="$d" \
        TILLANDSIAS_SALVAGE_TRUNK_REF="refs/heads/no-such-branch" \
        bash "$CHECK" 2>"$W/err2" )"; rc=$?
if [ "$rc" != "0" ] && case "$out" in *violation:salvage-refs-ledger:*) true ;; *) false ;; esac; then
    ok "an unreadable trunk copy REFUSES — a zero-byte read is not a clean answer"
    /usr/bin/grep -q 'could NOT be ruled out' "$W/err2" \
        && ok "and it says the behind-tree case could not be ruled out, rather than asserting a rescue" \
        || bad "it refused without saying the trunk copy was unreadable: $(head -3 "$W/err2" | tr '\n' ' ')"
else
    bad "an unreadable trunk copy was treated as 'no marker' and forgiven or mis-handled (rc=$rc): $out"
fi

# ── 5. the deletion protocol is stated where the delete happens ────────────
SWEEP="$REAL_ROOT/scripts/sweep-salvage-refs.sh"
if [ ! -f "$SWEEP" ]; then
    bad "scripts/sweep-salvage-refs.sh is absent — the protocol has nowhere to live"
elif /usr/bin/grep -qi 'pass AFTER' "$SWEEP" && /usr/bin/grep -q '1173-a5ng' "$SWEEP"; then
    ok "sweep-salvage-refs.sh states the one-pass-after-the-marker deletion rule"
else
    bad "sweep-salvage-refs.sh does not carry the deletion rule — the race is reduced by nothing on the writing side"
fi

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: salvage-refs ledger trunk fallback $pass/$total (1173-a5ng)"
    exit 0
fi
echo "FAIL: salvage-refs ledger trunk fallback $pass/$total (1173-a5ng)"
exit 1
