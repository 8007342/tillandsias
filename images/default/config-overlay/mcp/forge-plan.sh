#!/usr/bin/env bash
# MCP Server: Forge Plan + Methodology Query Tools
# @trace order:456, order:394b, order:394c, spec:spec-traceability, invariant:plan_is_queried_via_mcp_server_avoiding_heuristic_parsing
# Communicates via JSON-RPC over stdin/stdout (MCP stdio transport)
#
# Tools:
#   plan_check        — integrity + schema validation
#   plan_status       — one packet's status line
#   plan_ready        — ready packets for a pickup role
#   plan_blocked_by   — packets directly blocked by a given packet
#   plan_closure      — everything transitively downstream of a packet
#   plan_burndown     — release-target children with statuses
#   plan_answer       — the CITED answer envelope (order 394b)
#   methodology_path  — YAML path query over the methodology corpus (order 394c)
#   methodology_ask   — a canonical discipline question, routed to its path (394c)
#
# ORDER 394c lives HERE, in the forge-plan server, rather than in a sibling
# server file. Both corpora are served by the SAME binary
# (`tillandsias-plan`), so a second server would duplicate every line of
# binary resolution and degraded-envelope handling below, and would need a
# registration entry in images/default/config-overlay/opencode/config.json —
# which is outside this slice's file scope. The tools sit beside plan_answer
# and share its one contract: the envelope, on every path.
#
# Wraps the compiled tillandsias-plan CLI for 100% accurate YAML queries.
# The binary is preferred over grep/python because it parses the plan
# ledger via serde_yaml with full dependency-graph awareness.

set -euo pipefail

# Launch-state directory written by lib-common.sh::ensure_forge_experts.
# tmpfs — dies with the container. MUST agree with FORGE_EXPERTS_STATE_DIR.
FORGE_EXPERTS_STATE_DIR="${FORGE_EXPERTS_STATE_DIR:-/dev/shm/tillandsias-experts}"

# Canonical install destination for the plan expert binary, produced by
# lib-common.sh::ensure_forge_experts. This literal MUST stay identical on both
# sides — a wrapper probing a path that no build step produces is exactly what
# made this server dead on arrival when order 456 landed it. The agreement is
# pinned structurally by litmus:forge-plan-expert-build-shape.
PLAN_BIN_CANONICAL="$HOME/.local/bin/tillandsias-plan"

# ── Expert usage telemetry (order 575) ──────────────────────────────────────
#
# One JSONL line per expert call, so a cycle can report whether the experts were
# USED and whether they were USEFUL — two different questions that a single
# "expert calls" counter cannot separate.
#
# WHY THE OUTCOME FIELD IS THE LOAD-BEARING ONE: an expert called two hundred
# times that refuses two hundred times is heavily used and completely useless,
# and a bare call count reports that as success. Order 531 was exactly this
# shape in the wild — the expert answered `confidence=unsupported` for every
# query because the forge was seeded from a pre-expert branch, while every
# health signal read green. So the ratio that matters is answered / (answered +
# unsupported), and it is recorded per call rather than derived later.
#
# THIS COUNTER CANNOT REWARD ACTIVITY. `answered` is only reachable when the
# expert returns citations, which the binary emits only when it resolved a real
# packet or YAML path. Calling the tool more cannot raise the ratio; only
# answering more can.
#
# Fail-soft by construction: telemetry must never break a tool call, so every
# write is best-effort and the whole function is guarded. A metric that can take
# down the surface it measures is worse than no metric.
EXPERT_USAGE_LOG="${TILLANDSIAS_EXPERT_USAGE_LOG:-/tmp/forge-expert-usage.jsonl}"

# record_expert_call <tool> <result-text> <unknown-flag>
# Outcome vocabulary (CLOSED SET):
#   answered     — a cited envelope, or a non-envelope tool that produced output
#   unsupported  — the expert REFUSED (confidence=unsupported): no citations
#   degraded     — the expert could not run at all (binary missing / not built)
#   error        — protocol error (unknown tool)
record_expert_call() {
    _rec_tool="$1"
    _rec_result="${2:-}"
    _rec_unknown="${3:-0}"
    _rec_outcome="answered"
    _rec_conf="-"
    _rec_cites=0

    if [ "$_rec_unknown" = "1" ]; then
        _rec_outcome="error"
    else
        # Envelope tools carry a confidence field; the others do not. Parse only
        # when it is actually JSON, so a plain-text status line is never
        # misread as a refusal.
        _rec_conf="$(printf '%s' "$_rec_result" | jq -r '.confidence // "-"' 2>/dev/null || echo '-')"
        _rec_cites="$(printf '%s' "$_rec_result" | jq -r '(.citations // []) | length' 2>/dev/null || echo 0)"
        case "$_rec_conf" in
            unsupported)
                _rec_outcome="unsupported"
                # Distinguish "the expert ran and refused" from "the expert
                # could not run": both surface as unsupported to the caller,
                # but only the first is a retrieval quality signal. Conflating
                # them makes a broken build look like a hard question.
                case "$_rec_result" in
                    *"experts state:"* | *"binary"*) _rec_outcome="degraded" ;;
                esac
                ;;
        esac
    fi

    # Best-effort append. `|| true` on the whole chain: a full tmpfs, a
    # read-only path, or absent jq must not fail the tool call.
    {
        printf '{"ts":"%s","tool":"%s","outcome":"%s","confidence":"%s","citations":%s}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)" \
            "$_rec_tool" "$_rec_outcome" "$_rec_conf" "${_rec_cites:-0}" \
            >>"$EXPERT_USAGE_LOG"
    } 2>/dev/null || true
    return 0
}

# Detect the plan index — prefer TILLANDSIAS_PLAN_INDEX, fall back to
# the canonical repo plan/index.yaml.
resolve_plan_index() {
    if [ -n "${TILLANDSIAS_PLAN_INDEX:-}" ] && [ -f "${TILLANDSIAS_PLAN_INDEX}" ]; then
        printf '%s\n' "$TILLANDSIAS_PLAN_INDEX"
        return 0
    fi
    for candidate in \
        "$HOME/src/tillandsias/plan/index.yaml" \
        "$HOME/tillandsias/plan/index.yaml" \
        "/opt/cheatsheets/plan-index.yaml"; do
        if [ -f "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    printf '\n'
}

# Locate the tillandsias-plan binary.
#
# The probe list used to cover only INSTALLED locations, which meant this server
# worked exclusively inside a forge — where ensure_forge_experts builds and
# installs to PLAN_BIN_CANONICAL — and returned "the tillandsias-plan binary is
# not installed" everywhere else. On a host checkout the binary normally lives at
# target/release/tillandsias-plan (that is what ./build.sh produces and what the
# coordinator runs all day), so every plan_* tool errored on the host even though
# a perfectly good binary was sitting in the tree. Reproduced 2026-07-30:
# plan_check / plan_ready / plan_status all returned the not-installed
# diagnostic, and plan_answer / methodology_ask degraded to
# confidence=unsupported.
#
# Adding the cargo output path makes ONE server correct in both contexts. The
# installed locations still win: inside a forge the canonical install is the
# artifact ensure_forge_experts just produced and is the one the launch state
# reports on, so preferring a possibly-stale target/release there would make the
# experts state line lie about which binary is answering.
resolve_plan_bin() {
    if [ -n "${TILLANDSIAS_PLAN_BIN:-}" ] && [ -x "${TILLANDSIAS_PLAN_BIN}" ]; then
        printf '%s\n' "$TILLANDSIAS_PLAN_BIN"
        return 0
    fi
    for candidate in \
        "$PLAN_BIN_CANONICAL" \
        "/usr/local/bin/tillandsias-plan" \
        "/usr/bin/tillandsias-plan"; do
        if [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    # Fallback: a cargo-built binary in the checkout this server is serving.
    # Derived from the resolved index rather than assumed, so it follows
    # TILLANDSIAS_PLAN_INDEX and the probe order above.
    _idx="$(resolve_plan_index)"
    if [ -n "$_idx" ]; then
        _root="$(dirname "$(dirname "$_idx")")"
        if [ -x "$_root/target/release/tillandsias-plan" ]; then
            printf '%s\n' "$_root/target/release/tillandsias-plan"
            return 0
        fi
    fi
    printf '\n'
}

# Render the experts launch state using the grammar pinned in lib-common.sh:
#   ready | building(<n>s) | degraded(<reason>)
experts_state_line() {
    local state="" started=0 now=0 elapsed=0
    if [ -r "$FORGE_EXPERTS_STATE_DIR/state" ]; then
        state="$(cat "$FORGE_EXPERTS_STATE_DIR/state" 2>/dev/null || true)"
    fi
    case "$state" in
        ready) printf 'ready\n' ;;
        building)
            started="$(cat "$FORGE_EXPERTS_STATE_DIR/started_at" 2>/dev/null || echo 0)"
            case "$started" in
                '' | *[!0-9]*) started=0 ;;
            esac
            now="$(date +%s 2>/dev/null || echo 0)"
            elapsed=$((now - started))
            [ "$elapsed" -ge 0 ] || elapsed=0
            budget="${FORGE_EXPERTS_BUILD_BUDGET_SECS:-300}"
            if [ "$elapsed" -gt "$budget" ]; then
                printf 'degraded(build-abandoned-after-%ss)\n' "$elapsed"
            else
                printf 'building(%ss)\n' "$elapsed"
            fi
            ;;
        degraded:*) printf 'degraded(%s)\n' "${state#degraded:}" ;;
        *) printf 'degraded(not-built)\n' ;;
    esac
}

# Precise, actionable "binary absent" text. A bare "not found" told an agent
# nothing about whether the condition was transient or permanent, or which step
# was supposed to produce the binary. This names the build step, the canonical
# install path, and the current launch state.
binary_missing_error() {
    local state
    state="$(experts_state_line)"
    printf 'ERROR: the tillandsias-plan binary is not installed.\n'
    printf '  probed: %s, /usr/local/bin/tillandsias-plan, /usr/bin/tillandsias-plan\n' "$PLAN_BIN_CANONICAL"
    printf '  produced by: lib-common.sh::ensure_forge_experts — backgrounded at forge launch\n'
    printf '               immediately after clone_project_from_mirror; it runs\n'
    printf '               `cargo build --release -p tillandsias-plan` and installs the\n'
    printf '               artifact to %s.\n' "$PLAN_BIN_CANONICAL"
    printf '  experts state: %s\n' "$state"
    case "$state" in
        building*)
            printf '  TRANSIENT: the build is still running. Retry this tool in a few seconds.\n'
            ;;
        'degraded(build-abandoned-after-'*)
            printf '  FAILED/ABANDONED: the background build exceeded its budget without installing\n'
            printf '  the binary (it may have been OOM-killed or failed). Build it manually:\n'
            printf '  cargo build --release -p tillandsias-plan &&\n'
            printf '  install -m0755 target/release/tillandsias-plan %s\n' "$PLAN_BIN_CANONICAL"
            ;;
        'degraded(no-plan-crate)')
            printf '  NOT APPLICABLE: this project has no crates/tillandsias-plan, so there is no\n'
            printf '  plan expert to build. The forge-plan MCP server has nothing to serve here.\n'
            ;;
        'degraded(not-built)')
            printf '  The expert build never started in this container (no project clone in this\n'
            printf '  lane, or the launch predates the build step). Build it by hand from the\n'
            printf '  checkout: cargo build --release -p tillandsias-plan &&\n'
            printf '  install -m0755 target/release/tillandsias-plan %s\n' "$PLAN_BIN_CANONICAL"
            ;;
        *)
            printf '  PERMANENT for this session. See /tmp/forge-lifecycle.log for the failure,\n'
            printf '  then rebuild by hand from the checkout:\n'
            printf '  cargo build --release -p tillandsias-plan &&\n'
            printf '  install -m0755 target/release/tillandsias-plan %s\n' "$PLAN_BIN_CANONICAL"
            ;;
    esac
    printf '  This never affected your session: expert construction is fail-soft by contract.\n'
}

# Resolved once at startup, then RE-RESOLVED lazily per call while unresolved.
# The expert build is backgrounded, so an MCP client that connects during the
# build would otherwise cache an empty path and stay broken for the whole
# session even after the binary appears.
PLAN_INDEX="$(resolve_plan_index)"
PLAN_BIN="$(resolve_plan_bin)"

plan_query() {
    local cmd="$1"
    shift
    [ -n "$PLAN_BIN" ] || PLAN_BIN="$(resolve_plan_bin)"
    [ -n "$PLAN_INDEX" ] || PLAN_INDEX="$(resolve_plan_index)"
    # NOTE: these paths return 0, deliberately. The call sites capture this
    # function with `result=$(plan_query ...)`, and this script runs under
    # `set -e` — a non-zero return there KILLS the MCP server mid-request, so
    # the client sees a dropped connection instead of the diagnostic. The error
    # text on stdout IS the signal; it is delivered as the tool result.
    if [ -z "$PLAN_BIN" ]; then
        binary_missing_error
        return 0
    fi
    if [ -z "$PLAN_INDEX" ]; then
        echo "ERROR: plan/index.yaml not found (probed \$TILLANDSIAS_PLAN_INDEX, \$HOME/src/tillandsias/plan/index.yaml, \$HOME/tillandsias/plan/index.yaml, /opt/cheatsheets/plan-index.yaml)"
        return 0
    fi
    "$PLAN_BIN" --index "$PLAN_INDEX" "$cmd" "$@" 2>&1 || true
}

# ── ORDER 394b: the answer envelope at the WRAPPER boundary ─────────────────
#
# `plan_answer` promises the ratified §4 envelope
# ({answer, citations[], freshness, confidence}), so its DEGRADED paths must
# answer with an envelope too — not the prose diagnostic the other six tools
# return. Two failures are being closed here at once:
#
#   * a client that parses plan_answer's output must never be handed something
#     unparseable just because the expert build has not finished; and
#   * the load-bearing rule — ZERO CITATIONS RENDERS AS "unsupported", NEVER A
#     GUESS — must hold on this side of the boundary as well as inside the
#     engine. This function is the ONLY degraded-path constructor and it
#     hardcodes `citations: []` together with `confidence: "unsupported"`, so
#     the two can never drift apart.
#
# The reason string carries the truthful launch state from experts_state_line
# (ready | building(<n>s) | degraded(<reason>)) — the same grammar
# binary_missing_error reports for the other tools — so "I cannot answer yet"
# and "I will never be able to answer" are distinguishable by the caller.
unsupported_envelope() {
    jq -cn --arg reason "$1" \
        '{answer: ("unsupported: " + $reason),
          citations: [],
          freshness: {source_commit: "unknown", indexed_at: "unknown"},
          confidence: "unsupported"}'
}

plan_answer_envelope() {
    local question="$1" state out hint
    [ -n "$PLAN_BIN" ] || PLAN_BIN="$(resolve_plan_bin)"
    [ -n "$PLAN_INDEX" ] || PLAN_INDEX="$(resolve_plan_index)"
    state="$(experts_state_line)"
    if [ -z "$question" ]; then
        unsupported_envelope "no question was supplied"
        return 0
    fi
    if [ -z "$PLAN_BIN" ]; then
        # Same TRANSIENT / NOT APPLICABLE / PERMANENT triage that
        # binary_missing_error gives the other six tools — an agent must be
        # able to tell "retry shortly" from "never, this session" without
        # reading prose written for a human.
        case "$state" in
            building*)
                hint="TRANSIENT: the build is still running — retry in a few seconds."
                ;;
            'degraded(no-plan-crate)')
                hint="NOT APPLICABLE: this project has no crates/tillandsias-plan, so there is no plan expert here."
                ;;
            'degraded(not-built)')
                hint="The expert build never started in this container. Build it by hand: cargo build --release -p tillandsias-plan && install -m0755 target/release/tillandsias-plan ${PLAN_BIN_CANONICAL}"
                ;;
            *)
                hint="PERMANENT for this session — see /tmp/forge-lifecycle.log, then rebuild by hand: cargo build --release -p tillandsias-plan && install -m0755 target/release/tillandsias-plan ${PLAN_BIN_CANONICAL}"
                ;;
        esac
        unsupported_envelope "the plan expert cannot answer — experts state: ${state}. The binary is produced by lib-common.sh::ensure_forge_experts and installed to ${PLAN_BIN_CANONICAL}. ${hint}"
        return 0
    fi
    if [ -z "$PLAN_INDEX" ]; then
        unsupported_envelope "no plan/index.yaml was found to answer from (probed \$TILLANDSIAS_PLAN_INDEX, \$HOME/src/tillandsias/plan/index.yaml, \$HOME/tillandsias/plan/index.yaml, /opt/cheatsheets/plan-index.yaml) — experts state: ${state}"
        return 0
    fi
    out="$("$PLAN_BIN" --index "$PLAN_INDEX" answer "$question" 2>/dev/null || true)"
    # Anything that is not an envelope (engine crash, argument error, a cached
    # pre-394b binary that has no `answer` subcommand) is DOWNGRADED rather
    # than forwarded. Forwarding prose from a tool that promises JSON is how a
    # diagnostic gets read as a finding.
    if printf '%s' "$out" | jq -e 'type == "object" and has("answer") and has("citations") and has("confidence")' >/dev/null 2>&1; then
        printf '%s\n' "$out"
    else
        unsupported_envelope "the plan expert returned no envelope for this question — experts state: ${state}"
    fi
}

# ── ORDER 394c: the methodology L0 path query ───────────────────────────────
#
# A DIFFERENT corpus from the plan ledger: methodology.yaml plus
# methodology/**/*.yaml, rooted at the checkout. The root is derived from the
# resolved plan index (…/plan/index.yaml -> …), because in the forge both live
# in the same clone; TILLANDSIAS_METHODOLOGY_ROOT overrides for anything else.
# It is probed for methodology.yaml, never assumed: answering "which checkout?"
# wrongly would cite line numbers from a different tree.
resolve_methodology_root() {
    local candidate
    if [ -n "${TILLANDSIAS_METHODOLOGY_ROOT:-}" ] && [ -f "${TILLANDSIAS_METHODOLOGY_ROOT}/methodology.yaml" ]; then
        printf '%s\n' "$TILLANDSIAS_METHODOLOGY_ROOT"
        return 0
    fi
    [ -n "$PLAN_INDEX" ] || PLAN_INDEX="$(resolve_plan_index)"
    if [ -n "$PLAN_INDEX" ]; then
        candidate="$(dirname "$(dirname "$PLAN_INDEX")")"
        if [ -f "$candidate/methodology.yaml" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    fi
    for candidate in "$HOME/src/tillandsias" "$HOME/tillandsias"; do
        if [ -f "$candidate/methodology.yaml" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    printf '\n'
}

METHODOLOGY_ROOT="$(resolve_methodology_root)"

# One helper for both methodology tools. Same discipline as
# plan_answer_envelope: the ENVELOPE is the contract on every path, including
# the degraded ones, and `unsupported_envelope` is the single degraded-path
# constructor so `citations: []` and `confidence: "unsupported"` cannot drift.
methodology_envelope() {
    local subcommand="$1" argument="$2" state out
    [ -n "$PLAN_BIN" ] || PLAN_BIN="$(resolve_plan_bin)"
    [ -n "$METHODOLOGY_ROOT" ] || METHODOLOGY_ROOT="$(resolve_methodology_root)"
    state="$(experts_state_line)"
    if [ -z "$argument" ]; then
        unsupported_envelope "no ${subcommand} argument was supplied"
        return 0
    fi
    if [ -z "$PLAN_BIN" ]; then
        unsupported_envelope "the methodology expert cannot answer — experts state: ${state}. The binary is produced by lib-common.sh::ensure_forge_experts and installed to ${PLAN_BIN_CANONICAL}."
        return 0
    fi
    if [ -z "$METHODOLOGY_ROOT" ]; then
        unsupported_envelope "no methodology corpus was found to answer from (probed \$TILLANDSIAS_METHODOLOGY_ROOT, the checkout holding \$TILLANDSIAS_PLAN_INDEX, \$HOME/src/tillandsias, \$HOME/tillandsias) — experts state: ${state}"
        return 0
    fi
    out="$("$PLAN_BIN" "$subcommand" --root "$METHODOLOGY_ROOT" "$argument" 2>/dev/null || true)"
    # Anything that is not an envelope (an argument error, or a cached
    # pre-394c binary with no methodology subcommand) is DOWNGRADED, never
    # forwarded: prose from a tool that promises JSON reads as a finding.
    if printf '%s' "$out" | jq -e 'type == "object" and has("answer") and has("citations") and has("confidence")' >/dev/null 2>&1; then
        printf '%s\n' "$out"
    else
        unsupported_envelope "the methodology expert returned no envelope for ${subcommand} ${argument} — experts state: ${state}"
    fi
}

# ORDER 548. The FAT spec expert: RAG over the whole-spec corpus (openspec/specs
# + cheatsheets + methodology). The compiled binary does the network-free
# chunk/retrieve/envelope (order 547); embedding + synthesis are curl over /v1.
# Fail-soft on EVERY missing prerequisite: this tool must be VISIBLE in the MCP
# panel (so the harness knows the capability exists) and return a typed
# `unsupported` envelope — never a crash, never a guess — when the index or an
# endpoint is absent. The GPU fat model / NPU fallback is a config choice: point
# TILLANDSIAS_SPEC_EXPERT_ENDPOINT at whichever /v1 the policy router selected.
SPEC_INDEX_DIR="${FORGE_SPEC_INDEX_DIR:-$FORGE_EXPERTS_STATE_DIR/spec-index}"
spec_answer_envelope() {
    local question="$1"
    [ -n "$PLAN_BIN" ] || PLAN_BIN="$(resolve_plan_bin)"
    local embed_ep="${TILLANDSIAS_EMBED_ENDPOINT:-}"
    local synth_ep="${TILLANDSIAS_SPEC_EXPERT_ENDPOINT:-$embed_ep}"
    local embed_model="${TILLANDSIAS_EMBED_MODEL:-nomic-embed-text-v1-GGUF}"
    local synth_model="${TILLANDSIAS_SPEC_EXPERT_MODEL:-}"
    if [ -z "$question" ]; then
        unsupported_envelope "no question was supplied"
        return 0
    fi
    if [ -z "$PLAN_BIN" ]; then
        unsupported_envelope "the spec expert needs the tillandsias-plan binary (spec-retrieve/spec-envelope) — experts state: $(experts_state_line)"
        return 0
    fi
    if [ ! -s "$SPEC_INDEX_DIR/chunks.jsonl" ] || [ ! -s "$SPEC_INDEX_DIR/vectors.jsonl" ]; then
        unsupported_envelope "the spec RAG index is not built at ${SPEC_INDEX_DIR} (need chunks.jsonl + vectors.jsonl). Build it: tillandsias-plan spec-index --root <repo> --out ${SPEC_INDEX_DIR}, then embed each chunk's text via ${embed_ep:-\$TILLANDSIAS_EMBED_ENDPOINT}/embeddings into vectors.jsonl (order 552 does this at launch/commit)."
        return 0
    fi
    if [ -z "$embed_ep" ]; then
        unsupported_envelope "no embedding endpoint — set TILLANDSIAS_EMBED_ENDPOINT to a /v1 base that serves ${embed_model}"
        return 0
    fi
    local work qv top synth env
    work="$(mktemp -d "${TMPDIR:-/tmp}/spec-answer.XXXXXX")"
    qv="$work/query-vec.json"; top="$work/top.json"; synth="$work/synth.txt"; env="$work/env.json"
    # 1) embed the query (fail-soft)
    if ! curl -fsS "$embed_ep/embeddings" -H 'Content-Type: application/json' \
        -d "$(jq -nc --arg m "$embed_model" --arg q "$question" '{model:$m, input:$q}')" 2>/dev/null \
        | jq -c '.data[0].embedding' > "$qv" 2>/dev/null || [ ! -s "$qv" ]; then
        rm -rf "$work"
        unsupported_envelope "the embedding endpoint ${embed_ep} did not answer for model ${embed_model} — the spec expert cannot retrieve"
        return 0
    fi
    # 2) retrieve (network-free)
    if ! "$PLAN_BIN" spec-retrieve --index-dir "$SPEC_INDEX_DIR" --query-vec "$qv" --k 6 > "$top" 2>/dev/null || [ ! -s "$top" ]; then
        rm -rf "$work"
        unsupported_envelope "spec-retrieve produced no candidates from ${SPEC_INDEX_DIR}"
        return 0
    fi
    # 3) synthesize over the cited spans; instruct the model to echo the keys so
    #    the citations survive verify(). Fail-soft to a retrieval-only answer.
    local ctx keys sys payload ok=0
    ctx="$(jq -r '.[] | "=== \(.key) (\(.path)) ===\n\(.text)\n"' "$top")"
    keys="$(jq -r '.[].key' "$top" | paste -sd '; ')"
    sys="You are the Tillandsias spec expert. Answer the question using ONLY the retrieved spec sections below. Be concise. Then on a FINAL line write 'Sources:' followed by the exact section names you used, comma-separated, copied verbatim from: ${keys}.

${ctx}"
    if [ -n "$synth_ep" ]; then
        payload="$(jq -nc --arg m "$synth_model" --arg s "$sys" --arg u "$question" \
            '{messages:[{role:"system",content:$s},{role:"user",content:$u}], max_tokens:320, temperature:0.2} + (if $m=="" then {} else {model:$m} end)')"
        if curl -fsS "$synth_ep/chat/completions" -H 'Content-Type: application/json' -d "$payload" 2>/dev/null \
            | jq -r '.choices[0].message.content // empty' > "$synth" 2>/dev/null && [ -s "$synth" ]; then
            ok=1
        fi
    fi
    # cited retrieval-only digest: keys present by construction, so it always
    # verifies with ZERO model tokens — the fail-soft floor.
    retrieval_only() {
        jq -r '.[] | "- \(.key) [\(.path):\(.line_start)-\(.line_end)]"' "$top" > "$synth"
        { echo; echo "Sources: $keys"; } >> "$synth"
    }
    [ "$ok" = 1 ] || retrieval_only
    # 4) build a VERIFIED envelope (keeps only citations the answer used). If the
    #    synthesized prose grounded in NO key (small model paraphrased away the
    #    section names), the envelope comes back unsupported — fall back to the
    #    cited digest so good retrieval still yields a verifiable cited answer,
    #    rather than refusing a question we actually found spec sections for.
    "$PLAN_BIN" spec-envelope --chunks-json "$top" --answer-file "$synth" --root "${TILLANDSIAS_REPO_ROOT:-.}" > "$env" 2>/dev/null || true
    if [ "$ok" = 1 ] && { [ ! -s "$env" ] || [ "$(jq -r '.confidence // "unsupported"' "$env" 2>/dev/null)" = "unsupported" ]; }; then
        retrieval_only
        "$PLAN_BIN" spec-envelope --chunks-json "$top" --answer-file "$synth" --root "${TILLANDSIAS_REPO_ROOT:-.}" > "$env" 2>/dev/null || true
    fi
    if [ -s "$env" ]; then
        cat "$env"
    else
        unsupported_envelope "spec-envelope could not build a verifiable answer from the retrieved chunks"
    fi
    rm -rf "$work"
}

# Read JSON-RPC requests from stdin, respond on stdout
while IFS= read -r line; do
    method=$(echo "$line" | jq -r '.method // empty')
    id=$(echo "$line" | jq -r '.id // empty')

    case "$method" in
        "initialize")
            echo '{"jsonrpc":"2.0","id":"'"$id"'","result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"forge-plan","version":"1.0.0"}}}'
            ;;
        "tools/list")
            echo '{"jsonrpc":"2.0","id":"'"$id"'","result":{"tools":[
                {"name":"plan_check","description":"Run integrity + schema validation on the plan ledger (shell: tillandsias-plan check)","inputSchema":{"type":"object","properties":{}}},
                {"name":"plan_status","description":"Get the status line of a packet by id or order number","inputSchema":{"type":"object","properties":{"reference":{"type":"string"}},"required":["reference"]}},
                {"name":"plan_ready","description":"List ready packets, optionally filtered by pickup role","inputSchema":{"type":"object","properties":{"role":{"type":"string"}}}},
                {"name":"plan_blocked_by","description":"List packets directly blocked by a given packet","inputSchema":{"type":"object","properties":{"reference":{"type":"string"}},"required":["reference"]}},
                {"name":"plan_closure","description":"List everything transitively downstream of a given packet","inputSchema":{"type":"object","properties":{"reference":{"type":"string"}},"required":["reference"]}},
                {"name":"plan_burndown","description":"List all children of a milestone/release-target with their statuses","inputSchema":{"type":"object","properties":{"reference":{"type":"string"}},"required":["reference"]}},
                {"name":"plan_answer","description":"Answer a plan question as the CITED envelope {answer, citations[], freshness, confidence}. Every citation carries a repo-relative path and a line range whose span contains the packet it is offered as evidence for; verify with `tillandsias-plan verify-answer`. An answer with zero citations is returned as confidence=unsupported — the expert refuses rather than guesses.","inputSchema":{"type":"object","properties":{"question":{"type":"string","description":"e.g. \"what is blocked by 394b\", \"everything downstream of 394\", \"what is ready for linux\", \"status of 394a\""}},"required":["question"]}},
                {"name":"methodology_path","description":"METHODOLOGY EXPERT (L0). Look up a YAML path in methodology.yaml and methodology/**/*.yaml and return the matched block plus a resolvable file:line, in the same CITED envelope as plan_answer. Query by full dotted path (methodology.runtime_language_policy.tlatoani_hard_no_python.rule), by path suffix (forge_cycle_budget.rule), or with * wildcards. An unknown path returns confidence=unsupported with zero citations — never the nearest key, never a guess.","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"e.g. \"forge_cycle_budget.rule\", \"bar_raise_governance.authority\", \"multi_host_development.pull_merge_cadence.pre_push_gate.rule\""}},"required":["path"]}},
                {"name":"methodology_ask","description":"METHODOLOGY EXPERT (L0). Route a canonical discipline question to its YAML path and answer it in the CITED envelope. Deterministic routing only: a question matching no route, or two routes, is refused as confidence=unsupported and the refusal lists the routed forms so you can re-ask methodology_path directly.","inputSchema":{"type":"object","properties":{"question":{"type":"string","description":"e.g. \"may a forge cycle drain two packets?\", \"may I embed a script in base64?\", \"who may raise the scan bar?\", \"what happens to a dead mechanism with a live intent?\", \"which branch does macOS checkpoint to?\""}},"required":["question"]}},
                {"name":"spec_answer","description":"FAT SPEC EXPERT (L1 RAG, orders 547/548). Answer a cross-cutting question about the whole spec corpus (openspec/specs + cheatsheets + methodology, ~950k tokens — too big for any context) as the same CITED envelope {answer, citations[], freshness, confidence=retrieved}. Retrieves the top spec sections (cosine over a local embedding index), synthesizes prose grounded ONLY in them, and keeps ONLY citations the answer actually used — verify with `tillandsias-plan verify-answer`. Use for JOIN-across-specs questions the deterministic plan/methodology experts refuse; those single-node lookups still go to plan_answer/methodology_ask. Fail-soft: returns confidence=unsupported (never a guess) when the index or an inference endpoint is unavailable.","inputSchema":{"type":"object","properties":{"question":{"type":"string","description":"e.g. \"how does the forge stay isolated from the host and control outbound network access?\", \"which specs govern async inference launch?\", \"how do the browser isolation specs interact with the enclave CA?\""}},"required":["question"]}}
            ]}}'
            ;;
        "tools/call")
            tool=$(echo "$line" | jq -r '.params.name')
            args=$(echo "$line" | jq -r '.params.arguments // {}')
            case "$tool" in
                "plan_check")
                    result=$(plan_query "check")
                    ;;
                "plan_status")
                    ref=$(echo "$args" | jq -r '.reference')
                    result=$(plan_query "status" "$ref")
                    ;;
                "plan_ready")
                    role=$(echo "$args" | jq -r '.role // ""')
                    if [ -n "$role" ]; then
                        result=$(plan_query "ready" "$role")
                    else
                        result=$(plan_query "ready")
                    fi
                    ;;
                "plan_blocked_by")
                    ref=$(echo "$args" | jq -r '.reference')
                    result=$(plan_query "blocked-by" "$ref")
                    ;;
                "plan_closure")
                    ref=$(echo "$args" | jq -r '.reference')
                    result=$(plan_query "blocked-closure" "$ref")
                    ;;
                "plan_burndown")
                    ref=$(echo "$args" | jq -r '.reference')
                    result=$(plan_query "burndown" "$ref")
                    ;;
                "plan_answer")
                    # Order 394b. Routed through plan_answer_envelope, NOT
                    # plan_query: this tool's contract is the JSON envelope on
                    # every path, including the degraded ones.
                    question=$(echo "$args" | jq -r '.question // ""')
                    result=$(plan_answer_envelope "$question")
                    ;;
                "methodology_path")
                    # Order 394c. Envelope on every path, same as plan_answer.
                    ypath=$(echo "$args" | jq -r '.path // ""')
                    result=$(methodology_envelope "methodology" "$ypath")
                    ;;
                "methodology_ask")
                    question=$(echo "$args" | jq -r '.question // ""')
                    result=$(methodology_envelope "methodology-ask" "$question")
                    ;;
                "spec_answer")
                    # Order 548. RAG over the whole-spec corpus; envelope on every
                    # path (fail-soft to unsupported), same contract as plan_answer.
                    question=$(echo "$args" | jq -r '.question // ""')
                    result=$(spec_answer_envelope "$question")
                    ;;
                *)
                    # An unhandled tool name is a PROTOCOL error, not a successful
                    # answer whose text happens to say "Unknown tool". Returning it
                    # as a result made this server the textbook instance of the
                    # project's own ratified anti-pattern
                    # `silent-drop-on-unhandled-control-variant`
                    # (methodology/multi-host-development.yaml:435-447): a caller
                    # sees success, the model reads the sentence as an ANSWER, and a
                    # typo'd or renamed tool degrades into a plausible reply instead
                    # of a loud failure. The tray's MCP socket already answers
                    # -32601 here (crates/tillandsias-headless/src/tray/mod.rs:798),
                    # so the two host MCP surfaces disagreed on the same contract.
                    # Flag and branch AFTER the case: an early `return`/`exit` inside
                    # this command-substitution context is what previously killed the
                    # server mid-session rather than reporting (order 456 event,
                    # 2026-07-29T03:10Z).
                    unknown_tool=1
                    ;;
            esac
            # Order 568: the single chokepoint every tool call passes through,
            # so usage is recorded in ONE place rather than at nine call sites
            # that could each drift.
            record_expert_call "$tool" "${result:-}" "${unknown_tool:-0}"
            if [ "${unknown_tool:-0}" = "1" ]; then
                unknown_tool=0
                escaped=$(echo "Unknown tool: $tool" | jq -Rs .)
                echo '{"jsonrpc":"2.0","id":"'"$id"'","error":{"code":-32601,"message":'"$escaped"'}}'
            else
                escaped=$(echo "$result" | jq -Rs .)
                echo '{"jsonrpc":"2.0","id":"'"$id"'","result":{"content":[{"type":"text","text":'"$escaped"'}]}}'
            fi
            ;;
        "prompts/list")
            echo '{"jsonrpc":"2.0","id":"'"$id"'","result":{"prompts":[]}}'
            ;;
        "resources/list")
            echo '{"jsonrpc":"2.0","id":"'"$id"'","result":{"resources":[]}}'
            ;;
        "resources/templates/list")
            echo '{"jsonrpc":"2.0","id":"'"$id"'","result":{"resourceTemplates":[]}}'
            ;;
        "notifications/initialized")
            ;;
        *)
            if [ -n "$id" ]; then
                echo '{"jsonrpc":"2.0","id":"'"$id"'","error":{"code":-32601,"message":"Method not found: '"$method"'"}}'
            fi
            ;;
    esac
done
