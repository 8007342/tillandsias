#!/bin/bash
# @trace spec:inference-engine-slots (SLOT-1, SLOT-2, SLOT-4, SLOT-7, SLOT-8), order 482b
#
# The llama-server engine slot, selected with TILLANDSIAS_INFERENCE_ENGINE=llama-server
# (the default engine stays ollama: SLOT-3, engine_slots::default_engine_kind).
#
# NO SECOND IMAGE AND NO NEW BINARY. The slot runs the llama-server that the
# digest-pinned ollama payload already ships (lib/ollama/llama-server, upstream
# llama.cpp), whose executable is already hashed by the 521 engine manifest. The
# Mesa/Vulkan userspace was already in this image (order 482). What this file adds:
#
#   1. Backend selection, EXACTLY ONE (vulkan | cpu | cuda_v12 | cuda_v13):
#        auto     vulkan when a render node in the container is readable AND writable,
#                 else cpu. No host CUDA or ROCm stack is ever needed (SLOT-4).
#        cuda     only when explicitly requested AND the cuda lane is delivered
#                 (tier gpu-cuda, which the launcher downgrades without CDI, plus
#                 /dev/nvidia0 in the container); otherwise refused, then auto.
#        rocm     refused: this payload ships no rocm backend, and a refusal is more
#                 honest than a silent alias (order 482 runs AMD through vulkan).
#   2. The pin. llama-server loads ONLY the backend library GGML_BACKEND_PATH names:
#      measured 2026-10-12 with the v0.34.0 payload, a vulkan dir beside the binary
#      and no pin listed no devices at all; with the pin, exactly the RADV iGPU.
#      CPU runs with no pin. A payload carrying more backend dirs than the
#      selection, with no pin naming the selected library, is refused
#      (engine-integrity-refused:multi-backend-unpinned) — that is the race
#      OLLAMA_VULKAN=true ran against bundled cuda dirs, closed for this slot.
#   3. Models FAIL CLOSED. llama.cpp's own `-hf` download verifies nothing, so
#      the slot never uses it. A tier model is served only when gguf-pins.tsv names
#      its file, size and sha256; the download is verified before it is used, and
#      the cached file is re-verified at every start. Unpinned rows are refused
#      (engine-integrity-refused:gguf-unpinned:<id>); bytes that do not match are
#      refused and deleted (engine-integrity-refused:gguf-digest-mismatch:<id>).
#      482b pins T0 only; 482-igky pins the rest per shard.
#   4. The unchanged endpoint (SLOT-1/SLOT-2). llama-server binds 127.0.0.1:11435;
#      caddy owns :11434. GET /api/version answers 200 {"version":"llama-server <build>"}
#      ONLY while llama-server's /health answers 200, inside the one-second probe
#      bound; everything else is proxied verbatim (/v1/models, /v1/chat/completions).
#   5. Supervision. Both processes are children of the entrypoint; when either
#      exits, the other is stopped and the container exits NON-ZERO, so a dead
#      engine can never hide behind a live shim.
#
# Functions only when sourced (no side effects), like the other image helpers, so
# litmus:inference-llama-server-lane-shape runs every rule against fixtures with no
# container. Standalone verbs at the bottom. No python, no eval.

TILLANDSIAS_LLAMA_UPSTREAM_PORT="${TILLANDSIAS_LLAMA_UPSTREAM_PORT:-11435}"
TILLANDSIAS_LLAMA_CADDYFILE="${TILLANDSIAS_LLAMA_CADDYFILE:-/usr/local/share/tillandsias/llama-server.Caddyfile}"

# The container's /dev, overridable ONLY so fixtures can stand in for device nodes.
_tillandsias_llama_dev() { printf '%s\n' "${TILLANDSIAS_LLAMA_DEV_ROOT:-/dev}"; }

# First render node this process can actually open: present AND readable AND
# writable. A node that exists but is not accessible is "unusable", and SLOT-5
# forbids fixing that at runtime, so it is reported, never chmod-ed.
tillandsias_llama_render_node() {
    _tlr_dev="$(_tillandsias_llama_dev)"
    for _tlr_node in "$_tlr_dev"/dri/renderD*; do
        [ -e "$_tlr_node" ] || continue
        if [ -r "$_tlr_node" ] && [ -w "$_tlr_node" ]; then
            printf '%s\n' "$_tlr_node"
            return 0
        fi
    done
    return 1
}

# Prints "<backend> <reason>" — exactly one backend, and why.
#   request: TILLANDSIAS_INFERENCE_LLAMA_BACKEND = auto (default) | vulkan | cpu | cuda | rocm
#   tier:    TILLANDSIAS_INFERENCE_TIER (already downgraded by the launcher when the
#            GPU cannot be delivered, order 392)
#   cuda:    OLLAMA_LLM_LIBRARY, pinned by the launcher to cuda_v12|cuda_v13 (482a)
tillandsias_llama_backend_select() {
    _tlb_req="${TILLANDSIAS_INFERENCE_LLAMA_BACKEND:-auto}"
    _tlb_dev="$(_tillandsias_llama_dev)"
    _tlb_note=""
    case "$_tlb_req" in
        cuda)
            if [ "${TILLANDSIAS_INFERENCE_TIER:-}" != "gpu-cuda" ]; then
                _tlb_note="cuda-refused:tier-${TILLANDSIAS_INFERENCE_TIER:-unset}-not-gpu-cuda,"
            elif [ ! -e "$_tlb_dev/nvidia0" ]; then
                _tlb_note="cuda-refused:no-nvidia0-in-container,"
            else
                case "${OLLAMA_LLM_LIBRARY:-}" in
                    cuda_v13) echo "cuda_v13 requested:cuda-lane-delivered" ;;
                    *) echo "cuda_v12 requested:cuda-lane-delivered" ;;
                esac
                return 0
            fi
            ;;
        rocm)
            _tlb_note="rocm-refused:no-rocm-backend-in-payload,"
            ;;
        cpu)
            echo "cpu requested:cpu"
            return 0
            ;;
        vulkan | auto) ;;
        *)
            _tlb_note="unknown-request:${_tlb_req},"
            ;;
    esac
    if _tlb_node="$(tillandsias_llama_render_node)"; then
        echo "vulkan ${_tlb_note}render-node:${_tlb_node##*/}"
        return 0
    fi
    # Distinguish "no node" from "a node this uid cannot open" (SLOT-5: logged no-op).
    _tlb_why="no-render-node"
    for _tlb_node in "$_tlb_dev"/dri/renderD*; do
        [ -e "$_tlb_node" ] && _tlb_why="render-node-unusable:${_tlb_node##*/}" && break
    done
    echo "cpu ${_tlb_note}${_tlb_why}"
}

# The backend dir the engine payload must carry for a backend ("" for cpu).
tillandsias_llama_backend_dir() { # <backend>
    case "$1" in
        cpu) echo "" ;;
        *) echo "$1" ;;
    esac
}

# The library GGML_BACKEND_PATH must name for a backend ("" for cpu).
tillandsias_llama_backend_pin() { # <libdir> <backend>
    case "$2" in
        cpu) echo "" ;;
        *) echo "$1/$2/libggml-${2%%_*}.so" ;;
    esac
}

# Closure verdict for the INSTALLED payload against the selection. One token:
#   ok
#   engine-integrity-refused:backend-missing:<lib>
#   engine-integrity-refused:engine-set-disagrees:<recorded set>
#   engine-integrity-refused:multi-backend-unpinned:<dirs>
tillandsias_llama_backend_verdict() { # <libdir> <backend> <engine-set> <ggml-backend-path>
    _tlv_lib="$1"; _tlv_be="$2"; _tlv_set="$3"; _tlv_pin="$4"
    _tlv_dir="$(tillandsias_llama_backend_dir "$_tlv_be")"
    _tlv_want_pin="$(tillandsias_llama_backend_pin "$_tlv_lib" "$_tlv_be")"
    if [ -n "$_tlv_want_pin" ] && [ ! -f "$_tlv_want_pin" ]; then
        echo "engine-integrity-refused:backend-missing:${_tlv_want_pin#"$_tlv_lib"/}"
        return 0
    fi
    _tlv_want_set="core${_tlv_dir:++$_tlv_dir}"
    if [ "$_tlv_set" != "$_tlv_want_set" ]; then
        echo "engine-integrity-refused:engine-set-disagrees:${_tlv_set:-none}"
        return 0
    fi
    _tlv_dirs=""
    _tlv_n=0
    for _tlv_d in "$_tlv_lib"/*/; do
        [ -d "$_tlv_d" ] || continue
        _tlv_d="${_tlv_d%/}"
        _tlv_dirs="${_tlv_dirs:+$_tlv_dirs,}${_tlv_d##*/}"
        _tlv_n=$((_tlv_n + 1))
    done
    _tlv_allowed=0
    [ -n "$_tlv_dir" ] && _tlv_allowed=1
    _tlv_pinned=0
    [ -n "$_tlv_want_pin" ] && [ "$_tlv_pin" = "$_tlv_want_pin" ] && _tlv_pinned=1
    if [ "$_tlv_n" -gt "$_tlv_allowed" ] && [ "$_tlv_pinned" -eq 0 ]; then
        echo "engine-integrity-refused:multi-backend-unpinned:$_tlv_dirs"
        return 0
    fi
    echo "ok"
}

# Pin row for a logical id: "<repo> <file> <sha256> <bytes>", rc 1 when unpinned.
tillandsias_llama_gguf_pin() { # <logical-id>
    _tlp_tab="${TILLANDSIAS_TIERS_DIR:-/usr/local/share/tillandsias/tiers}/gguf-pins.tsv"
    [ -r "$_tlp_tab" ] || return 1
    while IFS="$(printf '\t')" read -r _tlp_id _tlp_repo _tlp_file _tlp_sha _tlp_bytes _tlp_rest; do
        case "$_tlp_id" in '' | '#'*) continue ;; esac
        [ "$_tlp_id" = "$1" ] || continue
        case "$_tlp_sha" in *[!0-9a-f]* | '') return 1 ;; esac
        [ "${#_tlp_sha}" -eq 64 ] || return 1
        case "$_tlp_bytes" in *[!0-9]* | '') return 1 ;; esac
        printf '%s %s %s %s\n' "$_tlp_repo" "$_tlp_file" "$_tlp_sha" "$_tlp_bytes"
        return 0
    done < "$_tlp_tab"
    return 1
}

# Verify a file against a pin. One token: ok | size-mismatch | gguf-digest-mismatch | no-verifier | missing
tillandsias_llama_gguf_check() { # <path> <sha256> <bytes>
    [ -f "$1" ] || { echo "missing"; return 0; }
    command -v sha256sum >/dev/null 2>&1 || { echo "no-verifier"; return 0; }
    _tlc_size="$(wc -c < "$1" 2>/dev/null | tr -d ' ')"
    [ "$_tlc_size" = "$3" ] || { echo "size-mismatch"; return 0; }
    _tlc_sha="$(sha256sum "$1" 2>/dev/null)"
    [ "${_tlc_sha%% *}" = "$2" ] || { echo "gguf-digest-mismatch"; return 0; }
    echo "ok"
}

# Make a pinned GGUF available, verified. Prints the path on success (rc 0);
# prints "reason=engine-integrity-refused:<why>:<id>" or a download failure on stderr (rc 1).
# Never serves bytes it has not verified; a mismatching file is deleted.
tillandsias_llama_gguf_ensure() { # <logical-id> <dir>
    _tle_id="$1"; _tle_dir="$2"
    if ! _tle_pin="$(tillandsias_llama_gguf_pin "$_tle_id")"; then
        echo "[inference] reason=engine-integrity-refused:gguf-unpinned:$_tle_id — no sha256 pin in gguf-pins.tsv; NOT downloaded (482-igky pins the remaining rows)" >&2
        return 1
    fi
    set -- $_tle_pin
    _tle_repo="$1"; _tle_file="$2"; _tle_sha="$3"; _tle_bytes="$4"
    _tle_path="$_tle_dir/$_tle_file"
    _tle_v="$(tillandsias_llama_gguf_check "$_tle_path" "$_tle_sha" "$_tle_bytes")"
    if [ "$_tle_v" = "ok" ]; then
        printf '%s\n' "$_tle_path"
        return 0
    fi
    if [ "$_tle_v" = "no-verifier" ]; then
        echo "[inference] reason=engine-integrity-refused:no-verifier:$_tle_id — sha256sum absent, refusing to serve an unverified model" >&2
        return 1
    fi
    if [ "$_tle_v" != "missing" ]; then
        echo "[inference] reason=engine-integrity-refused:gguf-digest-mismatch:$_tle_id — cached $_tle_file failed verification ($_tle_v); deleted, re-fetching" >&2
        rm -f "$_tle_path"
    fi
    mkdir -p "$_tle_dir" || { echo "[inference] reason=gguf-dir-unwritable:$_tle_dir" >&2; return 1; }
    _tle_tmp="$_tle_path.partial"
    if ! curl -fsSL --max-time 1800 --retry 2 --retry-delay 3 \
        "https://huggingface.co/$_tle_repo/resolve/main/$_tle_file" -o "$_tle_tmp"; then
        rm -f "$_tle_tmp"
        echo "[inference] gguf $_tle_id download failed — will retry next launch (non-fatal for the forge)" >&2
        return 1
    fi
    _tle_v="$(tillandsias_llama_gguf_check "$_tle_tmp" "$_tle_sha" "$_tle_bytes")"
    if [ "$_tle_v" != "ok" ]; then
        rm -f "$_tle_tmp"
        echo "[inference] reason=engine-integrity-refused:gguf-digest-mismatch:$_tle_id — downloaded bytes do not match the pin ($_tle_v); deleted, NOT served" >&2
        return 1
    fi
    mv -f "$_tle_tmp" "$_tle_path"
    echo "[inference] gguf $_tle_id verified: $_tle_file sha256 ok ($_tle_bytes bytes)" >&2
    printf '%s\n' "$_tle_path"
}

# Serve: llama-server on loopback, caddy on :11434, supervised. Never returns.
tillandsias_llama_serve() { # <llama-server> <gguf> <backend> <alias>
    _tls_bin="$1"; _tls_model="$2"; _tls_be="$3"; _tls_alias="$4"
    _tls_ngl=99
    [ "$_tls_be" = "cpu" ] && _tls_ngl=0
    # The /api/version body names the engine build (SLOT-2 compatibility shim).
    _tls_build="$("$_tls_bin" --version 2>&1)"
    _tls_build="${_tls_build#version: }"
    _tls_build="${_tls_build%%$'\n'*}"
    export TILLANDSIAS_LLAMA_SERVER_BUILD="llama-server ${_tls_build:-unknown}"
    export TILLANDSIAS_LLAMA_UPSTREAM="127.0.0.1:$TILLANDSIAS_LLAMA_UPSTREAM_PORT"
    echo "[inference] llama-server: backend=$_tls_be ngl=$_tls_ngl model=$_tls_alias build='$TILLANDSIAS_LLAMA_SERVER_BUILD' upstream=$TILLANDSIAS_LLAMA_UPSTREAM shim=:11434"
    "$_tls_bin" -m "$_tls_model" --alias "$_tls_alias" \
        --host 127.0.0.1 --port "$TILLANDSIAS_LLAMA_UPSTREAM_PORT" \
        -ngl "$_tls_ngl" -c "${TILLANDSIAS_LLAMA_CTX:-4096}" &
    _tls_lp=$!
    caddy run --config "$TILLANDSIAS_LLAMA_CADDYFILE" --adapter caddyfile &
    _tls_cp=$!
    trap 'kill -TERM "$_tls_lp" "$_tls_cp" 2>/dev/null' TERM INT
    _tls_rc=0
    wait -n "$_tls_lp" "$_tls_cp" || _tls_rc=$?
    _tls_who="caddy"
    kill -0 "$_tls_lp" 2>/dev/null || _tls_who="llama-server"
    echo "[inference] FATAL: $_tls_who exited (rc=$_tls_rc) — stopping the other and exiting non-zero so the endpoint never outlives the engine" >&2
    kill -TERM "$_tls_lp" "$_tls_cp" 2>/dev/null
    wait "$_tls_lp" "$_tls_cp" 2>/dev/null
    [ "$_tls_rc" -ne 0 ] || _tls_rc=1
    exit "$_tls_rc"
}

case "${0##*/}" in
    llama-server-lane.sh | tillandsias-llama-server-lane.sh)
        _tll_verb="${1:-}"
        [ "$#" -gt 0 ] && shift
        case "$_tll_verb" in
            select) tillandsias_llama_backend_select ;;
            verdict) tillandsias_llama_backend_verdict "$@" ;;
            pin) tillandsias_llama_gguf_pin "$@" || echo "unpinned:$1" ;;
            check) tillandsias_llama_gguf_check "$@" ;;
            *) echo "usage: llama-server-lane.sh select|verdict|pin|check ..." ;;
        esac
        exit 0
        ;;
esac
