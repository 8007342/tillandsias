#!/usr/bin/env bash
# Fleet nix-capability probe that says HOW it knows — 917-zkge premise rebuild.
#
# WHY THIS EXISTS. 917-zkge records that five hosts "each independently
# confirmed no nix at all". On 2026-08-30 that premise cracked: yoga was
# nix-capable the whole time, one `dnf install nix` inside a tillandsias-nix
# toolbox that had been running for 21 hours. In one night three DIFFERENT
# probes each produced an identical, confident "no":
#
#   1. ensure-without-install (yoga)   nix-toolbox.sh creates a toolbox and
#      never installs nix into it, then reports `no-nix-and-no-toolbox` — a
#      verdict naming an absent toolbox that was present and running.
#   2. query-that-never-reached-a-daemon (macbook)  with the podman machine
#      never booted, `podman ps -a` errors to STDERR and exits nonzero; piped
#      into grep, "could not look" and "looked and found nothing" are the same
#      empty stdout.
#   3. fixture-skip (lenovinha)  a cache fixture printed a green skip over a
#      RUNNING service because it gated on host nix.
#
# All three answered "no". None of them had looked. So this probe's contract is
# not "report nix capability" — it is REPORT WHAT WAS ACTUALLY OBSERVED, and
# refuse to render an unreachable substrate as an absence.
#
# THE RULE, from macbook and adopted for the rebuild: substrate STATE first,
# inventory second, and every row carries its method. A fleet sweep whose rows
# do not carry their method reproduces the same fluency on the next sweep.
#
# Output: one JSON object on stdout.
#   verdict  capable | not-capable | one-step-away | unknown
#   method   what was run and what it returned, in words
# `unknown` is a first-class answer here and is the whole point: it is what an
# unreachable substrate honestly produces, and the three failures above are all
# hosts that returned `not-capable` where `unknown` was the truth.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST="${1:-$(hostname -s 2>/dev/null || echo unknown)}"

emit() { # verdict, method, detail
    if command -v jq >/dev/null 2>&1; then
        jq -nc --arg h "$HOST" --arg v "$1" --arg m "$2" --arg d "${3:-}" \
            --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg os "$(uname -s)" \
            '{ts:$ts, host:$h, os:$os, verdict:$v, method:$m, detail:(if $d=="" then null else $d end)}'
    else
        printf '{"host":"%s","verdict":"%s","method":"%s"}\n' "$HOST" "$1" "$2"
    fi
    exit 0
}

# ── 1. HOST NIX, the cheapest true yes ──────────────────────────────────────
if command -v nix >/dev/null 2>&1 && nix --version >/dev/null 2>&1; then
    emit capable "host nix answered --version" "$(nix --version 2>&1|head -1)"
fi
# A `nix` on PATH that does not answer is NOT a nix. yoga's builder toolbox
# carries a host-escape shim forwarding to a host binary that does not exist,
# so `command -v nix` succeeds and every invocation fails.
if command -v nix >/dev/null 2>&1; then
    _shim_err="$(nix --version 2>&1|head -1)"
    emit unknown "a 'nix' is on PATH but did not answer --version — it may be a shim to an absent binary; this is NOT evidence of absence" "$_shim_err"
fi

# ── 2. SUBSTRATE STATE BEFORE INVENTORY ─────────────────────────────────────
if ! command -v podman >/dev/null 2>&1; then
    emit not-capable "no host nix, and podman is absent so no container could hold one" ""
fi

case "$(uname -s)" in
    Darwin)
        # macbook's finding: with the machine never booted, `podman ps -a`
        # errors to stderr and exits nonzero. Ask the machine first.
        _ml="$(podman machine list --format '{{.Name}} {{.Running}} {{.LastUp}}' 2>&1)"
        if [[ $? -ne 0 ]]; then
            emit unknown "podman machine list failed — the substrate could not be queried, so nothing was observed" "$_ml"
        fi
        if [[ -z "${_ml//[[:space:]]/}" ]]; then
            emit not-capable "podman machine list succeeded and reported NO machines — nothing could hold a toolbox" ""
        fi
        if ! grep -qi "true" <<<"$_ml"; then
            emit unknown "a podman machine exists but is NOT running, so its container inventory is unreadable — 'no toolbox' here would mean 'could not look'" "$_ml"
        fi
        ;;
    *)
        if ! podman info >/dev/null 2>&1; then
            emit unknown "podman is present but 'podman info' failed — the container inventory could not be read, which is not the same as it being empty" "$(podman info 2>&1|tail -1)"
        fi
        ;;
esac

# ── 3. INVENTORY, only now that the substrate answered ──────────────────────
_ps="$(podman ps -a --format '{{.Names}}' 2>&1)"
if [[ $? -ne 0 ]]; then
    emit unknown "podman ps -a failed after info succeeded — inventory unread" "$(printf '%s' "$_ps"|tail -1)"
fi

_tb="$(grep -x 'tillandsias-nix' <<<"$_ps" || true)"
if [[ -z "$_tb" ]]; then
    # PIRRIA'S CASE, 2026-08-30 — and the first version of this probe got it
    # wrong in exactly the way the file's own header warns about.
    #
    # "No tillandsias-nix container" was reported as not-capable. But a host
    # running a live tillandsias-builder toolbox has ALL the substrate the
    # toolbox rung needs: the toolbox binary, a live podman, and the
    # fedora-toolbox image already cached. What is missing is a `toolbox
    # create` and the dnf install — two cheap commands. And because stock init
    # creates tillandsias-builder everywhere, that is plausibly the DEFAULT
    # out-of-box state fleet-wide, so the old boundary would have systematically
    # filed nearly-there hosts as dead ones.
    #
    # That is line 33's warning one rung over: the verdict was about the
    # ABSENCE OF A NAME rather than about the capability, and a reader cannot
    # tell "cannot" from "not created yet" out of "not-capable".
    #
    # one-step-away exists precisely so a nearly-there host is never filed as a
    # dead one, so the boundary moves to substrate-present and the DETAIL
    # carries the exact remaining distance. not-capable is now reserved for a
    # host that genuinely cannot host the rung.
    _has_toolbox_bin=no
    command -v toolbox >/dev/null 2>&1 && _has_toolbox_bin=yes
    _img="$(podman images --format '{{.Repository}}' 2>/dev/null | grep -m1 'fedora-toolbox' || true)"

    if [[ "$_has_toolbox_bin" == no ]]; then
        emit not-capable "podman answered, no tillandsias-nix container, AND no toolbox binary — nothing here can create the rung" \
            "containers: $(printf '%s' "$_ps"|tr '\n' ' ')"
    fi
    if [[ -n "$_img" ]]; then
        emit one-step-away "substrate is present (toolbox binary + live podman + a fedora-toolbox image already cached); only the tillandsias-nix toolbox and its nix are missing" \
            "distance: scripts/nix-toolbox.sh ensure, then 'toolbox run -c tillandsias-nix sudo dnf install -y nix'. Image already local ($_img), so no pull is needed. Containers present: $(printf '%s' "$_ps"|tr '\n' ' ')"
    fi
    emit one-step-away "substrate is present (toolbox binary + live podman) but no fedora-toolbox image is cached — the rung is reachable if a pull succeeds, which is NOT established here" \
        "distance: a fedora-toolbox pull (unverified from this probe), then scripts/nix-toolbox.sh ensure, then the dnf install. Containers present: $(printf '%s' "$_ps"|tr '\n' ' ')"
fi

# ── 4. THE TOOLBOX EXISTS — does it hold a nix? ─────────────────────────────
if toolbox run -c tillandsias-nix nix --version >/dev/null 2>&1; then
    emit capable "tillandsias-nix toolbox exists and its nix answered --version" \
        "$(toolbox run -c tillandsias-nix nix --version 2>&1|head -1)"
fi

# THE yoga CASE. The toolbox is present and running; only the install is
# missing. Reporting this as not-capable is the false negative that put a hole
# in 917-zkge's premise.
emit one-step-away \
    "tillandsias-nix toolbox EXISTS but has no working nix — this host is one 'toolbox run -c tillandsias-nix sudo dnf install -y nix' from capable, and must NOT be recorded as no-nix" \
    "toolbox present; nix --version inside it did not answer"
