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
if [ "$(state_of "$out1")" = "heads-unknown" ]; then
    ok "no tracking data -> unknown ($out1)"
else
    bad "arm1: expected heads-unknown, got '$out1' — a mirror that has never fetched upstream is not current"
fi

# ── ARM 2 — CURRENT: tracking twin equal to the exported head. ───────────────
echo "arm 2 — an up-to-date mirror reports current"
m2="$W/m2"; mk_mirror "$m2" 0 >/dev/null
out2="$(sh "$PUB" "$m2" 2>/dev/null)"
if [ "$(state_of "$out2")" = "heads-current" ]; then
    ok "tracking twin equal -> current ($out2)"
else
    bad "arm2: expected heads-current, got '$out2'"
fi

# ── ARM 3 — BEHIND: the arm this fixture exists for. ─────────────────────────
# THE FAILS CONTROL. Before the publisher existed there was no verdict at all;
# the only signal a host got was a push that had already been refused. If this
# arm ever passes on an unmodified `current` mirror the fixture is vacuous.
echo "arm 3 — a mirror whose upstream moved reports behind, with the head count"
m3="$W/m3"; mk_mirror "$m3" 3 >/dev/null
out3="$(sh "$PUB" "$m3" 2>/dev/null)"
ref3="$(git -C "$m3" for-each-ref --format='%(refname)' refs/tillandsias/sync-state 2>/dev/null | head -1)"
if [ "$(state_of "$out3")" = "heads-behind" ] && [ "${ref3#refs/tillandsias/sync-state/heads-behind/1/}" != "$ref3" ]; then
    ok "upstream ahead -> behind, one head behind ($out3, $ref3)"
else
    bad "arm3: expected heads-behind with a head count of 1, got '$out3' ref '$ref3'"
fi

# ── ARM 4 — an untracked local head must NOT read as behind. ─────────────────
# A salvage ref upstream has never seen would otherwise make every mirror
# permanently behind, which makes the verdict useless rather than wrong.
echo "arm 4 — a head with no tracking twin is not counted as behind"
m4="$W/m4"; mk_mirror "$m4" 0 >/dev/null
git -C "$m4" update-ref refs/heads/salvage/local-only "$(git -C "$m4" rev-parse refs/heads/linux-next)"
out4="$(sh "$PUB" "$m4" 2>/dev/null)"
if [ "$(state_of "$out4")" = "heads-current" ]; then
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

# ════════════════════════════════════════════════════════════════════════════
# ARMS 7-9 — THE LIFECYCLE. Order 1350-ku7v, second half.
#
# Arms 1-6 prove the publisher computes and publishes the right verdict. They
# would all have passed while the script was shipped nowhere and called by
# nothing, which is exactly what it was: a working script wired to nothing.
# A verdict no lifecycle produces is not a surface a consumer can read, and
# the acceptance this row owes is about the SURFACE.
#
# So these arms ask the second question: does anything actually run it?
# ════════════════════════════════════════════════════════════════════════════

CF="$ROOT/images/git/Containerfile"
EP="$ROOT/images/git/entrypoint.sh"
RR="$ROOT/images/git/relay-refs.sh"

# ── ARM 7 — the image ships it, executable. ─────────────────────────────────
# Read on the Containerfile directly: a COPY that never happened is invisible
# from inside every other arm, and this was the actual gap.
echo "arm 7 — the mirror image ships the publisher and marks it executable"
c7="$(grep -c 'COPY publish-sync-state.sh /usr/local/share/git-service/publish-sync-state' "$CF" || true)"
x7="$(grep -c '/usr/local/share/git-service/publish-sync-state' "$CF" || true)"
if [ "$c7" -eq 1 ] && [ "$x7" -ge 2 ]; then
    ok "Containerfile copies the publisher and chmods it (copy=$c7 mentions=$x7)"
else
    bad "arm7: the publisher is not shipped in the mirror image (copy=$c7 mentions=$x7) — it would be absent at every call site below"
fi

# ── ARM 8 — the entrypoint calls it at startup AND on the cadence. ───────────
# BOTH call sites are required and they answer different halves of the row:
# startup is what a forge launching beside the mirror reads, the reconciler
# tick is what bounds the verdict's staleness afterwards. One without the
# other leaves a consumer reading an absent or an arbitrarily old state.
echo "arm 8 — the entrypoint publishes at startup and on every reconciler tick"
o8="$(grep -c 'SYNC_STATE="\${SYNC_STATE:-/usr/local/share/git-service/publish-sync-state}"' "$EP" || true)"
n8="$(grep -c 'run_sync_state "' "$EP" || true)"
if [ "$o8" -eq 1 ] && [ "$n8" -ge 2 ]; then
    ok "entrypoint has an overridable SYNC_STATE and $n8 call sites"
else
    bad "arm8: entrypoint wiring incomplete (override=$o8 call-sites=$n8); startup and the reconciler tick must both publish"
fi

# ── ARM 9 — BEHAVIOURAL: a real relay run publishes a real verdict. ──────────
# The arm that cannot be satisfied by a comment. It drives the ACTUAL
# relay-refs.sh against a local bare upstream, with SYNC_STATE pointed at the
# actual publisher, and asks the mirror afterwards whether a verdict exists.
# Nothing here is mocked except the upstream URL, which is a path.
echo "arm 9 — a live relay run leaves a sync-state verdict in the mirror"
m9="$W/m9"; mk_mirror "$m9" 0 >/dev/null
up9="$W/up9.git"; git init -q --bare "$up9"
git -C "$m9" remote add origin "$up9" 2>/dev/null || git -C "$m9" remote set-url origin "$up9"
git -C "$m9" for-each-ref --format='%(refname)' refs/tillandsias/sync-state 2>/dev/null \
  | while read -r r; do git -C "$m9" update-ref -d "$r"; done
sha9="$(git -C "$m9" rev-parse refs/heads/linux-next)"
( cd "$m9" && printf '%s %s %s\n' "$sha9" "$sha9" refs/heads/linux-next \
    | SYNC_STATE="$PUB" sh "$RR" ) >/dev/null 2>&1 || true
ref9="$(git -C "$m9" for-each-ref --format='%(refname)' refs/tillandsias/sync-state 2>/dev/null | head -1)"
case "$ref9" in
    refs/tillandsias/sync-state/*)
        ok "relay published $ref9" ;;
    *)
        bad "arm9: a full relay run published NO sync-state verdict — the publisher is shipped and called by nothing that runs" ;;
esac

# ── ARM 10 — the relay's exit status is not hostage to the publisher. ────────
# A relay that refused a legitimate push because a verdict could not be written
# would be a worse defect than the blindness this row fixes. Point SYNC_STATE
# at something that always fails and require the relay to behave as before.
echo "arm 10 — a failing publisher never changes the relay's verdict"
m10="$W/m10"; mk_mirror "$m10" 0 >/dev/null
up10="$W/up10.git"; git init -q --bare "$up10"
git -C "$m10" remote add origin "$up10" 2>/dev/null || git -C "$m10" remote set-url origin "$up10"
boom="$W/boom.sh"; printf '#!/bin/sh\nexit 9\n' > "$boom"; chmod +x "$boom"
sha10="$(git -C "$m10" rev-parse refs/heads/linux-next)"
( cd "$m10" && printf '%s %s %s\n' "$sha10" "$sha10" refs/heads/linux-next \
    | SYNC_STATE="$boom" sh "$RR" ) >/dev/null 2>&1
rc10=$?
if [ "$rc10" -eq 0 ] && [ -n "$(git -C "$up10" rev-parse --verify --quiet refs/heads/linux-next || true)" ]; then
    ok "publisher exit 9 ignored; the push still landed and the relay still exited 0"
else
    bad "arm10: a failing publisher changed the relay's outcome (rc=$rc10) — the verdict must never gate the push"
fi

echo "mirror-sync-state: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || { echo "fail:mirror-sync-state:$fail arm(s)"; exit 1; }
echo "ok:mirror-sync-state:$pass/$pass arms"
exit 0
