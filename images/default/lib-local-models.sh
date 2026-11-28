#!/usr/bin/env bash
# lib-local-models.sh — model config for the local-model lanes (Pi, Oh My Pi).
#
# @trace order:2454-lhar, order:2455-lomp, spec:default-image
#
# Both lanes talk ONLY to the Lemonade Server the host runs. The endpoint is
# TILLANDSIAS_LEMONADE_URL (default http://lemonade:13305/api/v1); the enclave
# alias and relay that make that name answer are order 2456-lrly, not this
# file. Nothing here names a cloud model API host.
#
# Pure functions over files, so scripts/lua/test-forge-pi-omp-harness.lua runs
# THIS code against a stub /models answer (no network):
#   lemonade_pi_config   <models.json answer> <agent dir>  → models.json + settings.json
#   lemonade_omp_config  <agent dir>                       → models.yml + config.yml
#   lemonade_fetch_models <out file>                       → GET $base/models
# No jq: the Pi generator is lua/local-models-pi.lua on tillandsias-plan.

LEMONADE_DEFAULT_URL="http://lemonade:13305/api/v1"

# Every built-in cloud provider omp v19.2.1 documents (docs/models.md and
# docs/environment-variables.md), plus its implicit local discoveries, which
# would probe ports other than Lemonade's. The lane keeps exactly one
# provider: lemonade.
OMP_DISABLED_PROVIDERS="abliteration aiand aimlapi alibaba-coding-plan alibaba-token-plan amazon-bedrock anthropic antigravity apple-foundation-models azure-openai-responses baseten bifrost cerebras charm-hyper chutes cline-pass cloudflare-ai-gateway cloudflare-workers-ai commandcode coralbricks coreweave cursor deepinfra deepseek devin fireworks firepass github-copilot gitlab-duo gitlab-duo-agent gmi-cloud google google-antigravity google-gemini-cli google-vertex groq helmcode huggingface inception kilo kimi kimi-code kiro litellm llama.cpp lm-studio meta minimax minimax-code minimax-code-cn mistral modal modular moonshot nanogpt novita nvidia ollama ollama-cloud openai openai-codex opencode-go opencode-zen openrouter otari perplexity qianfan qwen-portal sakana sambanova scaleway siliconflow siliconflow-cn singularityapi-dev singularityapi-tech snowflake stepfun synthetic together umans venice vercel-ai-gateway vllm wafer-serverless xai xai-oauth xiaomi xiaomi-token-plan-ams xiaomi-token-plan-cn xiaomi-token-plan-sgp yolo-auto zai zenmux zhipu-coding-plan"

# The Lemonade base URL, refused unless it is a plain http(s) URL: it is
# written into YAML and JSON, and a quote or newline would let it add keys.
lemonade_base_url() {
    local url="${TILLANDSIAS_LEMONADE_URL:-$LEMONADE_DEFAULT_URL}"
    url="${url%/}"
    case "$url" in
        http://* | https://*) ;;
        *) echo "refused:lemonade-url:not-http:$url" >&2; return 1 ;;
    esac
    if printf '%s' "$url" | grep -q '[^A-Za-z0-9._:/@%-]'; then
        echo "refused:lemonade-url:unsafe-characters" >&2
        return 1
    fi
    printf '%s\n' "$url"
}

# The host part of the base URL, for no_proxy: the forge's curl and node must
# reach Lemonade directly, never through the egress proxy.
lemonade_host() {
    local rest
    rest="$(lemonade_base_url)" || return 1
    rest="${rest#*://}"
    rest="${rest%%/*}"
    rest="${rest##*@}"
    printf '%s\n' "${rest%%:*}"
}

lemonade_export_no_proxy() {
    local host
    host="$(lemonade_host)" || return 1
    case ",${NO_PROXY:-}," in *",$host,"*) ;; *) export NO_PROXY="${NO_PROXY:+$NO_PROXY,}$host" ;; esac
    case ",${no_proxy:-}," in *",$host,"*) ;; *) export no_proxy="${no_proxy:+$no_proxy,}$host" ;; esac
}

lemonade_fetch_models() {
    local base
    base="$(lemonade_base_url)" || return 1
    curl -fsS --max-time 15 "$base/models" -o "$1"
}

# Pi has no model discovery, so its models.json is generated from the answer.
# The selection and the JSON are lua/local-models-pi.lua on `tillandsias-plan
# script run --helper` (openspec forge-lua-helpers): new forge code carries no
# jq. The module sits beside this file (images/default/lua/ in a checkout,
# /usr/local/lib/tillandsias/lua/ in the image).
lemonade_pi_config() {
    local answer="$1" dir="$2" base lua="" c plan
    base="$(lemonade_base_url)" || return 1
    mkdir -p "$dir" || return 1
    for c in "${BASH_SOURCE[0]%/*}/lua/local-models-pi.lua" /usr/local/lib/tillandsias/lua/local-models-pi.lua; do
        if [ -r "$c" ]; then lua="$c"; break; fi
    done
    plan="${TILLANDSIAS_PLAN_BIN:-tillandsias-plan}"
    if [ -z "$lua" ] || ! command -v "$plan" >/dev/null 2>&1; then
        echo "refused:pi-config:helper-missing (lua/local-models-pi.lua or $plan is absent from this image)" >&2
        return 1
    fi
    _lemonade_pi_emit models "$dir/models.json" "$answer" "$dir/settings.json" "$lua" "$plan" "$base" || return 1
    _lemonade_pi_emit settings "$dir/settings.json" "$answer" "$dir/settings.json" "$lua" "$plan" || return 1
}

# One helper call → one file. A helper may not call verdict.*, so a refusal is
# the helper's only stdout line, starting `refused:`; it goes to stderr here and
# nothing is written.
_lemonade_pi_emit() {
    local mode="$1" dest="$2" answer="$3" settings="$4" lua="$5" plan="$6" first
    shift 6
    LEMONADE_MODELS_ANSWER="$answer" PI_SETTINGS_FILE="$settings" \
        "$plan" script run --helper "$lua" -- "$mode" "$@" > "$dest.tmp" || { rm -f "$dest.tmp"; return 1; }
    IFS= read -r first < "$dest.tmp" || first=""
    case "$first" in
        refused:*) printf '%s\n' "$first" >&2; rm -f "$dest.tmp"; return 1 ;;
        "{"*) mv -f "$dest.tmp" "$dest" ;;
        *) echo "refused:pi-config:helper-gave-no-json:$mode" >&2; rm -f "$dest.tmp"; return 1 ;;
    esac
}

# omp discovers the models itself (openai-models-list); the file names only the
# provider, and config.yml disables every built-in one.
lemonade_omp_config() {
    local dir="$1" base p
    base="$(lemonade_base_url)" || return 1
    mkdir -p "$dir" || return 1
    {
        echo "# Generated by entrypoint-forge-omp.sh (order 2455-lomp): local Lemonade only."
        echo "providers:"
        echo "  lemonade:"
        echo "    baseUrl: \"$base\""
        echo "    api: openai-completions"
        echo "    auth: none"
        echo "    discovery:"
        echo "      type: openai-models-list"
        echo "      injectV1: false"
    } > "$dir/models.yml.tmp" && mv -f "$dir/models.yml.tmp" "$dir/models.yml" || return 1
    {
        echo "# Generated by entrypoint-forge-omp.sh (order 2455-lomp): no cloud provider."
        echo "disabledProviders:"
        for p in $OMP_DISABLED_PROVIDERS; do
            echo "  - $p"
        done
    } > "$dir/config.yml.tmp" && mv -f "$dir/config.yml.tmp" "$dir/config.yml"
}
