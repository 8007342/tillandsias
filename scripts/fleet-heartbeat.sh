#!/usr/bin/env bash
# fleet-heartbeat.sh — report each host's liveness, distinguishing a DEAD
# terminal from a host that is alive and failing every cycle.
#
# WHY THIS EXISTS, and it is a defect in the coordinator's own instrument.
#
# The hourly heartbeat reported attestation age alone and flagged anything over
# ~6h as SILENT. 856-s56y's framing — "a silent host is usually a dead terminal,
# not a finished one" — is right, but it names only two states when there are
# three, and the third is the one that needs a different answer.
#
# Measured 2026-08-24. yoga's last attestation was 14h22m old, so every cycle
# reported it SILENT, which reads as dead or stood down. yoga had in fact
# claimed two rows at 16:20Z, implemented BOTH completely on disk, been
# interrupted before committing, and then refused three successive bootstrap
# cycles (19:45Z, 21:50Z, 02:00Z) on the dirty-start guard — while pushing a
# durable record of its own wedge 27 MINUTES before the report called it silent.
#
# A dirty-start refusal is explicitly NOT a work cycle and correctly never
# attests. So the healthiest possible response to being wedged produces exactly
# the same signal as being switched off.
#
#   dead     : no attestation, no commits            -> restart it
#   WEDGED   : no attestation, but recent commits    -> adjudicate its worktree
#   healthy  : attesting                             -> nothing
#
# Confusing the first two costs hours: a wedged host looks stood-down, so nobody
# looks, while it burns a cycle an hour refusing. Ten of yoga's hours went that
# way with the coordinator reporting "silent" each time and being wrong.
#
# Output: one line per host, plus a falsifiable last line:
#   ok:fleet-heartbeat:<healthy>/<wedged>/<blocked>/<dead>/<never>
#
# `blocked` joined the grammar in 864-w7rc. Widening a falsifiable verdict line
# is a breaking change for anything parsing it; checked first — nothing does,
# and this header was the only place still claiming the old four-field shape.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SILENT_MINS="${TILLANDSIAS_HEARTBEAT_SILENT_MINS:-360}"
ATTEST_DIR="plan/mo-full-attestations.d"
NOW="$(date -u +%s)"

# ISO-8601 -> epoch WITHOUT `date -d`, which is a GNU-ism (761-g36m). BSD date
# does not merely fail on it — it SUCCEEDS AND PRINTS GARBAGE, so an
# `|| echo 0` guard cannot catch the difference and this report would silently
# mis-age every host on the macOS lane. The arithmetic below (Howard Hinnant's
# days_from_civil) is exact for all Gregorian dates and depends on no platform
# behaviour at all.
iso_to_epoch() {
    printf '%s\n' "$1" | awk '
        function days_from_civil(y, m, d,   era, yoe, doy, doe) {
            if (m <= 2) y -= 1
            era = int((y >= 0 ? y : y - 399) / 400)
            yoe = y - era * 400
            doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
            doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
            return era * 146097 + doe - 719468
        }
        {
            if (match($0, /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/) == 0) { print 0; exit }
            y = substr($0,1,4) + 0; mo = substr($0,6,2) + 0; d = substr($0,9,2) + 0
            h = substr($0,12,2) + 0; mi = substr($0,15,2) + 0; s = substr($0,18,2) + 0
            print days_from_civil(y, mo, d) * 86400 + h * 3600 + mi * 60 + s
        }'
}

# A host's own activity, independent of whether it managed to attest. Commits
# are authored by the host name on every lane, which is what makes this
# readable without any new bookkeeping. `%ct` is already a UNIX epoch, so this
# side needs no date parsing whatsoever.
last_commit_epoch() {
    local host="$1" ct
    ct="$(git log --all --author="$host" -1 --format='%ct' 2>/dev/null)"
    case "$ct" in
        ''|*[!0-9]*) echo 0 ;;
        *) echo "$ct" ;;
    esac
}

last_attest_epoch() {
    local f="$1" ts
    ts="$(grep -oE '^## 20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' "$f" 2>/dev/null \
          | sed 's/^## //' | sort | tail -1)"
    [ -n "$ts" ] || { echo 0; return; }
    iso_to_epoch "$ts"
}

human() { printf '%dh%02dm' $(( $1 / 3600 )) $(( ($1 % 3600) / 60 )); }

# The roster is the capability matrix, not the attestation directory: a host
# that has NEVER attested has no file and would otherwise be invisible here —
# which is its own silent gap (pirria, 2026-08-23).
# Resolved through the shared probe, never a hardcoded ./target path: every
# forge exports CARGO_TARGET_DIR so ./target does not exist in the mounted
# checkout at all, and the WSL2 builder points it at a distro-native path for
# the same reason (704-zcgi). A hardcoded path would make this report silently
# roster-less on exactly the hosts most likely to be wedged.
roster=""
# shellcheck source=scripts/plan-binary-probe.sh
. "$ROOT/scripts/plan-binary-probe.sh"
if PLAN="$(resolve_plan_binary)"; then
    roster="$("$PLAN" capability-matrix --hosts 2>/dev/null | awk '{print $1}')"
fi
for f in "$ATTEST_DIR"/*.md; do
    [ -f "$f" ] || continue
    h="$(basename "$f" .md)"
    [ "$h" = "README" ] && continue
    roster="$roster
$h"
done
roster="$(printf '%s\n' "$roster" | grep -v '^$' | sort -u)"

# An OPEN BLOCKER THE HOST FILED ABOUT ITSELF, which is durable state rather
# than a decaying signal.
#
# The wedged/dead split below keys on commit recency, and that decays: a wedged
# host stops committing once it has nothing NEW to say about being wedged, so
# after six hours it reads "likely a dead terminal" again. Measured 2026-08-24 —
# yoga filed plan/issues/yoga-dirty-start-wedge-2026-08-23.md carrying
# `Status: blocked`, still holds two in_progress reap-held rows, and by the next
# cycle this report was calling it dead. The classifier lost information the
# ledger still had.
#
# So consult the record. This script already TELLS the reader to "check
# plan/issues/ for a record it filed about itself" — and printed that hint only
# when something was already classified wedged, i.e. it vanished exactly when it
# became necessary. Automating the advice it was giving is the fix.
open_blocker_for() {
    local host="$1" f
    for f in plan/issues/*"$host"*.md; do
        [ -f "$f" ] || continue
        # A blocker is open until its own record says otherwise. `Status:` is the
        # field these records already carry; anything not blocked is ignored.
        if grep -qiE '^- Status:[[:space:]]*blocked' "$f" 2>/dev/null; then
            printf '%s\n' "$f"
            return 0
        fi
    done
    return 1
}

healthy=0; wedged=0; dead=0; never=0; blocked=0
for host in $roster; do
    f="$ATTEST_DIR/$host.md"
    a_epoch=0
    [ -f "$f" ] && a_epoch="$(last_attest_epoch "$f")"
    c_epoch="$(last_commit_epoch "$host")"

    a_age=$(( NOW - a_epoch )); [ "$a_epoch" -eq 0 ] && a_age=-1
    c_age=$(( NOW - c_epoch )); [ "$c_epoch" -eq 0 ] && c_age=-1

    if [ "$a_epoch" -eq 0 ]; then
        if [ "$c_epoch" -ne 0 ] && [ "$c_age" -lt $(( SILENT_MINS * 60 )) ]; then
            printf '%-24s NEVER ATTESTED but committed %s ago  <-- ALIVE, NOT ATTESTING\n' \
                "$host" "$(human "$c_age")"
        else
            printf '%-24s NEVER ATTESTED, no recent commits\n' "$host"
        fi
        never=$(( never + 1 ))
        continue
    fi

    if [ "$a_age" -le $(( SILENT_MINS * 60 )) ]; then
        printf '%-24s %s\n' "$host" "$(human "$a_age")"
        healthy=$(( healthy + 1 ))
    elif [ "$c_epoch" -ne 0 ] && [ "$c_age" -lt "$a_age" ] \
         && [ "$c_age" -lt $(( SILENT_MINS * 60 )) ]; then
        # THE STATE THE OLD REPORT COULD NOT SEE. It is pushing work and cannot
        # attest — a dirty-start refusal, a failing gate, a push it cannot land.
        printf '%-24s attested %s ago BUT COMMITTED %s ago  <-- WEDGED, alive and failing\n' \
            "$host" "$(human "$a_age")" "$(human "$c_age")"
        wedged=$(( wedged + 1 ))
    elif rec="$(open_blocker_for "$host")"; then
        # Durable beats recent. The host said it was blocked and nothing has
        # said otherwise, so silence is EXPLAINED rather than suspicious.
        printf '%-24s %s  <-- BLOCKED (it said so): %s\n' \
            "$host" "$(human "$a_age")" "$rec"
        blocked=$(( blocked + 1 ))
    else
        printf '%-24s %s  <-- SILENT, no commits either (likely a dead terminal)\n' \
            "$host" "$(human "$a_age")"
        dead=$(( dead + 1 ))
    fi
done

if [ "$wedged" -gt 0 ] || [ "$blocked" -gt 0 ]; then
    echo "  A WEDGED or BLOCKED host needs its WORKTREE adjudicated, not a restart." >&2
    echo "  Read the record it filed about itself; it usually names the unblock path." >&2
fi
echo "ok:fleet-heartbeat:${healthy}/${wedged}/${blocked}/${dead}/${never}"
