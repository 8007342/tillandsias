#!/usr/bin/env bash
# Fixture for order 895-j8ag — the daily-maintenance gate's day boundary is UTC.
#
# THE DEFECT. The verdict compared the LOCAL date against a marker that records
# both `date=` and `utc=`. On a host at a non-zero UTC offset the two disagree
# for part of every day, and the verdict followed the local half.
#
# MEASURED on three hosts, all UTC-7, all reading `ok:...-current` while the UTC
# day had already rolled — pirria, macuahuitl, and lenovinha (this host, live:
# 2026-08-26T03:48:12Z / 2026-08-25 20:48 PDT against a marker whose utc= was
# 2026-08-25T20:14:30Z). Before the fix the verdict was
# `ok:daily-maintenance-current:2026-08-25`; after it, on the same host at the
# same instant, `due:stale:2026-08-25`.
#
# THE FAILURE IS DIRECTIONAL, which is why the arms below test BOTH SIGNS. A
# UTC-negative host reports a stale gate as current for the last hours of its
# local day. A UTC-positive host has the mirror problem: its local date rolls
# BEFORE UTC, so it can demand a second run inside one UTC day. Every observed
# reproduction was UTC-negative, so a one-sign fixture would have passed on half
# the fleet and left the mirror case to be discovered in production. This
# fixture simulates the unobserved sign with TZ rather than waiting for a host.
#
# THE PROPERTY, stated so it cannot drift: with the boundary on UTC, `TZ` must
# not change the verdict AT ALL. `date -u` ignores TZ; `date` does not. So a
# verdict that moves when only TZ moves is, by construction, reading the local
# date.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
GUARD="$PWD/scripts/check-daily-maintenance.sh"
fail=0
ok()  { echo "ok: $1"; }
bad() { echo "FAIL: $1" >&2; fail=1; }

W="$(mktemp -d "${TMPDIR:-/tmp}/daily-boundary.XXXXXX")"
trap 'rm -rf "$W"' EXIT

# A marker stamped for a known UTC day, written directly so the fixture controls
# the input rather than depending on when it runs.
mk_marker() { # mk_marker <path> <date=> <utc=>
    printf 'date=%s utc=%s host=fixture steps=probe:ok\n' "$2" "$3" > "$1"
}

run() { # run <marker> <TZ> [TODAY-override]
    local m="$1" tz="$2" today="${3:-}"
    if [ -n "$today" ]; then
        env TZ="$tz" TILLANDSIAS_DAILY_MAINTENANCE_MARKER="$m" \
            TILLANDSIAS_DAILY_MAINTENANCE_TODAY="$today" \
            bash "$GUARD" check 2>/dev/null
    else
        env TZ="$tz" TILLANDSIAS_DAILY_MAINTENANCE_MARKER="$m" \
            bash "$GUARD" check 2>/dev/null
    fi
}

M="$W/marker"
mk_marker "$M" 2026-08-25 2026-08-25T20:14:30Z

# ── 1. THE BOUNDARY FLIPS EXACTLY ONCE, AT THE RIGHT INSTANT. ────────────────
# Pinned either side of the chosen rollover, per the packet's exit criterion.
same="$(run "$M" UTC 2026-08-25)"
next="$(run "$M" UTC 2026-08-26)"
case "$same" in ok:daily-maintenance-current:2026-08-25)
    ok "on the marker's own UTC day -> current" ;;
  *) bad "same-day verdict: $same" ;;
esac
case "$next" in due:stale:2026-08-25)
    ok "one UTC day later -> due:stale, naming the stale day" ;;
  *) bad "next-day verdict: $next" ;;
esac
# "Flips EXACTLY once" means exactly one day in a window reads current — not
# merely that two days differ. The first draft of this compared 08-24 against
# 08-26 and demanded they differ; both correctly read `due:stale:2026-08-25`,
# because a marker is stale on either side of its own day. That assertion was
# wrong about the property, not about the code — a test can be red for
# describing the wrong thing.
current_days=0
for d in 2026-08-23 2026-08-24 2026-08-25 2026-08-26 2026-08-27; do
    case "$(run "$M" UTC "$d")" in
        ok:daily-maintenance-current:*)
            current_days=$((current_days + 1))
            [ "$d" = "2026-08-25" ] || bad "read current on $d, which is not the marker's day" ;;
    esac
done
[ "$current_days" -eq 1 ] \
    && ok "across a five-day window exactly ONE day reads current, and it is the marker's" \
    || bad "expected exactly 1 current day in the window, got $current_days"

# ── 2. BOTH SIGNS OF UTC OFFSET, and this is the arm that was missing. ───────
# With the boundary on UTC, TZ must not change the verdict. Same marker, same
# instant, only the zone differs.
utc_v="$(run "$M" UTC)"
neg_v="$(run "$M" America/Los_Angeles)"   # UTC-7/8 — the OBSERVED failing sign
pos_v="$(run "$M" Asia/Tokyo)"            # UTC+9   — the UNOBSERVED mirror
if [ "$utc_v" = "$neg_v" ] && [ "$utc_v" = "$pos_v" ]; then
    ok "TZ does not move the verdict: UTC == UTC-7 == UTC+9 ($utc_v)"
else
    bad "verdict follows LOCAL time — UTC=$utc_v UTC-7=$neg_v UTC+9=$pos_v"
fi

# The directional shapes, pinned explicitly rather than left to whenever the
# suite happens to run. A marker stamped late on a UTC day is:
#   - still current at 23:59Z
#   - stale at 00:01Z the next UTC day, from EVERY zone
mk_marker "$W/late" 2026-08-25 2026-08-25T23:50:00Z
for tz in UTC America/Los_Angeles Asia/Tokyo Pacific/Kiritimati; do
    v="$(run "$W/late" "$tz" 2026-08-26)"
    case "$v" in due:stale:2026-08-25) ;;
      *) bad "TZ=$tz did not report stale on the next UTC day: $v" ;;
    esac
done
ok "a marker from the previous UTC day reads stale in every zone tested"

# ── 3. NEGATIVE CONTROL: the verdict GRAMMAR is unchanged. ──────────────────
# Callers branch on these tokens; changing the boundary must not change them.
grammar='^(ok:daily-maintenance-(current|stamped):[0-9]{4}-[0-9]{2}-[0-9]{2}|skip:forge-exempt|due:(no-marker|unreadable-marker|stale:[0-9]{4}-[0-9]{2}-[0-9]{2}))$'
for v in "$same" "$next" "$neg_v" "$pos_v"; do
    printf '%s\n' "$v" | grep -qE "$grammar" \
        || bad "verdict escaped the pinned grammar: $v"
done
ok "every verdict still matches the pinned grammar"
miss="$(run "$W/absent-marker" UTC 2026-08-26)"
[ "$miss" = "due:no-marker" ] && ok "an absent marker is still due:no-marker" \
    || bad "no-marker verdict changed: $miss"
printf 'garbage\n' > "$W/corrupt"
corrupt="$(run "$W/corrupt" UTC 2026-08-26)"
[ "$corrupt" = "due:unreadable-marker" ] && ok "a corrupt marker is still due:unreadable-marker" \
    || bad "unreadable verdict changed: $corrupt"

# ── 4. THE MARKER STILL RECORDS BOTH date= AND utc=. ────────────────────────
# That pair is what made this defect findable — without utc= the gate reads as
# perfectly healthy — and it is how a host reading an OLD marker can tell which
# boundary produced it. Which matters exactly once: across this change.
S="$W/stamped"
env TILLANDSIAS_DAILY_MAINTENANCE_MARKER="$S" bash "$GUARD" stamp \
    --host fixture --steps 'probe:ok' >/dev/null 2>&1
if grep -qE '^date=[0-9]{4}-[0-9]{2}-[0-9]{2} utc=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z ' "$S"; then
    ok "the stamp still records BOTH date= and utc="
else
    bad "the marker lost a field: $(cat "$S")"
fi
# And the two now agree, because both are UTC. A divergence here would mean the
# stamp and the comparison had drifted apart again — the original defect.
sd="$(sed -n 's/^date=\([0-9-]*\).*/\1/p' "$S")"
su="$(sed -n 's/.*utc=\([0-9-]*\)T.*/\1/p' "$S")"
[ "$sd" = "$su" ] && ok "stamp date= and utc= agree on the same UTC day ($sd)" \
    || bad "stamp wrote date=$sd but utc=$su — the two boundaries drifted apart again"

# ── 5. MUTATION CONTROL: the pre-fix guard must FAIL arm 2. ─────────────────
# Reconstruct the local-date version and require it to disagree across zones on
# the very input arm 2 passes. Without this, arm 2 could pass because the test
# machine happens to sit at UTC.
PRE="$W/pre-895-guard.sh"
sed 's/^TODAY="${TILLANDSIAS_DAILY_MAINTENANCE_TODAY:-$(date -u +%Y-%m-%d/TODAY="${TILLANDSIAS_DAILY_MAINTENANCE_TODAY:-$(date +%Y-%m-%d/' \
    "$GUARD" > "$PRE"
if ! grep -q 'date +%Y-%m-%d' "$PRE"; then
    bad "could not reconstruct the pre-fix guard — the TODAY= line moved, so this control tests nothing"
else
    # Pick an instant where local and UTC days differ in BOTH directions by
    # using a marker on the UTC day and asking from either side.
    mk_marker "$W/m2" 2026-08-25 2026-08-25T23:50:00Z
    a="$(env TZ=America/Los_Angeles TILLANDSIAS_DAILY_MAINTENANCE_MARKER="$W/m2" bash "$PRE" check 2>/dev/null)"
    b="$(env TZ=Asia/Tokyo         TILLANDSIAS_DAILY_MAINTENANCE_MARKER="$W/m2" bash "$PRE" check 2>/dev/null)"
    if [ "$a" != "$b" ]; then
        ok "MUTATION: the pre-fix guard disagrees across zones (UTC-7=$a UTC+9=$b) — arm 2 has teeth"
    else
        bad "MUTATION reconstruction agreed across zones ($a) — arm 2 may pass for the wrong reason"
    fi
fi

if [ "$fail" -eq 0 ]; then
    echo "ok:daily-maintenance-day-boundary:all"
    exit 0
fi
echo "fail:daily-maintenance-day-boundary"
exit 1
