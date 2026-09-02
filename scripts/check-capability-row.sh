#!/usr/bin/env bash
# @trace order:850-bif2, order:859-b2zc, order:889-ewvt, spec:accel-capability-probe
#
# check-capability-row.sh — is THIS host visible in the capability matrix?
#
# WHY (order 850-bif2). Five of seven known hosts were silent in the matrix —
# not failed, simply never asked to publish — and capability-aware routing
# (847-wgy4) cannot route to hardware the matrix cannot see. This makes the
# question falsifiable so the meta-orchestration Start-Of-Day gate can act on
# it: a joining host's first cycle answers `due:` and publishes, every later
# cycle answers `ok:` for free.
#
# HOST IDENTITY IS NOT RE-DERIVED HERE (order 859-b2zc). This script used to
# resolve the host inline with `hostname -s || hostname`, and the `hostname`
# BINARY IS ABSENT from every Fedora image this project runs on — both WSL
# distros on the Windows hosts and `localhost/tillandsias-forge`, the last
# verified directly under podman on 2026-08-23. The check therefore answered
# `unavailable:host-unresolvable` (exit 2) in precisely the environments the
# 850-bif2 gate exists to prompt, which is why the forge has never once been
# asked to publish a row: `unavailable:` is the one verdict that asks nobody
# to do anything.
#
# The correct chain already existed as a sourceable helper —
# tillandsias_agent_workstation() in scripts/agent-identity.sh, added under
# 743-mgf3, whose own comment says in as many words that "some environments
# ship no `hostname`". So source the helper; never re-derive the chain. This is
# the 704-zcgi shape on a different probe: three scripts independently
# re-implemented one probe and all three got it wrong the same way, and the
# lesson there was that fixing instances is not enough — the copy has to go.
#
# ── THE TRUTH DIMENSION (order 889-ewvt) ────────────────────────────────────
#
# Everything above this line is about REPORTING. Every token the original
# grammar could produce answered "has this host published a row" and none of
# them could answer "is the row still true". So on yoga, 2026-08-25, this check
# printed `ok:capability-row-reported:yoga` on every cycle all night over a
# committed row advertising `gpu/container/ollama` on a host with no ollama
# binary, no endpoint and no model. That false row then ROUTED the authoritative
# release gate to yoga precisely because it advertised the engine. A missing row
# routes nothing; a false row routes confidently and wrongly, which is strictly
# worse.
#
# A guard that only checks a row's EXISTENCE cannot be falsified by the row
# being WRONG. Before trusting a probe, ask what result would have falsified it;
# if nothing would have, you measured your own input.
#
# So the check now compares the COMMITTED row against a LIVE one — and it does
# not re-derive the derivation to do it. `schedulable: <class>/<lane>/<engine>`
# triples are folded from the raw accel document by the plan binary, and a bash
# reimplementation of that fold is the 704-zcgi shape waiting to happen (three
# scripts independently re-implementing one probe, all three wrong the same
# way). Instead: write THIS cycle's live `--fragment` into a throwaway one-row
# ledger and ask the SAME `capability-matrix` subcommand to fold it. Same code,
# two inputs, so "what the row says" and "what the host is" cannot drift for any
# reason except the host actually having changed.
#
# NEGATIVE CONTROL, and it is the one that matters: an UNRUNNABLE probe reads
# `unavailable:`, never `drifted:`. Manufacturing a drift claim out of a probe
# that could not run would be this very defect inverted — an artifact read as
# evidence of the check that would have produced it.
#
# Grammar (exactly one line):
#   ^(ok:capability-row-current:<h>
#    |due:no-capability-row:<h>
#    |stale:capability-row-drifted:<h>:row-only=<set>,probe-only=<set>
#    |stale:capability-row-expired:<h>:age=<seconds>s
#    |unavailable:[a-z-]+)$
# where <set> is `-` or `+`-joined `<class>/<lane>/<engine>` triples.
#
# `ok:capability-row-reported:<h>` is still emitted, but ONLY when the truth
# comparison could not be made for a named reason that is not the host's fault
# (the live fold is unavailable while the committed matrix is fine). It now
# means strictly "a row exists, unverified" and never "the row is true".
#
# Exit codes: 0 = row present and current; 1 = actionable (publish a row:
# absent, drifted, or expired — all three are fixed by
# `scripts/host-capability-probe.sh --fragment`); 2 = could not determine
# (report, never guess — an unavailable matrix is not an absent row).
#
# Advisory to the gate, like the health probe: these verdicts ask the cycle to
# publish and commit a row, they never block work.
#
# Seams (used by the fixture — nothing below touches real hardware under them):
#   TILLANDSIAS_CAPABILITY_COMMITTED_MATRIX  file standing in for the ledger fold
#   TILLANDSIAS_CAPABILITY_LIVE_MATRIX       file standing in for the live fold
#   TILLANDSIAS_CAPABILITY_LIVE_UNRUNNABLE   force the live probe to fail
#   TILLANDSIAS_CAPABILITY_ROW_MAX_AGE       freshness window, seconds (604800)
#   TILLANDSIAS_CAPABILITY_ROW_NOW           force "now" as an epoch
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || { echo "unavailable:worktree-unreadable"; exit 2; }

# shellcheck source=scripts/plan-binary-probe.sh
. "$ROOT/scripts/plan-binary-probe.sh"
# shellcheck source=scripts/agent-identity.sh
. "$ROOT/scripts/agent-identity.sh"

PLAN="$(resolve_plan_binary)" || { echo "unavailable:no-runnable-plan-binary"; exit 2; }

# An EPHEMERAL identity must not be published (order 859-b2zc, criterion 3).
#
# Fixing the fallback chain alone is not enough, and getting this wrong is
# worse than the bug it replaces. A forge container has no stable node name:
# `run-forge-project.sh` passes no `--hostname` and no entrypoint exports
# TILLANDSIAS_WORKSTATION, so HOSTNAME, /etc/hostname and `uname -n` all report
# the container id (measured: `d872da8c03df`). With the chain repaired and
# nothing else, the forge would stop answering `unavailable:` and start
# answering `due:` under a name that changes every launch — and a matrix that
# grows a row per container is a regression, not progress. Turning a silent
# host into a noisy one is not a fix.
#
# So when this IS a forge and no stable identity was launch-provided, decline
# and name the remedy. The platform test is the canonical one
# (TILLANDSIAS_HOST_KIND=forge, else the .forge-startup-context.md marker), not
# a guess at the image name.
#
# THE FIXTURE IS EXEMPT, AND MUST BE (order 964-fwvh). This guard and the host
# resolution below both run at top level, BEFORE the `case` dispatch at the
# foot of the file, so on an ephemeral forge they refused `fixture` too — the
# hermetic self-test never reached its first case, printed the live refusal,
# and exited 2. `./build.sh --check` reads that as "the capability-row truth
# fixture broke — a stale row can be consumed as a current fact again", so
# every forge failed the gate with a message about a defect that was not there.
# Measured on macuahuitl-tillandsias-forge 2026-09-02.
#
# The exemption is sound rather than convenient: this guard exists to stop a
# host PUBLISHING under a name that changes every launch, and the fixture
# publishes nothing. It supplies `TILLANDSIAS_WORKSTATION=fixturehost` on every
# one of its own `_run` invocations, so the identity it tests with is its own and the
# ambient one is irrelevant to it.
if [ "${1:-check}" = "fixture" ]; then
    :
elif [ -z "${TILLANDSIAS_WORKSTATION:-}" ] && [ "$(tillandsias_agent_platform)" = "forge" ]; then
    echo "[check-capability-row] This forge has no stable identity: TILLANDSIAS_WORKSTATION is unset and every other source (HOSTNAME, /etc/hostname, uname -n) reports the container id, which changes on every launch. Publishing under it would add a matrix row per container. Export TILLANDSIAS_WORKSTATION with the forge's fleet name before asking it to publish." >&2
    echo "unavailable:forge-identity-ephemeral"
    exit 2
fi

# tillandsias_agent_workstation honours TILLANDSIAS_WORKSTATION first, then
# HOSTNAME, /etc/hostname and the tillandsias_node_name probe, domain-stripping
# the result. It does NOT lowercase (the launch-provided value is authoritative
# as given), and the matrix fold key is lowercase — `Esmeraldinha` on the
# Windows hosts would miss `host:esmeraldinha` — so lowercase here with the
# shared helper rather than another inline `tr`.
host="$(tillandsias_lower "$(tillandsias_agent_workstation)")"
[ -n "$host" ] || { echo "unavailable:host-unresolvable"; exit 2; }

MAX_AGE="${TILLANDSIAS_CAPABILITY_ROW_MAX_AGE:-604800}"

# ISO-UTC to epoch WITHOUT `date -d` (GNU) or `date -j -f` (BSD). This script
# runs on macOS too, and BSD `date -d` succeeds with garbage rather than
# failing, so an exit-code guard cannot catch it (761-g36m). Days-from-civil is
# the same arithmetic scripts/check-deslop-due.sh already uses for this.
iso_to_epoch() {
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
        }' 2>/dev/null
}

now_epoch() {
    if [ -n "${TILLANDSIAS_CAPABILITY_ROW_NOW:-}" ]; then
        printf '%s\n' "$TILLANDSIAS_CAPABILITY_ROW_NOW"
        return 0
    fi
    date -u +%s 2>/dev/null || echo 0
}

# The committed fold: what routing actually reads.
committed_matrix() {
    if [ -n "${TILLANDSIAS_CAPABILITY_COMMITTED_MATRIX:-}" ]; then
        cat "$TILLANDSIAS_CAPABILITY_COMMITTED_MATRIX" 2>/dev/null || return 1
        return 0
    fi
    "$PLAN" capability-matrix 2>/dev/null || return 1
}

# The live fold: this cycle's hardware, run through the SAME folder. A throwaway
# one-fragment ledger is the whole trick — no reimplementation of the
# device->triple derivation lives here, so there is nothing to drift.
live_matrix() {
    if [ -n "${TILLANDSIAS_CAPABILITY_LIVE_UNRUNNABLE:-}" ]; then
        return 1
    fi
    if [ -n "${TILLANDSIAS_CAPABILITY_LIVE_MATRIX:-}" ]; then
        cat "$TILLANDSIAS_CAPABILITY_LIVE_MATRIX" 2>/dev/null || return 1
        return 0
    fi
    _lm_dir="$(mktemp -d 2>/dev/null)" || return 1
    _lm_rc=1
    if mkdir -p "$_lm_dir/plan/index.d" 2>/dev/null \
       && printf 'packets: []\n' >"$_lm_dir/plan/index.yaml" 2>/dev/null \
       && bash "$ROOT/scripts/host-capability-probe.sh" --fragment \
              >"$_lm_dir/plan/index.d/live.yaml" 2>/dev/null \
       && [ -s "$_lm_dir/plan/index.d/live.yaml" ]; then
        if _lm_out="$("$PLAN" --index "$_lm_dir/plan/index.yaml" capability-matrix 2>/dev/null)"; then
            printf '%s\n' "$_lm_out"
            _lm_rc=0
        fi
    fi
    rm -rf "$_lm_dir" 2>/dev/null || true
    return "$_lm_rc"
}

# The schedulable triple set for one host, as a stable `+`-joined string (`-`
# when the host schedules nothing). Sorted, so set equality is string equality.
row_schedulable() {
    _rs_set="$(printf '%s\n' "$1" | awk -v h="host:$2" '
        index($0, h "\t") == 1 { inrow = 1; next }
        /^host:/ { inrow = 0 }
        inrow && /^  schedulable: / {
            sub(/^  schedulable: /, "");
            if ($0 != "none" && $0 != "") print
        }' 2>/dev/null | sort -u | tr '\n' '+' | sed 's/+$//')"
    printf '%s\n' "${_rs_set:--}"
}

row_ts() {
    printf '%s\n' "$1" | awk -v h="host:$2" '
        index($0, h "\t") == 1 {
            for (i = 1; i <= NF; i++) if ($i ~ /^ts:/) { sub(/^ts:/, "", $i); print $i; exit }
        }' 2>/dev/null
}

# Set difference A \ B over `+`-joined sets, printed in the same shape.
set_minus() {
    _sm_a="$1"; _sm_b="$2"
    [ "$_sm_a" = "-" ] && { printf '%s\n' "-"; return 0; }
    _sm_out="$(printf '%s\n' "$_sm_a" | tr '+' '\n' | grep . | while read -r _sm_t; do
        printf '%s\n' "$_sm_b" | tr '+' '\n' | grep -qxF "$_sm_t" || printf '%s\n' "$_sm_t"
    done | tr '\n' '+' | sed 's/+$//')"
    printf '%s\n' "${_sm_out:--}"
}

check() {
    if ! matrix="$(committed_matrix)"; then
        echo "unavailable:capability-matrix-failed"
        return 2
    fi

    # 795-imz3: `if ! <pipeline>` inverts under pipefail + SIGPIPE (grep -q
    # exits on the first match and the writer takes the signal), so capture the
    # answer first and branch on the value.
    row_present="$(printf '%s\n' "$matrix" | grep -c "^host:$host	" 2>/dev/null)"
    case "$row_present" in
        '' | 0)
            echo "due:no-capability-row:$host"
            return 1
            ;;
    esac

    # A row EXISTS. That used to be the whole answer; it is now the premise.
    if ! live="$(live_matrix)"; then
        # NEGATIVE CONTROL. The probe could not run, so nothing here knows
        # whether the row is true. Say that, and say it as its own state — a
        # drift claim invented from a probe that never ran would be exactly the
        # defect this dimension exists to remove, pointed the other way.
        echo "ok:capability-row-reported:$host"
        return 0
    fi

    committed_set="$(row_schedulable "$matrix" "$host")"
    live_set="$(row_schedulable "$live" "$host")"

    if [ "$committed_set" != "$live_set" ]; then
        # Name BOTH directions. A row claiming an engine the host does not have
        # is what misrouted the release gate; a host that has gained an engine
        # the row does not advertise is under-routed rather than mis-routed, and
        # the remedy for both is one `--fragment` publish.
        echo "stale:capability-row-drifted:$host:row-only=$(set_minus "$committed_set" "$live_set"),probe-only=$(set_minus "$live_set" "$committed_set")"
        return 1
    fi

    # The claims agree. Age is still a fact a consumer is entitled to decline
    # on: agreement today says nothing about a row nobody has re-probed in a
    # week, and the matrix surfaces `ts:` on every row precisely so a reader can
    # make that call without re-probing every host in the fleet.
    ts="$(row_ts "$matrix" "$host")"
    if [ -n "$ts" ]; then
        row_epoch="$(iso_to_epoch "$ts")"
        case "$row_epoch" in
            '' | *[!0-9]*) row_epoch="" ;;
        esac
        if [ -n "$row_epoch" ]; then
            age=$(( $(now_epoch) - row_epoch ))
            [ "$age" -lt 0 ] && age=0
            if [ "$age" -gt "$MAX_AGE" ]; then
                echo "stale:capability-row-expired:$host:age=${age}s"
                return 1
            fi
        fi
    fi

    echo "ok:capability-row-current:$host"
    return 0
}

fixture() {
    _fx_fail=0
    _fx_dir="$(mktemp -d)"
    _fx_self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    _fx_committed="$_fx_dir/committed"
    _fx_live="$_fx_dir/live"

    _mk() {
        # <file> <host> <ts> <triples...>
        _f="$1"; _h="$2"; _t="$3"; shift 3
        {
            printf 'capability-matrix: 1 row(s)\n'
            printf 'host:%s\tlocus:bare-metal\tkind:linux\tid_source:node-name\tderived_tier:cpu\tts:%s\twriter:linux_immutable\tfrom:x\n' "$_h" "$_t"
            if [ "$#" -eq 0 ]; then
                printf '  schedulable: none\n'
            else
                for _tr in "$@"; do printf '  schedulable: %s\n' "$_tr"; done
            fi
        } >"$_f"
    }
    _run() {
        TILLANDSIAS_WORKSTATION=fixturehost \
        TILLANDSIAS_CAPABILITY_COMMITTED_MATRIX="$_fx_committed" \
        TILLANDSIAS_CAPABILITY_ROW_NOW="${_FX_NOW:-1800000000}" \
            env "$@" bash "$_fx_self" check
    }
    _expect() {
        _n="$1"; _want="$2"; _rc="$3"; shift 3
        _got="$(_run "$@" 2>/dev/null)"; _grc=$?
        if [ "$_got" = "$_want" ] && [ "$_grc" = "$_rc" ]; then
            echo "ok: $_n ($_got rc=$_grc)"
        else
            echo "FAIL: $_n expected '$_want' rc=$_rc, got '$_got' rc=$_grc"
            _fx_fail=1
        fi
    }

    # Literal timestamps rather than epoch arithmetic through `date`: the
    # fixture must behave identically on a host whose `date` is BSD. `_FX_NOW`
    # below is 1800000000 = 2027-01-15T08:00:00Z, so these sit one hour and
    # eight days behind it respectively.
    _fresh_ts="2027-01-15T07:00:00Z"
    _old_ts="2027-01-07T07:00:00Z"

    # 1. No row at all: absence, unchanged. Absence and falsehood keep
    #    different tokens — conflating them was half the original defect.
    _mk "$_fx_committed" otherhost "$_fresh_ts" cpu/container/ollama
    _mk "$_fx_live" fixturehost "$_fresh_ts" cpu/container/ollama
    _expect "no-row-is-due-not-drifted" "due:no-capability-row:fixturehost" 1 \
        TILLANDSIAS_CAPABILITY_LIVE_MATRIX="$_fx_live"

    # 2. Row agrees with the live probe: ok, and it now MEANS the row is true.
    _mk "$_fx_committed" fixturehost "$_fresh_ts" cpu/container/ollama
    _expect "row-matching-the-probe-is-current" "ok:capability-row-current:fixturehost" 0 \
        TILLANDSIAS_CAPABILITY_LIVE_MATRIX="$_fx_live"

    # 3. THE DEFECT, PINNED. The committed row claims an engine the live probe
    #    does not report — the exact yoga 2026-08-25 state that printed green
    #    all night and misrouted the release gate. Distinct token, engine named.
    _mk "$_fx_committed" fixturehost "$_fresh_ts" cpu/container/ollama gpu/container/ollama
    _mk "$_fx_live" fixturehost "$_fresh_ts" cpu/container/ollama
    _expect "row-claiming-an-absent-engine-is-drifted-and-names-it" \
        "stale:capability-row-drifted:fixturehost:row-only=gpu/container/ollama,probe-only=-" 1 \
        TILLANDSIAS_CAPABILITY_LIVE_MATRIX="$_fx_live"

    # 4. The other direction: the host gained an engine the row does not carry.
    #    Under-routed rather than mis-routed, but still a false row.
    _mk "$_fx_committed" fixturehost "$_fresh_ts"
    _mk "$_fx_live" fixturehost "$_fresh_ts" cpu/container/ollama
    _expect "row-missing-a-live-engine-is-drifted-too" \
        "stale:capability-row-drifted:fixturehost:row-only=-,probe-only=cpu/container/ollama" 1 \
        TILLANDSIAS_CAPABILITY_LIVE_MATRIX="$_fx_live"

    # 5. NEGATIVE CONTROL, the load-bearing one. An unrunnable probe must NOT
    #    manufacture a drift claim. It falls back to the unverified reporting
    #    verdict, which is honest about exactly what it checked.
    _mk "$_fx_committed" fixturehost "$_fresh_ts" gpu/container/ollama
    _expect "an-unrunnable-probe-never-manufactures-drift" \
        "ok:capability-row-reported:fixturehost" 0 \
        TILLANDSIAS_CAPABILITY_LIVE_UNRUNNABLE=1

    # 6. Freshness: an agreeing row older than the window is declinable without
    #    re-probing, and says so as its own state rather than as drift.
    _mk "$_fx_committed" fixturehost "$_old_ts" cpu/container/ollama
    _mk "$_fx_live" fixturehost "$_fresh_ts" cpu/container/ollama
    _got="$(_run TILLANDSIAS_CAPABILITY_LIVE_MATRIX="$_fx_live" 2>/dev/null)"; _grc=$?
    case "$_got:$_grc" in
        stale:capability-row-expired:fixturehost:age=*s:1)
            echo "ok: an-agreeing-but-week-old-row-is-expired ($_got)" ;;
        *) echo "FAIL: expected stale:capability-row-expired:fixturehost:age=<n>s rc=1, got '$_got' rc=$_grc"; _fx_fail=1 ;;
    esac

    # 7. Drift OUTRANKS age: a row that is both false and old must report the
    #    falsehood, which is the one that misroutes.
    _mk "$_fx_committed" fixturehost "$_old_ts" gpu/container/ollama
    _expect "drift-outranks-age" \
        "stale:capability-row-drifted:fixturehost:row-only=gpu/container/ollama,probe-only=cpu/container/ollama" 1 \
        TILLANDSIAS_CAPABILITY_LIVE_MATRIX="$_fx_live"

    # 8. An unreadable committed matrix stays `unavailable:` — an unavailable
    #    matrix is not an absent row and is certainly not a drifted one.
    _expect "unreadable-matrix-is-unavailable" "unavailable:capability-matrix-failed" 2 \
        TILLANDSIAS_CAPABILITY_COMMITTED_MATRIX="$_fx_dir/nonexistent" \
        TILLANDSIAS_CAPABILITY_LIVE_MATRIX="$_fx_live"

    # 9. Grammar: exactly one well-formed line per invocation.
    _mk "$_fx_committed" fixturehost "$_fresh_ts" cpu/container/ollama
    _lines="$(_run TILLANDSIAS_CAPABILITY_LIVE_MATRIX="$_fx_live" 2>/dev/null | grep -cE '^(ok:capability-row-(current|reported):[a-z0-9-]+|due:no-capability-row:[a-z0-9-]+|stale:capability-row-drifted:[a-z0-9-]+:row-only=[^,]+,probe-only=[^,]+|stale:capability-row-expired:[a-z0-9-]+:age=[0-9]+s|unavailable:[a-z-]+)$')"
    if [ "$_lines" = "1" ]; then
        echo "ok: grammar-exactly-one-line"
    else
        echo "FAIL: grammar expected 1 well-formed line, got $_lines"
        _fx_fail=1
    fi

    rm -rf "$_fx_dir"
    [ "$_fx_fail" = 0 ] && echo "ok:capability-row-check-fixture:9"
    return "$_fx_fail"
}

case "${1:-check}" in
    fixture) fixture; exit $? ;;
    check)   verdict="$(check)" && rc=0 || rc=$?; echo "$verdict"; exit "$rc" ;;
    *)       echo "usage: check-capability-row.sh [check|fixture]" >&2; exit 2 ;;
esac
