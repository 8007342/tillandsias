#!/usr/bin/env bash
# @trace order:614-2gqx, spec:meta-orchestration
set -uo pipefail

# check-mo-full-attestations.sh — the pre-push gate for the durable MO-FULL
# attestation ledger (plan/mo-full-attestations.d/, packet 651-2x5s).
#
# WHY THIS EXISTS. The terminal marker (614-2gqx) is emitted into a transcript
# nothing parses unless the litmus launcher runs — and a cycle driven by an
# operator prompt or ./repeat never is. A marker that lives only there is
# decorative (the 2026-08-10 breach: 8 real + 32 invented SHA characters), and
# a decorative attestation is worse than none. `scripts/mo-full-attest.sh
# record` makes it durable by appending the VERIFIED line to the per-host
# ledger; this gate refuses to let a tampered, fabricated, or unreachable line
# reach origin.
#
# What is enforced, and where:
#   * EVERY file, grammar: `MO-FULL: <DISP> <LOCAL_SHA> <BRANCH> <REMOTE_SHA>`
#     with DISP ∈ {COMPLETE,BLOCKED}, 40-hex SHAs, LOCAL_SHA == REMOTE_SHA, a
#     branch name, and a well-formed `## <ISO-UTC> <host>` heading before each
#     marker. Structural garbage fails on ANY host that runs the gate.
#   * THE CURRENT HOST'S FILE only: each LOCAL_SHA must be a real commit object
#     (`git cat-file -e`) and reachable from the local branch ref it names
#     (`git merge-base --is-ancestor`). Durability is per-host: `record`
#     verified remote convergence at write time, and the owning host's gate
#     re-proves it at push time. Cross-host markers are grammar-swept only — an
#     object may not be fetched yet, so one host can never red another host's
#     gate (the repo's diff-scoped posture: you break it, YOUR push fails).
#     This is also what automation consumes: a ledger LOCAL_SHA is verified as
#     REACHABLE, not as equal to the current remote head (the head advances
#     with the bookkeeping commit — see methodology/mo-full-attestation.yaml).
#
# A missing ledger directory passes vacuously (0 files) — the directory is
# committed, so any synced checkout has it; the gate never hard-fails because
# its own helper (`mo-full-attest.sh host`) is absent, only because the DATA is
# bad.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

SHA_RE='^[0-9a-f]{40}$'
TS_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
BRANCH_RE='^[A-Za-z0-9][A-Za-z0-9._/-]*$'

ledger_dir="plan/mo-full-attestations.d"
violations=0
markers=0
files=0
own_file=""

host="$(bash scripts/mo-full-attest.sh host 2>/dev/null | tr -d '[:space:]' || true)"
if [ -n "$host" ] && [ -f "$ledger_dir/$host.md" ]; then
    own_file="$ledger_dir/$host.md"
fi

refuse() { # refuse <file> <detail...>
    violations=$((violations + 1))
    echo "REFUSED: $1" >&2
    shift
    printf '   %s\n' "$@" >&2
}

# shellcheck disable=SC2094   # refuse() writes stderr only; $f is read, never written
verify_file() { # verify_file <path>
    local f="$1"
    local line_no ln heading ts hbranch marker disp local_sha branch remote_sha
    local last_heading="" heading_marker=0 seen_heading=0

    # Track heading→marker pairing: each `## <ts> <host>` heading must be
    # immediately followed by exactly one marker line, and every marker must
    # follow a heading.
    ln=0
    while IFS= read -r line_no || [ -n "$line_no" ]; do
        ln=$((ln + 1))
        case "$line_no" in
            '## '*)
                if [ "$heading_marker" -ne 0 ]; then
                    refuse "$f" "heading at line $ln has no following marker line (parsing becomes ambiguous)"
                fi
                heading="${line_no#\#\# }"
                ts="${heading%% *}"
                hbranch="${heading#* }"
                if ! printf '%s' "$ts" | grep -qE "$TS_RE" || [ -z "$hbranch" ]; then
                    refuse "$f" "malformed heading at line $ln: '$line_no' (want '## <ISO-UTC-ts> <host>')"
                fi
                last_heading="$heading"
                heading_marker=0
                seen_heading=1
                ;;
            ''|'#'*|'--'*)
                # blanks, the header block, and rule-off comments are inert
                ;;
            'MO-FULL: '*)
                marker="$line_no"
                markers=$((markers + 1))
                if [ "$seen_heading" -eq 0 ]; then
                    refuse "$f" "marker at line $ln precedes any '## <ts> <host>' heading: $marker"
                fi
                if [ "$heading_marker" -ne 0 ]; then
                    refuse "$f" "more than one marker after heading '$last_heading' at line $ln"
                fi
                heading_marker=1
                # shellcheck disable=SC2034
                read -r _tag disp local_sha branch remote_sha <<< "$marker"
                case "$disp" in
                    COMPLETE|BLOCKED) ;;
                    *) refuse "$f" "malformed disposition '$disp' at line $ln: $marker" ;;
                esac
                if ! printf '%s' "$local_sha" | grep -qE "$SHA_RE" \
                    || ! printf '%s' "$remote_sha" | grep -qE "$SHA_RE"; then
                    refuse "$f" "malformed sha at line $ln: $marker"
                fi
                if [ "$local_sha" != "$remote_sha" ]; then
                    refuse "$f" "unpushed commit claim at line $ln (LOCAL_SHA != REMOTE_SHA): $marker"
                fi
                if ! printf '%s' "$branch" | grep -qE "$BRANCH_RE"; then
                    refuse "$f" "malformed branch '$branch' at line $ln: $marker"
                fi
                if [ "$f" = "$own_file" ]; then
                    if ! git cat-file -e "$local_sha^{commit}" 2>/dev/null; then
                        refuse "$f" "LOCAL_SHA $local_sha is not a real commit in this repo — fabricated or tampered (line $ln): $marker"
                    elif ! git show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
                        refuse "$f" "marker claims branch '$branch' with no local ref — this host records only its own branches, so this is tampered or lost history (line $ln): $marker"
                    elif ! git merge-base --is-ancestor "$local_sha" "refs/heads/$branch" 2>/dev/null; then
                        refuse "$f" "LOCAL_SHA $local_sha is not reachable from refs/heads/$branch — recorded marker was never a durable ancestor (line $ln): $marker"
                    fi
                fi
                ;;
            *)
                refuse "$f" "unexpected line at line $ln: '$line_no' (want 'MO-FULL: …', '## …', or a header comment)"
                ;;
        esac
    done <"$f"
    if [ "$heading_marker" -eq 0 ] && [ -n "$last_heading" ]; then
        refuse "$f" "heading '$last_heading' has no following marker line"
    fi
}

if [ -d "$ledger_dir" ]; then
    for f in "$ledger_dir"/*.md; do
        [ -e "$f" ] || continue
        case "$f" in
            */README.md) continue ;;   # contract prose, not a ledger
        esac
        files=$((files + 1))
        verify_file "$f"
    done
fi

if [ "$violations" -gt 0 ]; then
    echo "violation:mo-full-attestations:$violations"
    exit 1
fi
if [ "$files" -eq 0 ]; then
    echo "ok:mo-full-attestations:no-ledger-dir 0 markers verified"
    exit 0
fi
if [ -z "$own_file" ]; then
    echo "ok:mo-full-attestations:$files files $markers markers grammar-verified (no own-host file '$host.md' — reachability owned by the recording host)"
    exit 0
fi
echo "ok:mo-full-attestations:$files files $markers markers verified ($host.md reachability-checked)"
exit 0
