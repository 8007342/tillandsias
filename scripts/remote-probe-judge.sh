# shellcheck shell=bash
# @trace order:2256-tt3v, order:2239-rmun
# Sourced by ./build.sh --preflight and the pre-push hook, from the repo root,
# after scripts/plan-binary-probe.sh. Only the probe's own verdict suspends a
# host: a probe that CRASHED (a plan binary older than the script, say) says
# nothing about the remote (yolanda: a stale guest binary read as "SUSPEND").
#
# remote_probe_judge <plan-binary>
#   0  ok, or could-not-run:remote-probe:script-error (named on stderr, not judged)
#   10 blocked:remote-unreachable:<cause>; the probe's output is on stderr.
#      Its own code: a caller whose `.` failed (1) must not read as blocked.
remote_probe_judge() {
    local out rc=0 l
    out="$("$1" script run scripts/lua/probe-remote-reachable.lua 2>&1)" || rc=$?
    while IFS= read -r l; do
        case "$rc:$l" in
            0:ok:remote-reachable) return 0 ;;
            1:blocked:remote-unreachable:[a-z]*) printf '%s\n' "$out" >&2; return 10 ;;
        esac
    done <<<"$out"
    printf '%s\n' "$out" >&2
    echo "could-not-run:remote-probe:script-error" >&2
    if plan_binary_is_stale "$1"; then
        echo "  why: the probe gave no verdict (rc=$rc), and $1 is older than crates/tillandsias-plan, so it likely predates what the script needs; the remote was NOT judged" >&2
        echo "  remedy: cargo build --release -p tillandsias-plan, then re-run. Do not suspend this host for it" >&2
    else
        echo "  why: the probe gave no verdict (rc=$rc; its output is above); the remote was NOT judged" >&2
        echo "  remedy: fix or report the script error. Do not suspend this host for it; a real outage still fails the push" >&2
    fi
    return 0
}
