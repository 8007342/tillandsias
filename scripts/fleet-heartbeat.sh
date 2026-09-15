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

# DECLARED identity, because git authorship is INCIDENTAL and one host already
# falls through it (order 872-k4pv).
#
# last_commit_epoch matches `git log --author=<roster name>`, which is a
# substring search over author name AND email. Measured 2026-08-24 across the
# roster:
#
#   pirria       16 commits   author "Laptopirria"  — matches by luck, the
#                                                     roster name is a substring
#   macuahuitl 1029 commits   author "Tlatoani"     — matches only via the email
#   yoga        232 commits   author "Tlatoāni"     — same
#   yolanda       0 commits   nothing matched at all
#
# So the WEDGED signal — "no attestation BUT recent commits" — is unreachable
# for yolanda: it can only ever be reported dead, which is precisely the
# confusion 864-t4nq was built to end. The probe worked for four hosts by
# coincidence of naming and silently failed for the fifth.
#
# A host's ledger events carry a DECLARED identity rather than whatever
# `git config user.name` happens to say. That is the identity to trust. The
# canonical grammar (scripts/agent-identity.sh, order 756-hn3a; enforced at
# write time by 874-idnt) is `<platform>-<workstation>-<backend>-<timestamp>`
# — the WORKSTATION is the second component, so the probe matches
# `-<host>-` after exactly one leading component. This comment used to
# document the shape as `<kind>-<host>-<model>-<stamp>`, codifying a deviant
# vocabulary the 2026-08-24 retrospective caught; the component CLASS below
# stays `[a-z0-9_]+` (a superset of the canonical `[a-z0-9]+`) so historic
# fragments whose first component was a kind label like `linux_mutable`
# still register as declarations — liveness must not forget the past to
# enforce the future. The match is anchored to the key at line start so an
# `agent_id:` mention inside prose can never count as a declaration.
last_declared_epoch() {
    local host="$1" newest="" f ts
    for f in plan/index.d/*.yaml; do
        [ -f "$f" ] || continue
        grep -qE "^[[:space:]]*agent_id:[[:space:]]*[a-z0-9_]+-${host}-" "$f" 2>/dev/null || continue
        ts="$(grep -oE '^[[:space:]]*ts:[[:space:]]*"?20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' "$f" 2>/dev/null \
              | grep -oE '20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' | sort | tail -1)"
        [ -n "$ts" ] || continue
        if [ -z "$newest" ] || [ "$ts" \> "$newest" ]; then newest="$ts"; fi
    done
    [ -n "$newest" ] || { echo 0; return; }
    iso_to_epoch "$newest"
}

# The host was active if EITHER signal says so. Keeping the git probe rather
# than replacing it: it sees work that never reached a ledger fragment, which
# the declared probe cannot.
last_activity_epoch() {
    local a b
    a="$(last_commit_epoch "$1")"
    b="$(last_declared_epoch "$1")"
    [ "$a" -ge "$b" ] && echo "$a" || echo "$b"
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
    # ORDER 1196-5hva — THE LEDGER IS THE SECOND SOURCE, AND TODAY IT IS THE
    # LIVE ONE.
    #
    # The markdown field above is not broken, it is UNREACHABLE. Measured by
    # macneo 2026-09-15 with `git log -S` over the project's whole history:
    # `- Status: blocked` has been written TWICE, ever, and zero times today,
    # while the bullet form carries six other values in 16 live occurrences and
    # the control (`Status:` anywhere) matches 139 commits. Hosts record
    # blockers as ledger packets now. A detector whose one trigger value is the
    # one nobody writes reports nothing and looks healthy doing it.
    #
    # ATTRIBUTION IS BY CAPABILITY, NEVER BY HOST NAME. Operator ruling,
    # 2026-09-15, and it retired this function's first implementation before it
    # landed — that version keyed on the status channel's `host:` field, which
    # reads "blocked by yoga".
    #
    # THE FLEET IS AN IMPLEMENTATION DETAIL. Which hosts exist, how many, what
    # hardware they carry, which agents and harnesses run them — all ephemeral,
    # all expected to change, and the whole thing is meant to converge on
    # "forge" and be agent-agnostic. A blocker keyed to `lenovinha` is a fact
    # about a machine that may not exist next week, and every consumer of it
    # would have to be rewritten when it does not. A blocker keyed to
    # `kind:macos` or `schedulable:npu` stays true about whatever host answers
    # that description, including hosts nobody has built yet.
    #
    # DO NOT OVER-APPLY THIS TO EVERY host: FIELD IN THE LEDGER (macuahuitl,
    # 2026-09-15). A CLAIM and a BLOCKER are the same field family with opposite
    # lifetimes. `status in_progress --host lenovinha` is a TRANSIENT fact about
    # who holds a row right now: it is read within the hour, it expires, and the
    # selector needs the host identity to separate concurrent hosts — stripping
    # it would break claiming. A BLOCKER is a DURABLE statement about what the
    # row NEEDS, outliving any particular machine, so it must be a capability.
    # Host-keyed claims stay; host-keyed blockers go.
    #
    # And the capability is DERIVED AT READ TIME from the matrix below rather
    # than stored beside the block, so a host that is renamed, retired or
    # re-specced changes nothing in the ledger and no stored copy goes stale.
    #
    # So `blocked_by:` carries CAPABILITY TOKENS drawn from the vocabulary the
    # capability matrix already publishes — kind:, locus:, tier:, schedulable: —
    # and a host matches when it answers one of them. No new inventory, no
    # hardcoded roster, and a token naming a capability no current host has
    # simply matches nothing rather than erroring: that is the CRDT-shaped
    # behaviour, where a fact can be written before or after the thing it
    # describes exists.
    #
    # THE FRAGMENT IS ONLY THE ATTRIBUTION, NEVER THE TRUTH. Whether the packet
    # is STILL blocked is asked of the folded ledger, because a later fragment
    # can have unblocked it and the channel is last-write-wins. Reading the raw
    # fragment alone would resurrect every block ever set and expire none — a
    # detector that can only say "blocked", which fails exactly as badly as one
    # that can only say nothing.
    #
    # No plan binary means no ledger source and the markdown source stands
    # alone, exactly as before this order: a host that cannot fold the ledger
    # must not invent blockers from fragments it cannot verify.
    [ -n "${_FH_BLOCKED_SET:-}" ] || return 1
    local tokens order tok
    # BOTH KINDS OF TOKEN ARE ACCEPTED, ADDITIVELY (operator, 2026-09-15:
    # "use both: CRDT style"). A token carrying a colon is a CAPABILITY
    # (kind:macos, schedulable:npu, tier:gpu-rocm) and matches whatever host
    # answers to it; a bare token is a HOST IDENTITY and matches that host.
    #
    # Union, not choice, and that is the CRDT-shaped part: two writers can name
    # the same block differently — one by capability, one by the machine in
    # front of it — and neither write has to know about the other or be
    # rewritten later. A capability token keeps working when the roster turns
    # over, a host token keeps working for a here-and-now block on a named
    # machine, and a reader that meets a token kind it does not understand
    # simply does not match rather than failing.
    tokens=" $(host_capability_tokens "$host") $host "
    while read -r order tok; do
        [ -n "$order" ] || continue
        case " $_FH_BLOCKED_SET " in *" $order "*) ;; *) continue ;; esac
        case "$tokens" in
            *" $tok "*) printf 'ledger packet %s (blocked_by: %s)\n' "$order" "$tok"; return 0 ;;
        esac
    done <<EOF
$(ledger_blocked_by_pairs)
EOF
    return 1
}

# The capability tokens a host answers to, from the matrix this script already
# uses for its roster. Vocabulary is whatever the matrix publishes, so it grows
# on its own as hosts declare new facts; nothing here enumerates hosts.
host_capability_tokens() {
    local host="$1"
    [ -n "${PLAN:-}" ] || return 0
    "$PLAN" capability-matrix 2>/dev/null | awk -v want="$host" '
        /^host:/ {
            inhost = 0
            for (i = 1; i <= NF; i++) {
                if ($i == "host:" want) inhost = 1
                if (inhost && $i ~ /^kind:/)         print $i
                if (inhost && $i ~ /^locus:/)        print $i
                if (inhost && $i ~ /^derived_tier:/) { t = $i; sub(/^derived_tier:/, "tier:", t); print t }
            }
            next
        }
        inhost && /^[[:space:]]*schedulable:/ {
            # schedulable: <class>/<lane>/<engine> -> schedulable:<class> and the
            # full triple, so a blocker can name either breadth.
            line = $0; sub(/^[[:space:]]*schedulable:[[:space:]]*/, "", line)
            if (line == "none") next
            print "schedulable:" line
            split(line, p, "/"); print "schedulable:" p[1]
        }
    ' | sort -u | tr '\n' ' '
}

# (order, capability-token) pairs from every `blocked_by` the ledger carries —
# a packet declaration or an LWW correction, later ts winning. Attribution only;
# the caller confirms each order against the folded blocked set.
ledger_blocked_by_pairs() {
    # ONLY PASS FILES THAT EXIST. awk aborts on a missing operand and never runs
    # its END block, so the whole result is silently empty — and `2>/dev/null`
    # hides the reason. A checkout with no plan/index.yaml (a fresh clone, a
    # scratch tree, a forge that mounts only fragments) would have reported
    # "no blockers" rather than "could not look", which is the exact failure
    # class this row is about.
    local -a _files=()
    local _f
    for _f in plan/index.d/*.yaml plan/index.yaml; do
        [ -f "$_f" ] && _files+=("$_f")
    done
    [ "${#_files[@]}" -gt 0 ] || return 0
    awk '
        function flush() {
            if (pid != "" && by != "") {
                if (!(pid in best_ts) || ts >= best_ts[pid]) { best_ts[pid] = ts; best_by[pid] = by }
            }
            if (pid != "" && ord != "") ord_of[pid] = ord
        }
        /^[[:space:]]*-[[:space:]]*packet_id:/ { flush(); pid=$0; sub(/^[^:]*:[[:space:]]*/,"",pid); by=""; ts=""; ord="" ; next }
        /^[[:space:]]*order:/       { ord=$0; sub(/^[^:]*:[[:space:]]*/,"",ord); next }
        /^[[:space:]]*ts:/          { ts=$0;  sub(/^[^:]*:[[:space:]]*/,"",ts); gsub(/"/,"",ts); next }
        /^[[:space:]]*blocked_by:/  { by=$0;  sub(/^[^:]*:[[:space:]]*/,"",by); gsub(/[",]/," ",by); next }
        /^[[:space:]]*field:[[:space:]]*blocked_by/ { isfield=1; next }
        /^[[:space:]]*value:/       { if (isfield) { by=$0; sub(/^[^:]*:[[:space:]]*/,"",by); gsub(/[",]/," ",by); isfield=0 } next }
        END {
            flush()
            for (p in best_by) {
                n = split(best_by[p], toks, " ")
                for (i = 1; i <= n; i++)
                    if (toks[i] != "") print (p in ord_of ? ord_of[p] : p), toks[i]
            }
        }
    ' "${_files[@]}" 2>/dev/null
}

# ORDER 1196-5hva. The authoritative "is it blocked NOW" set, folded once.
# Empty when no plan binary resolved, which disables the ledger source rather
# than guessing from unfoldable fragments.
_FH_BLOCKED_SET=""
if [ -n "${PLAN:-}" ]; then
    _FH_BLOCKED_SET="$("$PLAN" query --status blocked --limit 1000 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
fi

healthy=0; wedged=0; dead=0; never=0; blocked=0; stale_record=0
for host in $roster; do
    f="$ATTEST_DIR/$host.md"
    a_epoch=0
    [ -f "$f" ] && a_epoch="$(last_attest_epoch "$f")"
    c_epoch="$(last_activity_epoch "$host")"

    a_age=$(( NOW - a_epoch )); [ "$a_epoch" -eq 0 ] && a_age=-1
    c_age=$(( NOW - c_epoch )); [ "$c_epoch" -eq 0 ] && c_age=-1

    if [ "$a_epoch" -eq 0 ]; then
        if [ "$c_epoch" -ne 0 ] && [ "$c_age" -lt $(( SILENT_MINS * 60 )) ]; then
            printf '%-24s NEVER ATTESTED but active %s ago  <-- ALIVE, NOT ATTESTING\n' \
                "$host" "$(human "$c_age")"
        else
            printf '%-24s NEVER ATTESTED, no recent commits\n' "$host"
        fi
        never=$(( never + 1 ))
        continue
    fi

    if [ "$a_age" -le $(( SILENT_MINS * 60 )) ]; then
        # ATTESTING IS NOT THE SAME AS UNBLOCKED (order 872-c9nd, 2026-08-24).
        #
        # 864-t4nq taught this report to see WEDGED; 864-w7rc taught it to keep
        # saying BLOCKED after the commits stop. Both assumed a wedge ends when
        # someone RESOLVES it. yoga's ended when its wedged checkout was
        # REPLACED BY A FRESH CLONE, destroying four hours of finished,
        # uncommitted 642-fedr/776-cm74 work. The host then attested normally
        # from the clean clone and this report called it healthy — while its own
        # filed record still read `Status: blocked` and the work it described
        # was gone.
        #
        # The signal could not tell "unwedged" from "wedge deleted", because
        # both look like a host that started attesting again.
        #
        # So a host that IS attesting is not reclassified — it really is
        # cycling, and calling it blocked would be its own kind of lie — but an
        # open blocker it filed about ITSELF is surfaced beside it. Exactly one
        # of two things is then true, and both want someone's attention: the
        # record is stale and should be closed, or the block outlived the
        # symptom that made it visible.
        if rec="$(open_blocker_for "$host")"; then
            printf '%-24s %s  <-- attesting, but its own blocker is still OPEN: %s\n' \
                "$host" "$(human "$a_age")" "$rec"
            stale_record=$(( stale_record + 1 ))
        else
            printf '%-24s %s\n' "$host" "$(human "$a_age")"
        fi
        healthy=$(( healthy + 1 ))
    elif [ "$c_epoch" -ne 0 ] && [ "$c_age" -lt "$a_age" ] \
         && [ "$c_age" -lt $(( SILENT_MINS * 60 )) ]; then
        # THE STATE THE OLD REPORT COULD NOT SEE. It is pushing work and cannot
        # attest — a dirty-start refusal, a failing gate, a push it cannot land.
        #
        # ORDER 1196-5hva — ASK WHETHER IT IS EXPLAINED BEFORE CALLING IT A
        # WEDGE. This branch is evaluated BEFORE the blocked branch and returns
        # first, so a host that keeps committing never reached open_blocker_for
        # at all. That is not a corner case: a blocked host's most useful
        # response is to FILE what blocked it, which is a commit, which pinned
        # it here. macbookair filed three packets during the 1193-yw6u window
        # and would still have read WEDGED with a perfect blocker source, because
        # nothing asked.
        #
        # The distinction is the whole point of the report. WEDGED prescribes
        # "adjudicate its worktree" — go hunt local dirt. When the host has
        # already said what is wrong, that advice points AWAY from the fix, and
        # during 1193-yw6u the cause was a trunk-wide red another host had
        # already diagnosed. So an explained one is still shown as alive and
        # failing, and is named BLOCKED, because that is the response its reader
        # should have.
        if rec="$(open_blocker_for "$host")"; then
            printf '%-24s attested %s ago BUT ACTIVE %s ago  <-- BLOCKED, alive and failing (it said so): %s\n' \
                "$host" "$(human "$a_age")" "$(human "$c_age")" "$rec"
            blocked=$(( blocked + 1 ))
        else
            printf '%-24s attested %s ago BUT ACTIVE %s ago  <-- WEDGED, alive and failing\n' \
                "$host" "$(human "$a_age")" "$(human "$c_age")"
            wedged=$(( wedged + 1 ))
        fi
    elif rec="$(open_blocker_for "$host")"; then
        # Durable beats recent. The host said it was blocked and nothing has
        # said otherwise, so silence is EXPLAINED rather than suspicious.
        printf '%-24s %s  <-- BLOCKED (it said so): %s\n' \
            "$host" "$(human "$a_age")" "$rec"
        blocked=$(( blocked + 1 ))
    else
        printf '%-24s %s  <-- SILENT, no activity either (likely a dead terminal)\n' \
            "$host" "$(human "$a_age")"
        dead=$(( dead + 1 ))
    fi
done

if [ "$stale_record" -gt 0 ]; then
    echo "  A host can ATTEST and still be blocked: its record outlives the symptom." >&2
    echo "  Either close the record or say why the block persists — 872-c9nd is the case" >&2
    echo "  where a wedge 'ended' by the work being destroyed, and the host looked fine." >&2
fi
if [ "$wedged" -gt 0 ] || [ "$blocked" -gt 0 ]; then
    echo "  A WEDGED or BLOCKED host needs its WORKTREE adjudicated, not a restart." >&2
    echo "  Read the record it filed about itself; it usually names the unblock path." >&2
fi
echo "ok:fleet-heartbeat:${healthy}/${wedged}/${blocked}/${dead}/${never}"
