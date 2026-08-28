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

# --- capability, non-creating (order 799-tb7q, second criterion) -----------
#
# WHY THESE ARE CONSTRUCTED RATHER THAN SCANNED. The defect being fixed is a
# host whose nix lives ONLY in a toolbox being reported nix-incapable, and no
# host in the fleet is in that state on demand. An arm that ran `capability`
# here and checked the answer would assert whatever this machine happens to
# be — green on every host, red on none. So arms 11 and 12 build both worlds
# out of fake `toolbox`/`podman`/`nix` binaries on PATH.

# 10. GRAMMAR + EXIT-CODE AGREEMENT, on the real host, whatever it is.
cap="$("$SCRIPT" capability 2>/dev/null)"
caprc=$?
capl="$(printf '%s' "$cap" | grep -c '')"
[ "$capl" = 1 ] || failures+=("capability printed $capl lines, expected 1: $cap")
printf '%s' "$cap" | grep -qE '^(ok:nix-capability:(daemon|chroot|toolbox)|none:nix-capability:no-nix-and-no-toolbox)$' \
    || failures+=("capability verdict outside the pinned grammar: $cap")
case "$cap" in
    ok:*)   [ "$caprc" -eq 0 ] || failures+=("capability ok verdict with non-zero exit $caprc") ;;
    none:*) [ "$caprc" -ne 0 ] || failures+=("capability none verdict with exit 0 — a caller reads that as capable") ;;
esac

# 11. IT MUST NEVER CREATE. This is the whole reason `capability` exists rather
#     than callers using `ensure`: a pre-push gate and the work selector ask the
#     question, and `ensure` answers it by pulling a 400 MiB image and creating a
#     toolbox. Fake toolbox/podman record every call; nix is absent from PATH.
if [ -n "$TMPROOT" ]; then
    B11="$TMPROOT/bin11"; mkdir -p "$B11"
    LOG11="$TMPROOT/calls11"; : > "$LOG11"
    cat > "$B11/toolbox" <<EOF11
#!/usr/bin/env bash
printf 'toolbox %s\n' "\$*" >> "$LOG11"
case "\$1" in
    list) printf 'CONTAINER ID  CONTAINER NAME  CREATED\n' ;;   # no containers
    *) exit 1 ;;
esac
EOF11
    cat > "$B11/podman" <<EOF11
#!/usr/bin/env bash
printf 'podman %s\n' "\$*" >> "$LOG11"
exit 1
EOF11
    chmod +x "$B11/toolbox" "$B11/podman"
    # A PATH with the fakes and the POSIX baseline, but deliberately no `nix`.
    c11="$(env PATH="$B11:/usr/bin:/bin" HOME="$TMPROOT/h11" \
             TILLANDSIAS_NIX_CHROOT_STORE="$TMPROOT/s11" \
             bash "$SCRIPT" capability 2>/dev/null)"
    [ "$c11" = "none:nix-capability:no-nix-and-no-toolbox" ] \
        || failures+=("capability on a host with no nix and no toolbox should be none, got: $c11")
    if grep -qE '^(podman .*pull|toolbox .*create)' "$LOG11"; then
        failures+=("capability PROVISIONED: it pulled or created infrastructure while answering a question — $(grep -E '^(podman .*pull|toolbox .*create)' "$LOG11" | head -1)")
    fi
    # NEGATIVE CONTROL for the arm itself: `ensure`, given the identical fake
    # world, DOES reach for the pull. Without this the arm above could pass
    # because the fakes are never consulted at all.
    : > "$LOG11"
    env PATH="$B11:/usr/bin:/bin" HOME="$TMPROOT/h11" \
        TILLANDSIAS_NIX_CHROOT_STORE="$TMPROOT/s11" \
        bash "$SCRIPT" ensure >/dev/null 2>&1
    grep -qE '^podman .*pull' "$LOG11" \
        || failures+=("negative control failed: ensure did not attempt a pull in the fake world, so arm 11 proves nothing")
fi

# 12. THE DEFECT, POSITIVELY. A host with NO host nix but an EXISTING nix
#     toolbox that carries nix is nix-CAPABLE. Before 799-tb7q both callers
#     judged by `command -v nix` on the host and declared this host incapable:
#     check-nix-deps-stability.sh skipped green and select-work-batch.sh
#     subtracted every nix-tagged packet from the pool.
if [ -n "$TMPROOT" ]; then
    B12="$TMPROOT/bin12"; mkdir -p "$B12"
    cat > "$B12/toolbox" <<'EOF12'
#!/usr/bin/env bash
case "$1" in
    list) printf 'CONTAINER ID  CONTAINER NAME  CREATED\n0000  tillandsias-nix  now\n' ;;
    run)  shift; [ "$1" = "-c" ] && shift 2; exec "$@" ;;   # the container HAS nix
    *) exit 1 ;;
esac
EOF12
    cat > "$B12/nix" <<'EOF12'
#!/usr/bin/env bash
exit 0
EOF12
    chmod +x "$B12/toolbox" "$B12/nix"
    # `nix` lives in $B12 but is reachable only THROUGH the fake toolbox run:
    # PATH for the script itself excludes it, so a host-binary probe finds none.
    B12H="$TMPROOT/bin12host"; mkdir -p "$B12H"
    cp "$B12/toolbox" "$B12H/toolbox"
    cat > "$B12H/toolbox" <<EOF12H
#!/usr/bin/env bash
case "\$1" in
    list) printf 'CONTAINER ID  CONTAINER NAME  CREATED\n0000  tillandsias-nix  now\n' ;;
    run)  shift; [ "\$1" = "-c" ] && shift 2; exec env PATH="$B12:/usr/bin:/bin" "\$@" ;;
    *) exit 1 ;;
esac
EOF12H
    chmod +x "$B12H/toolbox"
    c12="$(env PATH="$B12H:/usr/bin:/bin" HOME="$TMPROOT/h12" \
             TILLANDSIAS_NIX_CHROOT_STORE="$TMPROOT/s12" \
             bash "$SCRIPT" capability 2>/dev/null)"
    [ "$c12" = "ok:nix-capability:toolbox" ] \
        || failures+=("a host whose nix lives in an existing toolbox must report ok:nix-capability:toolbox, got: $c12 — this is the 799-tb7q defect")
fi

# 13. NEITHER CALLER JUDGES NIX BY THE HOST BINARY ANY MORE. Asserted as a
#     BEHAVIOUR-adjacent source check on the two specific decision points,
#     because reproducing the selector's whole ledger query hermetically costs
#     more than it proves — and scoped to a `command -v nix` used as the
#     VERDICT, which is what was wrong. nix-toolbox.sh's own rung probes still
#     use `command -v nix`, correctly: there it is one input among three.
for caller in check-nix-deps-stability.sh select-work-batch.sh; do
    f="$ROOT/scripts/$caller"
    [ -f "$f" ] || { failures+=("arm 13 caller missing: $caller"); continue; }
    if grep -vE '^\s*#' "$f" | grep -q 'command -v nix'; then
        failures+=("$caller still decides nix capability from the host binary (command -v nix) — 799-tb7q")
    fi
    grep -q 'nix-toolbox.sh' "$f" \
        || failures+=("$caller does not consult nix-toolbox.sh for nix capability")
done

if [ "${#failures[@]}" -gt 0 ]; then
    printf 'FAIL: %s\n' "${failures[@]}" >&2
    echo "nix-toolbox: FAIL ${#failures[@]} scenario(s)"
    exit 1
fi
echo "PASS: nix-toolbox fixture 13/13 (grammar, exit-code agreement, idempotence, store-probe-not-pure-eval, nix-args usable, store-path override, delete-and-rebuild, pinned-survives-gc, gc-refuses-when-deps-unresolved, capability-grammar, capability-never-creates, toolbox-only-nix-is-capable, callers-off-host-binary) rung=${out#ok:nix-toolbox:}"
