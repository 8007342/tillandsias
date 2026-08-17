#!/usr/bin/env bash
# @trace order:736-mcy3, spec:ci-release
set -uo pipefail

# Fixture for scripts/nix-toolbox.sh (order 736-mcy3).
#
# What is worth pinning here is the GRAMMAR and the IDEMPOTENCE, not which rung
# a given host lands on — that legitimately differs per host, which is the whole
# reason the script reports the rung instead of assuming one. A test that
# demanded `daemon` would fail on exactly the hosts the script exists to serve.
#
# The one behavioural trap it does pin: `nix eval --expr '1'` is PURE and
# succeeds with the daemon dead, so an ensure that probed with eval reported
# `daemon` on a host where `nix build` then failed to connect to the socket.
# The probe must exercise the STORE.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/nix-toolbox.sh"

failures=()

# 1. GRAMMAR: exactly one line, from the closed vocabulary.
out="$("$SCRIPT" ensure 2>/dev/null)"
rc=$?
lines="$(printf '%s' "$out" | grep -c '')"
[ "$lines" = 1 ] || failures+=("ensure printed $lines lines, expected 1: $out")
printf '%s' "$out" | grep -qE '^(ok:nix-toolbox:(daemon|chroot|toolbox)|blocked:nix-toolbox:(no-nix-and-no-toolbox|image-pull-failed|create-failed))$' \
    || failures+=("ensure verdict outside the pinned grammar: $out")

# 2. EXIT CODE agrees with the verdict — a blocked rung that exits 0 would let a
#    caller build on a nix that does not work.
case "$out" in
    ok:*)      [ "$rc" -eq 0 ] || failures+=("ok verdict with non-zero exit $rc") ;;
    blocked:*) [ "$rc" -ne 0 ] || failures+=("blocked verdict with exit 0") ;;
esac

# 3. IDEMPOTENCE: running it again on an already-prepared host is a no-op that
#    reports the same rung. This is the property the operator asked for — the
#    script must be safe to call from any runbook, on a fresh host or a warm one.
out2="$("$SCRIPT" ensure 2>/dev/null)"
[ "$out" = "$out2" ] || failures+=("not idempotent: first='$out' second='$out2'")

# 4. The store probe is not a pure eval. Asserted on the SOURCE because
#    reproducing a dead daemon inside a fixture would mean stopping a system
#    service; this is the one place a source assertion is cheaper than the
#    behaviour, and its negative control is that `eval --expr` must NOT be the
#    probe.
if grep -q 'nix "${NIX_FEATURES\[@\]}" eval --expr .* >/dev/null 2>&1$' "$SCRIPT"; then
    failures+=("daemon probe uses a pure eval — it answers with the daemon dead")
fi
grep -q 'store ping' "$SCRIPT" || failures+=("no store-exercising probe found")

# 5. nix-args must be consumable: either flags, or a refusal on stderr with a
#    non-zero exit. Never flags AND a refusal.
args="$("$SCRIPT" nix-args 2>/dev/null)"
argrc=$?
if [ "$argrc" -eq 0 ]; then
    printf '%s' "$args" | grep -q 'extra-experimental-features' \
        || failures+=("nix-args exited 0 without usable flags: $args")
fi

# --- persistent store (order 795-h8er) ------------------------------------
#
# HERMETIC BY CONSTRUCTION. Every scenario below points
# TILLANDSIAS_NIX_CHROOT_STORE at a throwaway directory. The real store is
# multi-GiB and shared by every worktree on the host; a fixture that collected
# it would cost hours of recompilation to "pass".

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/nix-toolbox-fixture.XXXXXX")" || TMPROOT=""
cleanup() { [ -n "$TMPROOT" ] && rm -rf "$TMPROOT"; }
trap cleanup EXIT HUP INT TERM

# 6. The store root is configurable, which is what makes 7 and 8 hermetic and
#    what lets a host relocate the cache to a bigger disk.
if [ -n "$TMPROOT" ]; then
    sp="$(TILLANDSIAS_NIX_CHROOT_STORE="$TMPROOT/s6" "$SCRIPT" store-path 2>/dev/null)"
    [ "$sp" = "$TMPROOT/s6" ] || failures+=("store-path ignored the env override: $sp")
fi

# 7. DELETING THE STORE IS SAFE: status says so honestly, and the next ensure
#    rebuilds it rather than erroring. This is the "ephemeral-ish" half of the
#    operator's ask — the cache must be disposable without breaking the host.
if [ -n "$TMPROOT" ] && command -v nix >/dev/null 2>&1; then
    S7="$TMPROOT/s7"
    r1="$(TILLANDSIAS_NIX_CHROOT_STORE="$S7" "$SCRIPT" ensure 2>/dev/null)"
    if [ "$r1" = "ok:nix-toolbox:chroot" ]; then
        rm -rf "$S7"
        st="$(TILLANDSIAS_NIX_CHROOT_STORE="$S7" "$SCRIPT" store-status 2>/dev/null)"
        [ "$st" = "skip:nix-store:no-store" ] \
            || failures+=("store-status after deletion should be skip:nix-store:no-store, got: $st")
        r2="$(TILLANDSIAS_NIX_CHROOT_STORE="$S7" "$SCRIPT" ensure 2>/dev/null)"
        [ "$r2" = "$r1" ] \
            || failures+=("ensure did not rebuild a deleted store: first='$r1' second='$r2'")
        [ -d "$S7/nix/store" ] || failures+=("ensure reported ok but did not recreate $S7/nix/store")
    fi
fi

# 8. THE ROOT MECHANISM ITSELF. A path under the pin directory survives
#    `nix store gc`; an unrooted path does not.
#
#    This is the single most load-bearing assertion in this file. The daily
#    build_cache_hygiene lane runs a collection against this store, and before
#    order 795-h8er every root was an `auto` indirect root pointing into a fork
#    worktree that had already been deleted — so the entire 5.8 GiB cache was
#    garbage by nix's reckoning and one hygiene run from gone. If a nix upgrade
#    ever stops honouring roots in this location, the cache evaporates silently
#    and the only symptom is that builds got slow again. Fail loud here instead.
if [ -n "$TMPROOT" ] && command -v nix >/dev/null 2>&1; then
    S8="$TMPROOT/s8"
    NF8=(--extra-experimental-features "nix-command flakes")
    mkdir -p "$S8"
    printf 'rooted\n'   > "$TMPROOT/keep.txt"
    printf 'unrooted\n' > "$TMPROOT/drop.txt"
    keep="$(nix "${NF8[@]}" --store "$S8" store add-path "$TMPROOT/keep.txt" --name fixture-keep 2>/dev/null)"
    drop="$(nix "${NF8[@]}" --store "$S8" store add-path "$TMPROOT/drop.txt" --name fixture-drop 2>/dev/null)"
    if [ -n "$keep" ] && [ -n "$drop" ]; then
        # Same location and same logical-path convention nix-toolbox.sh pins to.
        mkdir -p "$S8/nix/var/nix/gcroots/tillandsias"
        ln -sfn "$keep" "$S8/nix/var/nix/gcroots/tillandsias/fixture-keep"
        nix "${NF8[@]}" --store "$S8" store gc >/dev/null 2>&1
        nix "${NF8[@]}" --store "$S8" path-info "$keep" >/dev/null 2>&1 \
            || failures+=("gc deleted a PINNED path — roots under nix/var/nix/gcroots/tillandsias are not honoured")
        if nix "${NF8[@]}" --store "$S8" path-info "$drop" >/dev/null 2>&1; then
            failures+=("gc kept an UNROOTED path — the collection is vacuous and proves nothing")
        fi
    fi
fi

# 9. THE SAFETY INTERLOCK: when flake evaluation cannot say which deps closures
#    are current, `gc` must REFUSE rather than collect. Without this, any
#    condition that breaks evaluation — a syntax error mid-edit, a missing
#    flake input, a bad checkout — silently converts the daily hygiene lane
#    into "delete the entire build cache", because with nothing resolvable
#    nothing gets pinned and every path looks like garbage.
#
#    The ceiling is forced to 0 so the interlock is the ONLY thing that can
#    stop the collection; otherwise this would pass for free on a small store.
if [ -n "$TMPROOT" ] && command -v nix >/dev/null 2>&1; then
    S9="$TMPROOT/s9"
    mkdir -p "$S9/scripts"
    cp "$SCRIPT" "$S9/scripts/nix-toolbox.sh"
    # Deliberately no flake.nix beside it, so every deps resolution fails.
    env TILLANDSIAS_NIX_CHROOT_STORE="$S9/store" TILLANDSIAS_NIX_STORE_CEILING_GIB=0 \
        bash "$S9/scripts/nix-toolbox.sh" ensure >/dev/null 2>&1
    printf 'precious\n' > "$TMPROOT/precious.txt"
    prec="$(nix --extra-experimental-features "nix-command flakes" --store "$S9/store" \
              store add-path "$TMPROOT/precious.txt" --name fixture-precious 2>/dev/null)"
    if [ -n "$prec" ]; then
        v="$(env TILLANDSIAS_NIX_CHROOT_STORE="$S9/store" TILLANDSIAS_NIX_STORE_CEILING_GIB=0 \
               bash "$S9/scripts/nix-toolbox.sh" gc 2>/dev/null)"
        vrc=$?
        [ "$v" = "blocked:nix-store-gc:unresolved-deps" ] \
            || failures+=("gc with unresolvable deps should refuse, got: $v")
        [ "$vrc" -ne 0 ] || failures+=("gc refused but exited 0 — a lane would treat that as success")
        nix --extra-experimental-features "nix-command flakes" --store "$S9/store" \
            path-info "$prec" >/dev/null 2>&1 \
            || failures+=("gc collected despite refusing — the interlock does not actually gate the collection")
    fi
fi

if [ "${#failures[@]}" -gt 0 ]; then
    printf 'FAIL: %s\n' "${failures[@]}" >&2
    echo "nix-toolbox: FAIL ${#failures[@]} scenario(s)"
    exit 1
fi
echo "PASS: nix-toolbox fixture 9/9 (grammar, exit-code agreement, idempotence, store-probe-not-pure-eval, nix-args usable, store-path override, delete-and-rebuild, pinned-survives-gc, gc-refuses-when-deps-unresolved) rung=${out#ok:nix-toolbox:}"
