#!/bin/bash
set -e
# @trace spec:inference-container
# Entrypoint for the Tillandsias inference container.
# Starts ollama listening on all interfaces so forge containers can reach it.
# DISTRO: Fedora Minimal 43 — has curl (NOT wget), bash, pciutils.
#         Rust health checks use curl, not wget (see handlers.rs).

# ── Certificate Authority injection ──────────────────────────
# @trace spec:transparent-https-caching
# If the enclave CA cert is mounted at /etc/tillandsias/ca.crt (from orchestrate-enclave.sh),
# inject it into the system trust store so ollama and curl can use the tillandsias-proxy
# for transparent HTTPS caching.
if [ -f /etc/tillandsias/ca.crt ]; then
    # Fedora Minimal: anchor + update-ca-trust (NOT Debian's update-ca-certificates
    # + /usr/local/share/ca-certificates, which has NEVER worked on this image —
    # the command is absent and the failure was swallowed by || true).
    # Guard the mkdir in case we're running on an older image — `set -e` is active
    # and a Permission denied here exits the container immediately.
    mkdir -p /etc/pki/ca-trust/source/anchors/ 2>/dev/null || true
    cp /etc/tillandsias/ca.crt /etc/pki/ca-trust/source/anchors/tillandsias-ca.crt 2>/dev/null || true
    update-ca-trust 2>/dev/null || true
fi

# Bind to all interfaces — reachable from other containers in the enclave.
export OLLAMA_HOST=0.0.0.0:11434

# Resource limits — prevent OOM on constrained hosts.
export OLLAMA_NUM_PARALLEL=1
export OLLAMA_MAX_LOADED_MODELS=1

# Shared model cache — persisted via volume mount.
export OLLAMA_MODELS=/home/ollama/.ollama/models/

# ── Proxy reachability guard (order 268) ────────────────────────────────
# The image bakes HTTP(S)_PROXY=http://proxy:3128 for enclave operation.
# Outside the enclave network (bare `podman run`, litmus shapes, dev loops)
# the name `proxy` does not resolve, and every network client — curl here
# AND the ollama daemon's own model pulls — dies before touching the wire
# (curl exit 5, the 2026-07-10 gate red). Enclave proxy-exemption class
# (orders 116/118/119): when the configured proxy host cannot resolve,
# clear the proxy env ONCE at startup and run direct; when it resolves
# (enclave shape), leave everything routed through Squid untouched.
_proxy_host="$(printf '%s' "${HTTP_PROXY:-${http_proxy:-}}" | sed -E 's|^[a-z]+://||; s|:[0-9]+/?$||')"
if [ -n "$_proxy_host" ] && ! getent hosts "$_proxy_host" >/dev/null 2>&1; then
    echo "[inference] configured proxy '$_proxy_host' does not resolve — running direct (non-enclave shape)"
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
fi

# ── Self-install ollama binary (FIRST_RUN into persistent model cache) ──
# @trace plan/issues/forge-firstrun-tool-migration-2026-07-04.md (order 180 ollama sub-slice)
# Download the latest ollama release, extracting only bin/ollama (skipping
# ~1.8GB GPU runner libs). Installs into the persistent model cache volume so
# it survives container restarts. Arch-aware (x86_64|aarch64). Fail-soft.
OLLAMA_BINDIR="${OLLAMA_MODELS}.tools/ollama"
OLLAMA_BIN="$OLLAMA_BINDIR/ollama"
if [ ! -x "$OLLAMA_BIN" ]; then
    echo "[inference] Installing ollama binary (first run)..."
    mkdir -p "$OLLAMA_BINDIR" 2>/dev/null || true
    OLLAMA_ARCH=""
    case "$(uname -m)" in
        x86_64 | amd64) OLLAMA_ARCH="amd64" ;;
        aarch64 | arm64) OLLAMA_ARCH="arm64" ;;
    esac
    if [ -n "$OLLAMA_ARCH" ]; then
        TMP_O="$(mktemp -d 2>/dev/null)" || true
        if [ -n "$TMP_O" ]; then
            # The image bakes HTTP(S)_PROXY=http://proxy:3128 for enclave
            # operation. On first launch the proxy may not be fully warmed
            # up yet (order 313: proxy warm-up race). Inside the enclave the
            # proxy IS the only egress path (no direct DNS), so a "retry
            # direct" fallback is dead by design — retry the proxied route
            # after a short delay instead.
            OLLAMA_URL="https://github.com/ollama/ollama/releases/latest/download/ollama-linux-${OLLAMA_ARCH}.tar.zst"
            _ollama_dl=0
            curl -fsSL --max-time 600 --retry 2 --retry-delay 3 \
                "$OLLAMA_URL" -o "$TMP_O/ollama.tar.zst" \
                || { echo "[inference] proxied download failed — retrying after 10s proxy warm-up delay" >&2; \
                     sleep 10; \
                     curl -fsSL --max-time 600 --retry 2 --retry-delay 3 \
                         "$OLLAMA_URL" -o "$TMP_O/ollama.tar.zst"; } \
                || _ollama_dl=1
            if [ "$_ollama_dl" -eq 0 ]; then
                if zstd -d "$TMP_O/ollama.tar.zst" -o "$TMP_O/ollama.tar" 2>/dev/null \
                    && tar -xf "$TMP_O/ollama.tar" -C "$TMP_O" bin/ollama 2>/dev/null \
                    && install -m 0755 "$TMP_O/bin/ollama" "$OLLAMA_BIN" 2>/dev/null; then
                    echo "[inference] ollama $OLLAMA_ARCH installed into model cache"
                else
                    echo "[inference] ollama install FAILED — will retry next launch (non-fatal)" >&2
                fi
            else
                echo "[inference] ollama download FAILED — will retry next launch (non-fatal)" >&2
            fi
            rm -rf "$TMP_O"
        fi
    else
        echo "[inference] unsupported arch $(uname -m) — relying on system ollama" >&2
    fi
fi
if [ -x "$OLLAMA_BIN" ]; then
    export PATH="$OLLAMA_BINDIR:$PATH"
fi

# CA certificate from podman secret for HTTPS trust.
# @trace spec:podman-secrets-integration, spec:inference-container
# Ollama may need to trust the enclave proxy's CA when pulling models through it.
# Curl (used by health checks) also respects this variable.
if [ -f /run/secrets/tillandsias-ca-cert ]; then
    export CURL_CA_BUNDLE
    CURL_CA_BUNDLE=/run/secrets/tillandsias-ca-cert
    echo "[inference] CA certificate loaded from podman secret."
fi

# @trace spec:inference-container
# Detect GPU at runtime (devices passed through via --device flags)
GPU_STATUS="CPU only"
if [ -e /dev/nvidia0 ]; then
    GPU_STATUS="NVIDIA ($(ls /dev/nvidia[0-9]* 2>/dev/null | wc -l) device(s))"
elif [ -e /dev/kfd ]; then
    GPU_STATUS="AMD ROCm"
fi

echo "========================================"
echo "  tillandsias inference"
echo "  listening on :11434"
echo "  models:  $OLLAMA_MODELS"
echo "  GPU:     $GPU_STATUS"
echo "========================================"

# @trace spec:inference-container, spec:zen-default-with-ollama-analysis-pool
# Seed the bind-mounted models cache from /opt/baked-models/ if T0/T1
# manifests aren't already present in the cache. The cache survives
# container restarts (host-mounted volume), so this only fires the first
# time on a host that's never run a forge before.
if [ -d /opt/baked-models ]; then
    BAKED_MANIFEST=/opt/baked-models/manifests/registry.ollama.ai/library/qwen2.5/0.5b
    USER_MANIFEST=$OLLAMA_MODELS/manifests/registry.ollama.ai/library/qwen2.5/0.5b
    if [ -f "$BAKED_MANIFEST" ] && [ ! -f "$USER_MANIFEST" ]; then
        echo "[inference] Seeding model cache from /opt/baked-models (first run)..."
        # cp -an: archive (preserve perms/links) + no-clobber. tar fallback if cp -n unsupported.
        cp -an /opt/baked-models/. "$OLLAMA_MODELS/" 2>/dev/null \
            || (cd /opt/baked-models && tar cf - . | tar xf - -C "$OLLAMA_MODELS")
        echo "[inference] Cache seeded"
    fi
fi

# @trace spec:inference-container — order 268 fail-loud guard
# Without any ollama binary (self-install failed and none baked/system),
# every later step is a confusing `command not found` cascade ending in a
# banner-then-die exit 127. Exit early with one clear line instead; the
# container dying IS the "retry next launch" mechanism.
if ! command -v ollama >/dev/null 2>&1; then
    echo "[inference] FATAL: no ollama binary available (self-install failed above) — exiting so the next launch retries" >&2
    exit 1
fi

# @trace spec:inference-container
# Start ollama in background so we can pre-pull models before going live.
ollama serve &
OLLAMA_PID=$!

# Wait for ollama to accept connections.
for i in $(seq 1 30); do
    if ollama list &>/dev/null 2>&1; then
        break
    fi
    sleep 1
done

# ── Tier-tagged tool-capable model pre-pulls ────────────────────
# @trace spec:inference-container, spec:zen-default-with-ollama-analysis-pool
# The DEFAULT small set (0.3-1.5B) is always pulled first-run (see the block
# below). LARGER tier models (T2+: qwen2.5:7b … 32b) pull at runtime only if the
# host has the headroom; pull failures stay non-fatal — Squid SSL bump tends to
# EOF on big ollama manifest pulls (see project memory project_squid_ollama_eof.md).
# All ship tool-capable models. NOTE: on a 16GB laptop RAM_GB>=16 selects T2 and
# background-pulls qwen2.5:7b — this conflicts with the "tiny-model-first" reference
# envelope and should be reconciled (follow-up: gate T2+ behind an opt-in, keep the
# small default set as the laptop baseline).

# Detect runtime tier from RAM (CPU) and GPU VRAM, pick the highest.
RAM_GB=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 0)
VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 || echo 0)
VRAM_GB=$(( ${VRAM_MB:-0} / 1024 ))

TIER="T1"
if [ "$VRAM_GB" -ge 32 ]; then TIER="T5"
elif [ "$VRAM_GB" -ge 16 ]; then TIER="T4"
elif [ "$VRAM_GB" -ge 8 ] || [ "$RAM_GB" -ge 32 ]; then TIER="T3"
elif [ "$VRAM_GB" -ge 4 ] || [ "$RAM_GB" -ge 16 ]; then TIER="T2"
fi

echo "[inference] tier=$TIER (RAM ${RAM_GB}GB, VRAM ${VRAM_GB}GB)"

# ── Default small models (0.3-1.5B) — pulled on FIRST_RUN ─────────
# @trace spec:inference-container
# @trace plan/issues/inference-firstrun-small-models-impl-2026-07-04.md (order 183)
# Operator directive: a fresh forge should have a few general-purpose 0.3-1.5B
# models available on first run (foundation for fine-tuning + forge build-test
# diagnostics). Pulled at container startup — NOT baked at build (keeps the image
# small) — into the host-mounted models cache (~/.cache/tillandsias/models), so
# only the first run downloads; subsequent starts load from the cached volume.
#
# All in the 0.3-1.5B envelope (the operator's "tiny-model-first" spec — llama3.2:3b
# was 3B and is replaced by llama3.2:1b). qwen2.5-coder:1.5b serves the "diagnose
# local build tests" use case. Idempotent (skip if cached), non-fatal (a failed
# pull degrades gracefully + retries next launch; Squid SSL-bump can EOF big
# manifests — see project memory project_squid_ollama_eof.md), and overridable via
# TILLANDSIAS_DEFAULT_MODELS (space-separated ollama tags).
DEFAULT_MODELS="${TILLANDSIAS_DEFAULT_MODELS:-qwen2.5:0.5b}"
for _model in $DEFAULT_MODELS; do
    if ollama list 2>/dev/null | grep -q "$_model"; then
        echo "[inference] default model $_model ready (cached)"
    else
        echo "[inference] pulling default model $_model (first run)..."
        if ollama pull "$_model" 2>&1; then
            echo "[inference] default model $_model ready"
        else
            echo "[inference] default model $_model pull FAILED — will retry next launch (non-fatal)" >&2
        fi
    fi
done

if [ -n "${TILLANDSIAS_INFERENCE_SKIP_RUNTIME_PULLS:-}" ]; then
    echo "[inference] status-check mode — skipping runtime pulls"
else
    # T2+ pull in background if tier permits.
    case "$TIER" in
        T5|T4|T3|T2)
            (
                [ "$TIER" != "T0" ] && [ "$TIER" != "T1" ] && \
                    ollama pull qwen2.5:7b \
                    && echo "[inference] T2 (qwen2.5:7b) ready" \
                    || echo "[inference] T2 (qwen2.5:7b) pull failed (squid SSL-bump EOF likely; non-fatal)" >&2
                case "$TIER" in T5|T4|T3)
                    ollama pull qwen2.5-coder:7b \
                        && echo "[inference] T3 (qwen2.5-coder:7b) ready" \
                        || echo "[inference] T3 (qwen2.5-coder:7b) pull failed (non-fatal)" >&2
                esac
                case "$TIER" in T5|T4)
                    ollama pull qwen2.5:14b \
                        && echo "[inference] T4 (qwen2.5:14b) ready" \
                        || echo "[inference] T4 (qwen2.5:14b) pull failed (non-fatal)" >&2
                esac
                case "$TIER" in T5)
                    ollama pull qwen2.5-coder:32b \
                        && echo "[inference] T5 (qwen2.5-coder:32b) ready" \
                        || echo "[inference] T5 (qwen2.5-coder:32b) pull failed (non-fatal)" >&2
                esac
                echo "[inference] runtime tier pulls complete"
            ) &
            ;;
        *)
            echo "[inference] tier=T0/T1 only — no runtime pulls"
            ;;
    esac
fi

# Hand off to ollama as the foreground process for signal handling.
wait $OLLAMA_PID
