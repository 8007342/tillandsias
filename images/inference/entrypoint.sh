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
    # Order 525: this update CANNOT succeed as uid 1000 on this image — the
    # Containerfile chowns only source/anchors, so /etc/pki/ca-trust/extracted
    # stays root-owned under `USER 1000:1000`. It is attempted anyway (a future
    # image may fix the ownership) but its failure is now REPORTED once with its
    # rc instead of disappearing behind three separate `|| true`s.
    _trust_rc=0
    {
        mkdir -p /etc/pki/ca-trust/source/anchors/ \
            && cp /etc/tillandsias/ca.crt /etc/pki/ca-trust/source/anchors/tillandsias-ca.crt \
            && update-ca-trust
    } 2>/dev/null || _trust_rc=$?
    if [ "$_trust_rc" -ne 0 ]; then
        echo "[inference] WARN: system trust store not updated (rc=$_trust_rc, expected as uid $(id -u) on this image) — relying on SSL_CERT_FILE/CURL_CA_BUNDLE" >&2
    fi
    # Order 486: point curl at the mounted enclave CA directly so downloads
    # verify regardless of trust-store state (curl exit 60 otherwise).
    export CURL_CA_BUNDLE=/etc/tillandsias/ca.crt
    # Order 525: CURL_CA_BUNDLE fixes CURL ONLY. ollama is a Go binary and Go's
    # crypto/x509 reads SSL_CERT_FILE — which appeared NOWHERE in this image — so
    # with the trust store unwritable every `ollama pull` through squid's TLS bump
    # failed x509 verification. That failure is non-fatal, so it surfaced to the
    # agent as `inference_reason=no-models`, making "the enclave CA is not
    # trusted" indistinguishable from "nothing is cached yet". Two very different
    # faults, one message. Export the variable Go actually honours.
    export SSL_CERT_FILE=/etc/tillandsias/ca.crt
    # Some Go/OpenSSL paths consult a directory rather than a file; pointing it at
    # the anchors dir is harmless when the copy above failed and correct when it
    # succeeded.
    export SSL_CERT_DIR=/etc/pki/ca-trust/source/anchors
    echo "[inference] ca-trust: store_rc=$_trust_rc ssl_cert_file=$SSL_CERT_FILE curl_ca_bundle=$CURL_CA_BUNDLE"
fi

# Bind to all interfaces — reachable from other containers in the enclave.
export OLLAMA_HOST=0.0.0.0:11434

# Resource limits — prevent OOM on constrained hosts.
# OLLAMA_MAX_LOADED_MODELS is NOT pinned here any more: order 392a derives it
# from the preload policy below (1 default-model slot + RAM-derived expert
# slots), and an operator-supplied value is respected verbatim. On a <8GB host
# the policy still yields exactly 1, i.e. the pre-392a behaviour.
#
# OLLAMA_NUM_PARALLEL is likewise NOT pinned here any more: order 406 derives it
# (with flash attention and the KV cache type) from the accelerator tier in
# engine-tuning.sh, sourced below. Hardcoding 1 here would have looked like an
# operator override and suppressed the tier policy.

# Shared model cache — persisted via volume mount.
export OLLAMA_MODELS=/home/ollama/.ollama/models/

# ── Default small models (0.3-1.5B) ───────────────────────────────
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

# ── Preload policy (order 392a) ───────────────────────────────────
# @trace spec:inference-container
# Sourced BEFORE `ollama serve` because it exports OLLAMA_MAX_LOADED_MODELS,
# which ollama reads once at process start. Sets PRELOAD_POLICY,
# PRELOAD_MODELS, PRELOAD_EXPERT_SLOTS, PRELOAD_RAM_GB and prints the pinned
# `preload: policy=... models=... expert_slots=... max_loaded=... ram_gb=...`
# line. See images/inference/preload-policy.sh for the full rationale
# (eager/lazy/off, and why a 4GB host gets zero expert slots).
PRELOAD_POLICY_SH=/usr/local/bin/tillandsias-preload-policy.sh
if [ -r "$PRELOAD_POLICY_SH" ]; then
    # shellcheck source=preload-policy.sh
    . "$PRELOAD_POLICY_SH"
else
    # Older image without the policy file: fall back to the pre-392a shape so
    # the container still starts (never fail-closed on a policy helper).
    echo "[inference] WARN: $PRELOAD_POLICY_SH missing — falling back to eager preload, max_loaded=1" >&2
    PRELOAD_POLICY="eager"
    PRELOAD_MODELS="$DEFAULT_MODELS"
    PRELOAD_EXPERT_SLOTS=0
    PRELOAD_RAM_GB=0
    export OLLAMA_MAX_LOADED_MODELS=1
    PRELOAD_LINE="preload: policy=eager models=${DEFAULT_MODELS} expert_slots=0 max_loaded=1 ram_gb=0"
fi
echo "[inference] $PRELOAD_LINE"

# ── Accelerator engine tuning (order 406) ─────────────────────────
# @trace spec:inference-container
# Sourced BEFORE `ollama serve` because it exports OLLAMA_FLASH_ATTENTION,
# OLLAMA_KV_CACHE_TYPE and OLLAMA_NUM_PARALLEL, all of which ollama reads once
# at process start. Prints the pinned
# `tuning: tier=... flash_attn=... kv_cache=... num_parallel=... vram_mb=...`
# line. See images/inference/engine-tuning.sh for the measured A/B that chose
# these values (30% VRAM saved at equal throughput on the CUDA lane) and why the
# vulkan/rocm lanes deliberately stay conservative.
ENGINE_TUNING_SH=/usr/local/bin/tillandsias-engine-tuning.sh
if [ -r "$ENGINE_TUNING_SH" ]; then
    # shellcheck source=engine-tuning.sh
    . "$ENGINE_TUNING_SH"
else
    # Older image without the tuning file: fall back to the pre-406 shape so the
    # container still starts (never fail-closed on a policy helper).
    echo "[inference] WARN: $ENGINE_TUNING_SH missing — falling back to untuned defaults" >&2
    export OLLAMA_NUM_PARALLEL=1
    TUNING_LINE="tuning: tier=${TILLANDSIAS_INFERENCE_TIER:-cpu} flash_attn=0 kv_cache=f16 num_parallel=1 vram_mb=0"
fi
echo "[inference] $TUNING_LINE"

# Persistent inventory of what preload actually warmed, written on the mounted
# model volume so a cold volume becomes a warm one for every later start.
PRELOAD_CHECKPOINT="${OLLAMA_MODELS}.preloaded"

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

# ── Self-install ollama ENGINE (FIRST_RUN into persistent model cache) ──
# @trace plan/issues/forge-firstrun-tool-migration-2026-07-04.md (order 180 ollama sub-slice)
# @trace spec:inference-container — order 406 engine payload
#
# ORDER 406 ROOT CAUSE (macuahuitl, live repro 2026-07-29). The release tarball is
# `bin/ollama` (37 MB) plus `lib/ollama/` (2101 MB). `lib/ollama/` is NOT optional
# "GPU runner libs": it holds **llama-server**, the binary ollama EXECS for every
# single model load, plus libggml/libllama and the CPU backends. Extracting only
# `bin/ollama` — the pre-406 behaviour, whose comment called the remainder skippable
# — left llama-server absent, so `ollama serve` bound :11434 and answered
# /api/version (healthcheck GREEN) while EVERY /api/generate returned HTTP 500
# "llama-server binary not found". That held on every host and every tier: the
# inference substrate could not serve one token, GPU or CPU.
#
# Only the per-accelerator BACKEND dirs are genuinely large, and exactly one of them
# is usable on any given host, so select instead of dropping the lot:
#
#   core (root of lib/ollama, ~30 MB)  llama-server + libggml/libllama + CPU backends
#   cuda_v13 (~844 MB)                 CUDA UMD >= 13
#   cuda_v12 (~1277 MB)                CUDA UMD 12
#   vulkan   (~51 MB)                  mobile/integrated GPUs and the AMD lane
#
# On this host that is 871 MB installed instead of 2138 MB, and the excluded
# backends could never have loaded anyway. Arch-aware (x86_64|aarch64). Fail-soft
# on download, FAIL-LOUD on a payload that cannot serve (guard below).
OLLAMA_BINDIR="${OLLAMA_MODELS}.tools/ollama"
OLLAMA_BIN="$OLLAMA_BINDIR/ollama"
# ollama resolves llama-server relative to the dir holding the ollama binary; the
# probe list includes `<bindir>/../lib/ollama/llama-server`, which is this path.
# Verified live: libdirs=ollama,cuda_v13 with the model fully resident in VRAM.
OLLAMA_TOOLSROOT="${OLLAMA_MODELS}.tools"
OLLAMA_LIBDIR="$OLLAMA_TOOLSROOT/lib/ollama"
OLLAMA_ENGINE_MANIFEST="$OLLAMA_TOOLSROOT/.engine-set"

# Which backend dirs does THIS host need? Derived from the effective tier the
# launcher passed (TILLANDSIAS_INFERENCE_TIER, already downgraded when podman
# cannot deliver the GPU — order 392) corroborated by the device nodes actually
# visible in the container. Echoes a space-separated set; empty means core-only.
_engine_wanted_backends() {
    _tier="${TILLANDSIAS_INFERENCE_TIER:-}"
    # Corroborate: a tier claiming cuda with no /dev/nvidia0 in the container gets
    # core-only rather than an 844 MB backend that can never load.
    case "$_tier" in
        gpu-cuda)
            [ -e /dev/nvidia0 ] || { echo ""; return 0; }
            _cuda_mm=""
            if command -v nvidia-smi >/dev/null 2>&1; then
                # "CUDA UMD Version : 13.3"; the older "CUDA Version" line carries a
                # deprecation suffix, so match a bare major.minor either way.
                _cuda_mm="$(nvidia-smi -q 2>/dev/null \
                    | grep -m1 -E 'CUDA (UMD )?Version' \
                    | grep -oE '[0-9]+\.[0-9]+' | head -n1)"
            fi
            _cuda_major="${_cuda_mm%%.*}"
            case "$_cuda_major" in
                ''|*[!0-9]*)
                    # Undetectable CUDA version: correctness over size — ship both
                    # majors and let ollama pick, rather than guess wrong and fall
                    # back to CPU on a GPU host.
                    echo "cuda_v13 cuda_v12" ;;
                *) if [ "$_cuda_major" -ge 13 ]; then echo "cuda_v13"; else echo "cuda_v12"; fi ;;
            esac
            ;;
        gpu-rocm)
            # This ollama release ships no rocm backend dir; Vulkan is the working
            # AMD lane (RamaLama's proven pattern, order 482).
            echo "vulkan" ;;
        gpu-vulkan) echo "vulkan" ;;
        *) echo "" ;;
    esac
}
OLLAMA_WANTED_BACKENDS="$(_engine_wanted_backends)"
# Stable set id for the manifest: core plus the sorted wanted backends.
OLLAMA_ENGINE_SET="core$(printf '%s' "$OLLAMA_WANTED_BACKENDS" | tr ' ' '\n' | sed '/^$/d' | sort | sed 's/^/+/' | tr -d '\n')"
_engine_installed_set=""
[ -f "$OLLAMA_ENGINE_MANIFEST" ] && _engine_installed_set="$(cat "$OLLAMA_ENGINE_MANIFEST" 2>/dev/null)"
# Reinstall when the binary is missing, when llama-server is missing (the pre-406
# payload), or when the host's required backend set changed (e.g. a CPU-only host
# that gained a GPU, or a driver major bump).
if [ ! -x "$OLLAMA_BIN" ] || [ ! -x "$OLLAMA_LIBDIR/llama-server" ] \
    || [ "$_engine_installed_set" != "$OLLAMA_ENGINE_SET" ]; then
    echo "[inference] engine payload: need '$OLLAMA_ENGINE_SET' (have '${_engine_installed_set:-none}')"
    echo "[inference] Installing ollama binary (first run)..."
    # Order 313: NO error swallowing in this chain — the volume-ownership
    # EACCES (root-owned models bind-mount vs uid-1000 container) hid for
    # weeks behind 2>/dev/null while the failure was blamed on the proxy.
    mkdir -p "$OLLAMA_BINDIR" || echo "[inference] WARN: cannot create $OLLAMA_BINDIR (volume ownership? see order 313)" >&2
    OLLAMA_ARCH=""
    case "$(uname -m)" in
        x86_64 | amd64) OLLAMA_ARCH="amd64" ;;
        aarch64 | arm64) OLLAMA_ARCH="arm64" ;;
    esac
    if [ -n "$OLLAMA_ARCH" ]; then
        TMP_O="$(mktemp -d 2>/dev/null)" || true
        if [ -n "$TMP_O" ]; then
            # The image bakes HTTP(S)_PROXY=http://proxy:3128 for enclave
            # operation. Inside the enclave the proxy IS the only egress path
            # (no direct DNS), so a "retry direct" fallback is dead by design.
            # Order 486 (cold-start evidence 2026-07-24): a single fixed 10s
            # nap races proxy egress readiness — curl (7) means squid is not
            # serving yet, and curl (60) is squid bumping its OWN error page
            # because UPSTREAM egress is still unready, NOT a real CA problem.
            # Gate the download on a proven egress probe with bounded backoff;
            # an egress that never comes up fails loud but stays non-fatal
            # (the fail-loud guard below + launcher soft-degrade handle it).
            OLLAMA_URL="https://github.com/ollama/ollama/releases/latest/download/ollama-linux-${OLLAMA_ARCH}.tar.zst"
            _egress_ok=0
            _egress_delay=2
            for _attempt in 1 2 3 4 5; do
                if curl -fsSI --max-time 15 -o /dev/null https://github.com/; then
                    _egress_ok=1
                    break
                fi
                if [ "$_attempt" -lt 5 ]; then
                    echo "[inference] proxy egress not ready (attempt $_attempt/5) — retrying in ${_egress_delay}s" >&2
                    sleep "$_egress_delay"
                    _egress_delay=$((_egress_delay * 2))
                fi
            done
            _ollama_dl=1
            if [ "$_egress_ok" -eq 1 ]; then
                curl -fsSL --max-time 600 --retry 2 --retry-delay 3 \
                    "$OLLAMA_URL" -o "$TMP_O/ollama.tar.zst" \
                    && _ollama_dl=0 \
                    || echo "[inference] download failed AFTER proven egress — genuine failure, not a proxy race" >&2
            else
                echo "[inference] FATAL: proxy egress never became ready within bounded backoff (5 probes) — skipping self-install this launch" >&2
            fi
            if [ "$_ollama_dl" -eq 0 ]; then
                # Two STREAMING passes over the .zst (list, then extract) instead of
                # materialising the 2.1 GB intermediate .tar: peak extra disk is the
                # installed payload, not payload + 2.1 GB. Costs one extra decompress
                # (a few seconds) and buys ~2 GB of headroom on a constrained host.
                #
                # Pass 1: discover which backend dirs THIS release actually ships, so
                # a newly-added backend is neither silently installed nor able to
                # break the exclude list.
                _have_backends="$(zstd -dc "$TMP_O/ollama.tar.zst" 2>/dev/null \
                    | tar -tf - 2>/dev/null \
                    | sed -n 's|^lib/ollama/\([^/][^/]*\)/.*|\1|p' | sort -u)"
                echo "[inference] engine backends available: $(echo "$_have_backends" | tr '\n' ' ')"
                # Exclude every shipped backend dir that this host cannot use.
                set --
                for _b in $_have_backends; do
                    _keep=0
                    for _w in $OLLAMA_WANTED_BACKENDS; do
                        [ "$_b" = "$_w" ] && _keep=1
                    done
                    [ "$_keep" -eq 0 ] && set -- "$@" --exclude="lib/ollama/$_b"
                done
                # A wanted backend the release does not ship is a REAL mismatch: say
                # so rather than silently installing a CPU-only payload on a GPU host.
                for _w in $OLLAMA_WANTED_BACKENDS; do
                    echo "$_have_backends" | grep -qx "$_w" \
                        || echo "[inference] WARN: tier wants backend '$_w' but this ollama release does not ship it — inference will fall back to CPU" >&2
                done
                mkdir -p "$OLLAMA_LIBDIR" 2>/dev/null || true
                # Pass 2: extract bin/ollama + the selected slice of lib/ollama.
                if zstd -dc "$TMP_O/ollama.tar.zst" 2>/dev/null \
                    | tar -xf - -C "$OLLAMA_TOOLSROOT" "$@" bin/ollama lib/ollama \
                    && install -m 0755 "$OLLAMA_TOOLSROOT/bin/ollama" "$OLLAMA_BIN"; then
                    rm -rf "$OLLAMA_TOOLSROOT/bin"
                    printf '%s\n' "$OLLAMA_ENGINE_SET" > "$OLLAMA_ENGINE_MANIFEST"
                    echo "[inference] ollama $OLLAMA_ARCH engine '$OLLAMA_ENGINE_SET' installed ($(du -sh "$OLLAMA_LIBDIR" 2>/dev/null | cut -f1) libs) into model cache"
                else
                    echo "[inference] ollama install FAILED (see errors above) — will retry next launch (non-fatal)" >&2
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

# @trace spec:inference-container — order 406 fail-loud guard
# `command -v ollama` was the WRONG thing to assert. ollama execs a separate
# llama-server binary for every model load, so a payload with `ollama` but no
# llama-server serves /api/version happily (healthcheck GREEN, launcher READY)
# and 500s on every single /api/generate. That is a silent, total inference
# outage wearing a healthy badge — precisely the "no ambiguous state" boundary
# this project forbids. Assert the binary that actually serves tokens.
if [ ! -x "$OLLAMA_LIBDIR/llama-server" ]; then
    echo "[inference] FATAL: engine payload incomplete — no executable llama-server at $OLLAMA_LIBDIR/llama-server." >&2
    echo "[inference]   ollama would bind :11434 and answer /api/version while EVERY model load returns HTTP 500." >&2
    echo "[inference]   Exiting so the next launch re-installs the engine (see order 406)." >&2
    exit 1
fi
# Tier truth: report the backend set that is actually installed, so an agent is
# never promised a GPU the engine cannot use. Corroborated against the dirs on
# disk, not against the tier string alone.
_installed_backends="$(find "$OLLAMA_LIBDIR" -maxdepth 1 -mindepth 1 -type d -printf '%f ' 2>/dev/null)"
echo "[inference] engine: set=$OLLAMA_ENGINE_SET backends=[${_installed_backends:-core-only}] llama-server=ok"

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
# The DEFAULT small set (0.3-1.5B) is pulled first-run under the eager preload
# policy (see the block below). LARGER tier models (T2+: qwen2.5:7b … 32b) are
# sized by this ladder; pull failures stay non-fatal — Squid SSL bump tends to
# EOF on big ollama manifest pulls (see project memory project_squid_ollama_eof.md).
# All ship tool-capable models. RECONCILED (order 392a): the old NOTE — "on a
# 16GB laptop RAM_GB>=16 selects T2 and background-pulls qwen2.5:7b, which
# conflicts with the tiny-model-first envelope" — is now fixed. The ladder still
# CLASSIFIES the host (the tier= line below is the report), but the pulls
# themselves are OPT-IN via TILLANDSIAS_INFERENCE_TIER_PULLS=1, so the small
# default set is the baseline on every host and multi-GB models never evict the
# expert slots reserved by the preload policy.

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

# ── Model preload (order 392a) ────────────────────────────────────
# @trace spec:inference-container
# @trace plan/issues/inference-firstrun-small-models-impl-2026-07-04.md (order 183)
#
# Runs AFTER `ollama serve` is already answering /api/version, so it NEVER
# gates a lane launch: the launcher's readiness gate waits only for the API and
# is warn-and-continue (order 486). What preload DOES gate is the WARM state
# the forge startup context reports — `READY (models=N, warm=<csv>)` is
# asserted only once a model is genuinely cached, and an endpoint answering
# with zero models reports `NOT-READY (no-models: …)` instead, which agents
# can branch on.
#
# The set and the policy come from preload-policy.sh (sourced above):
# eager pulls PRELOAD_MODELS now; lazy/off pull nothing here.
_prev_inventory=""
if [ -r "$PRELOAD_CHECKPOINT" ]; then
    _prev_inventory="$(tr '\n' ' ' < "$PRELOAD_CHECKPOINT" 2>/dev/null | sed 's/  */ /g; s/^ //; s/ *$//')"
fi
if [ -n "$_prev_inventory" ]; then
    echo "[inference] preload checkpoint: warm volume ($_prev_inventory)"
else
    echo "[inference] preload checkpoint: none (cold volume)"
fi

if [ "$PRELOAD_POLICY" != "eager" ]; then
    echo "[inference] preload policy=$PRELOAD_POLICY — no startup pulls (models are served from the mounted cache only)"
fi

for _model in $PRELOAD_MODELS; do
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

# ── Warm-model inventory + checkpoint (order 392a) ────────────────
# The authoritative warm set is what `ollama list` reports, not what preload
# intended — a failed pull must never be recorded as warm. The inventory is
# checkpointed onto the MOUNTED model volume so a cold volume becomes a warm
# one for every subsequent start (and so a restart can see, before any network
# call, what the last successful preload achieved).
_inventory="$(ollama list 2>/dev/null | awk 'NR > 1 && $1 != "" { print $1 }' | sort -u)"
_warm_count=0
_warm_csv=""
for _m in $_inventory; do
    _warm_count=$((_warm_count + 1))
    _warm_csv="${_warm_csv},${_m}"
done
_warm_csv="$(printf '%s' "$_warm_csv" | sed 's/^,//')"
[ -n "$_warm_csv" ] || _warm_csv="-"

_checkpoint_state="skipped"
if [ "$_warm_count" -gt 0 ]; then
    if printf '%s\n' "$_inventory" > "$PRELOAD_CHECKPOINT" 2>/dev/null; then
        _checkpoint_state="written"
    else
        _checkpoint_state="unwritable"
    fi
fi

# PINNED GRAMMAR (litmus:inference-model-preload-policy) — one line:
#   [inference] preload-state: warm=<N> models=<csv|-> policy=<eager|lazy|off>
#               expert_slots=<N> max_loaded=<N> checkpoint=<written|skipped|unwritable>
echo "[inference] preload-state: warm=$_warm_count models=$_warm_csv policy=$PRELOAD_POLICY expert_slots=$PRELOAD_EXPERT_SLOTS max_loaded=$OLLAMA_MAX_LOADED_MODELS checkpoint=$_checkpoint_state"

# ── Larger tier pulls — OPT-IN (order 392a) ───────────────────────
# Reconciles the long-standing NOTE above: on a 16GB laptop the tier ladder
# selected T2 and background-pulled qwen2.5:7b, which contradicts the
# tiny-model-first envelope AND fills the loaded-model slots the EXPERTS family
# (milestone 391) needs. Tier pulls are now opt-in via
# TILLANDSIAS_INFERENCE_TIER_PULLS=1; the small default set stays the baseline
# on every host. TILLANDSIAS_INFERENCE_SKIP_RUNTIME_PULLS (status-check mode)
# and a non-eager preload policy both keep them off regardless.
if [ -n "${TILLANDSIAS_INFERENCE_SKIP_RUNTIME_PULLS:-}" ]; then
    echo "[inference] status-check mode — skipping runtime pulls"
elif [ "$PRELOAD_POLICY" != "eager" ]; then
    echo "[inference] preload policy=$PRELOAD_POLICY — skipping runtime tier pulls"
elif [ "${TILLANDSIAS_INFERENCE_TIER_PULLS:-0}" != "1" ]; then
    echo "[inference] tier pulls opt-in (set TILLANDSIAS_INFERENCE_TIER_PULLS=1) — skipping runtime tier pulls"
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
