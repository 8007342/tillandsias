#!/usr/bin/env bash
# @trace order:1406-9ctt, order:756-rfdr, spec:binary-signing
#
# Every `gh release upload <tag> <dir>/*` in a release workflow must be preceded,
# IN THE SAME JOB, by `check-release-asset-integrity.sh <dir>` over that same
# directory. A whole-file count of the check (the old pin, "exactly 2") went
# red when a job gained a correct check, and stayed green while macos-release
# uploaded twice with none: it counted the words, not which upload they gated.
#
# GRAMMAR (exactly one line on stdout)
#   ok:release-uploads-gated:<n> uploads in <j> jobs
#   refused:release-uploads-gated:ungated=<job>:<dir>[,...]
#   could-not-run:release-uploads-gated:<reason>
set -uo pipefail
wf="${1:-.github/workflows/release.yml}"
[ -f "$wf" ] || { echo "could-not-run:release-uploads-gated:no-file:$wf"; exit 3; }
awk '
    # Comments cannot publish anything (and name `gh release upload` in prose).
    /^[[:space:]]*#/ { next }
    # A job header: two-space indent, a key, a colon, nothing after.
    /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { job = $1; sub(/:$/, "", job); delete gated; cwd = ""; next }
    # Each step runs in a fresh shell at the workspace root.
    /^[[:space:]]*- name:/ { cwd = ""; cont = 0 }
    /^[[:space:]]*cd[[:space:]]+[^[:space:]]+[[:space:]]*$/ { cwd = ($2 == ".." ? "" : $2) }
    /check-release-asset-integrity\.sh[[:space:]]+[^[:space:]]+/ {
        for (i = 1; i < NF; i++) if ($i ~ /check-release-asset-integrity\.sh$/) {
            g = $(i + 1); if (g == ".") g = cwd; gated[g] = 1
        }
    }
    # A publishing command, and the backslash-continued lines under it.
    /gh release (upload|create)/ { cont = 1 }
    cont {
        for (i = 1; i <= NF; i++) if ($i ~ /\/\*$/) {
            d = $i; sub(/\/\*$/, "", d); n++; jobs[job] = 1
            if (!(d in gated)) bad = bad (bad == "" ? "" : ",") job ":" d
        }
        cont = ($NF == "\\")
    }
    END {
        for (j in jobs) nj++
        if (n == 0) { print "could-not-run:release-uploads-gated:no-uploads-found"; exit 3 }
        if (bad != "") { print "refused:release-uploads-gated:ungated=" bad; exit 1 }
        printf "ok:release-uploads-gated:%d uploads in %d jobs\n", n, nj
    }
' "$wf"
