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

# Hermetic scenario fixtures (order 742-ye7w, pinned by
# litmus:mo-full-attestation-ledger-shape). Nothing here touches the real ledger:
# each scenario builds a throwaway repo and writes a ledger for a host name that
# is NOT this host, so the reachability branch stays out of the way and the
# PARSER is what gets exercised.
#
# The multi-entry scenario is the regression that motivated all of this: the
# heading branch tested `heading_marker -ne 0`, which is true exactly when the
# previous heading WAS correctly paired, so a second appended attestation was
# refused. No litmus pinned this checker, so the inversion shipped and every
# host's second full-mode cycle would have failed ./build.sh --check.
if [ "${1:-}" = "fixture" ]; then
    _fx_self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    _fx_dir="$(mktemp -d)"
    _fx_fail=0
    _fx_sha_a="$(printf '%040d' 1)"
    _fx_sha_b="$(printf '%040d' 2)"

    _fx_case() { # _fx_case <name> <want:ok|refuse> <ledger-body>
        _n="$1"; _want="$2"; _body="$3"
        rm -rf "$_fx_dir/repo"
        mkdir -p "$_fx_dir/repo/plan/mo-full-attestations.d" "$_fx_dir/repo/scripts"
        ( cd "$_fx_dir/repo" && git init -q . ) >/dev/null 2>&1
        printf '%s' "$_body" >"$_fx_dir/repo/plan/mo-full-attestations.d/fixturehost.md"
        # The checker resolves ROOT from its OWN location and cd's there, so a
        # fixture that merely cd's into a temp repo silently validates the REAL
        # ledger and every scenario "passes". Run a COPY inside the fixture repo.
        cp "$_fx_self" "$_fx_dir/repo/scripts/"
        _out="$( cd "$_fx_dir/repo" && bash "scripts/$(basename "$_fx_self")" 2>&1 )"
        _rc=$?
        if [ "$_want" = ok ] && [ "$_rc" = 0 ]; then
            echo "ok: $_n"
        elif [ "$_want" = refuse ] && [ "$_rc" != 0 ]; then
            echo "ok: $_n (refused as required)"
        else
            echo "FAIL: $_n wanted $_want, rc=$_rc out=$_out"
            _fx_fail=1
        fi
    }

    _fx_hdr='# MO-FULL attestation ledger
'
    _fx_case "single-entry-passes" ok "$_fx_hdr
## 2026-08-15T00:00:00Z fixturehost
MO-FULL: COMPLETE $_fx_sha_a linux-next $_fx_sha_a
"
    # THE REGRESSION (742-ye7w): a ledger must hold more than one cycle.
    _fx_case "REGRESSION multi-entry-ledger-passes" ok "$_fx_hdr
## 2026-08-15T00:00:00Z fixturehost
MO-FULL: COMPLETE $_fx_sha_a linux-next $_fx_sha_a

## 2026-08-15T01:00:00Z fixturehost
MO-FULL: COMPLETE $_fx_sha_b linux-next $_fx_sha_b
"
    _fx_case "three-entry-ledger-passes" ok "$_fx_hdr
## 2026-08-15T00:00:00Z fixturehost
MO-FULL: COMPLETE $_fx_sha_a linux-next $_fx_sha_a

## 2026-08-15T01:00:00Z fixturehost
MO-FULL: COMPLETE $_fx_sha_b linux-next $_fx_sha_b

## 2026-08-15T02:00:00Z fixturehost
MO-FULL: BLOCKED $_fx_sha_a linux-next $_fx_sha_a
"
    # NEGATIVE CONTROLS — the pairing rule must still bite.
    _fx_case "NEGATIVE unpaired-trailing-heading-refused" refuse "$_fx_hdr
## 2026-08-15T00:00:00Z fixturehost
MO-FULL: COMPLETE $_fx_sha_a linux-next $_fx_sha_a

## 2026-08-15T01:00:00Z fixturehost
"
    _fx_case "NEGATIVE heading-followed-by-heading-refused" refuse "$_fx_hdr
## 2026-08-15T00:00:00Z fixturehost

## 2026-08-15T01:00:00Z fixturehost
MO-FULL: COMPLETE $_fx_sha_a linux-next $_fx_sha_a
"
    _fx_case "NEGATIVE two-markers-under-one-heading-refused" refuse "$_fx_hdr
## 2026-08-15T00:00:00Z fixturehost
MO-FULL: COMPLETE $_fx_sha_a linux-next $_fx_sha_a
MO-FULL: COMPLETE $_fx_sha_b linux-next $_fx_sha_b
"
    _fx_case "NEGATIVE marker-before-any-heading-refused" refuse "$_fx_hdr
MO-FULL: COMPLETE $_fx_sha_a linux-next $_fx_sha_a
"
    _fx_case "NEGATIVE unpushed-claim-local-ne-remote-refused" refuse "$_fx_hdr
## 2026-08-15T00:00:00Z fixturehost
MO-FULL: COMPLETE $_fx_sha_a linux-next $_fx_sha_b
"
    rm -rf "$_fx_dir"
    [ "$_fx_fail" = 0 ] && echo "ok: all mo-full-attestation-ledger scenarios passed"
    exit "$_fx_fail"
fi

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
                # Refuse when the PREVIOUS heading never got a marker. The sense
                # matters: `heading_marker=1` means "a marker was seen for the
                # heading we are leaving", so testing `-ne 0` here refused every
                # correctly-paired entry the moment a SECOND one was appended —
                # i.e. the ledger accepted exactly one attestation per host, and
                # every host's second full-mode cycle failed ./build.sh --check
                # and could not push. The EOF check below already uses the
                # correct sense, which is what makes the inversion visible.
                if [ "$seen_heading" -ne 0 ] && [ "$heading_marker" -eq 0 ]; then
                    refuse "$f" "heading '$last_heading' has no following marker line (parsing becomes ambiguous)"
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
