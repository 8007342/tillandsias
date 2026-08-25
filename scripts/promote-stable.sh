#!/usr/bin/env bash
# @trace spec:ci-release
# promote-stable.sh — promote a vetted daily release to the STABLE channel.
# Plan order 305 (stable-release-channel).
#
# Dailies are published as PRE-releases (release.yml), so the README's
# /releases/latest/download/... install URLs resolve to the newest
# NON-prerelease — i.e. whatever this script last promoted. Promotion:
#   1. requires curl-install e2e PASS evidence for the tag in plan/
#      (the operator-owned gate; --force overrides with a loud record),
#   2. flips the release to prerelease=false and marks it "latest",
#   3. moves the annotated `stable` git tag to the release commit.
# DEMOTING A MISTAKEN PROMOTION IS NOT ONE COMMAND, and this comment used to
# claim it was (`gh release edit <tag> --prerelease`). Measured false on
# 2026-08-23: that sets prerelease=true and /releases/latest GOES ON SERVING THE
# DEMOTED TAG, because GitHub's `make_latest` is sticky — it is not recomputed
# from "newest non-prerelease by date" just because the current holder became a
# prerelease. DEMOTION IS NOT THE INVERSE OF PROMOTION ON THE GITHUB API.
# Do not hand-run the steps: use the subcommand, which performs them in order
# and then VERIFIES by re-reading /releases/latest instead of assuming.
#   scripts/promote-stable.sh demote <mistaken-tag> --to <intended-tag>
# Order 864-mk2p.
#
# Output grammar (last line, falsifiable):
#   ^promoted:v[0-9][A-Za-z0-9.\-]*$              promotion happened
#   ^would-promote:v[0-9][A-Za-z0-9.\-]*$         --dry-run, gates all passed
#   ^demoted:<mistaken>:latest-now:<intended>$    demotion happened AND verified
#   ^would-demote:<mistaken>:latest-would-be:<intended>$   --dry-run
#   ^refused:(no-evidence|no-release|bad-tag|missing-target|demote-verify-failed):.*$
#                                                 refusal (exit 1)
#
# --dry-run RUNS EVERY GATE AND MUTATES NOTHING (order 864-8tqv). It exists
# because the only observable this script offered was its side effect, so the
# natural way to test a change to the evidence gate — run it and read the
# verdict — published a channel change to every user. That happened on
# 2026-08-23: piping this script to `head -4` promoted a release and then
# SIGPIPE-killed it between the `gh release edit` and the stable-tag push,
# leaving the GitHub release and the git tag disagreeing. A command whose effect
# is outward-facing should be ASKABLE.
#
# Usage:
#   scripts/promote-stable.sh vX.Y.YYMMDD.N [--force] [--dry-run]
#   scripts/promote-stable.sh demote <mistaken-tag> --to <intended-tag> [--dry-run]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Flags are order-independent. The old form took --force positionally as $2, so
# `<tag> --force` still parses; `<tag> --dry-run --force` now does too, which the
# positional form silently ignored.
MODE="promote"
TAG=""
TARGET=""
FORCE=""
DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        demote)     MODE="demote" ;;
        --force)    FORCE="--force" ;;
        --dry-run)  DRY_RUN=1 ;;
        --to)       shift; TARGET="${1:-}" ;;
        -*)         echo "usage: $0 vX.Y.YYMMDD.N [--force] [--dry-run]" >&2
                    echo "refused:bad-tag:$1"; exit 1 ;;
        *)          if [ -z "$TAG" ]; then TAG="$1"; else TARGET="$1"; fi ;;
    esac
    shift
done

# A tag is well-formed or it is not; both paths need the same answer.
_valid_tag() { printf '%s' "${1:-}" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; }

# owner/repo for the endpoints `gh release` does not cover. Derived, never
# hardcoded: this script is read by other forks of the runbook.
_nwo() { gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null; }

if [ -z "$TAG" ] || ! _valid_tag "$TAG"; then
    echo "usage: $0 vX.Y.YYMMDD.N [--force] [--dry-run]" >&2
    echo "refused:bad-tag:${TAG:-<empty>}"
    exit 1
fi

if [ "$MODE" = "demote" ]; then
    # 864-mk2p. Demotion is NOT the inverse of promotion: GitHub's make_latest
    # is sticky, so flipping the mistaken release to prerelease leaves
    # /releases/latest still serving it. The intended release must be named and
    # explicitly re-marked, and then the RESULT must be read back — the whole
    # defect was a remediation step that reported success while the channel
    # stayed wrong.
    if [ -z "$TARGET" ] || ! _valid_tag "$TARGET"; then
        echo "demote needs the release that SHOULD be latest: $0 demote <mistaken> --to <intended>" >&2
        echo "refused:missing-target:${TARGET:-<empty>}"
        exit 1
    fi
    for _t in "$TAG" "$TARGET"; do
        if ! gh release view "$_t" >/dev/null 2>&1; then
            echo "refused:no-release:$_t"
            exit 1
        fi
    done

    NWO="$(_nwo)"
    if [ -z "$NWO" ]; then
        echo "cannot resolve owner/repo; is gh authenticated for this remote?" >&2
        echo "refused:no-release:$TAG"
        exit 1
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "would demote $TAG, re-mark $TARGET as latest, and move the stable tag." >&2
        echo "would-demote:$TAG:latest-would-be:$TARGET"
        exit 0
    fi

    TARGET_ID="$(gh api "repos/$NWO/releases/tags/$TARGET" --jq .id 2>/dev/null)"
    if [ -z "$TARGET_ID" ]; then
        echo "refused:no-release:$TARGET"
        exit 1
    fi

    gh release edit "$TAG" --prerelease --latest=false
    gh api -X PATCH "repos/$NWO/releases/$TARGET_ID" -f make_latest=true >/dev/null

    TARGET_COMMIT="$(gh release view "$TARGET" --json targetCommitish --jq '.targetCommitish')"
    git -C "$REPO_ROOT" tag -f -a stable -m "Stable channel: demoted $TAG, restored $TARGET" "$TARGET_COMMIT"
    git -C "$REPO_ROOT" push origin refs/tags/stable --force

    # VERIFY, never assume. This read is the entire point of the packet: the
    # documented one-liner reported success with the channel still wrong.
    LATEST_NOW="$(gh api "repos/$NWO/releases/latest" --jq .tag_name 2>/dev/null)"
    if [ "$LATEST_NOW" != "$TARGET" ]; then
        echo "DEMOTION DID NOT TAKE: /releases/latest still resolves to ${LATEST_NOW:-<unknown>}, not $TARGET." >&2
        echo "make_latest is sticky; re-run or PATCH make_latest=true on $TARGET by hand, then re-verify." >&2
        echo "refused:demote-verify-failed:$LATEST_NOW"
        exit 1
    fi
    echo "/releases/latest verified: now resolves to $TARGET." >&2
    echo "demoted:$TAG:latest-now:$TARGET"
    exit 0
fi

if ! gh release view "$TAG" >/dev/null 2>&1; then
    echo "refused:no-release:$TAG"
    exit 1
fi

# Evidence gate: a dated plan record of a curl-install (or local-build) e2e
# PASS naming this exact tag/version. Promotion is an explicit operator
# (Tlatoani) action; the gate makes "vetted" falsifiable rather than vibes.
VERSION_NO_V="${TAG#v}"
# Dots are regex wildcards: an unescaped 0.4.260817.1 also matches 0X4X260817X1.
# On a gate that decides releases, accidental permissiveness is the wrong
# direction to be sloppy in.
VERSION_RE="$(printf '%s' "$VERSION_NO_V" | sed 's/\./\\./g')"

# GREP IS LINE-SCOPED, AND THE EVIDENCE IS NOT ALL ON ONE LINE.
#
# The original pattern required "e2e" or "smoke" AND "PASS" AND the version to
# co-occur on a SINGLE line. The e2e skill does not write that line. What it
# writes is plan/issues/smoke-e2e-findings-v<version>-<date>.md containing
#   ## Run 2026-08-17T17:58Z→18:06Z — **PASS** (tag v0.4.260817.1, build …)
# The words "smoke" and "e2e" are in the FILENAME; the PASS and the version are
# on a heading that never repeats them. So a real, dated, unambiguous PASS for
# v0.4.260817.1 existed from 2026-08-17 and this gate reported "No e2e PASS
# evidence" for six days — which is why nothing was promoted, which is why
# hosts then deferred running the e2e ("no release newer than last tested
# evidence"), which is why nothing moved.
#
# The fix keeps the gate falsifiable and does NOT loosen what counts as
# evidence. A file still has to (a) identify itself as e2e/smoke evidence, and
# (b) contain a line asserting PASS for THIS EXACT version. The only change is
# that (a) may be satisfied by the file's name rather than by the same line as
# the verdict.
# ── PLATFORM-AWARE EVIDENCE (order 888-p3kt) ─────────────────────────────────
#
# TWO DEFECTS, both measured on 2026-08-25 against the live ledger.
#
# (1) PLATFORM-BLIND. The gate asked only "does SOME file under plan/ assert a
#     PASS for this version". Tillandsias ships three platforms and the
#     operator's acceptance criterion is that each one passed; one platform's
#     PASS satisfied the gate for all three. A release could be promoted on
#     Windows evidence alone with linux and macos never run.
#
# (2) IT WAS PASSING ON JUNK. For v0.4.260817.1 the two files that satisfied
#     branch 1 were plan/index.yaml — whose packet body DESCRIBES this gate's
#     own past defect, so the words "smoke", "PASS" and the version co-occur
#     while describing a bug — and a freshness-audit line in a loop_status
#     entry. The REAL report was reachable only through the filename fallback,
#     which never ran because branch 1 had already matched. The verdict was
#     accidentally right; the mechanism was not.
#
# LEDGERS ARE NOT REPORTS. The fix for (2) is to stop reading bookkeeping
# surfaces as evidence at all. plan/index.yaml, plan/index.d/, the loop-status
# ledgers, the attestation ledger and plan/archive/ are places where a version
# string and the word PASS co-occur constantly and mean nothing about a test
# run. Evidence lives in a REPORT — which is what /smoke-curl-install-and-test-e2e
# actually writes, and what a human would point at.
#
# PLATFORM DETECTION IS SCOPED, NOT WHOLE-FILE — and this is the subtle part.
# The genuine Windows report for v0.4.260817.1 contains the sentence "that lane
# is Linux/Podman per the skill's §0.1". A whole-file grep for "linux" marks it
# as linux evidence too, which reproduces defect (2) one level down: incidental
# co-occurrence, now deciding platform coverage instead of existence. So the
# platform is read ONLY from the filename and the file's first heading line —
# both of which are authored as identity, not prose. Verified against all four
# real reports in the ledger.
_ev_required="${TILLANDSIAS_REQUIRED_PLATFORMS:-linux macos windows}"
_ev_found=""
_ev_disclaimed=""
_ev_src=""

# Ledger surfaces: never evidence, however the words fall on a line.
_ev_is_ledger() {
    case "${1#"$REPO_ROOT/"}" in
        plan/index.yaml|plan/index.d/*|\
        plan/loop_status.md|plan/loop_status.d/*|\
        plan/mo-full-attestations.d/*|plan/archive/*) return 0 ;;
    esac
    return 1
}

# Platform tokens from the filename + the first heading line ONLY.
_ev_platforms_of() {
    local _f="$1" _hay _p=""
    _hay="$(basename "$_f")
$(grep -m1 -E '^#' "$_f" 2>/dev/null || true)"
    _hay="$(printf '%s' "$_hay" | tr 'A-Z' 'a-z')"
    case "$_hay" in *linux*|*silverblue*)          _p="$_p linux" ;; esac
    case "$_hay" in *macos*|*darwin*|*osx*|*mac\ os*) _p="$_p macos" ;; esac
    case "$_hay" in *windows*|*wsl*)               _p="$_p windows" ;; esac
    printf '%s' "$_p"
}

_ev_note_file() {
    local _f="$1" _p
    _p="$(_ev_platforms_of "$_f")"
    [ -n "$_p" ] || return 0
    _ev_found="$_ev_found$_p"
    for _q in $_p; do _ev_src="$_ev_src
  $_q	${_f#"$REPO_ROOT/"}"; done
    # A report may assert PASS while explicitly disclaiming promotion clearance
    # ("run-scoped; does NOT clear promotion"). The matcher still counts it —
    # reading intent out of prose is a rule that rots — but the operator must
    # SEE it, so it is surfaced loudly below rather than silently absorbed.
    if grep -qiE 'does not clear promotion|run-scoped' "$_f" 2>/dev/null; then
        _ev_disclaimed="$_ev_disclaimed ${_f#"$REPO_ROOT/"}"
    fi
}

# ONE RULE, not two. A file counts as evidence iff it (a) NAMES itself as an
# e2e/smoke/findings report, (b) asserts PASS for THIS EXACT version, and (c)
# has a detectable platform. The verdict line need not repeat "e2e"/"smoke" —
# that was the 2026-08-23 false-negative and it stays fixed.
#
# THE SECOND PASS THIS REPLACES WAS THE BUG. It accepted ANY file under plan/
# with "e2e|smoke" + "PASS" + the version on one line, which is how a packet
# body describing this gate's own defect became evidence. Worse, measured on
# plan/issues/windows-next-work-queue-2026-07.md: that pass accepted a line
# reading "run PASS end-to-end ... but promotion verdict for the tag UNCHANGED
# (morning FAIL)". A line that says the promotion verdict is FAIL was counting
# as promotion evidence. Requiring report identity makes the second pass a
# strict subset of this one, so there is now only one rule to reason about.
while IFS= read -r _f; do
    [ -n "$_f" ] || continue
    _ev_is_ledger "$_f" && continue
    grep -qE "(PASS|pass).*${VERSION_RE}|${VERSION_RE}.*(PASS|pass)" "$_f" 2>/dev/null || continue
    _ev_note_file "$_f"
done <<EOF
$(find "$REPO_ROOT/plan" -type f \( -iname "*e2e*" -o -iname "*smoke*" -o -iname "*findings*" \) 2>/dev/null)
EOF

_ev_missing=""
for _p in $_ev_required; do
    case " $_ev_found " in *" $_p "*) ;; *) _ev_missing="$_ev_missing,$_p" ;; esac
done
_ev_missing="${_ev_missing#,}"
_has_evidence=1
[ -n "$_ev_missing" ] && _has_evidence=0

# NAME THE EVIDENCE (order 889-bx99, coordinator request 2026-08-25).
#
# A PASS report proves the run COMPLETED. It does not, by itself, prove the run's
# preconditions held. 889-bx99 is the live example: the macOS smoke's destruction
# step targeted `~/Library/Application Support/tillandsias` (lowercase) while the
# app writes `Tillandsias` — on a case-SENSITIVE volume that rm matches nothing,
# exits 0, and the smoke proceeds against a pre-existing multi-GiB image while
# reporting a clean-room result. A false PASS on a precondition, on the very path
# this gate consumes as evidence.
#
# This gate deliberately does NOT try to verify clean-room preconditions — that is
# a much larger packet, and a gate that half-verifies them would be worse than one
# that honestly does not. What it CAN do for free is stop being anonymous: print
# exactly which report is carrying each platform, so the operator can check them
# against whatever they know that the gate does not.
#
# Correlating evidence dates against known precondition defects was considered and
# REJECTED as the wrong shape: it needs a hand-maintained registry of defect
# windows per platform, and a registry nobody updates would go quiet exactly when
# it mattered — reading as "no known defects" when it means "nobody wrote one
# down". Naming the evidence rots in no direction.
if [ "$_has_evidence" -eq 1 ]; then
    echo "Evidence satisfying this promotion (verify these are the runs you mean):" >&2
    printf '%s\n' "$_ev_src" | sed '/^$/d' >&2
    echo "  NOTE: a PASS proves the run completed, not that its preconditions held" >&2
    echo "  (see 889-bx99 for a precondition that failed silently while reporting PASS)." >&2
fi

if [ -n "$_ev_disclaimed" ] && [ "$_has_evidence" -eq 1 ]; then
    echo "WARNING: evidence accepted, but a report asserts PASS while disclaiming" >&2
    echo "  promotion clearance (\"run-scoped\" / \"does not clear promotion\"):" >&2
    for _f in $_ev_disclaimed; do echo "    $_f" >&2; done
    echo "  The gate counts it — reading intent from prose is a rule that rots —" >&2
    echo "  but YOU are being told, because its author did not mean it to clear a" >&2
    echo "  promotion. Confirm before proceeding." >&2
fi
if [ "$_has_evidence" -eq 0 ]; then
    if [ "$FORCE" = "--force" ]; then
        echo "WARNING: promoting $TAG WITHOUT complete per-platform e2e PASS evidence (--force)." >&2
        echo "  missing platform(s): ${_ev_missing}" >&2
        echo "Record the override as a cycle entry via 'tillandsias-plan loop-status-append' (who/when/why; never rewrite plan/loop_status.md in place)." >&2
    else
        echo "Incomplete e2e PASS evidence for $VERSION_NO_V under plan/." >&2
        echo "  required platforms: ${_ev_required// /,}" >&2
        echo "  have:               ${_ev_found:-<none>}" >&2
        echo "  MISSING:            ${_ev_missing}" >&2
        echo "Run /smoke-curl-install-and-test-e2e on the missing platform(s), or pass --force (operator override)." >&2
        echo "refused:no-evidence:$TAG:missing=${_ev_missing}"
        exit 1
    fi
fi

# 864-8tqv. Every gate above has run; below this line the script mutates an
# outward-facing channel. --dry-run stops exactly here, which is what makes the
# gates testable without publishing anything.
if [ "$DRY_RUN" -eq 1 ]; then
    echo "would promote $TAG: flip prerelease=false + latest, move the stable tag." >&2
    echo "would-promote:$TAG"
    exit 0
fi

gh release edit "$TAG" --prerelease=false --latest

# Move the annotated stable tag to the release's commit.
COMMIT="$(gh release view "$TAG" --json targetCommitish --jq '.targetCommitish')"
git -C "$REPO_ROOT" tag -f -a stable -m "Stable channel: promoted $TAG" "$COMMIT"
git -C "$REPO_ROOT" push origin refs/tags/stable --force

echo "Stable channel now serves $TAG (README /releases/latest URLs resolve to it)." >&2
echo "NEXT: run a ONE-SHOT stable curl-install smoke to prove the promoted" >&2
echo "artifact installs — SMOKE_CHANNEL=stable /smoke-curl-install-and-test-e2e —" >&2
echo "then routine smoke goes back to the daily channel (default)." >&2
echo "promoted:$TAG"
