#!/usr/bin/env bash
# @trace order:1443-qwpj, spec:meta-orchestration
#
# verify-closure.sh <order> [--index <plan/index.yaml>] [--root <dir>]
#
# Runs a packet's OWN verifiable_closure command(s) and compares the PRINTED
# output with what the closure says it prints. This is the acceptance an
# orchestrator runs instead of reading a delegate's "met" (operator ruling 2,
# 2026-09-27). A delegate's report is NEVER an input: `--claim <anything>` is
# accepted and ignored, so no caller can pass a verdict in.
#
# WHY: on 2026-09-27 a Haiku implementer reported 1437-gbwi "met" while its
# own measurement read 76 s, then 70 s, against an "under 20 s" criterion, and
# nothing between the report and the acceptance ran the closure.
#
# VERDICTS (stdout; exit code in brackets):
#   ok:closure:<order>:<expected|rc=0>                           [0] one line per command
#   unmet:closure:<order>:expected=<E> measured=<M|none>          [1]
#   unmet:closure:<order>:rc=<n|timeout>                          [1] expected line present, rc wrong
#   unscoreable:closure:<order>:<why>                             [2] never ok
#     why = no-closure | declared | no-command-grammar | unsafe-command:<token>
#         | uncovered-criterion:<first words> | not-found
# Exit 2 means the closure could not be scored AS WRITTEN. That is a refusal to
# accept, not a pass: the orchestrator escalates, it does not accept.
#
# EXTRACTION. A closure is prose plus commands. The RUNNABLE part is its leading
# clause(s) in the scorable grammar the 977-448j guard already requires:
#   [VAR=value ...] (bash|sh) scripts/<x>.sh [args]  |  scripts/<x>.sh [args]
#   | (bash) ./build.sh [args]  |  cargo (test|run) [args]  |  litmus:<name>
# each optionally followed by `prints <token>` and `[and] exits <n>` (or
# `passes`); clauses chain with `and`. The EXPECTED output is the token after
# `prints`; `<placeholder>` inside it (e.g. <n>, <key12>, <sha>) matches any
# non-empty run of non-space characters. A stdout line satisfies it when one
# of its whitespace-separated fields matches the whole expected token. The
# expected rc is the number after `exits`, else 0.
#
# WHAT IS REFUSED RATHER THAN GUESSED. A closure scores as `ok` only if EVERY
# criterion is carried by a command, a printed token or an exit code. Text
# after the parsed clauses is allowed only when it is an explanation: `where …`
# (the arms a fixture checks), `PRE-FIX …`, or a parenthesis. Anything else —
# "with every existing ok line unchanged", "duration_ms under 20,000", or a
# standalone uppercase AND that opens a second criterion — is
# uncovered-criterion. 1437-gbwi's closure is exactly this case: its command
# exits 0 while its real criterion is a timing threshold, so a tool that
# checked only the exit code would have repeated the misreport.
#
# SAFETY. The command comes from ledger prose. It is split into argv and run
# directly, never through eval or `bash -c`. A token carrying a shell
# metacharacter (; | & $ ` < > ( ) quotes backslash) is refused.
#
# TIMEOUT: TILLANDSIAS_CLOSURE_TIMEOUT_S (default 1800), enforced by a watchdog
# process because macOS ships no timeout(1). CWD: the repo root.
# bash 3.2 clean; no jq (the 1375-tsfu ratchet); the plan binary reads the ledger.
set -uo pipefail

ROOT_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
order=""; index=""; root=""
while [ $# -gt 0 ]; do
    case "$1" in
        --index) index="${2:-}"; shift 2 ;;
        --root)  root="${2:-}"; shift 2 ;;
        --claim) echo "note: --claim is ignored; the verdict depends only on the command's output" >&2; shift 2 ;;
        --claim=*) echo "note: --claim is ignored; the verdict depends only on the command's output" >&2; shift ;;
        -h|--help) sed -n '4,49p' "$0"; exit 0 ;;
        -*) echo "usage: verify-closure.sh <order> [--index F] [--root D]" >&2; exit 2 ;;
        *) [ -z "$order" ] || { echo "usage: one <order>" >&2; exit 2; }; order="$1"; shift ;;
    esac
done
[ -n "$order" ] || { echo "usage: verify-closure.sh <order> [--index F] [--root D]" >&2; exit 2; }
root="${root:-$ROOT_DEFAULT}"
[ -n "$index" ] || index="$root/plan/index.yaml"

_plan="$(cd "$ROOT_DEFAULT" && . scripts/plan-binary-probe.sh && resolve_plan_binary 2>/dev/null)" || _plan=""
case "$_plan" in ./*) _plan="$ROOT_DEFAULT/${_plan#./}" ;; esac
[ -n "$_plan" ] || { echo "unscoreable:closure:$order:no-plan-binary"; exit 2; }
PLAN="$_plan"

refuse() { echo "unscoreable:closure:$order:$1"; exit 2; }

# ── the folded closure text ─────────────────────────────────────────────────
closure="$("$PLAN" --index "$index" query --json --limit 100000 2>/dev/null \
    | "$PLAN" json get -r --arg o "$order" '.[] | select((.order | tostring) == $o or .packet_id == $o) | .verifiable_closure' 2>/dev/null)"
case "$closure" in
    "") # distinguish "no such packet" from "packet with no closure"
        found="$("$PLAN" --index "$index" query --json --limit 100000 2>/dev/null \
            | "$PLAN" json get -r --arg o "$order" '.[] | select((.order | tostring) == $o or .packet_id == $o) | .packet_id' 2>/dev/null)"
        [ -n "$found" ] && refuse no-closure || refuse not-found ;;
    null) refuse no-closure ;;
esac

# One line, single spaces: the grammar is about words, not layout.
flat="$(printf '%s' "$closure" | tr '\n\t' '  ' | tr -s ' ')"
flat="${flat# }"
case "$flat" in [Uu]nscoreable:*) refuse declared ;; esac

# ── parse the leading clause(s) ─────────────────────────────────────────────
# shellcheck disable=SC2206
words=($flat)
n=${#words[@]}; i=0
cmds=(); expects=(); rcs=()

is_start() { # $1 = word, $2 = next word -> 0 when a command of the grammar starts here
    case "$1" in
        bash|sh) case "${2:-}" in scripts/*.sh|./build.sh|./build.sh,) return 0 ;; esac; return 1 ;;
        scripts/*.sh|./build.sh|litmus:*) return 0 ;;
        cargo) case "${2:-}" in test|run) return 0 ;; esac; return 1 ;;
    esac
    return 1
}
is_stop() {
    case "$1" in prints|passes|passes,|passes.|exits|and|with|where|when|over|under|within|AND) return 0 ;; esac
    return 1
}
unsafe() { case "$1" in *[\;\|\&\$\`\<\>\(\)\'\"\\]*) return 0 ;; esac; return 1; }

while [ "$i" -lt "$n" ]; do
    j=$i
    while [ "$j" -lt "$n" ] && [[ "${words[$j]}" =~ ^[A-Z_][A-Z0-9_]*=[^[:space:]]*$ ]]; do j=$((j + 1)); done
    [ "$j" -lt "$n" ] && is_start "${words[$j]}" "${words[$((j + 1))]:-}" || break
    cmd=()
    k=$i
    while [ "$k" -lt "$n" ]; do
        w="${words[$k]}"
        if [ "$k" -gt "$j" ] && is_stop "$w"; then break; fi
        last=0
        case "$w" in *,|*.|*\;) w="${w%?}"; last=1 ;; esac
        # a bare "." or "," is not part of a command
        if [ -n "$w" ]; then
            unsafe "$w" && refuse "unsafe-command:$w"
            cmd+=("$w")
        fi
        k=$((k + 1))
        [ "$last" = 1 ] && break
    done
    # litmus:<name> is run through the litmus runner.
    if [ "${#cmd[@]}" -ge 1 ] && [ "${cmd[0]#litmus:}" != "${cmd[0]}" ]; then
        cmd=(bash scripts/run-litmus-test.sh "${cmd[0]#litmus:}" --compact)
    fi
    expect=""; rc_want=0
    while [ "$k" -lt "$n" ]; do
        case "${words[$k]}" in
            prints) expect="${words[$((k + 1))]:-}"; expect="${expect%,}"; expect="${expect%.}"; expect="${expect%;}"; k=$((k + 2)) ;;
            exits)  rc_want="${words[$((k + 1))]:-0}"; rc_want="${rc_want%,}"; rc_want="${rc_want%.}"; k=$((k + 2)) ;;
            passes|passes,|passes.) k=$((k + 1)) ;;
            and)
                # "and exits 0" belongs to this clause; "and <command>" opens the next.
                if [ "${words[$((k + 1))]:-}" = "exits" ]; then k=$((k + 1)); else break; fi ;;
            *) break ;;
        esac
    done
    case "$rc_want" in ''|*[!0-9]*) refuse "uncovered-criterion:exits-${rc_want}" ;; esac
    cmds+=("$(printf '%s\x1f' "${cmd[@]}")"); expects+=("$expect"); rcs+=("$rc_want")
    i=$k
    # chain: "and <command>" -> next clause
    if [ "$i" -lt "$n" ] && [ "${words[$i]}" = "and" ]; then
        t=$((i + 1))
        while [ "$t" -lt "$n" ] && [[ "${words[$t]}" =~ ^[A-Z_][A-Z0-9_]*=[^[:space:]]*$ ]]; do t=$((t + 1)); done
        if [ "$t" -lt "$n" ] && is_start "${words[$t]}" "${words[$((t + 1))]:-}"; then i=$((i + 1)); continue; fi
    fi
    break
done
[ "${#cmds[@]}" -gt 0 ] || refuse no-command-grammar

# ── the remainder must be explanation, never another criterion ──────────────
rest=""; [ "$i" -lt "$n" ] && rest="${words[*]:$i}"
# "…exits 0 with the arms above" / "with the five arms against …" names the
# fixture's OWN arms, which the command already runs: explanation, not a new
# criterion. "with every existing ok line unchanged" (1437-gbwi) is not.
arms_re='^with (the |all )?([A-Za-z0-9-]+ )?arms?([^A-Za-z]|$)'
case "$rest" in
    ""|where*|where,*|Where*|PRE-FIX*|pre-fix*|Pre-fix*|\(*) : ;;
    *) [[ "$rest" =~ $arms_re ]] || refuse "uncovered-criterion:$(printf '%s' "$rest" | cut -d' ' -f1-6 | tr ' ' '_')" ;;
esac
for w in "${words[@]:$i}"; do [ "$w" = "AND" ] && refuse "uncovered-criterion:AND"; done

# ── run and compare ─────────────────────────────────────────────────────────
TIMEOUT_S="${TILLANDSIAS_CLOSURE_TIMEOUT_S:-1800}"
case "$TIMEOUT_S" in ''|*[!0-9]*) TIMEOUT_S=1800 ;; esac
out_file="$(mktemp "${TMPDIR:-/tmp}/verify-closure.XXXXXX")"
trap 'rm -f "$out_file" "$out_file.to"' EXIT

to_regex() { # expected token -> anchored ERE; <placeholder> = any non-space run
    printf '%s' "$1" | sed -e 's/[][\.*^$+?(){}|\/]/\\&/g' -e 's/<[A-Za-z0-9_-]*>/[^[:space:]]+/g'
}

worst=0
for idx in "${!cmds[@]}"; do
    IFS=$'\x1f' read -r -a argv <<<"${cmds[$idx]}"
    # Leading VAR=value words become the command's environment.
    envs=(); while [ "${#argv[@]}" -gt 0 ] && [[ "${argv[0]}" =~ ^[A-Z_][A-Z0-9_]*= ]]; do envs+=("${argv[0]}"); argv=("${argv[@]:1}"); done
    rm -f "$out_file.to"
    ( cd "$root" && exec env ${envs[@]+"${envs[@]}"} "${argv[@]}" ) >"$out_file" 2>/dev/null </dev/null &
    pid=$!
    # The watchdog must hold NO stdout: a caller capturing the verdict with
    # $(…) otherwise waits out the whole timeout on the inherited pipe even
    # after the command finished. And it kills its own sleep on TERM, or the
    # sleep outlives it. (Measured: a 900 s timeout held a $(…) caller for
    # the full 900 s after a 3 s fixture had returned.)
    (
        s=""
        trap '[ -n "$s" ] && kill "$s" 2>/dev/null; exit 0' TERM
        sleep "$TIMEOUT_S" & s=$!
        wait "$s"
        : > "$out_file.to"
        kill -TERM "$pid" 2>/dev/null
    ) </dev/null >/dev/null 2>&1 &
    watchdog=$!
    wait "$pid"; rc=$?
    kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
    [ -f "$out_file.to" ] && rc=timeout

    expect="${expects[$idx]}"; rc_want="${rcs[$idx]}"
    if [ -n "$expect" ]; then
        re="$(to_regex "$expect")"
        hit="$(awk -v re="^${re}\$" '{ for (f = 1; f <= NF; f++) if ($f ~ re) { print $f; exit } }' "$out_file")"
        if [ -z "$hit" ]; then
            # The closest measured token: same family (the segment after the first ':').
            fam="$(printf '%s' "$expect" | cut -d: -f2)"
            measured="$(awk -v fam="$fam" -F'[[:space:]]+' '{ for (f = 1; f <= NF; f++) { n = split($f, s, ":"); if (n >= 2 && s[2] == fam) { print $f; exit } } }' "$out_file")"
            echo "unmet:closure:$order:expected=$expect measured=${measured:-none}"
            worst=1; continue
        fi
        if [ "$rc" != "$rc_want" ]; then
            echo "unmet:closure:$order:rc=$rc"
            worst=1; continue
        fi
        echo "ok:closure:$order:$hit"
    else
        if [ "$rc" != "$rc_want" ]; then
            echo "unmet:closure:$order:rc=$rc"
            worst=1; continue
        fi
        # An rc-only criterion cannot tell a pass from a SKIP: fixtures exit 0
        # on skip:<reason> (no plan binary, no jq, …) having exercised nothing.
        last="$(awk 'NF { l = $0 } END { print l }' "$out_file")"
        case "$last" in
            skip:*|skipped:*) echo "unmet:closure:$order:skipped:${last%% *}"; worst=1; continue ;;
        esac
        echo "ok:closure:$order:rc=$rc"
    fi
done
exit "$worst"
