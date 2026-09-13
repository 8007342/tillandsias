#!/usr/bin/env bash
# @trace order:1165-g6wx, spec:ci-release
#
# probe-silverblue-update-skew.sh — READ-ONLY. Reports whether this Silverblue
# host is in the akmods/kernel-devel-matched depsolve skew, so a cycle says
# "skew" instead of a host guessing at "update ready, requires restart".
#
# THE CONDITION, root-caused by lenovinha 2026-09-13 and scope-tested on yoga.
# `akmods` (which the NVIDIA stack drags in) carries the rich dependency
# `(kernel-devel-matched if kernel-core)`. kernel-core is present from the
# OSTree base, so the dependency FIRES; every kernel-devel-matched in the repo
# is refused because it wants a kernel-core the base already provides and no
# repo kernel-core can be layered. Depsolve fails, NOTHING is staged, and the
# non-depsolving `--check` keeps answering "ready" — which is why the symptom
# reads as "ready, requires restart" followed by a failed apply and an empty
# staging area. Transient by construction: it clears when the updates repo
# publishes kernel-devel-matched for the kernel the base already shipped.
#
# WHY A PROBE RATHER THAN A FIX. The remedies — wait, temporarily unlayer the
# NVIDIA stack, or pin — are the OPERATOR'S decision on their own workstation,
# not an agent's. This reports; it never resolves.
#
# NOTHING HERE MUTATES A DEPLOYMENT. No `rpm-ostree upgrade` without --check, no
# `deploy`, no `rebase`, no `pin`, no `cleanup`. `--check` fetches metadata and
# stages nothing, and it is the row's own named mechanism for "is a kernel bump
# offered". If you are extending this file, that constraint is the packet's, not
# a style preference.
#
# Exit: 0 ok or skip | 1 skew reported | 3 could-not-run
#   A caller must NOT treat 1 as fatal: the skew is a host condition with an
#   operator-owned remedy, and failing a cycle on it would punish the host for
#   a repository's publishing lag.
set -uo pipefail

STATUS_FROM=""; CHECK_FROM=""; JOURNAL_FROM=""
while [ $# -gt 0 ]; do
    case "$1" in
        # TEST SEAMS. Production passes none of these; the fixture supplies all
        # three so it can construct the skew without a host that has it — the
        # condition is transient and no host can be relied on to be in it.
        --status-from)  STATUS_FROM="${2:-}"; shift 2 ;;
        --check-from)   CHECK_FROM="${2:-}"; shift 2 ;;
        --journal-from) JOURNAL_FROM="${2:-}"; shift 2 ;;
        --help|-h) sed -n '3,30p' "$0"; exit 0 ;;
        *) shift ;;
    esac
done

_read_status() {
    [ -n "$STATUS_FROM" ] && { cat "$STATUS_FROM" 2>/dev/null; return; }
    command -v rpm-ostree >/dev/null 2>&1 || return 1
    rpm-ostree status 2>/dev/null
}
_read_check() {
    [ -n "$CHECK_FROM" ] && { cat "$CHECK_FROM" 2>/dev/null; return; }
    command -v rpm-ostree >/dev/null 2>&1 || return 1
    # --check is read-only: it fetches metadata and stages nothing. Bounded so a
    # slow or unreachable mirror degrades to could-not-run rather than hanging a
    # cycle preamble.
    timeout 120 rpm-ostree upgrade --check 2>/dev/null
}
_read_journal() {
    [ -n "$JOURNAL_FROM" ] && { cat "$JOURNAL_FROM" 2>/dev/null; return; }
    command -v journalctl >/dev/null 2>&1 || return 1
    journalctl -u rpm-ostreed --no-pager -n 400 2>/dev/null
}

# ── Not a Silverblue-shaped host: skip, and say so. A skip is not an ok. ─────
if [ -z "$STATUS_FROM" ] && ! command -v rpm-ostree >/dev/null 2>&1; then
    echo "skip:silverblue-update-skew:no-rpm-ostree (this host is not rpm-ostree managed; nothing is asserted about update skew)"
    exit 0
fi

_status="$(_read_status)" || _status=""
if [ -z "$_status" ]; then
    echo "could-not-run:silverblue-update-skew:no-status (rpm-ostree status returned nothing; this is NOT a no-skew verdict)"
    exit 3
fi

# ── Is akmods layered? THE discriminator. yoga layers rocm and is unaffected;
#    lenovinha layers the NVIDIA stack which drags akmods in. ───────────────
_layered="$(printf '%s\n' "$_status" | sed -n 's/.*LayeredPackages:[[:space:]]*//p' | head -1)"
case " $_layered " in
    *" akmods "*|*" akmod-"*) _has_akmods=1 ;;
    *) _has_akmods=0 ;;
esac
if [ "$_has_akmods" -eq 0 ]; then
    echo "ok:no-skew:no-akmods-layered (layered: ${_layered:-none}) — the rich dependency that produces this skew is not present on this host"
    exit 0
fi

# ── Is a kernel bump offered? ───────────────────────────────────────────────
_check="$(_read_check)" || _check=""
if [ -z "$_check" ]; then
    echo "could-not-run:silverblue-update-skew:no-check (rpm-ostree upgrade --check returned nothing; this is NOT a no-skew verdict)"
    exit 3
fi
_offered="$(printf '%s\n' "$_check" | sed -n 's/.*[Vv]ersion:[[:space:]]*\([0-9][0-9.]*\).*/\1/p' | head -1)"
case "$_check" in
    *AvailableUpdate*) : ;;
    *)
        echo "ok:no-skew:no-update-offered (akmods is layered, but nothing is on offer to depsolve against)"
        exit 0
        ;;
esac

# ── Did the last Upgrade transaction fail at depsolve naming the rich dep? ──
#    This is the half that separates "an update is pending" from "this host
#    CANNOT apply it": the journal is where the depsolve failure is recorded,
#    and --check never sees it because --check does not depsolve.
_journal="$(_read_journal)" || _journal=""
if [ -z "$_journal" ]; then
    echo "could-not-run:silverblue-update-skew:no-journal (the rpm-ostreed journal could not be read; an offered update alone does not establish skew)"
    exit 3
fi
if printf '%s\n' "$_journal" | grep -q 'kernel-devel-matched' \
   && printf '%s\n' "$_journal" | grep -qi 'depsolve'; then
    echo "skew:akmods-kernel-devel-matched:${_offered:-unknown} — akmods is layered, an update is offered, and the rpm-ostreed journal shows a depsolve failure naming kernel-devel-matched. NOTHING IS STAGED and no restart will apply it; the remedies (wait for the repo, temporarily unlayer the NVIDIA stack, or pin) are the OPERATOR'S decision. See cheatsheets/runtime/silverblue-updates.md (1165-g6wx)."
    exit 1
fi

echo "ok:no-skew:akmods-layered-but-no-depsolve-failure (an update is offered and the journal shows no kernel-devel-matched depsolve failure; this host is not in the skew)"
exit 0
