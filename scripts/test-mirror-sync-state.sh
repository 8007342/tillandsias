#!/usr/bin/env bash
# @trace spec:git-mirror-service
#
# test-mirror-sync-state.sh — ORDER 1350-ku7v (T1).
#
# Pins images/git/publish-sync-state.sh, the verdict a forge and a host read to
# learn whether their mirror is current with upstream BEFORE spending a push on
# the answer.
#
# HERMETIC BY CONSTRUCTION. Every arm builds a scratch bare repository and
# manufactures the tracking namespace by hand, so the fixture runs anywhere,
# touches no container, and never needs this host's mirror to be in a
# particular state. That matters more than usual here: the defect this guards
# is "the mirror is behind", and a fixture that waited for a real mirror to
# fall behind would be untestable on a healthy host — which is every host most
# of the time.
#
# THE ARMS THAT CAN ACTUALLY FAIL are 2, 3 and 4. An arm run against a mirror
# that happens to be CURRENT cannot fail for this defect, which is the trap
# this row's closure names explicitly; so the BEHIND case is manufactured and
# is the fixture's centre of gravity.
#
# GRAMMAR — `ok:mirror-sync-state:<n>/<n> arms` on success.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 3

PUB="${TILLANDSIAS_SYNC_STATE_PUBLISHER:-$ROOT/images/git/publish-sync-state.sh}"
[ -f "$PUB" ] || { echo "skip:mirror-sync-state:no-publisher"; exit 3; }

W="$(mktemp -d "${TMPDIR:-/tmp}/sync-state.XXXXXX")" || exit 3
trap 'rm -rf "$W"' EXIT

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS  $1"; }
bad() { fail=$((fail + 1)); echo "FAIL: $1" >&2; }

# Build a bare mirror with one head, and optionally a tracking twin placed
# `$2` commits ahead of it. Prints the mirror path.
mk_mirror() { # mk_mirror <dir> <ahead-count>
    local dir="$1" ahead="$2" src="$1.src" i
    mkdir -p "$src"
    git init -q "$src"
    git -C "$src" config user.email a@b; git -C "$src" config user.name t
    echo base > "$src/f"; git -C "$src" add f
    git -C "$src" commit -q -m base
    git init -q --bare "$dir"
    git -C "$src" push -q "$dir" HEAD:refs/heads/linux-next
    # The exported head is where the mirror is. Advance the SOURCE further and
    # record that as the tracking twin, which is exactly the shape relay-refs.sh
    # produces: upstream fetched into refs/remotes/origin/*, exported heads left
    # alone.
    for ((i = 0; i < ahead; i++)); do
        echo "more$i" >> "$src/f"
        git -C "$src" commit -q -am "ahead$i"
    done
    git -C "$dir" fetch -q "$src" "+refs/heads/master:refs/remotes/origin/linux-next" 2>/dev/null \
      || git -C "$dir" fetch -q "$src" "+refs/heads/main:refs/remotes/origin/linux-next" 2>/dev/null
    echo "$dir"
}

state_of() { printf '%s' "$1" | cut -d: -f2; }

# ── ARM 1 — UNKNOWN: no tracking data at all is not "current". ───────────────
echo "arm 1 — a mirror with no tracking refs reports unknown, never current"
m1="$W/m1"; mk_mirror "$m1" 0 >/dev/null
git -C "$m1" for-each-ref --format='%(refname)' refs/remotes/origin 2>/dev/null \
  | while read -r r; do git -C "$m1" update-ref -d "$r"; done
out1="$(sh "$PUB" "$m1" 2>/dev/null)"
if [ "$(state_of "$out1")" = "unknown" ]; then
    ok "no tracking data -> unknown ($out1)"
else
    bad "arm1: expected unknown, got '$out1' — a mirror that has never fetched upstream is not current"
fi

# ── ARM 2 — CURRENT: tracking twin equal to the exported head. ───────────────
echo "arm 2 — an up-to-date mirror reports current"
m2="$W/m2"; mk_mirror "$m2" 0 >/dev/null
out2="$(sh "$PUB" "$m2" 2>/dev/null)"
if [ "$(state_of "$out2")" = "current" ]; then
    ok "tracking twin equal -> current ($out2)"
else
    bad "arm2: expected current, got '$out2'"
fi

# ── ARM 3 — BEHIND: the arm this fixture exists for. ─────────────────────────
# THE FAILS CONTROL. Before the publisher existed there was no verdict at all;
# the only signal a host got was a push that had already been refused. If this
# arm ever passes on an unmodified `current` mirror the fixture is vacuous.
echo "arm 3 — a mirror whose upstream moved reports behind, with the head count"
m3="$W/m3"; mk_mirror "$m3" 3 >/dev/null
out3="$(sh "$PUB" "$m3" 2>/dev/null)"
ref3="$(git -C "$m3" for-each-ref --format='%(refname)' refs/tillandsias/sync-state 2>/dev/null | head -1)"
if [ "$(state_of "$out3")" = "behind" ] && [ "${ref3#refs/tillandsias/sync-state/behind/1/}" != "$ref3" ]; then
    ok "upstream ahead -> behind, one head behind ($out3, $ref3)"
else
    bad "arm3: expected behind with a head count of 1, got '$out3' ref '$ref3'"
fi

# ── ARM 4 — an untracked local head must NOT read as behind. ─────────────────
# A salvage ref upstream has never seen would otherwise make every mirror
# permanently behind, which makes the verdict useless rather than wrong.
echo "arm 4 — a head with no tracking twin is not counted as behind"
m4="$W/m4"; mk_mirror "$m4" 0 >/dev/null
git -C "$m4" update-ref refs/heads/salvage/local-only "$(git -C "$m4" rev-parse refs/heads/linux-next)"
out4="$(sh "$PUB" "$m4" 2>/dev/null)"
if [ "$(state_of "$out4")" = "current" ]; then
    ok "untracked local head ignored -> current ($out4)"
else
    bad "arm4: an untracked head made the mirror read '$out4'; every mirror would be permanently behind"
fi

# ── ARM 5 — the namespace holds exactly one verdict after two runs. ──────────
echo "arm 5 — publishing twice prunes the older verdict"
sleep 1
sh "$PUB" "$m2" >/dev/null 2>&1
n5="$(git -C "$m2" for-each-ref --format='%(refname)' refs/tillandsias/sync-state 2>/dev/null | grep -c .)"
if [ "$n5" -eq 1 ]; then
    ok "one verdict after two runs"
else
    bad "arm5: expected 1 verdict ref, found $n5 — a consumer picking the largest epoch would still read, but the namespace grows without bound"
fi

# ── ARM 6 — the consumer contract: readable by ls-remote, empty blob. ────────
# This is what a forge actually does. If the ref were a commit the forge would
# have to fetch to read it, which is the constraint the design exists under.
echo "arm 6 — the verdict is readable by ls-remote and carries no payload"
ls6="$(git ls-remote "$m2" 'refs/tillandsias/sync-state/*' 2>/dev/null | head -1)"
sha6="$(printf '%s' "$ls6" | awk '{print $1}')"
empty="$(git -C "$m2" hash-object -t blob --stdin </dev/null 2>/dev/null)"
if [ -n "$ls6" ] && [ "$sha6" = "$empty" ]; then
    ok "ls-remote sees it and it points at the empty blob"
else
    bad "arm6: ls-remote returned '$ls6'; target '$sha6' is not the empty blob '$empty'"
fi

echo "mirror-sync-state: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || { echo "fail:mirror-sync-state:$fail arm(s)"; exit 1; }
echo "ok:mirror-sync-state:$pass/$pass arms"
exit 0
