#!/usr/bin/env bash
# Fixture for order 914-ahsy — scripts/lib/tool-materialize.sh and
# scripts/lib/no-tool-path.sh, plus the pilot caller loop-success-probe.sh.
#
# WHAT THIS PINS, and why each arm exists rather than being obvious:
#
# The 799-tb7q sweep left 17 jq callers unconverted because each invokes jq
# inside a LOOP and the per-call toolbox dispatch costs ~265 ms. The packet
# concluded they need RESTRUCTURING to a single jq pass. Measured, they do not:
# materializing the toolbox's binary once costs ~1.0 s and then runs at host
# speed, because it IS the host's binary at that point. These arms exist to stop
# that claim rotting into a comment nobody can check.
#
# THREE MEASUREMENT TRAPS THIS FILE PAID FOR, all found by building the harness
# rather than by designing it:
#
#   1. `command -v` ANSWERS FOR SHELL FUNCTIONS. The session that wrote
#      lib/no-tool-path.sh had a `grep` function in its environment, so
#      `command -v grep` returned the bare name and the curated bin got a
#      self-referential dangling symlink. Every consumer inside the curated PATH
#      then died with "grep: command not found" and the arm reported the
#      tool-less path unusable — a failure with nothing to do with its subject.
#      Arm 2b is the regression.
#   2. A COPY TESTED ON A HOST THAT HAS THE TOOL PROVES NOTHING. `cat
#      /usr/bin/jq > host/jq` runs fine on lenovinha because lenovinha has jq,
#      so /usr/lib64/libjq.so.1 is present. On a genuinely jq-less host it is
#      not. PATH cannot simulate that — PATH governs binaries, not shared
#      libraries. Arm 4 therefore asserts via `ldd` that the PRIVATE library
#      copies are the ones actually loaded, which is the property that holds
#      regardless of what the host has.
#   3. OVERRIDING XDG_RUNTIME_DIR BREAKS TOOLBOX. The first pilot arm pointed
#      XDG_RUNTIME_DIR at a temp dir to place a fixture event log, and podman
#      lost its user-session socket — so `toolbox run` failed, materialization
#      silently fell back to per-call dispatch, and the probe reported a false
#      `timeout`. The fixture log now lives UNDER the real runtime dir. A
#      fixture that rearranges the environment can break the runtime it is
#      measuring.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
ROOT="$PWD"
fail=0
ok()   { echo "ok: $1"; }
bad()  { echo "FAIL: $1" >&2; fail=1; }
skip() { echo "skip: $1"; }

# GNU-date probe (766-tdij). `date +%s%N` is GNU-only and BSD date does NOT
# fail on it — it succeeds and prints a literal N, so an exit-code guard cannot
# catch the difference and a timing arm would silently compare garbage. Probed
# once here; the timing arm SKIPS where it is absent rather than reporting a
# number it cannot compute. The two `date +%s%N` uses below carry the per-line
# exemption because they are reached only behind this probe.
_HAVE_GNU_DATE=0
case "$(date +%s%N 2>/dev/null)" in   # gnu-date: ok — this IS the probe; its whole purpose is to detect BSD date
    ''|*[!0-9]*) _HAVE_GNU_DATE=0 ;;
    *)           _HAVE_GNU_DATE=1 ;;
esac

W="$(mktemp -d "${TMPDIR:-/tmp}/tool-materialize.XXXXXX")" || exit 2
CACHE="$W/cache"
cleanup() {
    rm -rf "$W"
    [ -n "${FIXLOG:-}" ] && rm -f "$FIXLOG"
    return 0
}
trap cleanup EXIT HUP INT TERM

# 1. Both libs parse and source cleanly, twice (they advertise re-source safety).
bash -n scripts/lib/tool-materialize.sh || bad "tool-materialize.sh does not parse"
bash -n scripts/lib/no-tool-path.sh     || bad "no-tool-path.sh does not parse"
# shellcheck source=scripts/lib/tool-dispatch.sh
. scripts/lib/tool-dispatch.sh
. scripts/lib/tool-materialize.sh
. scripts/lib/tool-materialize.sh
. scripts/lib/no-tool-path.sh
command -v materialize_tool >/dev/null || bad "materialize_tool not defined after sourcing"
command -v fast_tool        >/dev/null || bad "fast_tool not defined after sourcing"
command -v make_no_tool_path >/dev/null || bad "make_no_tool_path not defined after sourcing"
ok "libs parse, source idempotently, and define their contract"

# 2. THE CURATED PATH GENUINELY LACKS THE TOOL. make_no_tool_path asserts its
#    own precondition and returns non-zero if the omission does not hold, so a
#    caller cannot measure the with-tool case while reporting the without.
if make_no_tool_path "$W/bin" jq --with toolbox podman flatpak-spawn setpriv id getent >/dev/null 2>&1; then
    if env -i PATH="$W/bin" sh -c 'command -v jq' >/dev/null 2>&1; then
        bad "curated PATH still reaches jq — every measurement below would be of the wrong host"
    else
        ok "curated PATH genuinely lacks jq (precondition asserted, not assumed)"
    fi
else
    bad "make_no_tool_path could not build a jq-less PATH"
fi

# 2b. REGRESSION for the self-symlink bug: every entry in the curated bin must
#     be an EXECUTABLE that resolves, not a dangling self-link. The original bug
#     produced `grep -> grep`, which passes `[ -L ]` and fails at exec.
_selfbad=0
for _e in "$W/bin"/*; do
    [ -e "$_e" ] || { bad "curated bin entry does not resolve: $_e (self-symlink bug, 914-ahsy)"; _selfbad=1; break; }
done
[ "$_selfbad" -eq 0 ] && ok "every curated bin entry resolves to a real binary (no self-symlinks)"

# 3. materialize_tool DECLINES when the host already has the tool — it exists to
#    remove a container round trip, and where there is none it must not insert a
#    copy of the host's own binary.
if command -v jq >/dev/null 2>&1; then
    if _m="$(materialize_tool jq 2>/dev/null)"; then
        bad "materialize_tool materialized jq although the host already has it: $_m"
    elif [ -n "$_m" ]; then
        bad "materialize_tool returned non-zero but still printed: $_m"
    else
        ok "materialize_tool declines (silently, non-zero) when the host has the tool"
    fi
    [ "$(fast_tool jq)" = "jq" ] || bad "fast_tool should answer the bare name when the host has the tool"
else
    skip "arm 3 needs a host jq to assert the decline path"
fi

# ---- toolbox-dependent arms ------------------------------------------------
# Every arm below needs a real toolbox carrying jq. macOS and Windows hosts run
# this suite too and legitimately have neither; they SKIP rather than fail, and
# the skip says which capability was missing.
if ! command -v toolbox >/dev/null 2>&1; then
    skip "arms 4-7 need a toolbox on this host"
elif ! toolbox run --container tillandsias-builder jq --version >/dev/null 2>&1; then
    skip "arms 4-7 need the tillandsias-builder toolbox to carry jq"
else

# THE CURATED PATH STANDS ALONE - no /usr/bin appended. Writing
# PATH="$W/bin:/usr/bin:/bin" was the first draft here and it puts jq straight
# back, so materialize_tool correctly declined ("the host has it") and arms 4
# and 7 measured host jq against host jq: 199 ms vs 196 ms, reported as "the
# mechanism is not working". The arm was right; the environment was wrong.
# Fourth instance in this packet's work of a measurement that varied the very
# thing it was controlling for.
#
# 4. THE CONFOUND-REMOVER. On a jq-less PATH, materialize_tool produces a jq
#    that works — and the PRIVATE library copies are the ones actually loaded.
#    That last clause is the whole arm: a bare copy also "works" on this host,
#    for the wrong reason (the host has libjq because it has jq), and would fail
#    on the tool-less host the materialization exists to serve.
_mt="$(env PATH="$W/bin" TILLANDSIAS_TOOL_CACHE="$CACHE" bash -c '
    . '"$ROOT"'/scripts/lib/tool-dispatch.sh
    . '"$ROOT"'/scripts/lib/tool-materialize.sh
    materialize_tool jq' 2>/dev/null)"
if [ -z "$_mt" ]; then
    bad "materialize_tool produced nothing on a jq-less PATH with a jq-carrying toolbox"
else
    _mtbin="${_mt##* }"
    _mtlib="$CACHE/tillandsias-builder/lib/jq"
    # Exit captured into a variable, never `if ! <pipeline>` (795-imz3): jq may
    # exit before draining stdin, printf then takes SIGPIPE, and under pipefail
    # the pipeline reports failure although jq succeeded — the guard inverts and
    # the arm reports a working materialization as broken.
    printf '{"a":1}' | env LD_LIBRARY_PATH="$_mtlib" "$_mtbin" -r .a >/dev/null 2>&1
    _rc4=$?
    if [ "$_rc4" -ne 0 ]; then
        bad "the materialized jq does not actually run (exit $_rc4)"
    else
        _loaded="$(LD_LIBRARY_PATH="$_mtlib" ldd "$_mtbin" 2>/dev/null | awk '/libjq/{print $3}')"
        case "$_loaded" in
            "$_mtlib"/*) ok "materialized jq runs AND loads its PRIVATE libjq ($_loaded) — the copy does not depend on the host having the tool" ;;
            "")          bad "could not determine which libjq the materialized binary loads" ;;
            *)           bad "materialized jq loaded the HOST's libjq ($_loaded) — on a host without jq this copy would fail at exec; the closure is not travelling with the binary" ;;
        esac
    fi
fi

# 5. A CORRUPT CACHE ENTRY IS RE-EXTRACTED, NOT TRUSTED. This is the arm that
#    matters for a cache living under target/: an entry can outlive the toolbox
#    that produced it, survive a `cargo clean` that took its libraries, or be
#    truncated by a killed run. A stale binary fails at exec INSIDE the caller's
#    pipeline, where the error is attributed to the caller rather than to the
#    cache — the same misattribution 799-tb7q was filed against, one level down.
#
#    REWRITTEN AFTER A MUTATION TEST, and worth recording because the first
#    version was exactly the shape this suite keeps catching. It asked for a
#    tool the toolbox does not have and asserted no partial entry was left. That
#    passes whether or not the cleanup exists: the request fails at the
#    `<tool> --version` probe, BEFORE anything is created, so there is nothing to
#    clean up. Nulling `_mt_abort` to a no-op left the arm green. A guard whose
#    subject is never reached is not a guard.
_c5="$CACHE/tillandsias-builder"
mkdir -p "$_c5/bin" "$_c5/lib/jq"
printf 'this is not an ELF binary\n' > "$_c5/bin/jq"
chmod 755 "$_c5/bin/jq"
rm -f "$_c5/lib/jq"/*
_m5="$(env PATH="$W/bin" TILLANDSIAS_TOOL_CACHE="$CACHE" bash -c '
    . '"$ROOT"'/scripts/lib/tool-dispatch.sh
    . '"$ROOT"'/scripts/lib/tool-materialize.sh
    materialize_tool jq' 2>/dev/null)"
if [ -z "$_m5" ]; then
    bad "materialize_tool gave up on a corrupt cache entry instead of re-extracting"
else
    # Same 795-imz3 capture as arm 4, for the same SIGPIPE reason.
    printf '{"a":1}' | env LD_LIBRARY_PATH="$_c5/lib/jq" "${_m5##* }" -r .a >/dev/null 2>&1
    _rc5=$?
fi
if [ -z "$_m5" ]; then
    :
elif [ "${_rc5:-1}" -ne 0 ]; then
    bad "materialize_tool returned a path from a CORRUPT cache entry — it trusted the cache instead of verifying it"
else
    ok "a corrupt cache entry is re-extracted and verified, not trusted"
fi

# ---- the pilot caller ------------------------------------------------------
#
# THE FIXTURE LOG LIVES UNDER THE REAL RUNTIME DIR ON PURPOSE (trap 3 above).
# Overriding XDG_RUNTIME_DIR to relocate it breaks podman's user-session socket,
# toolbox fails, materialization silently degrades to per-call dispatch, and the
# probe reports a false `timeout` — a fixture breaking the runtime it measures.
_RT="${XDG_RUNTIME_DIR:-/run/user/$(id -u 2>/dev/null || echo 0)}"
if [ ! -d "$_RT" ]; then
    skip "arms 6-7 need a usable XDG_RUNTIME_DIR"
else
    mkdir -p "$_RT/tillandsias/logs/opencode-web" 2>/dev/null
    FIXLOG="$_RT/tillandsias/logs/opencode-web/tm-fixture-914ahsy.jsonl"
    : > "$FIXLOG"
    _i=1
    while [ "$_i" -le 60 ]; do
        printf '{"ts":%d,"stage":"proxy","state":"progress","detail":"chatter %d with spaces"}\n' "$_i" "$_i" >> "$FIXLOG"
        _i=$((_i + 1))
    done
    for _st in proxy git inference forge; do
        printf '{"ts":9,"stage":"%s","state":"started","detail":"up"}\n' "$_st" >> "$FIXLOG"
    done
    printf '{"ts":9,"stage":"browser","state":"route_ready","detail":"ok"}\n' >> "$FIXLOG"
    printf '{"ts":9,"stage":"browser","state":"launched","detail":"ok"}\n'    >> "$FIXLOG"

    _run() { # <label> <extra-env...> -> sets _OUT and _MS
        _l="$1"; shift
        _s=$(date +%s%N)   # gnu-date: ok
        _OUT="$(env "$@" bash "$ROOT/scripts/loop-success-probe.sh" tm-fixture-914ahsy 120 2>/dev/null)"
        _e=$(date +%s%N)   # gnu-date: ok
        _MS=$(( (_e - _s) / 1000000 ))
    }

    # 6. SAME ANSWER ON ALL THREE PATHS. This is the arm that matters most: a
    #    speed-up that changes the verdict is not a speed-up, it is a bug. The
    #    probe emits a JSON verdict, so equality is exact rather than fuzzy.
    rm -rf "$CACHE"
    _run host
    _host_out="$_OUT"; _host_ms="$_MS"
    _run materialized PATH="$W/bin" TILLANDSIAS_TOOL_CACHE="$CACHE" \
        XDG_RUNTIME_DIR="$_RT" HOME="${HOME:-/tmp}"
    _mat_out="$_OUT"; _mat_ms="$_MS"
    # Materialization disabled by pointing the cache somewhere unwritable, so
    # fast_tool falls through to the 799-tb7q per-call prefix. This is the
    # counterfactual the packet assumed everyone would have to live with.
    _run percall PATH="$W/bin" TILLANDSIAS_TOOL_CACHE=/proc/nonexistent-914ahsy \
        XDG_RUNTIME_DIR="$_RT" HOME="${HOME:-/tmp}"
    _pc_out="$_OUT"; _pc_ms="$_MS"

    case "$_host_out" in
        *'"status":"ok"'*) : ;;
        *) bad "the pilot did not succeed even with host jq — fixture log is wrong, not the code: $_host_out" ;;
    esac
    if [ "$_host_out" != "$_mat_out" ]; then
        bad "MATERIALIZED path gives a DIFFERENT verdict than host jq: host='$_host_out' materialized='$_mat_out'"
    elif [ "$_host_out" != "$_pc_out" ]; then
        bad "PER-CALL path gives a DIFFERENT verdict than host jq: host='$_host_out' percall='$_pc_out'"
    else
        ok "pilot verdict identical on all three tool paths (host / materialized / per-call): $_host_out"
    fi

    # 7. THE MEASURED BOUND exit criterion 2 asks for. Stated as a RATIO against
    #    the per-call path measured in the same run, never as an absolute
    #    millisecond figure: absolute numbers are a property of the machine and
    #    would make this arm a flake on slower hardware.
    #
    #    The bound is deliberately loose (4x). The measured margin on lenovinha
    #    2026-08-28 was 22x (2306 ms vs 51520 ms over a 200-line log), so 4x
    #    fails only if the mechanism has genuinely stopped working, not because
    #    a host is slow or the container was cold.
    if [ "$_HAVE_GNU_DATE" -eq 0 ]; then
        skip "arm 7 needs GNU date (+%s%N) to time the runs — BSD date prints a literal N and would compare garbage"
    elif [ "$_mat_ms" -le 0 ] || [ "$_pc_ms" -le 0 ]; then
        skip "arm 7 could not time the runs"
    elif [ $(( _mat_ms * 4 )) -lt "$_pc_ms" ]; then
        ok "materialized run is >4x faster than per-call dispatch (${_mat_ms}ms vs ${_pc_ms}ms; host jq ${_host_ms}ms) — cold cache, extraction included"
    else
        bad "materialization bought less than 4x over per-call dispatch (${_mat_ms}ms vs ${_pc_ms}ms) — the mechanism is not working; check that the toolbox is reachable and the cache is writable"
    fi
fi
fi

if [ "$fail" -ne 0 ]; then
    echo "tool-materialize: FAIL"
    exit 1
fi
echo "ok:tool-materialize:all"
