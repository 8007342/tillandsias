#!/usr/bin/env bash
# ORDER 914-ahsy — materialize a toolbox tool ONCE onto the host, instead of
# paying a container round trip per call.
#
# THE PROBLEM THIS SOLVES, and it is the whole reason 914-ahsy was split out of
# 799-tb7q. resolve_tool (lib/tool-dispatch.sh) answers with a PREFIX, and on a
# host without the tool that prefix is `toolbox run --container … <tool>`.
# MEASURED on lenovinha 2026-08-28, warm container, 20 calls each:
#
#     host jq                  2 ms/call
#     toolbox run jq         265 ms/call      (cold first call: 460 ms)
#
# 133x. For a FLAT caller with 7-9 sites that is ~2 s and acceptable, which is
# why the 799-tb7q sweep converted 23 of them and stopped. For a caller that
# invokes jq inside a LOOP it is ruinous: measure-bands.sh's shape — 9 sites in
# a loop — projects to 238 s over 100 iterations, on exactly the tool-less host
# the dispatch exists to serve. That is what "unusably slow" meant.
#
# THE PACKET'S PREMISE WAS THAT THOSE 17 CALLERS NEED RESTRUCTURING to a single
# jq pass. MEASURED, THEY DO NOT. Materializing the binary once costs ~1.0 s and
# then runs at 2 ms/call — identical to host jq, because it IS the same binary.
# The same 238 s projection becomes 2.8 s. Restructuring 102 call sites across
# 17 scripts is a large, risky, per-script rewrite; this is one line per script
# and uniform. Prefer it, and reach for a restructure only where a caller wants
# one on its own merits.
#
# NOT A NEW IDEA IN THIS TREE — generalized from a proven one. run-litmus-test.sh
# already materializes the toolbox's yq into target/litmus-runtime/bin for
# exactly this reason ("a `toolbox run` round trip measures ~0.29s here"). This
# file makes that reusable and fixes the one thing that does not generalize:
# yq is a Go binary and copies cleanly, jq is DYNAMICALLY LINKED.
#
# THE SHARED-LIBRARY CLOSURE, and why the naive copy is a trap that PASSES on
# every host that does not need it. `cat /usr/bin/jq > host/jq` produced a
# working jq on lenovinha — and that result is CONFOUNDED, because lenovinha has
# jq installed, so /usr/lib64/libjq.so.1 and libonig.so.5 were already there. On
# a genuinely jq-less host those libraries are absent too and the copy would
# fail at exec. A test of the copy on a host that has the tool cannot tell you
# anything about a host that does not. So this extracts the NON-GLIBC closure
# alongside the binary and runs it under a private LD_LIBRARY_PATH; verified on
# lenovinha by `ldd` reporting the PRIVATE copies as the ones actually loaded,
# not the host's.
#
# glibc itself is deliberately NOT copied: the loader is version-sensitive and a
# mismatched libc.so.6 is a crash rather than a fallback. The toolbox and a
# Fedora host share a glibc generation by construction (both fedora-toolbox:44
# lineage — measured 2.43 on both here). If that ever stops holding, the
# verify step below catches it and the caller degrades to per-call dispatch.
#
# VERIFY BEFORE TRUST. Nothing here is believed: the extracted binary must
# answer `--version` under its private loader path or the whole cache entry is
# removed and the function returns 1. A caller that gets 1 falls back to
# resolve_tool and behaves exactly as it does today. This is strictly additive.
#
# SOURCED, NOT EXECUTED. BASH 3.2 CLEAN (761-g36m).

# _tm_cache_dir
# Where materialized tools live. Under target/ (gitignored) so it is disposable
# and never committed, and keyed by container so two containers cannot collide.
_tm_cache_dir() {
    _tmc_root="${TILLANDSIAS_TOOL_CACHE:-}"
    if [ -z "$_tmc_root" ]; then
        _tmc_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
        while [ -n "$_tmc_dir" ] && [ "$_tmc_dir" != "/" ] && [ ! -d "$_tmc_dir/.git" ]; do
            _tmc_dir="$(dirname "$_tmc_dir")"
        done
        _tmc_root="$_tmc_dir/target/tool-cache"
    fi
    printf '%s' "$_tmc_root"
}

# materialize_tool <tool> [container]
#
# Echoes a command prefix that runs <tool> NATIVELY on this host at host speed,
# extracting it from the toolbox on first use. Returns 1 — printing nothing —
# when the host already has the tool (use it directly), when there is no
# toolbox, or when the extraction cannot be verified.
#
# Returning 1 for "the host already has it" is deliberate: this function exists
# to remove a container round trip, and where there is none to remove it must
# not insert a copy of the host's own binary. Callers pair it with resolve_tool,
# which answers the bare name in that case.
materialize_tool() {
    _mt_tool="${1:?materialize_tool: tool name required}"
    _mt_container="${2:-tillandsias-builder}"

    # Host has it: nothing to materialize. Not an error, but not our business.
    command -v "$_mt_tool" >/dev/null 2>&1 && return 1
    command -v toolbox >/dev/null 2>&1 || return 1

    _mt_cache="$(_tm_cache_dir)/$_mt_container"
    _mt_bin="$_mt_cache/bin/$_mt_tool"
    _mt_lib="$_mt_cache/lib/$_mt_tool"

    # CACHED AND STILL GOOD. Re-verified rather than assumed present: a cache
    # entry can outlive the toolbox that produced it, and a stale binary whose
    # libraries were pruned fails at exec inside the caller's pipeline, where
    # the error is attributed to the caller.
    if [ -x "$_mt_bin" ] \
       && LD_LIBRARY_PATH="$_mt_lib" "$_mt_bin" --version >/dev/null 2>&1; then
        printf 'env LD_LIBRARY_PATH=%s %s' "$_mt_lib" "$_mt_bin"
        return 0
    fi

    # The tool must actually be IN the container — the container existing does
    # not mean the tool is in it (the 799-tb7q defect, one level down).
    toolbox run --container "$_mt_container" "$_mt_tool" --version >/dev/null 2>&1 || return 1

    # EVERY failure from here on removes the whole cache entry. A PARTIAL entry
    # is worse than none: the next call finds a bin/ or lib/ that looks
    # populated, and the failure surfaces inside the caller's pipeline where it
    # is attributed to the caller. Caught by the fixture — the first draft
    # returned early on an empty tool path and left an empty lib/jq behind.
    _mt_abort() { rm -rf "$_mt_bin" "$_mt_lib" 2>/dev/null; return 1; }

    mkdir -p "$(dirname "$_mt_bin")" "$_mt_lib" 2>/dev/null || { _mt_abort; return 1; }

    # `command -v` INSIDE the container, then required to be absolute — the
    # container's shell may answer for a function or builtin exactly as the
    # host's can (see _ntp_binpath in lib/no-tool-path.sh for the bug that
    # taught this). An answer that is not a path is not a binary we can copy.
    _mt_path="$(toolbox run --container "$_mt_container" command -v "$_mt_tool" 2>/dev/null \
                | tr -d '\r' | sed -n '/^\//{p;q;}')"
    [ -n "$_mt_path" ] || { _mt_abort; return 1; }

    toolbox run --container "$_mt_container" cat "$_mt_path" > "$_mt_bin" 2>/dev/null \
        || { _mt_abort; return 1; }
    [ -s "$_mt_bin" ] || { _mt_abort; return 1; }
    chmod 755 "$_mt_bin" 2>/dev/null || true

    # THE NON-GLIBC CLOSURE. ldd is read INSIDE the container, so the paths are
    # the container's. glibc and the loader are excluded on purpose (see header).
    for _mt_so in $(toolbox run --container "$_mt_container" ldd "$_mt_path" 2>/dev/null \
                    | awk '/=> \//{print $3}' \
                    | awk '!/\/(libc|libm|libdl|libpthread|librt|ld-linux)[-.]/'); do
        toolbox run --container "$_mt_container" cat "$_mt_so" \
            > "$_mt_lib/$(basename "$_mt_so")" 2>/dev/null || true
    done

    # VERIFY, then trust. An unverifiable extraction leaves NOTHING behind, so
    # the next call retries cleanly rather than reusing a broken cache entry.
    if LD_LIBRARY_PATH="$_mt_lib" "$_mt_bin" --version >/dev/null 2>&1; then
        printf 'env LD_LIBRARY_PATH=%s %s' "$_mt_lib" "$_mt_bin"
        return 0
    fi
    _mt_abort
    return 1
}

# fast_tool <tool> [container]
#
# THE ONE CALL A LOOP CALLER SHOULD MAKE. Host binary if present, else a
# materialized native copy, else the per-call toolbox prefix, else empty+1.
# Resolve ONCE into a variable outside the loop; the point is defeated by
# calling it per iteration.
fast_tool() {
    _ft_tool="${1:?fast_tool: tool name required}"
    _ft_container="${2:-tillandsias-builder}"
    if command -v "$_ft_tool" >/dev/null 2>&1; then
        printf '%s' "$_ft_tool"; return 0
    fi
    if _ft_cmd="$(materialize_tool "$_ft_tool" "$_ft_container")"; then
        printf '%s' "$_ft_cmd"; return 0
    fi
    if command -v resolve_tool >/dev/null 2>&1; then
        _ft_cmd="$(resolve_tool "$_ft_tool" "$_ft_container")" || return 1
        printf '%s' "$_ft_cmd"; return 0
    fi
    return 1
}
