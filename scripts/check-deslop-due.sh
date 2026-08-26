#!/usr/bin/env bash
# freshness: added 2026-08-21 linux-macuahuitl (order 829-dkuc)
# @trace order:829-dkuc, spec:methodology-accountability
#
# check-deslop-due.sh — the de-slop sweep's TRIGGER CLOCK.
#
# Answers exactly one question: has enough WORK happened since the last de-slop
# sweep that another one is worth running? It decides nothing else. It does not
# run the sweep, it does not judge the sweep's output, and it is NOT a build
# gate — it is a scheduler input the meta-orchestration cycle consults (see
# skills/meta-orchestration/SKILL.md → "De-slop sweep clock").
#
# ── THE RULE (settled by operator ruling; do not redesign here) ──────────────
#
#   DUE when   (current_order - order_at_last_sweep) >= 200      [event count]
#   FLOOR      never twice inside 48h                            [burst guard]
#   CEILING    none. Deliberate. See below.
#
# EVENT-COUNTED, NOT CALENDAR-COUNTED. `tillandsias-plan next-order` is already
# a monotone, collision-free, durable, host-skew-free, side-effect-free counter,
# and it advances with WORK — the thing that actually accumulates the slop the
# sweep removes. A quiet week should not trigger a sweep; a 900-commit burst
# should. Lamport clocks count events, and this is the project's Lamport clock.
#
# THE 48h FLOOR exists because the event counter can be satisfied by a filing
# BURST. Two hundred orders can land in an afternoon when a host is splitting
# packets; without the floor the clock would fire two sweeps in one day, and the
# second would examine rows the first had just examined.
#
# WHY THERE IS NO CALENDAR CEILING, and this is the part a future editor will be
# tempted to "fix": a ceiling ("sweep at least every 7 days") interacts FATALLY
# with the sweep's own kill rule. The sweep retires itself on
# `red:two-sweeps-zero-confirmed`. A quiet fortnight under a ceiling fires two
# sweeps over a queue that accumulated almost nothing, both come back with zero
# confirmed findings — correctly, because there was nothing to find — and the
# kill rule then retires the reconciler for doing nothing wrong. The ceiling
# would manufacture the exact evidence that kills the thing it is scheduling.
#
# The usual argument for a ceiling is "some slop decays with time, not with
# work". That is true and it is already covered elsewhere: claim staleness by
# `expire-claims` (24h TTL) and component staleness by `component_freshness`.
# Time-decaying properties have their own TTLs. The sweep need not carry them.
#
# ── CALIBRATION FROM THE FIRST REAL SWEEP (2026-08-19, commit 345bb8ed) ──────
#
# The first retraction pass yielded 51 of 410 rows — 12.4%, against a modelled
# ~50%. That first pass drained ACCUMULATED STOCK. Steady-state yield will be
# far lower, because the steady-state rate is the rate at which filed work goes
# stale, not the stock of stale work already sitting there.
#
# CONSEQUENCE FOR THE KILL RULE, recorded here because this clock is what sets
# the window the kill rule counts over: at a steady-state yield plausibly near
# zero for a >=200-order window, TWO CONSECUTIVE NEAR-ZERO SWEEPS IS A NORMAL
# OUTCOME FOR A HEALTHY QUEUE, not evidence the reconciler is broken. A sweep
# that confirms the queue is clean has done its job. The kill rule must count
# only sweeps that EXAMINED NEW ROWS — which is why `record` refuses without
# `--examined` and `--confirmed`, and why every record carries both. This
# script does not evaluate the kill rule; it makes the kill rule computable.
#
# ── WHY THE MARKER IS COMMITTED, NOT A HOST-LOCAL DOTFILE ────────────────────
#
# The sweep operates on the SHARED plan ledger, so "when did the last sweep run"
# is a fleet-wide fact with exactly one true answer. A dotfile under
# ${XDG_CACHE_HOME}/tillandsias (the shape check-daily-maintenance.sh uses, and
# correctly — daily maintenance IS host-local) would give every host its own
# private clock: macuahuitl sweeps, yoga's cache knows nothing about it, yoga
# sweeps the same rows a day later. So the marker lives in the repo, at
#
#   plan/deslop-sweeps.d/<host>.md
#
# — one file per host so concurrent hosts append without merge conflicts, the
# same fragment philosophy as plan/mo-full-attestations.d/ (651-2x5s) and
# plan/loop_status.d/ (582-nqw5). The CLOCK is fleet-wide even though the FILES
# are per-host: the reader folds every file in the directory and takes the
# highest `order=` as the last sweep, and the latest heading timestamp as the
# time of the last sweep. Which host ran it is provenance, not input.
#
# NO FORGE EXEMPTION, deliberately, and this is a considered departure from
# check-daily-maintenance.sh. That gate exempts ephemeral forges because they
# discard the substrate its body garbage-collects — there is genuinely nothing
# for a forge to do. Here the input is a COMMITTED ledger that a forge has a
# complete copy of, so a forge computes the same answer as any other host. An
# exemption would only make the clock lie on the host where the cycle most often
# runs. Nothing here is a build gate, so there is no gate to exempt it from.
#
# ── GRAMMAR (exactly one line on stdout) ─────────────────────────────────────
#
#   ok:deslop-due:order=<n> last=<n> delta=<n> hours=<n> reason=event-count
#   ok:deslop-due:order=<n> last=none delta=none hours=none reason=no-record
#   ok:deslop-not-due:order=<n> last=<n> delta=<n> hours=<n> reason=under-threshold
#   ok:deslop-not-due:order=<n> last=<n> delta=<n> hours=<n> reason=floor-48h
#   ok:deslop-recorded:order=<n> host=<h> examined=<n> confirmed=<n>
#   fail:deslop-due:<reason>[:<detail>]
#
# `fail:` is reserved for CANNOT COMPUTE — no runnable plan binary, a plan
# binary too old to mint an order, an unparseable record, an unwritable ledger.
# "not due" is not a failure and "due" is not a failure; both are the clock
# working. Every ok: line carries the four numbers it decided on, so the
# decision is re-derivable from the verdict alone without re-reading the ledger.
#
# ── EXIT CODES, AND READ THIS BEFORE WIRING A CALLER ─────────────────────────
#
#   0  not due        1  due        2  cannot compute / usage
#
# THE POLARITY IS INVERTED RELATIVE TO THE FILE NAME and that is on purpose, so
# say it plainly rather than let someone discover it: `check-deslop-due.sh`
# exiting 0 means the sweep is NOT due. This matches the already-litigated
# convention of check-daily-maintenance.sh, where the actionable state (`due:`)
# is the non-zero one, and it keeps the healthy steady state — "nothing to do" —
# at exit 0 where a caller running under `set -e` will not abort on it. The
# caller idiom is therefore:
#
#   if ! scripts/check-deslop-due.sh; then run_the_sweep; fi
#
# A caller that cannot afford to be wrong about this should branch on the
# VERDICT TOKEN (`deslop-due` vs `deslop-not-due`), which cannot be inverted by
# a copy-paste. The fixture pins both the tokens and the exit codes so a later
# edit cannot silently flip either.
#
# ── SUBCOMMANDS ──────────────────────────────────────────────────────────────
#
#   check                                the verdict (default)
#   record --examined <n> --confirmed <n> [--findings <n>] [--retracted <n>]
#          [--filed <n>] [--net-lines <±n>] [--order <n>] [--host <h>]
#                                        append this sweep to the ledger
#   show                                 print every record, newest last
#   fixture                              hermetic self-test
#
# Seams (used by the fixture and by the mutation control):
#   TILLANDSIAS_DESLOP_LEDGER_DIR    ledger directory
#   TILLANDSIAS_DESLOP_CURRENT_ORDER force the current order (skips the binary)
#   TILLANDSIAS_DESLOP_NOW           force "now" as an ISO-UTC timestamp

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || { echo "fail:deslop-due:no-repo-root"; exit 2; }

# shellcheck source=scripts/plan-binary-probe.sh
. "$ROOT/scripts/plan-binary-probe.sh"

LEDGER_DIR="${TILLANDSIAS_DESLOP_LEDGER_DIR:-$ROOT/plan/deslop-sweeps.d}"

# The two constants the whole file exists to apply. Not overridable by
# environment: a clock whose threshold a caller can dial is not a clock, and the
# fixture drives the DATA (order, timestamp) rather than the rule.
THRESHOLD_ORDERS=200
FLOOR_SECONDS=172800   # 48h

# ── Time ─────────────────────────────────────────────────────────────────────
#
# ISO-UTC to epoch seconds WITHOUT `date -d` (GNU) or `date -j -f` (BSD). This
# family has already cost the project one silent cross-platform failure — the
# `\b` GNU-sed extension that made three markers write-only on macOS while every
# self-test passed on Linux (order 803-bqte). Days-from-civil is ten lines of
# arithmetic that behaves identically under gawk, mawk and the one-true-awk, and
# it removes the question rather than answering it per platform. No regex
# interval expressions either ({4} is not portable across awks).
_iso_to_epoch() {
    awk -v s="$1" '
        function dfc(y, m, d,   era, yoe, doy, doe) {
            if (m <= 2) y -= 1
            era = int((y >= 0 ? y : y - 399) / 400)
            yoe = y - era * 400
            doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
            doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
            return era * 146097 + doe - 719468
        }
        BEGIN {
            if (s !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/)
                exit 3
            printf "%d\n", dfc(substr(s,1,4)+0, substr(s,6,2)+0, substr(s,9,2)+0) * 86400 \
                         + (substr(s,12,2)+0) * 3600 + (substr(s,15,2)+0) * 60 + (substr(s,18,2)+0)
        }'
}

_now_iso() {
    if [ -n "${TILLANDSIAS_DESLOP_NOW:-}" ]; then
        printf '%s\n' "$TILLANDSIAS_DESLOP_NOW"
        return 0
    fi
    date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

# ── The current order ────────────────────────────────────────────────────────
#
# `next-order` prints `<prefix>-<suffix>` where the prefix is (highest existing
# order + 1). Only the prefix is the counter; the suffix is collision avoidance.
# Reading it has no side effects — verified by running it twice against a clean
# tree and re-checking `git status`.
#
# Resolved through the shared probe, never a hardcoded target/ path: an
# executable BIT is a claim, RUNNING the binary is evidence (704-zcgi, 721-nyev).
_current_order() {
    local plan tok
    if [ -n "${TILLANDSIAS_DESLOP_CURRENT_ORDER:-}" ]; then
        printf '%s\n' "$TILLANDSIAS_DESLOP_CURRENT_ORDER"
        return 0
    fi
    plan="$(resolve_plan_binary)" || return 1
    # A binary that predates the subcommand is HOST STATE, not a finding. Saying
    # so by name is the 702-68zj lesson: a stale binary once produced a red gate
    # naming three violations that did not exist.
    plan_binary_has "$plan" next-order || return 2
    tok="$("$plan" next-order 2>/dev/null)" || return 3
    tok="${tok%%-*}"
    case "$tok" in ''|*[!0-9]*) return 4 ;; esac
    printf '%s\n' "$tok"
}

_fail_order() { # _fail_order <rc-from-_current_order>
    case "$1" in
        1) echo "fail:deslop-due:no-plan-binary:no runnable tillandsias-plan (see scripts/plan-binary-probe.sh)" ;;
        2) echo "fail:deslop-due:stale-plan-binary:this binary does not carry next-order" ;;
        *) echo "fail:deslop-due:unreadable-order:next-order did not print a numeric prefix" ;;
    esac
}

# ── The ledger ───────────────────────────────────────────────────────────────
#
# Emits one `REC <ts> <order> <file> <line>` per well-formed record and one
# `BAD <file> <line>` per malformed one. Field reads are SPACE-SPLIT AND
# ANCHORED (`^order=[0-9]+$`) rather than boundary-matched, so a record may grow
# new fields in any order without breaking this reader, and no GNU-only regex
# atom is involved (803-bqte). README.md is skipped by the caller's glob and
# would in any case carry no column-0 DESLOP-SWEEP line.
_scan_ledger() {
    local files=()
    local f
    for f in "$LEDGER_DIR"/*.md; do
        [ -f "$f" ] || continue
        case "$(basename "$f")" in README.md) continue ;; esac
        files+=("$f")
    done
    [ "${#files[@]}" -gt 0 ] || return 0
    awk '
        FNR == 1 { ts = "" }
        /^## / {
            ts = ""
            if ($0 ~ /^## [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z [^ ]+$/)
                ts = $2
            next
        }
        /^DESLOP-SWEEP:/ {
            ord = ""
            for (i = 2; i <= NF; i++)
                if ($i ~ /^order=[0-9]+$/) ord = substr($i, 7)
            if (ts == "" || ord == "") { printf "BAD %s %d\n", FILENAME, FNR; next }
            printf "REC %s %s %s %d\n", ts, ord, FILENAME, FNR
        }
    ' "${files[@]}"
}

_host_label() {
    # ONE implementation of the host label for the whole fleet: the shared probe
    # in scripts/agent-identity.sh, which is also what mo-full-attest.sh uses
    # (743-mgf3). Two ledgers keyed by two notions of "this host" would be a
    # divergent-duplicate of exactly the kind the sweep retracts.
    if [ -n "${TILLANDSIAS_DESLOP_HOST:-}" ]; then
        printf '%s\n' "$TILLANDSIAS_DESLOP_HOST"
        return 0
    fi
    if [ -r "$ROOT/scripts/agent-identity.sh" ]; then
        # shellcheck source=scripts/agent-identity.sh
        . "$ROOT/scripts/agent-identity.sh" 2>/dev/null
        if command -v tillandsias_node_name >/dev/null 2>&1; then
            tillandsias_node_name
            printf '\n'
            return 0
        fi
    fi
    uname -n 2>/dev/null | tr '[:upper:]' '[:lower:]' | cut -d. -f1
}

_is_uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
_is_int()  { case "${1:-}" in -*) _is_uint "${1#-}" ;; *) _is_uint "${1:-}" ;; esac; }

# ── check ────────────────────────────────────────────────────────────────────
do_check() {
    local cur rc scan last_order="" last_ts="" now now_epoch last_epoch delta elapsed hours

    cur="$(_current_order)" || { rc=$?; _fail_order "$rc"; return 2; }
    _is_uint "$cur" || { echo "fail:deslop-due:unreadable-order:$cur"; return 2; }

    scan="$(_scan_ledger)"
    if grep -q '^BAD ' <<<"$scan"; then
        # Present but unparseable is CANNOT COMPUTE, never "no record". Reading a
        # corrupt ledger as empty would fire a sweep off a lie, and reading it as
        # current would suppress one — both are worse than refusing.
        echo "fail:deslop-due:unparseable-record:$(awk '$1=="BAD"{print $2":"$3; exit}' <<<"$scan")"
        return 2
    fi

    # Highest order wins for the DELTA anchor; latest timestamp wins for the
    # FLOOR. They are the same record in practice, and when they are not, each
    # rule still gets the number it actually asks for: "how much work since the
    # furthest-along sweep" and "how long since ANY sweep". ISO-UTC sorts
    # lexically, so `sort` is the chronological order.
    if [ -n "$scan" ]; then
        last_order="$(awk '$1=="REC"{print $3}' <<<"$scan" | sort -n | tail -1)"
        last_ts="$(awk '$1=="REC"{print $2}' <<<"$scan" | sort | tail -1)"
    fi

    if [ -z "$last_order" ]; then
        echo "ok:deslop-due:order=$cur last=none delta=none hours=none reason=no-record"
        return 1
    fi

    now="$(_now_iso)"
    now_epoch="$(_iso_to_epoch "$now")" || {
        echo "fail:deslop-due:unreadable-clock:$now"
        return 2
    }
    last_epoch="$(_iso_to_epoch "$last_ts")" || {
        echo "fail:deslop-due:unparseable-timestamp:$last_ts"
        return 2
    }
    [ -n "$now_epoch" ] && [ -n "$last_epoch" ] || {
        echo "fail:deslop-due:unreadable-clock:$now"
        return 2
    }

    delta=$((cur - last_order))
    elapsed=$((now_epoch - last_epoch))
    hours=$((elapsed / 3600))

    if [ "$delta" -lt "$THRESHOLD_ORDERS" ]; then
        echo "ok:deslop-not-due:order=$cur last=$last_order delta=$delta hours=$hours reason=under-threshold"
        return 0
    fi
    if [ "$elapsed" -lt "$FLOOR_SECONDS" ]; then
        echo "ok:deslop-not-due:order=$cur last=$last_order delta=$delta hours=$hours reason=floor-48h"
        return 0
    fi
    echo "ok:deslop-due:order=$cur last=$last_order delta=$delta hours=$hours reason=event-count"
    return 1
}

# ── record ───────────────────────────────────────────────────────────────────
do_record() {
    local examined="" confirmed="" findings="" retracted="" filed="" net_lines=""
    local order="" host="" ts ledger line rc v

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --examined)  examined="${2:-}";  shift 2 || shift ;;
            --confirmed) confirmed="${2:-}"; shift 2 || shift ;;
            --findings)  findings="${2:-}";  shift 2 || shift ;;
            --retracted) retracted="${2:-}"; shift 2 || shift ;;
            --filed)     filed="${2:-}";     shift 2 || shift ;;
            --net-lines) net_lines="${2:-}"; shift 2 || shift ;;
            --order)     order="${2:-}";     shift 2 || shift ;;
            --host)      host="${2:-}";      shift 2 || shift ;;
            *) shift ;;
        esac
    done

    # EXAMINED AND CONFIRMED ARE MANDATORY. The kill rule counts only sweeps that
    # examined new rows (see the calibration above); a record without those two
    # numbers cannot be counted either way, and a ledger of uncountable records
    # is the unfalsifiability this whole mechanism removes, reintroduced one
    # level up. The refusal prints the argv that works (801-ajcd).
    if ! _is_uint "$examined" || ! _is_uint "$confirmed"; then
        echo "fail:deslop-due:record-needs-evidence:usage: check-deslop-due.sh record --examined <rows-this-sweep-actually-looked-at> --confirmed <findings-that-led-to-a-deletion-or-an-armed-guard> [--findings n] [--retracted n] [--filed n] [--net-lines n] [--host h]; the kill rule counts only sweeps that examined new rows, so a record missing either number cannot be counted"
        return 2
    fi
    for v in "$findings" "$retracted" "$filed"; do
        [ -z "$v" ] && continue
        _is_uint "$v" || { echo "fail:deslop-due:record-non-numeric:$v"; return 2; }
    done
    if [ -n "$net_lines" ]; then
        _is_int "$net_lines" || { echo "fail:deslop-due:record-non-numeric:$net_lines"; return 2; }
    fi

    if [ -z "$order" ]; then
        order="$(_current_order)" || { rc=$?; _fail_order "$rc"; return 2; }
    fi
    _is_uint "$order" || { echo "fail:deslop-due:record-non-numeric:$order"; return 2; }

    ts="$(_now_iso)"
    _iso_to_epoch "$ts" >/dev/null || { echo "fail:deslop-due:unreadable-clock:$ts"; return 2; }

    [ -n "$host" ] || host="$(_host_label)"
    case "$host" in ''|*[![:alnum:]._-]*) echo "fail:deslop-due:bad-host-label:$host"; return 2 ;; esac

    line="DESLOP-SWEEP: order=$order examined=$examined confirmed=$confirmed"
    [ -n "$findings" ]  && line="$line findings=$findings"
    [ -n "$retracted" ] && line="$line retracted=$retracted"
    [ -n "$filed" ]     && line="$line filed=$filed"
    [ -n "$net_lines" ] && line="$line net_lines=$net_lines"

    ledger="$LEDGER_DIR/$host.md"
    mkdir -p "$LEDGER_DIR" 2>/dev/null
    if [ ! -f "$ledger" ]; then
        {
            printf '%s\n' \
                "# De-slop sweep ledger — $host.md (see scripts/check-deslop-due.sh)" \
                "# One record per completed sweep, appended by: check-deslop-due.sh record" \
                "# Grammar: DESLOP-SWEEP: order=<n> examined=<n> confirmed=<n> [findings=<n>] [retracted=<n>] [filed=<n>] [net_lines=<±n>]" \
                "# Read by: check-deslop-due.sh check — highest order= is the delta anchor, latest heading is the 48h floor."
        } >>"$ledger" 2>/dev/null || {
            echo "fail:deslop-due:unwritable-ledger:$ledger"
            return 2
        }
    fi
    printf '\n## %s %s\n%s\n' "$ts" "$host" "$line" >>"$ledger" 2>/dev/null || {
        # An unwritable ledger must be loud. Silently "succeeding" would leave
        # the clock anchored to the previous sweep forever, so the next cycle
        # would re-sweep rows this one just cleared and never learn why.
        echo "fail:deslop-due:unwritable-ledger:$ledger"
        return 2
    }
    echo "ok:deslop-recorded:order=$order host=$host examined=$examined confirmed=$confirmed"
    return 0
}

# ── fixture ──────────────────────────────────────────────────────────────────
do_fixture() {
    local fail=0 dir self got rc want_v want_rc n lines

    self="$ROOT/scripts/check-deslop-due.sh"
    dir="$(mktemp -d "${TMPDIR:-/tmp}/deslop-due-fixture.XXXXXX")"

    _run() { # _run <args...>   env supplied by _FX_* below
        TILLANDSIAS_DESLOP_LEDGER_DIR="$dir/ledger" \
        TILLANDSIAS_DESLOP_CURRENT_ORDER="${_FX_ORDER:-1000}" \
        TILLANDSIAS_DESLOP_NOW="${_FX_NOW:-2026-08-21T12:00:00Z}" \
        TILLANDSIAS_DESLOP_HOST="${_FX_HOST:-fixturehost}" \
            bash "$self" "$@"
    }
    _expect() { # _expect <name> <want-verdict> <want-rc> <args...>
        n="$1"; want_v="$2"; want_rc="$3"; shift 3
        got="$(_run "$@" 2>/dev/null)"; rc=$?
        if [ "$got" = "$want_v" ] && [ "$rc" = "$want_rc" ]; then
            echo "ok: $n ($got rc=$rc)"
        else
            echo "FAIL: $n expected '$want_v' rc=$want_rc, got '$got' rc=$rc"
            fail=1
        fi
    }
    _marker() { # _marker <host> <ts> <order>
        mkdir -p "$dir/ledger"
        printf '\n## %s %s\nDESLOP-SWEEP: order=%s examined=410 confirmed=51\n' \
            "$2" "$1" "$3" >>"$dir/ledger/$1.md"
    }

    # 1. THE BOOTSTRAP STATE. An empty ledger is a VERDICT (due, reason=no-record),
    #    not silence and not a failure — there is no anchor, so the first sweep
    #    establishes one.
    _expect "empty-ledger-is-due-with-no-record" \
        "ok:deslop-due:order=1000 last=none delta=none hours=none reason=no-record" 1 check

    # 2. DELTA 199 — one short of the threshold. The negative control for the
    #    whole event counter: without it, a clock stuck at "due" passes case 3.
    _marker fixturehost 2026-08-01T12:00:00Z 801
    _expect "delta-199-is-not-due" \
        "ok:deslop-not-due:order=1000 last=801 delta=199 hours=480 reason=under-threshold" 0 check

    # 3. DELTA 200 exactly, well past the floor — DUE. Boundary is >=, not >.
    rm -rf "$dir/ledger"
    _marker fixturehost 2026-08-01T12:00:00Z 800
    _expect "delta-200-is-due" \
        "ok:deslop-due:order=1000 last=800 delta=200 hours=480 reason=event-count" 1 check

    # 4. DELTA 200 but only 3h since the last sweep — the FLOOR wins. This is the
    #    filing-burst case the floor exists for: 200 orders can land in an
    #    afternoon, and the second sweep would re-examine the first one's rows.
    rm -rf "$dir/ledger"
    _marker fixturehost 2026-08-21T09:00:00Z 800
    _expect "delta-200-inside-48h-is-blocked-by-the-floor" \
        "ok:deslop-not-due:order=1000 last=800 delta=200 hours=3 reason=floor-48h" 0 check

    # 5. FLOOR BOUNDARY: exactly 48h is NOT inside the floor.
    rm -rf "$dir/ledger"
    _marker fixturehost 2026-08-19T12:00:00Z 800
    _expect "exactly-48h-clears-the-floor" \
        "ok:deslop-due:order=1000 last=800 delta=200 hours=48 reason=event-count" 1 check

    # 6. FLEET-WIDE, NOT HOST-LOCAL: a sweep another host recorded must move THIS
    #    host's clock. This is the property a cache dotfile would have lost.
    rm -rf "$dir/ledger"
    _marker fixturehost 2026-08-01T12:00:00Z 700
    _marker otherhost   2026-08-19T12:00:00Z 900
    _expect "another-hosts-sweep-anchors-this-hosts-clock" \
        "ok:deslop-not-due:order=1000 last=900 delta=100 hours=48 reason=under-threshold" 0 check

    # 7. README.md in the ledger directory is documentation, not a record.
    printf '# readme\nDESLOP-SWEEP: order=999999 examined=0 confirmed=0\n' \
        >"$dir/ledger/README.md"
    _expect "readme-is-not-a-record" \
        "ok:deslop-not-due:order=1000 last=900 delta=100 hours=48 reason=under-threshold" 0 check

    # 8. A MALFORMED RECORD IS `fail:`, NEVER "no record" and never "current".
    #    Read as empty it would fire a sweep off a lie; read as current it would
    #    suppress one.
    rm -rf "$dir/ledger"
    mkdir -p "$dir/ledger"
    printf '\n## 2026-08-19T12:00:00Z fixturehost\nDESLOP-SWEEP: examined=1 confirmed=0\n' \
        >"$dir/ledger/fixturehost.md"
    got="$(_run check 2>/dev/null)"; rc=$?
    case "$got:$rc" in
        fail:deslop-due:unparseable-record:*:2) echo "ok: malformed-record-is-a-refusal ($got rc=$rc)" ;;
        *) echo "FAIL: malformed record expected fail:deslop-due:unparseable-record:* rc=2, got '$got' rc=$rc"; fail=1 ;;
    esac

    # 9. A record with no heading above it is malformed too (the timestamp is
    #    half the record; without it the 48h floor has nothing to stand on).
    rm -rf "$dir/ledger"
    mkdir -p "$dir/ledger"
    printf 'DESLOP-SWEEP: order=800 examined=1 confirmed=0\n' >"$dir/ledger/fixturehost.md"
    got="$(_run check 2>/dev/null)"; rc=$?
    case "$got:$rc" in
        fail:deslop-due:unparseable-record:*:2) echo "ok: headingless-record-is-a-refusal ($got rc=$rc)" ;;
        *) echo "FAIL: headingless record expected a refusal, got '$got' rc=$rc"; fail=1 ;;
    esac

    # 10. AN EVIDENCE-FREE RECORD IS REFUSED and writes nothing. The kill rule
    #     counts only sweeps that examined new rows, so a record that will not
    #     say how many rows it examined cannot be counted.
    rm -rf "$dir/ledger"
    got="$(_run record --confirmed 3 2>/dev/null)"; rc=$?
    case "$got:$rc" in
        fail:deslop-due:record-needs-evidence:usage:*:2) echo "ok: record-without-examined-is-refused" ;;
        *) echo "FAIL: record without --examined expected a refusal naming its usage, got '$got' rc=$rc"; fail=1 ;;
    esac
    [ -e "$dir/ledger" ] && { echo "FAIL: a refused record must not create the ledger"; fail=1; }
    got="$(_run record --examined 3 2>/dev/null)"; rc=$?
    case "$got:$rc" in
        fail:deslop-due:record-needs-evidence:usage:*:2) echo "ok: record-without-confirmed-is-refused" ;;
        *) echo "FAIL: record without --confirmed expected a refusal, got '$got' rc=$rc"; fail=1 ;;
    esac

    # 11. ROUND TRIP: what `record` writes, `check` reads. A write-only marker is
    #     the 803-bqte failure — every stamp succeeded, every check said
    #     unreadable, and the gate was permanently due on macOS for a week.
    _FX_NOW=2026-08-10T12:00:00Z _expect "record-writes-a-record" \
        "ok:deslop-recorded:order=1000 host=fixturehost examined=410 confirmed=51" 0 \
        record --examined 410 --confirmed 51 --retracted 51 --net-lines -1200 --order 1000
    _FX_ORDER=1150 _expect "the-record-just-written-reads-back" \
        "ok:deslop-not-due:order=1150 last=1000 delta=150 hours=264 reason=under-threshold" 0 check
    if grep -q 'retracted=51' "$dir/ledger/fixturehost.md" 2>/dev/null \
       && grep -q 'net_lines=-1200' "$dir/ledger/fixturehost.md" 2>/dev/null; then
        echo "ok: record-carries-its-optional-fields"
    else
        echo "FAIL: record lost its optional fields:"; cat "$dir/ledger/fixturehost.md"; fail=1
    fi

    # 12. GRAMMAR: exactly one well-formed line per invocation, in every state.
    lines=0
    for _st in check "record --examined 1 --confirmed 0 --order 1200" check "record --examined 1"; do
        # shellcheck disable=SC2086
        n="$(_run $_st 2>/dev/null | grep -cE '^(ok:deslop-(not-)?due:order=[0-9]+ last=(none|[0-9]+) delta=(none|-?[0-9]+) hours=(none|-?[0-9]+) reason=(no-record|under-threshold|floor-48h|event-count)|ok:deslop-recorded:order=[0-9]+ host=[A-Za-z0-9._-]+ examined=[0-9]+ confirmed=[0-9]+|fail:deslop-due:[a-z-]+:.*)$')"
        lines=$((lines + n))
    done
    if [ "$lines" = "4" ]; then
        echo "ok: grammar-exactly-one-line-per-invocation"
    else
        echo "FAIL: grammar expected 4 well-formed lines across 4 invocations, got $lines"
        fail=1
    fi

    # 13. POLARITY PIN. The file is named check-deslop-DUE and exits 0 when the
    #     sweep is NOT due. Pin it: an inversion here is silent at every call
    #     site and would either suppress the sweep forever or run it hourly.
    rm -rf "$dir/ledger"
    _marker fixturehost 2026-08-01T12:00:00Z 800
    _run check >/dev/null 2>&1; rc=$?
    rm -rf "$dir/ledger"
    _marker fixturehost 2026-08-01T12:00:00Z 801
    _run check >/dev/null 2>&1; n=$?
    if [ "$rc" = "1" ] && [ "$n" = "0" ]; then
        echo "ok: polarity-due-is-1-not-due-is-0"
    else
        echo "FAIL: polarity expected due=1 not-due=0, got due=$rc not-due=$n"
        fail=1
    fi

    # 14. The clock never touches the REAL ledger from the fixture.
    if [ -e "$ROOT/plan/deslop-sweeps.d/fixturehost.md" ]; then
        echo "FAIL: the fixture wrote into the real ledger directory"
        fail=1
    else
        echo "ok: fixture-is-hermetic"
    fi

    rm -rf "$dir"
    [ "$fail" = 0 ] && echo "ok:deslop-due-fixture:14"
    return "$fail"
}

case "${1:-check}" in
    check)   do_check ;;
    record)  shift; do_record "$@" ;;
    show)
        # Human affordance, deliberately outside the pinned grammar.
        found=0
        for f in "$LEDGER_DIR"/*.md; do
            [ -f "$f" ] || continue
            case "$(basename "$f")" in README.md) continue ;; esac
            found=1
            echo "== $f"
            cat "$f"
        done
        [ "$found" = 1 ] || echo "(no sweep records under $LEDGER_DIR)"
        exit 0
        ;;
    fixture) do_fixture ;;
    *)
        echo "usage: check-deslop-due.sh [check|record --examined <n> --confirmed <n> [--findings n] [--retracted n] [--filed n] [--net-lines n] [--order n] [--host h]|show|fixture]" >&2
        exit 2
        ;;
esac
