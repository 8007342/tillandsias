#!/usr/bin/env bash
# @trace spec:ci-release
# @trace order:1443-xkwb
#
# check-decider-retirement.sh — WHEN A BASH DECIDER RETIRES, by its own number.
#
# The bash deciders (check-bash-dialect, check-sigpipe-verdict-pipelines-added,
# check-jq-callsite-ratchet) were written for a bash corpus. As scripts move to
# scripts/lua, the corpus each one scans shrinks toward the shell that MUST stay
# shell: installers, the cargo bootstrap in build.sh, hook stubs, image
# entrypoints (design §6.5, listed in scripts/portability/bootstrap-shell-allowlist.txt).
# A decider whose whole population is that bootstrap set guards nothing that
# can still regress into bash, and can retire. Each decider prints
# `population=<n> bootstrap=<b>` on STDERR (its stdout verdict is an interface
# and unchanged); this script runs them and applies the rule.
#
# ADVISORY. It never fails a gate for a decider being live; it only answers.
#
# Usage: scripts/check-decider-retirement.sh [--root DIR]
#   --root DIR   the tree the deciders scan (default: this checkout). The
#                deciders themselves always come from THIS checkout.
#   TILLANDSIAS_BOOTSTRAP_ALLOWLIST   override the allowlist (fixtures); its
#                entries are then resolved against DIR instead of this checkout.
#
# Output, stdout, one line per decider then one summary line:
#   retire:<decider> population=<n> bootstrap=<n>    population equals bootstrap
#   live:<decider> population=<n> bootstrap=<b>      it still guards migratable shell
#   blocked:decider-retirement:<decider>:<why>       it could not answer; NEVER retire
#   ok:decider-retirement:<live> live                  exit 0
#   blocked:decider-retirement:<n> could not answer    exit 1
#   blocked:decider-retirement:dangling-allowlist-entry:<path>   exit 1, nothing run
#   could-not-run:decider-retirement:<why>           exit 2
#
# A decider whose population is EMPTY already refuses (1374-4u6i; the
# jq ratchet spells it blocked:jq-ratchet-empty-population). That refusal is
# carried through as blocked here: zero equals zero is not a retirement, it is
# a scan that saw nothing.
set -uo pipefail

SELF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$SELF_ROOT"
while [ $# -gt 0 ]; do
    case "$1" in
        --root)
            [ -n "${2:-}" ] || { echo "could-not-run:decider-retirement:--root-needs-a-dir"; exit 2; }
            ROOT="$(cd "$2" 2>/dev/null && pwd)" || { echo "could-not-run:decider-retirement:no-such-root:$2"; exit 2; }
            shift 2 ;;
        *) echo "could-not-run:decider-retirement:unknown-argument:$1"; exit 2 ;;
    esac
done

if [ -n "${TILLANDSIAS_BOOTSTRAP_ALLOWLIST:-}" ]; then
    ALLOWLIST="$TILLANDSIAS_BOOTSTRAP_ALLOWLIST"
    ENTRY_ROOT="$ROOT"
else
    ALLOWLIST="$SELF_ROOT/scripts/portability/bootstrap-shell-allowlist.txt"
    ENTRY_ROOT="$SELF_ROOT"
fi
[ -f "$ALLOWLIST" ] || { echo "could-not-run:decider-retirement:no-allowlist:$ALLOWLIST"; exit 2; }
export TILLANDSIAS_BOOTSTRAP_ALLOWLIST="$ALLOWLIST"

# A dangling entry would count toward nothing and hide that the list is stale.
while read -r entry _; do
    case "$entry" in ''|'#'*) continue ;; esac
    if [ ! -e "$ENTRY_ROOT/$entry" ]; then
        echo "blocked:decider-retirement:dangling-allowlist-entry:$entry"
        echo "  $ALLOWLIST names $entry, which does not exist under $ENTRY_ROOT" >&2
        exit 1
    fi
done < "$ALLOWLIST"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/decider-retirement.XXXXXX")" || { echo "could-not-run:decider-retirement:mktemp"; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# run_decider <name>: stdout to $WORK/<name>.out, stderr to $WORK/<name>.err.
# Each decider is driven through its OWN root seam, never by editing it.
# 1384-ddua: check-bash-dialect is a Lua decider on the one runner.
_dr_plan="$(cd "$SELF_ROOT" && . scripts/plan-binary-probe.sh 2>/dev/null && resolve_plan_binary 2>/dev/null)" || _dr_plan=""
case "$_dr_plan" in ./*) _dr_plan="$SELF_ROOT/${_dr_plan#./}" ;; esac

run_decider() {
    local name="$1" script="$SELF_ROOT/scripts/$1.sh"
    [ -f "$SELF_ROOT/scripts/lua/$1.lua" ] && script="$SELF_ROOT/scripts/lua/$1.lua"
    [ -f "$script" ] || { echo "could-not-run:decider-retirement:missing-decider:$name" > "$WORK/$name.out"; : > "$WORK/$name.err"; return; }
    case "$name" in
        check-bash-dialect)
            if [ -z "$_dr_plan" ]; then echo "could-not-run:decider-retirement:no-script-runner:$name" > "$WORK/$name.out"; : > "$WORK/$name.err"; return; fi
            ( cd "$ROOT" && "$_dr_plan" script run "$script" ) > "$WORK/$name.out" 2> "$WORK/$name.err" ;;
        check-jq-callsite-ratchet)
            bash "$script" --root "$ROOT" > "$WORK/$name.out" 2> "$WORK/$name.err" ;;
        check-sigpipe-verdict-pipelines-added)
            TILLANDSIAS_SIGPIPE_ROOT="$ROOT" bash "$script" > "$WORK/$name.out" 2> "$WORK/$name.err" ;;
    esac
}

live=0
unanswered=0
for d in check-bash-dialect check-sigpipe-verdict-pipelines-added check-jq-callsite-ratchet; do
    run_decider "$d"
    verdict="$(sed -n '1p' "$WORK/$d.out")"
    counts="$(grep -E '^population=[0-9]+ bootstrap=[0-9]+$' "$WORK/$d.err" | tail -n 1)"
    case "$verdict" in
        *scan-empty*|*empty-population*|could-not-run:*)
            echo "blocked:decider-retirement:$d:$verdict"
            unanswered=$((unanswered + 1))
            continue ;;
    esac
    if [ -z "$counts" ]; then
        echo "blocked:decider-retirement:$d:no-population-line"
        unanswered=$((unanswered + 1))
        continue
    fi
    n="${counts#population=}"; n="${n%% *}"
    b="${counts##*bootstrap=}"
    if [ "$n" -gt 0 ] && [ "$n" -eq "$b" ]; then
        echo "retire:$d population=$n bootstrap=$b"
    else
        echo "live:$d population=$n bootstrap=$b"
        live=$((live + 1))
    fi
done

if [ "$unanswered" -gt 0 ]; then
    echo "blocked:decider-retirement:$unanswered could not answer"
    exit 1
fi
echo "ok:decider-retirement:$live live"
exit 0
