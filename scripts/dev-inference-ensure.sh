#!/usr/bin/env bash
# @trace spec:inference-container, spec:methodology-accountability
#
# Order 718-nkm2. Make local inference available to the DEVELOPMENT host's
# expert system, idempotently, so a cycle can call this at start and never think
# about it again.
#
# THIS IS NOT THE END-USER RUNTIME. The in-VM `tillandsias` distro, its podman
# enclave and its `tillandsias-inference` container are the product; they are
# fully wired, ephemeral and none of this touches them. This is the separate
# question of how the AGENT running on bare metal reaches an inference endpoint
# for its own expert system.
#
# WHY IN THE BUILD DISTRO AND NOT ON WINDOWS
#
# The MCP expert servers already run inside WSL2: `.mcp.json` launches
# `bash images/default/config-overlay/mcp/*.sh` and the bash that answers is
# WSL's — every envelope this host receives carries a `/mnt/c/...` citation_root
# and `target/release/tillandsias-plan` is an ELF. So the endpoint has to be
# reachable FROM THE DISTRO, and this WSL install is in `nat` mode:
#
#   * ollama on Windows  -> the distro must use the host GATEWAY ip, which moves
#     across reboots; and `semantic_expert.rs` parses the endpoint as a literal
#     SocketAddr, so a hostname cannot paper over it. It would work until the
#     next reboot and then silently return None.
#   * ollama in the distro -> 127.0.0.1:11434 on the servers' own loopback.
#     Nothing to discover, nothing to break on reboot.
#
# Native rather than containerized because this distro has no podman and no
# systemd, and images/inference/entrypoint.sh self-installs ollama anyway — a
# container here would add a runtime to gain isolation a dev dependency does not
# need.
#
# IDEMPOTENT AND EPHEMERAL, in that order. Every step asks before it acts, and
# the whole thing is safe to destroy: `rm -rf ~/.local/share/tillandsias-dev-inference`
# plus a kill, and the next run rebuilds it. Nothing here is precious.
#
# GRAMMAR (exactly one line on stdout)
#   ok:dev-inference-ready:<generate-model>:<embed-model>
#   ok:dev-inference-started:<generate-model>:<embed-model>
#   blocked:no-network                   cannot fetch the runtime or a model
#   blocked:install-failed:<detail>   e.g. runtime-download, pull-<model>, no-zstd
#   blocked:not-ready-after:<seconds>s
#   blocked:image-missing:build-inference   linux lane: no tillandsias-inference
#                                           image — run ./build-inference.sh
#   blocked:container-start-failed       linux lane: podman refused the container
#   skip:unsupported-host                no lane was reasoned about for this host
#   skip:no-local-inference              operator kill switch (620-ca7g)
#
# Exit 0 on ok/skip, 1 on blocked.
#
# LANES (2026-08-15, extends order 718-nkm2 to the Linux development host):
#   wsl-native       — the original 718-nkm2 design: no podman/systemd in the
#                      build distro, so ollama runs native on loopback.
#   linux-container  — bare-metal Linux WITH podman (the immutable Fedora
#                      hosts): the already-built tillandsias-inference image
#                      runs as the SEPARATE container `tillandsias-dev-inference`
#                      publishing loopback ${ENDPOINT_PORT} — separate name so
#                      the forge enclave's own `tillandsias-inference` lifecycle
#                      (--replace, no host publish, enclave DNS) never fights
#                      it; same model cache so multi-GB weights are shared.
#                      Idempotent: reuse-if-running, start-if-stopped,
#                      launch-if-missing, never duplicate.

set -uo pipefail

ENDPOINT_HOST="127.0.0.1"
ENDPOINT_PORT="${TILLANDSIAS_DEV_INFERENCE_PORT:-11434}"
ENDPOINT="http://${ENDPOINT_HOST}:${ENDPOINT_PORT}"
# Same generation model the forge defaults to, so a dev answer and a runtime
# answer are not quietly produced by different weights.
GEN_MODEL="${TILLANDSIAS_INFERENCE_MODEL:-qwen2.5:0.5b}"
EMBED_MODEL="${TILLANDSIAS_EMBED_MODEL:-nomic-embed-text}"
STATE_DIR="${TILLANDSIAS_DEV_INFERENCE_HOME:-$HOME/.local/share/tillandsias-dev-inference}"
BIN="$STATE_DIR/bin/ollama"
LOG="$STATE_DIR/serve.log"
READY_BUDGET_SECS="${TILLANDSIAS_DEV_INFERENCE_READY_SECS:-90}"
DEV_CONTAINER="tillandsias-dev-inference"

# Operator kill switch (620-ca7g): any value except "0" disables local
# inference, loudly, on every lane.
if [ -n "${TILLANDSIAS_NO_LOCAL_INFERENCE:-}" ] && [ "${TILLANDSIAS_NO_LOCAL_INFERENCE}" != "0" ]; then
    echo "skip:no-local-inference"
    exit 0
fi

# Lane selection. Refuse to install into a host no lane was reasoned about —
# the whole design rests on "the expert servers and this endpoint share a
# loopback".
if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
    LANE="wsl-native"
elif [ "$(uname -s 2>/dev/null)" = "Linux" ] && command -v podman >/dev/null 2>&1; then
    LANE="linux-container"
else
    echo "skip:unsupported-host"
    exit 0
fi

api_up() { curl -fsS --max-time 2 "$ENDPOINT/api/version" >/dev/null 2>&1; }

have_model() { # <model>
    curl -fsS --max-time 5 "$ENDPOINT/api/tags" 2>/dev/null \
        | jq -e --arg m "$1" '.models[]?.name | select(. == $m or startswith($m + ":"))' \
            >/dev/null 2>&1
}

pull_model() { # <model> — native binary when present, else the serve API.
    # The API path covers the linux-container lane (the ollama binary lives
    # inside the container); /api/pull streams progress JSON, which the log
    # absorbs. Bounded: a model pull is minutes, never unbounded.
    if [ -x "$BIN" ]; then
        "$BIN" pull "$1" >>"$LOG" 2>&1
    else
        curl -fsS --max-time 1800 -X POST "$ENDPOINT/api/pull" \
            -d "$(jq -cn --arg m "$1" '{name: $m}')" >>"$LOG" 2>&1
    fi
}

# ── linux-container lane ────────────────────────────────────────────────────
# Idempotent by construction: reuse-if-running, start-if-stopped,
# launch-if-missing, never duplicate (`podman container exists` gates the run).
# Returns 0 ensured, 1 podman refused, 2 no image built.
ensure_container() {
    if podman container exists "$DEV_CONTAINER" 2>/dev/null; then
        _ec_state="$(podman inspect -f '{{.State.Status}}' "$DEV_CONTAINER" 2>/dev/null || echo unknown)"
        if [ "$_ec_state" != "running" ]; then
            podman start "$DEV_CONTAINER" >>"$LOG" 2>&1 || return 1
        fi
        return 0
    fi
    _ec_img=""
    if podman image exists "localhost/tillandsias-inference:latest" 2>/dev/null; then
        _ec_img="localhost/tillandsias-inference:latest"
    else
        _ec_img="$(podman images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
            | grep '^localhost/tillandsias-inference:v' | sort -V | tail -1 || true)"
    fi
    [ -n "$_ec_img" ] || return 2
    # Same hardening and the SAME model cache as the runtime container
    # (build_inference_run_args), minus the enclave network and proxy — this
    # endpoint is for the agent on this machine, bound to loopback only.
    _ec_cache="$HOME/.cache/tillandsias/models"
    mkdir -p "$_ec_cache" 2>/dev/null || true
    podman run --detach --name "$DEV_CONTAINER" \
        --publish "${ENDPOINT_HOST}:${ENDPOINT_PORT}:11434" \
        --cap-drop=ALL --security-opt=no-new-privileges --security-opt=label=disable \
        --userns=keep-id --pids-limit=128 \
        --env OLLAMA_DEBUG=1 \
        --env OLLAMA_KEEP_ALIVE="${TILLANDSIAS_DEV_INFERENCE_KEEP_ALIVE:-30m}" \
        -v "$_ec_cache:/home/ollama/.ollama/models:rw" \
        "$_ec_img" >>"$LOG" 2>&1 || return 1
    return 0
}

install_runtime() {
    mkdir -p "$STATE_DIR/bin" "$STATE_DIR/models" || return 1
    local arch base
    case "$(uname -m)" in
        x86_64) arch=amd64 ;;
        aarch64 | arm64) arch=arm64 ;;
        *) echo "unsupported arch $(uname -m)" >&2; return 1 ;;
    esac
    base="https://ollama.com/download/ollama-linux-${arch}"

    # Current releases ship .tar.zst; .tgz is the legacy fallback and 404s on
    # anything recent — which is exactly what the first version of this script
    # hit. Mirror the vendor's own probe order rather than pinning a shape that
    # silently ages out.
    #
    # We deliberately do NOT pipe their install.sh to a shell: it wants systemd,
    # sudo and /usr/local. This distro has no systemd, and a dev dependency has
    # no business owning a root-scoped install. Same bits, our lifecycle.
    if curl --fail --silent --head --location --max-time 30 "${base}.tar.zst" >/dev/null 2>&1; then
        command -v zstd >/dev/null 2>&1 || { echo "zstd missing" >&2; return 1; }
        curl --fail --silent --show-error --location --max-time 900 "${base}.tar.zst"             | zstd -d | tar -xf - -C "$STATE_DIR" || return 1
    else
        curl --fail --silent --show-error --location --max-time 900 "${base}.tgz"             | tar -xzf - -C "$STATE_DIR" || return 1
    fi
    [ -x "$STATE_DIR/bin/ollama" ] || return 1
    return 0
}

start_serve() {
    mkdir -p "$STATE_DIR/models"
    # OLLAMA_HOST binds loopback ONLY. This endpoint is for the agent on this
    # machine; it is not a service and must not look like one.
    OLLAMA_HOST="${ENDPOINT_HOST}:${ENDPOINT_PORT}" \
    OLLAMA_MODELS="$STATE_DIR/models" \
    OLLAMA_KEEP_ALIVE="${TILLANDSIAS_DEV_INFERENCE_KEEP_ALIVE:-30m}" \
        nohup "$BIN" serve >>"$LOG" 2>&1 &
    disown 2>/dev/null || true
}

wait_ready() {
    local waited=0
    while [ "$waited" -lt "$READY_BUDGET_SECS" ]; do
        api_up && return 0
        sleep 2
        waited=$((waited + 2))
    done
    return 1
}

started="no"

if ! api_up; then
    if [ "$LANE" = "linux-container" ]; then
        mkdir -p "$STATE_DIR" 2>/dev/null || true
        ensure_container
        case "$?" in
            0) ;;
            2) echo "blocked:image-missing:build-inference"; exit 1 ;;
            *) echo "blocked:container-start-failed"; exit 1 ;;
        esac
        started="yes"
        # First-ever start may exceed the budget while the image's entrypoint
        # self-installs the ollama runtime; the ensure is idempotent, so the
        # NEXT call converges to ready without re-doing anything.
        wait_ready || { echo "blocked:not-ready-after:${READY_BUDGET_SECS}s"; exit 1; }
    else
        if [ ! -x "$BIN" ]; then
            curl -fsS --max-time 5 -o /dev/null https://ollama.com 2>/dev/null || {
                echo "blocked:no-network"
                exit 1
            }
            install_runtime || { echo "blocked:install-failed:runtime-download"; exit 1; }
        fi
        start_serve
        started="yes"
        wait_ready || { echo "blocked:not-ready-after:${READY_BUDGET_SECS}s"; exit 1; }
    fi
fi

# Models are pulled only when absent, so the common path costs one /api/tags
# call. A pull failure is reported as an environment fault rather than silently
# leaving the tier half-present.
for m in "$GEN_MODEL" "$EMBED_MODEL"; do
    have_model "$m" && continue
    pull_model "$m" || { echo "blocked:install-failed:pull-$m"; exit 1; }
    have_model "$m" || { echo "blocked:install-failed:absent-after-pull-$m"; exit 1; }
done

if [ "$started" = "yes" ]; then
    echo "ok:dev-inference-started:${GEN_MODEL}:${EMBED_MODEL}"
else
    echo "ok:dev-inference-ready:${GEN_MODEL}:${EMBED_MODEL}"
fi
exit 0
