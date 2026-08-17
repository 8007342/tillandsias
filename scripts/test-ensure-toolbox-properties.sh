#!/usr/bin/env bash
# @trace spec:dev-build
#
# test-ensure-toolbox-properties.sh — behavioural fixtures for the toolbox-first
# include (operator directive 2026-08-16, order 777-amku).
#
# WHAT WAS MISSING. litmus:ensure-toolbox-include-shape shipped with the
# include and pinned its SHAPE: the file parses, sourcing it does not rewrite
# the caller's shell options, and two greps confirm the source text mentions
# the delegate and the methodology key. None of that touches the three
# properties the directive actually names — "if toolbox doesn't exist, create
# and init, otherwise noop". A `ensure_toolbox.sh` that did nothing at all
# passed every one of those steps on this host, because this host is Fedora
# Workstation: the Silverblue guard returns before any toolbox work, so
# `scripts/ensure_toolbox.sh && echo ok` is a tautology here. Order 634-39ik
# is the standing rule this violates — assert PROPERTIES, not source literals,
# and carry a negative control.
#
# HOW. Every property is a PREDICATE FUNCTION run twice: once against the real
# scripts/ensure_toolbox.sh (it must HOLD) and once against a mutant with that
# exact property removed (it must FAIL). A predicate that passes its own mutant
# proves nothing, and says so in its output. Each mutation is verified to have
# actually applied (`cmp`), because a sed that silently matched nothing is the
# classic control that removes nothing and certifies everything.
#
# HERMETIC. A fake `toolbox` and a fake `rpm-ostree` are placed first on PATH,
# HOME is redirected into the fixture's tmp, and the container name is
# `tillandsias-litmus-fake`. The real toolbox binary is unreachable by
# construction; if it were reached, the call log would be empty and every
# property would go red rather than quietly pass.
#
# NOT UNDER TEST: whether a real `toolbox create` succeeds on a real Silverblue
# host. That needs a Silverblue host and lives in the daily build lane.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_INCLUDE="$ROOT/scripts/ensure_toolbox.sh"
REAL_DELEGATE="$ROOT/scripts/with-tillandsias-builder.sh"
REAL_PROXY="$ROOT/scripts/podman-neutralize-proxy.sh"

for f in "$REAL_INCLUDE" "$REAL_DELEGATE" "$REAL_PROXY"; do
    if [ ! -f "$f" ]; then
        echo "FAIL: missing prerequisite $f" >&2
        exit 1
    fi
done

tmp="$(mktemp -d "${TMPDIR:-/tmp}/ensure-toolbox-props.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

ORIG_PATH="$PATH"
BASH_BIN="$(command -v bash)"
DIRNAME_BIN="$(command -v dirname)"

pass=0
fail=0
skip=0

# ── the fake host ───────────────────────────────────────────────────────────
FAKE_BIN="$tmp/fake-bin"
mkdir -p "$FAKE_BIN"

cat >"$FAKE_BIN/toolbox" <<'FAKE_TOOLBOX'
#!/usr/bin/env bash
# Hermetic fake `toolbox`. Never execs anything; records every call.
set -u
state="${FT_STATE:?FT_STATE unset — the fixture env did not reach the fake}"
mkdir -p "$state"
{
    printf 'toolbox'
    for _a in "$@"; do printf ' %s' "$_a"; done
    printf '\n'
} >>"$state/calls.log"

sub="${1:-}"
if [ -n "${FT_FAIL_ON:-}" ] && [ "$sub" = "$FT_FAIL_ON" ]; then
    echo "fake-toolbox: injected failure on '$sub'" >&2
    exit 1
fi

case "$sub" in
    list)
        echo "ID           NAME    CREATED      STATUS   IMAGE NAME"
        if [ -f "$state/containers" ]; then
            while IFS= read -r c; do
                [ -n "$c" ] || continue
                printf 'aaaabbbbcccc %s 1 day ago running fedora-toolbox\n' "$c"
            done <"$state/containers"
        fi
        ;;
    create)
        name=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --container) name="${2:-}"; shift 2 ;;
                *) shift ;;
            esac
        done
        if [ -z "$name" ]; then
            echo "fake-toolbox: create without --container" >&2
            exit 2
        fi
        if [ -f "$state/containers" ] && grep -qxF "$name" "$state/containers"; then
            # Real toolbox refuses a duplicate create; so must the fake, or an
            # unconditional-create mutant would look harmless.
            echo "fake-toolbox: container '$name' already exists" >&2
            exit 1
        fi
        echo "$name" >>"$state/containers"
        ;;
    run)
        joined="$*"
        case "$joined" in
            *"command -v gcc"*)
                # The delegate's initialization probe.
                [ -f "$state/initialized" ] || exit 1
                ;;
            *dnf*)
                : >"$state/initialized"
                ;;
        esac
        ;;
esac
exit 0
FAKE_TOOLBOX
chmod +x "$FAKE_BIN/toolbox"

# The delegate only reaches its toolbox work on rpm-ostree/Silverblue hosts.
printf '#!/usr/bin/env bash\nexit 0\n' >"$FAKE_BIN/rpm-ostree"
chmod +x "$FAKE_BIN/rpm-ostree"

# A PATH with no `toolbox` and no `rpm-ostree` at all — the off-toolbox host.
MIN_BIN="$tmp/min-bin"
mkdir -p "$MIN_BIN"
ln -s "$BASH_BIN" "$MIN_BIN/bash"
ln -s "$DIRNAME_BIN" "$MIN_BIN/dirname"

OUT="$tmp/stdout"
ERR="$tmp/stderr"

_fresh_env() {
    local tag="$1"
    FT_STATE="$tmp/state.$tag"
    rm -rf "$FT_STATE"
    mkdir -p "$FT_STATE"
    export FT_STATE
    unset FT_FAIL_ON

    HOME="$tmp/home.$tag"
    rm -rf "$HOME"
    mkdir -p "$HOME/.cache/tillandsias"
    # Pre-seed rustup-init so the delegate's init path never reaches the network.
    printf '#!/bin/sh\nexit 0\n' >"$HOME/.cache/tillandsias/rustup-init.sh"
    chmod +x "$HOME/.cache/tillandsias/rustup-init.sh"
    export HOME

    PATH="$FAKE_BIN:$ORIG_PATH"
    export PATH
    export TILLANDSIAS_BUILDER_TOOLBOX="tillandsias-litmus-fake"
    unset TILLANDSIAS_SKIP_TOOLBOX
    unset TOOLBOX_PATH
    unset container
    : >"$OUT"
    : >"$ERR"
    return 0
}

_created_count() {
    if [ -f "$FT_STATE/calls.log" ]; then
        grep -c '^toolbox create' "$FT_STATE/calls.log"
    else
        echo 0
    fi
}

_installed_count() {
    if [ -f "$FT_STATE/calls.log" ]; then
        grep -c 'dnf' "$FT_STATE/calls.log"
    else
        echo 0
    fi
}

# ── the mutants ─────────────────────────────────────────────────────────────
# Each builds $tmp/mut.<tag>/ensure_toolbox.sh with ONE property removed, and
# returns nonzero if its edit did not actually change the file. The callers
# treat that as fatal: a control that removes nothing certifies everything.
#
# These seds DO pin literal source text — deliberately, and it is the one place
# where that is safe: a drifted expression makes the mutation a no-op, `cmp`
# catches it, and the fixture goes RED naming the line that moved. The failure
# mode of a stale mutation here is a loud red, never a silent green.
_mutate() {
    local tag="$1" expr="$2"
    local d="$tmp/mut.$tag"
    rm -rf "$d"
    mkdir -p "$d"
    cp "$REAL_DELEGATE" "$d/with-tillandsias-builder.sh"
    cp "$REAL_PROXY" "$d/podman-neutralize-proxy.sh"
    chmod +x "$d/with-tillandsias-builder.sh"
    sed "$expr" "$REAL_INCLUDE" >"$d/ensure_toolbox.sh"
    chmod +x "$d/ensure_toolbox.sh"
    if cmp -s "$REAL_INCLUDE" "$d/ensure_toolbox.sh"; then
        echo "FAIL: mutation '$tag' changed nothing — the control removes nothing and proves nothing" >&2
        echo "      (scripts/ensure_toolbox.sh drifted away from: $expr)" >&2
        return 1
    fi
    return 0
}

_mutate_delegate() {
    local tag="$1" expr="$2"
    local d="$tmp/mut.$tag"
    rm -rf "$d"
    mkdir -p "$d"
    cp "$REAL_INCLUDE" "$d/ensure_toolbox.sh"
    cp "$REAL_PROXY" "$d/podman-neutralize-proxy.sh"
    chmod +x "$d/ensure_toolbox.sh"
    sed "$expr" "$REAL_DELEGATE" >"$d/with-tillandsias-builder.sh"
    chmod +x "$d/with-tillandsias-builder.sh"
    if cmp -s "$REAL_DELEGATE" "$d/with-tillandsias-builder.sh"; then
        echo "FAIL: mutation '$tag' changed nothing — the control removes nothing and proves nothing" >&2
        echo "      (scripts/with-tillandsias-builder.sh drifted away from: $expr)" >&2
        return 1
    fi
    return 0
}

# ── the properties ──────────────────────────────────────────────────────────
# Each takes the include under test and returns 0 iff the property HOLDS.

# P1: "if toolbox doesn't exist, create and init".
_prop_creates_if_missing() {
    local include="$1" tag="$2"
    _fresh_env "$tag"
    "$include" >"$OUT" 2>"$ERR"
    local rc=$?
    [ "$rc" -eq 0 ] || return 1
    [ "$(_created_count)" -ge 1 ] || return 1
    [ "$(_installed_count)" -ge 1 ] || return 1
    grep -qxF "tillandsias-litmus-fake" "$FT_STATE/containers" 2>/dev/null || return 1
    return 0
}

# P2: "otherwise noop" — the second run creates nothing and installs nothing.
_prop_idempotent() {
    local include="$1" tag="$2"
    _fresh_env "$tag"
    "$include" >"$OUT" 2>"$ERR"
    local rc1=$?
    [ "$rc1" -eq 0 ] || return 1
    [ "$(_created_count)" -ge 1 ] || return 1
    : >"$FT_STATE/calls.log"
    "$include" >"$OUT" 2>"$ERR"
    local rc2=$?
    [ "$rc2" -eq 0 ] || return 1
    [ "$(_created_count)" -eq 0 ] || return 1
    [ "$(_installed_count)" -eq 0 ] || return 1
    return 0
}

# P3: a host with no `toolbox` gets a silent, successful noop — zero bytes on
# both streams. "Silent" is the half that makes the include cheap enough to sit
# at the top of every script; a chatty noop is a banner on every invocation.
_prop_silent_noop_off_toolbox() {
    local include="$1" tag="$2"
    _fresh_env "$tag"
    PATH="$MIN_BIN"
    export PATH
    "$include" >"$OUT" 2>"$ERR"
    local rc=$?
    PATH="$ORIG_PATH"
    export PATH
    [ "$rc" -eq 0 ] || return 1
    [ ! -s "$OUT" ] || return 1
    [ ! -s "$ERR" ] || return 1
    return 0
}

# P4: the silence covers "not a toolbox host", NEVER "the ensure broke".
_prop_loud_when_ensure_fails() {
    local include="$1" tag="$2"
    _fresh_env "$tag"
    FT_FAIL_ON="create"
    export FT_FAIL_ON
    "$include" >"$OUT" 2>"$ERR"
    local rc=$?
    unset FT_FAIL_ON
    [ "$rc" -ne 0 ] || return 1
    [ -s "$ERR" ] || return 1
    return 0
}

# P5: delegation, not duplication — the include drives
# with-tillandsias-builder.sh and issues no container commands of its own, so
# the create/init logic has exactly one implementation.
_prop_delegates_not_duplicates() {
    local include="$1" tag="$2"
    _fresh_env "$tag"
    local d="$tmp/deleg.$tag"
    rm -rf "$d"
    mkdir -p "$d"
    cp "$include" "$d/ensure_toolbox.sh"
    chmod +x "$d/ensure_toolbox.sh"
    printf '#!/usr/bin/env bash\ntouch "%s"\nexit 0\n' "$d/delegate-called" \
        >"$d/with-tillandsias-builder.sh"
    chmod +x "$d/with-tillandsias-builder.sh"
    "$d/ensure_toolbox.sh" >"$OUT" 2>"$ERR"
    local rc=$?
    [ "$rc" -eq 0 ] || return 1
    [ -f "$d/delegate-called" ] || return 1
    [ "$(_created_count)" -eq 0 ] || return 1
    return 0
}

# ── the harness ─────────────────────────────────────────────────────────────
_holds() {
    local label="$1"
    shift
    if "$@"; then
        echo "ok: $label"
        pass=$((pass + 1))
    else
        echo "FAIL: $label — the property does NOT hold for scripts/ensure_toolbox.sh"
        fail=$((fail + 1))
    fi
    return 0
}

# NEGATIVE CONTROL. The same predicate against a mutant missing exactly that
# property: it must FAIL. If it passes, the assertion above is vacuous and this
# fixture says so instead of reporting a green.
_refuses() {
    local label="$1"
    shift
    if "$@"; then
        echo "FAIL: NEG-$label — the mutant PASSED; the matching assertion is vacuous"
        fail=$((fail + 1))
    else
        echo "ok: NEG-$label (mutant refused, so the assertion has teeth)"
        pass=$((pass + 1))
    fi
    return 0
}

# The delegate reaches its toolbox work only on hosts that HAVE /etc/os-release
# (its Silverblue guard reads it). A fake rpm-ostree covers the variant check,
# but the file itself cannot be faked at an absolute path.
HAS_OS_RELEASE=0
if [ -f /etc/os-release ]; then
    HAS_OS_RELEASE=1
fi

echo "== ensure_toolbox.sh property fixture (order 777-amku) =="

if [ "$HAS_OS_RELEASE" -eq 1 ]; then
    _mutate never-ensures \
        's#"$_ENSURE_TOOLBOX_DIR/with-tillandsias-builder.sh" true#true#' || exit 1
    _mutate_delegate always-creates \
        's#if ! _toolbox_exists; then#if true; then#' || exit 1
    _mutate swallows-failure \
        's#return 1 2>/dev/null || exit 1#return 0 2>/dev/null || exit 0#' || exit 1
    _mutate self-creates \
        's#"$_ENSURE_TOOLBOX_DIR/with-tillandsias-builder.sh" true#toolbox create --assumeyes --container "${TILLANDSIAS_BUILDER_TOOLBOX:-tillandsias-builder}"#' || exit 1
    M_NEVER_ENSURES="$tmp/mut.never-ensures/ensure_toolbox.sh"
    M_ALWAYS_CREATES="$tmp/mut.always-creates/ensure_toolbox.sh"
    M_SWALLOWS="$tmp/mut.swallows-failure/ensure_toolbox.sh"
    M_SELF_CREATES="$tmp/mut.self-creates/ensure_toolbox.sh"

    _holds   "P1 creates-and-inits when the toolbox is missing" \
        _prop_creates_if_missing "$REAL_INCLUDE" p1
    _refuses "P1 creates-and-inits" \
        _prop_creates_if_missing "$M_NEVER_ENSURES" p1n

    _holds   "P2 idempotent — the second run creates nothing and installs nothing" \
        _prop_idempotent "$REAL_INCLUDE" p2
    _refuses "P2 idempotent" \
        _prop_idempotent "$M_ALWAYS_CREATES" p2n

    _holds   "P4 a FAILED ensure is loud (nonzero + diagnosis on stderr)" \
        _prop_loud_when_ensure_fails "$REAL_INCLUDE" p4
    _refuses "P4 a FAILED ensure is loud" \
        _prop_loud_when_ensure_fails "$M_SWALLOWS" p4n

    _holds   "P5 delegates to with-tillandsias-builder.sh, duplicates nothing" \
        _prop_delegates_not_duplicates "$REAL_INCLUDE" p5
    _refuses "P5 delegates" \
        _prop_delegates_not_duplicates "$M_SELF_CREATES" p5n
else
    echo "n/a: P1/P2/P4/P5 need /etc/os-release (the delegate's Silverblue guard reads it); this host has none"
    skip=$((skip + 4))
fi

# P3 needs no os-release: it is the path where the include returns before
# reaching the delegate at all.
M_CHATTY="$tmp/mut.chatty"
mkdir -p "$M_CHATTY"
awk 'NR==1 { print; print "echo \"[ensure_toolbox] no toolbox on this host; skipping\""; next } { print }' \
    "$REAL_INCLUDE" >"$M_CHATTY/ensure_toolbox.sh"
chmod +x "$M_CHATTY/ensure_toolbox.sh"
if cmp -s "$REAL_INCLUDE" "$M_CHATTY/ensure_toolbox.sh"; then
    echo "FAIL: mutation 'chatty' changed nothing — the control removes nothing and proves nothing" >&2
    exit 1
fi

_holds   "P3 silent noop on a host with no toolbox (rc=0, both streams empty)" \
    _prop_silent_noop_off_toolbox "$REAL_INCLUDE" p3
_refuses "P3 silent noop" \
    _prop_silent_noop_off_toolbox "$M_CHATTY/ensure_toolbox.sh" p3n

echo "-- $pass ok, $fail failed, $skip n/a"
if [ "$fail" -ne 0 ]; then
    echo "FAIL: ensure_toolbox property fixture ($fail assertion(s) red)"
    exit 1
fi
echo "PASS: ensure_toolbox property fixture (order 777-amku) $pass/$((pass + skip))"
exit 0
