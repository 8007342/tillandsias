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
# `scripts/host-capability-probe.sh --fragment` WHERE THAT COMMAND CAN RUN);
# 2 = could not determine (report, never guess — an unavailable matrix is not
# an absent row).
#
# ORDER 1165-xkjh — THE REMEDY IS NOT AVAILABLE AT EVERY LOCUS. That paragraph
# used to promise the publish unconditionally. It is not true on a locus with no
# executable tillandsias: measured on esmeraldinha's Windows side 2026-09-13,
# where the expired verdict is correct and `--fragment` exits 2 because neither
# a native binary nor a runnable one exists there (the Linux debug build is an
# ELF and exits 126). When this guard emits an expired verdict on a path where
# its own probe just failed, it says so on STDERR — the verdict itself is
# unchanged, because a reader who is told to do the impossible learns to ignore
# the next verdict too.
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
    _rs_set="$(printf '%s\n' "$1" | awk -v h="host:$2\tlocus:$3\t" '
        index($0, h) == 1 { inrow = 1; next }
        /^host:/ { inrow = 0 }
        inrow && /^  schedulable: / {
            sub(/^  schedulable: /, "");
            if ($0 != "none" && $0 != "") print
        }' 2>/dev/null | sort -u | tr '\n' '+' | sed 's/+$//')"
    printf '%s\n' "${_rs_set:--}"
}

row_ts() {
    printf '%s\n' "$1" | awk -v h="host:$2\tlocus:$3\t" '
        index($0, h) == 1 {
            for (i = 1; i <= NF; i++) if ($i ~ /^ts:/) { sub(/^ts:/, "", $i); print $i; exit }
        }' 2>/dev/null
}

# The host's OWN locus, READ FROM THE LIVE FOLD rather than re-derived here.
#
# Order 1130-8zxn. A host can hold SEVERAL rows in the matrix — the Windows
# hosts each carry `locus:in-guest` (the WSL distro) and `locus:windows-host`
# (the native side), published by two different probes about two different
# machines that happen to share a node name. Every accessor above used to key
# on `host:<h>` alone and take whichever row came first, which is whichever
# locus sorts first. On yolanda that is `in-guest`, so a freshly published
# `windows-host` row could never clear the verdict: the guard read the OTHER
# row's ts and answered `stale:capability-row-expired:yolanda:age=682046s`
# — 7.9 days, the age of a row the publishing host was not even writing. The
# one action the verdict asks for could not change the verdict.
#
# WHY THE LIVE FOLD AND NOT A LOCAL DERIVATION. host-capability-probe.sh
# already decides locus (:142-149 — TILLANDSIAS_HOST_KIND=forge -> in-guest,
# host kind windows -> windows-host, else bare-metal) and stamps it on the row
# it publishes. A second copy of that rule in this file is exactly the 704-zcgi
# shape this script's own header warns about, and it would fail the same way
# this bug does: grading a host against a locus it never writes. The live fold
# is the probe answering the question itself, through the same
# `capability-matrix` subcommand that folded the committed row — so the two
# sides of every comparison below are keyed by construction.
row_locus() {
    printf '%s\n' "$1" | awk -v h="host:$2\t" '
        index($0, h) == 1 {
            for (i = 1; i <= NF; i++) if ($i ~ /^locus:/) { sub(/^locus:/, "", $i); print $i; exit }
        }' 2>/dev/null
}

# The NEWEST `ts:` across every row this host holds, at any locus.
#
# Order 1154-8ywc. The age check below used to sit AFTER the live-fold
# short-circuit, so on a host whose probe cannot run it never executed at all:
# `check()` returned `ok:capability-row-reported` and a row of any age read
# green. Measured three ways — esme, whose probe is unresolvable, answered ok:
# over rows 21 days old; lenovinha, forcing the short-circuit on a host that
# does not exhibit it naturally, answered ok: over a row dated 2020-01-01 whose
# 222163200s age was never computed; yolanda, probe runnable, correctly caught
# a stale row. A guard failing OPEN on age, in the one direction a guard must
# never fail.
#
# WHY THIS READS EVERY LOCUS AND NOT THE HOST'S OWN. The own-locus keying from
# 1130-8zxn depends on `row_locus "$live"` — and on this path there IS no live
# fold, which is the whole premise. Rather than guess a locus (the 1130-8zxn
# defect reintroduced as a fallback), take the MOST FAVOURABLE reading: the
# newest row the host holds anywhere. If even that one is expired then every
# row is expired, so whichever locus turns out to be this host's, the verdict
# holds. It cannot false-positive on a multi-locus host, and the age it reports
# is the smallest defensible number rather than the largest available one.
#
# AGE IS NOT TRUTH. The short-circuit's own comment is right that an unrunnable
# probe knows nothing about whether the row is TRUE. A ts is not a truth claim;
# it is provenance, it was readable the whole time, and the two were conflated.
newest_row_ts() {
    printf '%s\n' "$1" | awk -v h="host:$2\t" '
        index($0, h) == 1 {
            for (i = 1; i <= NF; i++) if ($i ~ /^ts:/) { sub(/^ts:/, "", $i); print $i }
        }' 2>/dev/null | sort | tail -1
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
        # AGE FIRST (1154-8ywc). A committed row's ts is a fact about the
        # LEDGER; whether a live probe can run is a fact about the host's BUILD
        # STATE. This branch used to treat the second as permission to skip the
        # first, and skipping it failed OPEN. The remedy for an expired row is
        # a `--fragment` publish, which needs no probe to ask for.
        _sc_ts="$(newest_row_ts "$matrix" "$host")"
        if [ -n "$_sc_ts" ]; then
            _sc_epoch="$(iso_to_epoch "$_sc_ts")"
            case "$_sc_epoch" in
                '' | *[!0-9]*) _sc_epoch="" ;;
            esac
            if [ -n "$_sc_epoch" ]; then
                _sc_age=$(( $(now_epoch) - _sc_epoch ))
                [ "$_sc_age" -lt 0 ] && _sc_age=0
                if [ "$_sc_age" -gt "$MAX_AGE" ]; then
                    # ORDER 1165-xkjh. THE REMEDY IS NAMED ONLY WHERE IT CAN
                    # RUN. Reaching here means BOTH that the row is expired AND
                    # that this guard's own live probe — which invokes exactly
                    # the command the remedy names — just failed. So the
                    # verdict is correct, actionable, and asks for something
                    # that does not work at this locus.
                    #
                    # Measured on esmeraldinha 2026-09-13 after 1154-8ywc made
                    # this path report honestly for the first time: the Windows
                    # side answered stale:capability-row-expired rc=1 while
                    # `host-capability-probe.sh --fragment` exited 2 on the same
                    # host and locus, having no native binary to run at all.
                    #
                    # A GUARD THAT NAMES AN UNAVAILABLE REMEDY TRAINS ITS READER
                    # TO IGNORE THE VERDICT. The evidence here is direct rather
                    # than inferred: live_matrix already ran the probe and got
                    # nothing back, so this is a report of what happened, not a
                    # guess about what would.
                    #
                    # STDOUT IS UNTOUCHED. The token and exit code are the
                    # grammar consumers parse (1154-8ywc kept them deliberately
                    # unchanged), so the constraint goes to stderr beside the
                    # verdict and never into it.
                    echo "check-capability-row: the remedy for this verdict is a fresh probe publish, and this guard's own probe could not run at this locus — publishing here needs a tillandsias binary that executes in this context (1165-xkjh)" >&2
                    echo "stale:capability-row-expired:$host:age=${_sc_age}s"
                    return 1
                fi
            fi
        fi

        # NEGATIVE CONTROL, and 1154-8ywc does NOT widen it. The probe could
        # not run, so nothing here knows whether the row is TRUE. Say that, and
        # say it as its own state — a drift claim invented from a probe that
        # never ran would be exactly the defect this dimension exists to
        # remove, pointed the other way. This packet added an AGE answer on
        # this path, never a TRUTH one: `ok:capability-row-reported` still
        # means "a row exists, unverified" and must never start implying that a
        # comparison happened.
        echo "ok:capability-row-reported:$host"
        return 0
    fi

    # 1130-8zxn. WHICH ROW is judged, decided before anything is judged.
    locus="$(row_locus "$live" "$host")"
    if [ -z "$locus" ]; then
        # Report, never guess. A live fold that carries no locus for this host
        # is an instrument fault, and picking an arbitrary committed row to
        # compare against would be this packet's own defect reintroduced as a
        # fallback.
        echo "unavailable:live-row-has-no-locus"
        return 2
    fi

    # A row exists for the host; whether one exists for THIS LOCUS is a
    # separate question, and the answer is the reason the `due:` token exists.
    # Without this, a host that has never published its own locus would be
    # carried past the absence check by a foreign-locus row, find no own-locus
    # ts, skip the age check on `[ -n "$ts" ]`, and be told it was current.
    # The token is deliberately unchanged: the remedy is the same single
    # `--fragment` publish, and consumers parse this grammar.
    own_present="$(printf '%s\n' "$matrix" | grep -c "^host:$host	locus:$locus	" 2>/dev/null)"
    case "$own_present" in
        '' | 0)
            echo "due:no-capability-row:$host"
            return 1
            ;;
    esac

    committed_set="$(row_schedulable "$matrix" "$host" "$locus")"
    live_set="$(row_schedulable "$live" "$host" "$locus")"

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
    ts="$(row_ts "$matrix" "$host" "$locus")"
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

    # ── ORDER 1130-8zxn: WHICH ROW IS JUDGED ────────────────────────────────
    #
    # A host can hold several rows, one per locus. `_mk` above writes a single
    # `bare-metal` row, which is why no arm 1-9 could ever have caught this:
    # every one of them was measured on a host shape that has exactly one row.
    # These use the REAL two-locus shape both Windows hosts are in today —
    # `in-guest` and `windows-host` — and the in-guest row is written FIRST
    # because that is the order the fold emits and the order is the bug.
    _row() { # <host> <locus> <ts> <triples...>
        _rw_h="$1"; _rw_l="$2"; _rw_t="$3"; shift 3
        printf 'host:%s\tlocus:%s\tkind:linux\tid_source:node-name\tderived_tier:cpu\tts:%s\twriter:windows\tfrom:x\n' \
            "$_rw_h" "$_rw_l" "$_rw_t"
        if [ "$#" -eq 0 ]; then
            printf '  schedulable: none\n'
        else
            for _rw_tr in "$@"; do printf '  schedulable: %s\n' "$_rw_tr"; done
        fi
    }
    _mk_hdr() { # <file> — header only; rows are appended by _row, in order
        printf 'capability-matrix: rows\n' >"$1"
    }

    # The live fold speaks for THIS host at THIS locus, and only ever holds the
    # one row — which is what makes it the right place to read the locus from.
    _mk_hdr "$_fx_live"
    _row fixturehost windows-host "$_fresh_ts" cpu/container/ollama >>"$_fx_live"

    # 10. THE DEFECT, PINNED. The host published its own locus an hour ago; a
    #     row for the OTHER locus is eight days old. Pre-fix this answered
    #     `stale:capability-row-expired:fixturehost:age=694800s` — the age of a
    #     row this host was not writing — so the publish it demanded could not
    #     clear it. The verdict was unfalsifiable by the only action offered.
    _mk_hdr "$_fx_committed"
    _row fixturehost in-guest     "$_old_ts"   cpu/container/ollama >>"$_fx_committed"
    _row fixturehost windows-host "$_fresh_ts" cpu/container/ollama >>"$_fx_committed"
    _expect "a-fresh-own-locus-row-outranks-an-older-foreign-locus-row" \
        "ok:capability-row-current:fixturehost" 0 \
        TILLANDSIAS_CAPABILITY_LIVE_MATRIX="$_fx_live"

    # 11. NEGATIVE CONTROL, and the load-bearing one for this packet. The
    #     OWN-locus row is genuinely expired while the foreign one is fresh.
    #     Staleness must still be enforced — this packet changes WHICH ROW is
    #     judged, never WHETHER age is judged. The age is asserted EXACTLY
    #     (694800s = the own row's eight days, not the foreign row's 3600s),
    #     because a fix that read the wrong row would still emit the right
    #     TOKEN here and only the number would give it away.
    _mk_hdr "$_fx_committed"
    _row fixturehost in-guest     "$_fresh_ts" cpu/container/ollama >>"$_fx_committed"
    _row fixturehost windows-host "$_old_ts"   cpu/container/ollama >>"$_fx_committed"
    _expect "a-genuinely-expired-own-locus-row-still-expires-and-reports-its-own-age" \
        "stale:capability-row-expired:fixturehost:age=694800s" 1 \
        TILLANDSIAS_CAPABILITY_LIVE_MATRIX="$_fx_live"

    # 12. The hole the narrow fix would have opened. The host has NEVER
    #     published its own locus; only a foreign-locus row exists. The
    #     host-only presence check passes it, and with a locus-aware ts lookup
    #     finding nothing the age branch is skipped entirely — so without this
    #     arm the answer is `ok:capability-row-current` for a host that has not
    #     published. It must be `due:`, which is the token that asks.
    _mk_hdr "$_fx_committed"
    _row fixturehost in-guest "$_fresh_ts" cpu/container/ollama >>"$_fx_committed"
    _expect "a-foreign-locus-row-does-not-satisfy-a-missing-own-locus-row" \
        "due:no-capability-row:fixturehost" 1 \
        TILLANDSIAS_CAPABILITY_LIVE_MATRIX="$_fx_live"

    # 13. Drift is judged per locus too. The foreign locus legitimately
    #     advertises hardware this locus does not have — two probes, two
    #     machines, one node name. Unioning them made the other machine's GPU
    #     read as this one lying about a GPU, which would have replaced a
    #     permanent `expired` with a permanent `drifted` had only the ts lookup
    #     been fixed.
    _mk_hdr "$_fx_committed"
    _row fixturehost in-guest     "$_fresh_ts" gpu/container/ollama >>"$_fx_committed"
    _row fixturehost windows-host "$_fresh_ts" cpu/container/ollama >>"$_fx_committed"
    _expect "a-foreign-locus-engine-is-not-this-locus-drifting" \
        "ok:capability-row-current:fixturehost" 0 \
        TILLANDSIAS_CAPABILITY_LIVE_MATRIX="$_fx_live"

    # ── ARMS 14-15: esmeraldinha's REAL folded rows, not triples I chose ─────
    #
    # Arm 13 above uses a non-empty set on BOTH loci, which passes but does not
    # discriminate. esme supplied the sharper shape and the reason, and the
    # reason is the part worth keeping: a UNIFORM pair cannot distinguish "read
    # the wrong locus" from "read the right locus and it was empty" — both
    # yield the empty set, so a green proves nothing. A MIXED pair breaks the
    # tie in both directions. These are esme's two rows as folded on
    # 2026-09-13, copied rather than invented:
    #
    #   locus:in-guest     kind:linux    schedulable: cpu/container/ollama
    #                                    schedulable: cpu/host-native/ollama
    #   locus:windows-host kind:windows  schedulable: none
    #
    # and the compounding that makes that host the best test in the fleet:
    # in-guest is SIMULTANEOUSLY the first-sorting locus, the newer one, and
    # the non-empty one. One wrong-locus read therefore corrupts the age and
    # the schedulable set at the same time, from the same accessor.
    _mk_hdr "$_fx_live"
    _row fixturehost windows-host "$_fresh_ts" >>"$_fx_live"

    # 14. Drift isolated: both loci held FRESH, so age cannot be what answers.
    #     The foreign locus schedules two real engines this locus does not have
    #     — a different machine behind the same node name. Pre-fix the union
    #     made those two read as this host advertising engines it lacks.
    _mk_hdr "$_fx_committed"
    _row fixturehost in-guest "$_fresh_ts" cpu/container/ollama cpu/host-native/ollama >>"$_fx_committed"
    _row fixturehost windows-host "$_fresh_ts" >>"$_fx_committed"
    _expect "a-foreign-locus-that-schedules-two-engines-is-not-this-empty-locus-drifting" \
        "ok:capability-row-current:fixturehost" 0 \
        TILLANDSIAS_CAPABILITY_LIVE_MATRIX="$_fx_live"

    # 15. THE COMPOUNDING, as its own arm. Same mixed pair, but now the own
    #     locus is genuinely expired while the foreign one is fresh — esme's
    #     actual polarity. Pre-fix this answered `drifted` (drift outranks age,
    #     arm 7), so a single accessor bug reported the WRONG DIMENSION as well
    #     as the wrong value: a real staleness problem surfaced as a fabricated
    #     hardware claim. Post-fix it must name the staleness, with the OWN
    #     row's age.
    _mk_hdr "$_fx_committed"
    _row fixturehost in-guest "$_fresh_ts" cpu/container/ollama cpu/host-native/ollama >>"$_fx_committed"
    _row fixturehost windows-host "$_old_ts" >>"$_fx_committed"
    _expect "one-wrong-locus-read-corrupts-the-age-and-the-engine-set-together" \
        "stale:capability-row-expired:fixturehost:age=694800s" 1 \
        TILLANDSIAS_CAPABILITY_LIVE_MATRIX="$_fx_live"

    # ── ARMS 16-19: ORDER 1154-8ywc, THE FAIL-OPEN ON AGE ───────────────────
    #
    # Arm 5 above already covers "an unrunnable probe never manufactures
    # drift", and it passed throughout — with a FRESH row. Nobody had asked
    # what that path does with a STALE one, and the answer was: nothing. The
    # expiry check sat after the short-circuit and never executed, so a row of
    # any age read green on any host whose probe cannot run.
    #
    # These four hold LIVE_UNRUNNABLE fixed and vary only the row's age, which
    # is the one variable that used to make no difference at all.

    # 16. THE DEFECT, PINNED. Live fold unavailable, committed row eight days
    #     old against a seven-day window. Pre-fix: ok:capability-row-reported
    #     rc=0, with the age never computed.
    _mk "$_fx_committed" fixturehost "$_old_ts" cpu/container/ollama
    _expect "an-expired-row-is-still-expired-when-the-probe-cannot-run" \
        "stale:capability-row-expired:fixturehost:age=694800s" 1 \
        TILLANDSIAS_CAPABILITY_LIVE_UNRUNNABLE=1

    # 17. NEGATIVE CONTROL 1, the one that keeps this packet honest. Same
    #     unrunnable path, row INSIDE the window: the verdict must stay
    #     `ok:capability-row-reported`. That token means "a row exists,
    #     unverified", and if this packet had widened it into a claim that a
    #     comparison happened, 889-ewvt's defect would be back — an artifact
    #     read as evidence of the check that would have produced it.
    _mk "$_fx_committed" fixturehost "$_fresh_ts" cpu/container/ollama
    _expect "a-fresh-row-with-no-probe-still-reports-rather-than-verifies" \
        "ok:capability-row-reported:fixturehost" 0 \
        TILLANDSIAS_CAPABILITY_LIVE_UNRUNNABLE=1

    # 18. NEGATIVE CONTROL 2: no TRUTH claim was added to this path. The
    #     committed row advertises an engine; the live fold cannot run, so
    #     nothing can contradict it. The verdict must NOT be `drifted` — that
    #     is arm 5's guarantee and it must survive an age answer being added
    #     beside it. Kept as its own arm because the two live on one code path
    #     now and a later edit could collapse them.
    _mk "$_fx_committed" fixturehost "$_fresh_ts" gpu/container/ollama
    _expect "an-age-answer-did-not-become-a-truth-answer" \
        "ok:capability-row-reported:fixturehost" 0 \
        TILLANDSIAS_CAPABILITY_LIVE_UNRUNNABLE=1

    # 19. MULTI-LOCUS ON THE UNRUNNABLE PATH. There is no live fold here, so
    #     there is no locus — the 1130-8zxn keying is unavailable by
    #     construction. Rather than guess one, the check reads the NEWEST row
    #     the host holds anywhere: if even that is expired, every row is, so
    #     the verdict holds whichever locus turns out to be this host's. Here
    #     the newest is FRESH and an older sibling exists, so it must NOT
    #     expire — a naive "any row is old" test would fail this arm, and that
    #     is exactly the false positive this shape avoids.
    _mk_hdr "$_fx_committed"
    _row fixturehost in-guest     "$_old_ts"   cpu/container/ollama >>"$_fx_committed"
    _row fixturehost windows-host "$_fresh_ts" cpu/container/ollama >>"$_fx_committed"
    _expect "the-newest-row-decides-on-the-unrunnable-path-so-an-old-sibling-does-not-expire-a-live-host" \
        "ok:capability-row-reported:fixturehost" 0 \
        TILLANDSIAS_CAPABILITY_LIVE_UNRUNNABLE=1

    # ── ARMS 20-22: ORDER 1165-xkjh, THE REMEDY MUST BE AVAILABLE ───────────
    #
    # 1154-8ywc made the unrunnable-probe path report an expired row honestly.
    # Honesty exposed the next problem: on esme's Windows locus that verdict is
    # correct and the remedy it names exits 2, because no tillandsias binary
    # executes there at all. A host told to publish, from a context where
    # publishing is impossible.
    #
    # These arms check STDERR while asserting stdout is unchanged, because the
    # whole design constraint is that the grammar consumers parse must not move.

    # 20. Expired row + no live fold: the constraint is named on stderr.
    _mk "$_fx_committed" fixturehost "$_old_ts" cpu/container/ollama
    _err_out="$(_run TILLANDSIAS_CAPABILITY_LIVE_UNRUNNABLE=1 2>&1 >/dev/null)"
    case "$_err_out" in
        *"could not run at this locus"*1165-xkjh*)
            echo "ok: an-unreachable-remedy-is-named-as-unreachable" ;;
        *)
            echo "FAIL: expected a stderr line naming the unavailable remedy, got '$_err_out'"
            _fx_fail=1 ;;
    esac

    # 21. STDOUT IS BYTE-IDENTICAL. The verdict is the contract; the diagnostic
    #     is beside it, never inside it. Asserted separately from arm 20 so a
    #     later edit cannot satisfy one by breaking the other.
    _expect "the-diagnostic-did-not-leak-into-the-verdict" \
        "stale:capability-row-expired:fixturehost:age=694800s" 1 \
        TILLANDSIAS_CAPABILITY_LIVE_UNRUNNABLE=1

    # 22. NEGATIVE CONTROL, and it is the one that stops this becoming the
    #     defect it fixes. On a host where the probe DOES run, an expired row
    #     must NOT carry the line — the remedy is available there, and telling
    #     a host its remedy is unreachable when it is reachable is the same
    #     false advisory in the opposite direction (1158-y3ad's carry-forward
    #     arm is the precedent).
    _mk "$_fx_committed" fixturehost "$_old_ts" cpu/container/ollama
    _mk "$_fx_live" fixturehost "$_fresh_ts" cpu/container/ollama
    _err_ok="$(_run TILLANDSIAS_CAPABILITY_LIVE_MATRIX="$_fx_live" 2>&1 >/dev/null)"
    case "$_err_ok" in
        *1165-xkjh*)
            echo "FAIL: a host with a runnable probe was told its remedy is unreachable: '$_err_ok'"
            _fx_fail=1 ;;
        *)
            echo "ok: a-reachable-remedy-is-not-announced-as-unreachable" ;;
    esac

    rm -rf "$_fx_dir"
    [ "$_fx_fail" = 0 ] && echo "ok:capability-row-check-fixture:22"
    return "$_fx_fail"
}

case "${1:-check}" in
    fixture) fixture; exit $? ;;
    check)   verdict="$(check)" && rc=0 || rc=$?; echo "$verdict"; exit "$rc" ;;
    *)       echo "usage: check-capability-row.sh [check|fixture]" >&2; exit 2 ;;
esac
