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
# Needs jq (the forge base has it).

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

# The jq filter shared by the lanes: downloaded models labelled chat or
# tool-calling, and none labelled for another modality.
_LEMONADE_CHAT_FILTER='
  (.data // [])
  | map(select(
      .downloaded == true
      and ((.labels // []) | any(. == "chat" or . == "tool-calling"))
      and ((.labels // []) | any(. as $l
            | ["image", "audio", "tts", "transcription", "embeddings", "embedding", "3d", "reranking"]
            | index($l)) | not)
    ))'

lemonade_chat_models() {
    jq -c "$_LEMONADE_CHAT_FILTER" "$1"
}

# Pi has no model discovery, so its models.json is generated from the answer.
lemonade_pi_config() {
    local answer="$1" dir="$2" base n
    base="$(lemonade_base_url)" || return 1
    mkdir -p "$dir" || return 1
    n="$(jq "$_LEMONADE_CHAT_FILTER | length" "$answer" 2>/dev/null)" || n=""
    if [ -z "$n" ] || [ "$n" -eq 0 ]; then
        echo "refused:pi-config:no-local-chat-model (Lemonade lists no downloaded chat or tool-calling model)" >&2
        return 1
    fi
    jq --arg base "$base" "$_LEMONADE_CHAT_FILTER"' as $m | {
        providers: {
          lemonade: {
            baseUrl: $base,
            api: "openai-completions",
            apiKey: "lemonade-local",
            models: ($m | map(
              ((.context_length // 8192) | if . < 1024 then 1024 else . end) as $ctx
              | {
                  id: .id,
                  name: .id,
                  contextWindow: $ctx,
                  maxTokens: ([16384, (($ctx / 4) | floor)] | min),
                  reasoning: ((.labels // []) | index("reasoning") != null),
                  input: (["text"] + (if ((.labels // []) | index("vision")) then ["image"] else [] end)),
                  compat: { supportsDeveloperRole: false, supportsStore: false }
                }))
          }
        }
      }' "$answer" > "$dir/models.json.tmp" && mv -f "$dir/models.json.tmp" "$dir/models.json" || return 1
    # The default model prefers one that can call tools.
    local default
    default="$(jq -r "$_LEMONADE_CHAT_FILTER"' | (map(select((.labels // []) | index("tool-calling"))) + .) | .[0].id' "$answer")"
    local settings="$dir/settings.json"
    [ -s "$settings" ] || echo '{}' > "$settings"
    jq --arg m "$default" '.defaultProvider = "lemonade" | .defaultModel = $m | .enabledModels = ["lemonade/*"]' \
        "$settings" > "$settings.tmp" && mv -f "$settings.tmp" "$settings"
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
