#!/usr/bin/env bash
# ORDER 998-qrwu: the CA directory comes from the ONE declaration
# (images/default/ca-path.txt), never a literal — see scripts/lib-ca-path.sh.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-ca-path.sh"

# ORDER 1135-z8gn (macbookair 2026-09-13). PORTABLE MODE READ.
#
# THIS SCRIPT DID NOT WORK ON macOS AT ALL, and the advisory's count of "7
# stat -c instances" undersold it. `stat -c` is GNU-only; BSD stat rejects it
# outright (`stat: illegal option -- c`, rc=1). So on every macOS host
# clamp_dir/clamp_file returned 1, the caller reported
# `violation:ca-material:cannot chmod ...`, and `--selftest` exited 1 with five
# failures and raw usage text on stderr. MEASURED here before this change.
#
# The counterpart is `stat -f '%Lp'`, which is what the fleet already uses
# (scripts/test-default-vault-cli-security.sh, scripts/hash-image-sources.sh).
# MEASURED on this host against known modes, with the system stat forced:
#   /usr/bin/stat -f '%Lp'  ->  700, 600, 644   (no zero padding)
# so the selftest's literal "700"/"600"/"644" comparisons keep their meaning.
#
# BOTH FORMS ON ONE LINE is deliberate and not merely tidy:
# check-portability-idioms.lua's fallback rule matches the counterpart on the
# SAME LINE, so a wrapper whose fallback sat on a second line would still be
# flagged. One line, one helper, seven call sites cleared.
#
# NOT PUT IN lib-ca-path.sh: that file is shared with other consumers and this
# change has no business widening their surface. If a third script needs it,
# that is the moment to promote it.
_mode_of() { # _mode_of <path> -> octal permission bits, or non-zero if neither form works
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}
# 1247-cam7: who owns a path, for the cannot-chmod remedy (same one-line
# GNU/BSD pair as _mode_of).
_owner_of() { stat -c '%U' "$1" 2>/dev/null || stat -f '%Su' "$1" 2>/dev/null; }
# 1247-cam7 (1247-amcu): why it refused and what clears it, on stderr, so the
# one stdout verdict line stays machine-readable (cycle-preflight discards it).
_afford() { printf '  why: %s\n  remedy: %s\n' "$1" "$2" >&2; }
_cannot_chmod() { # _cannot_chmod <path> <mode>
    echo "violation:ca-material:cannot chmod $1"
    _afford "chmod $2 $1 failed, and its owner is $(_owner_of "$1" || echo unknown) while this runs as $(id -un 2>/dev/null || echo "uid $(id -u)"); only the owner (or root) can change its mode, and until then CA private material stays readable beyond its owner" \
        "if a container uid owns it (rootless podman maps them), run podman unshare chmod $2 $1; if another host user owns it, run chmod $2 $1 as that user; then re-run scripts/clamp-ca-material.sh"
}
# @trace spec:secret-rotation, spec:proxy-container
#
# clamp-ca-material.sh — re-clamp CA material that a PRE-FIX binary created
# world-readable (order 791-swxt, residue of 755-qcxh).
#
# WHY A HOST-SIDE SCRIPT AND NOT A CODE FIX. 755-qcxh already fixed the code:
# ensure_ca_bundle creates the key 0600 and heals a pre-fix 0644 key down on
# every pass. But that heal lives in the TRAY BINARY, and every host runs the
# published release — v0.4.260815.1 is commit 0548ee1f2 (2026-08-14), which
# predates the fix. So the heal never executes anywhere, and the code fix
# cannot reach live material until a release ships. Two hosts were found with
# a world-readable CA private key days after the packet closed (macuahuitl
# and yoga, 2026-08-17).
#
# The general shape, worth keeping: a security fix that changes how material
# is CREATED is only half done. The material already created is the other
# half, and it is the half that is currently exploitable. That half cannot be
# repaired by the binary that created it.
#
# ORDER MATTERS. The directory is clamped BEFORE the key: 0700 removes
# traversal for other uids immediately, without touching a running container's
# already-established bind mount. Clamping the key first would leave a window
# where the directory is still traversable.
#
# Output grammar (exactly one line):
#   ^(ok:ca-material:(already-clamped|clamped:[0-9]+|absent)|violation:ca-material:.*)$
#
# Usage:
#   scripts/clamp-ca-material.sh            # clamp what needs it (idempotent)
#   scripts/clamp-ca-material.sh --check    # report only, never mutate
#   scripts/clamp-ca-material.sh --selftest # fixtures, no host state touched
set -uo pipefail

CA_DIR="${TILLANDSIAS_CA_DIR}"
MODE="${1:-fix}"

# Private material that must never be group/world readable. The .crt files are
# PUBLIC by design (every relabel=shared cert mount reads them) and are
# deliberately NOT clamped — over-clamping the cert would break squid and the
# vault-cli require_cacert path for no security gain.
_private_names() { printf '%s\n' intermediate.key vault.key; }

_clamp_dir() {
    local dir="$1" mode
    mode="$(_mode_of "$dir")" || return 1
    [ "$mode" = "700" ] && return 2   # already
    chmod 700 "$dir" 2>/dev/null || return 1
    return 0
}

_clamp_key() {
    local f="$1" mode
    [ -f "$f" ] || return 2
    mode="$(_mode_of "$f")" || return 1
    [ "$mode" = "600" ] && return 2   # already
    chmod 600 "$f" 2>/dev/null || return 1
    return 0
}

_run() {
    local dir="$1" check_only="$2" changed=0 name rc
    if [ ! -d "$dir" ]; then
        echo "ok:ca-material:absent"
        return 0
    fi
    if [ "$check_only" = "1" ]; then
        local offenders=0 mode
        mode="$(_mode_of "$dir")"
        [ "$mode" = "700" ] || offenders=$((offenders + 1))
        while IFS= read -r name; do
            [ -f "$dir/$name" ] || continue
            mode="$(_mode_of "$dir/$name")"
            [ "$mode" = "600" ] || offenders=$((offenders + 1))
        done < <(_private_names)
        if [ "$offenders" -gt 0 ]; then
            echo "violation:ca-material:$offenders path(s) not owner-only under $dir"
            _afford "the CA directory must be 0700 and its private keys 0600, or another local uid can read a key and mint certificates the enclave trusts (755-qcxh)" \
                "run scripts/clamp-ca-material.sh (without --check) to clamp them, then re-run with --check"
            return 1
        fi
        echo "ok:ca-material:already-clamped"
        return 0
    fi

    # Directory FIRST — see the header.
    _clamp_dir "$dir"; rc=$?
    [ "$rc" -eq 1 ] && { _cannot_chmod "$dir" 700; return 1; }
    [ "$rc" -eq 0 ] && changed=$((changed + 1))

    while IFS= read -r name; do
        _clamp_key "$dir/$name"; rc=$?
        [ "$rc" -eq 1 ] && { _cannot_chmod "$dir/$name" 600; return 1; }
        [ "$rc" -eq 0 ] && changed=$((changed + 1))
    done < <(_private_names)

    if [ "$changed" -gt 0 ]; then
        echo "ok:ca-material:clamped:$changed"
    else
        echo "ok:ca-material:already-clamped"
    fi
    return 0
}

if [ "$MODE" = "--selftest" ]; then
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    fail=0

    # Fixture: a pre-fix host — world-readable key, traversable dir.
    mkdir -p "$tmp/ca"
    : > "$tmp/ca/intermediate.key"; chmod 644 "$tmp/ca/intermediate.key"
    : > "$tmp/ca/intermediate.crt"; chmod 644 "$tmp/ca/intermediate.crt"
    chmod 755 "$tmp/ca"

    out="$(_run "$tmp/ca" 1 2>/dev/null)"
    case "$out" in
        violation:ca-material:*) : ;;
        *) echo "SELFTEST-FAIL: --check accepted a world-readable key ($out)"; fail=1 ;;
    esac

    out="$(_run "$tmp/ca" 0)"
    case "$out" in
        ok:ca-material:clamped:*) : ;;
        *) echo "SELFTEST-FAIL: fix did not report a clamp ($out)"; fail=1 ;;
    esac
    [ "$(_mode_of "$tmp/ca")" = "700" ] || { echo "SELFTEST-FAIL: dir not 700"; fail=1; }
    [ "$(_mode_of "$tmp/ca/intermediate.key")" = "600" ] || { echo "SELFTEST-FAIL: key not 600"; fail=1; }

    # The PUBLIC cert must be left alone: over-clamping it breaks squid and
    # vault-cli's require_cacert for no security gain.
    [ "$(_mode_of "$tmp/ca/intermediate.crt")" = "644" ] \
        || { echo "SELFTEST-FAIL: public cert was clamped"; fail=1; }

    # Idempotent: a second run reports already-clamped, not another change.
    out="$(_run "$tmp/ca" 0)"
    [ "$out" = "ok:ca-material:already-clamped" ] \
        || { echo "SELFTEST-FAIL: not idempotent ($out)"; fail=1; }

    # Absent dir is not a violation — a host that never provisioned is fine.
    out="$(_run "$tmp/nope" 0)"
    [ "$out" = "ok:ca-material:absent" ] \
        || { echo "SELFTEST-FAIL: absent dir mishandled ($out)"; fail=1; }

    # 1247-cam7 (1247-amcu): every violation says WHY and WHAT CLEARS IT on
    # stderr, beside its unchanged stdout verdict, and the --check remedy is
    # EXECUTED: run without --check, and --check then answers clean.
    mkdir -p "$tmp/ca2"; : > "$tmp/ca2/vault.key"; chmod 644 "$tmp/ca2/vault.key"; chmod 755 "$tmp/ca2"
    err="$(_run "$tmp/ca2" 1 2>&1 >/dev/null)"
    case "$err" in
        *"  why: "*"  remedy: "*"clamp-ca-material.sh"*) : ;;
        *) echo "SELFTEST-FAIL: --check violation carries no why/remedy naming the fix run ($err)"; fail=1 ;;
    esac
    _run "$tmp/ca2" 0 >/dev/null 2>&1
    out="$(_run "$tmp/ca2" 1 2>/dev/null)"
    [ "$out" = "ok:ca-material:already-clamped" ] \
        || { echo "SELFTEST-FAIL: the --check remedy, executed, did not clear it ($out)"; fail=1; }

    # cannot chmod: a path this uid cannot change (a container's mapped uid
    # under rootless podman owns it). chmod is shadowed to fail as EPERM does.
    # The remedy must name the owner; restoring chmod (acting as the owner)
    # must clear it.
    mkdir -p "$tmp/ca3"; : > "$tmp/ca3/intermediate.key"; chmod 644 "$tmp/ca3/intermediate.key"; chmod 755 "$tmp/ca3"
    owner="$(_owner_of "$tmp/ca3")"
    res="$( chmod() { return 1; }; _run "$tmp/ca3" 0 2>&1 )"
    case "$res" in
        *"violation:ca-material:cannot chmod $tmp/ca3"*"  why: "*"$owner"*"  remedy: "*"podman unshare chmod 700"*) : ;;
        *) echo "SELFTEST-FAIL: cannot-chmod carries no why naming the owner and no podman unshare remedy ($res)"; fail=1 ;;
    esac
    out="$(_run "$tmp/ca3" 0 2>/dev/null)"
    [ "$out" = "ok:ca-material:clamped:2" ] \
        || { echo "SELFTEST-FAIL: as the owner, the clamp did not clear it ($out)"; fail=1; }

    [ "$fail" -eq 0 ] || { echo "selftest:clamp-ca-material:FAIL"; exit 1; }
    echo "selftest:clamp-ca-material:10 cases PASS"
    exit 0
fi

case "$MODE" in
    --check) _run "$CA_DIR" 1 ;;
    fix | --fix) _run "$CA_DIR" 0 ;;
    *) echo "usage: $0 [--check|--fix|--selftest]" >&2; exit 2 ;;
esac
