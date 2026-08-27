# Wire RAG Layer, Domain Experts, and OpenCode "Local Experts" Mode

## Goal

Wire the local expert system's Lua-powered adversarial decomposition + CRDT
collection pipeline with domain-separated RAG (cheatsheets, plan, methodology,
code), update commit hooks for domain-specific re-embedding, update
meta-orchestration to proactively query local experts, and add an OpenCode
"Local Experts" prompt mode that routes all queries through local Ollama.

## Design Decisions (confirmed with operator)

- **Separate indexes + prompts**: Each domain gets its own chunks/vectors
  index AND a domain-specific synthesis prompt.
- **All queries through local**: The "Local Experts" mode routes every query
  through the local RAG + adversarial pipeline, bypassing Zen entirely.
- **Proactive at cycle start**: Meta-orchestration queries local experts at
  the start of each cycle to surface pending/neglected work.

---

## Phase 1: Domain-Separated RAG Indexes

### 1A. Split CORPUS_ROOTS into domain groups

**File**: `crates/tillandsias-plan/src/spec.rs`

Add a new constant `CORPUS_DOMAINS` that maps each corpus root to a domain
name, and a `domain_of_root()` function:

```rust
pub const CORPUS_DOMAINS: &[(&str, &str)] = &[
    ("cheatsheets", "cheatsheet"),
    ("docs/cheatsheets", "cheatsheet"),
    ("openspec/specs", "spec"),
    ("methodology", "methodology"),
    ("crates", "code"),
    ("scripts", "code"),
    ("images", "code"),
];

pub fn domain_of_root(root: &str) -> &'static str {
    CORPUS_DOMAINS.iter()
        .find(|(r, _)| *r == root)
        .map(|(_, d)| *d)
        .unwrap_or("unknown")
}
```

### 1B. Add domain filter to spec-index subcommand

**File**: `crates/tillandsias-plan/src/main.rs` (spec-index arm, ~line 2977)

Add `--domain <name>` flag. When provided, only chunks from corpus roots
matching that domain are written to the output. When omitted, all domains
are indexed (backward compatible).

### 1C. Add domain filter to spec-retrieve subcommand

**File**: `crates/tillandsias-plan/src/main.rs` (spec-retrieve arm, ~line 3012)

Add `--domain <name>` flag. When provided, only chunks whose `kind` matches
the domain are included in the top-k search.

### 1D. Create domain index directory layout

**File**: `scripts/spec-index-ensure.sh`

Extend the durable tier layout to support per-domain indexes:

```
<root>/
  cheatsheet/          # domain-separated index
    <fingerprint>/
      chunks.jsonl
      vectors.jsonl
      .fingerprint
      .model
      .commit
    current
  methodology/
    ...
  code/
    ...
  spec/                # openspec/specs
    ...
  _combined/           # backward-compat combined index (all domains)
    <fingerprint>/
      ...
    current
```

The `_combined` index is built by default for backward compatibility. Domain
indexes are built on demand via `--domain`.

### 1E. Add domain index paths to lib-dev-env.sh

**File**: `images/default/config-overlay/mcp/lib-dev-env.sh`

Add helper functions:

```bash
domain_index_root() {
    local domain="$1"
    echo "${FORGE_SPEC_INDEX_ROOT:-$HOME/.cache/tillandsias/spec-index}/${domain}"
}

domain_index_dir() {
    local domain="$1"
    local root
    root="$(domain_index_root "$domain")"
    if [ -s "$root/current" ]; then
        cat "$root/current"
    fi
}
```

---

## Phase 2: Domain-Separated Pipeline

### 2A. Add domain-aware decompose

**File**: `crates/tillandsias-plan/src/pipeline.rs`

Add a `domain` field to `InferenceConfig`:

```rust
pub struct InferenceConfig {
    pub host: String,
    pub port: u16,
    pub model: String,
    pub timeout: Duration,
    pub domain: Option<String>,  // NEW: domain filter for RAG
}
```

Modify `decompose_with_llm()` to include domain context in the decomposition
prompt. When a domain is set, the LLM is told which domain it's working in
and generates domain-appropriate adversarial variants:

```rust
fn decompose_with_llm(config: &InferenceConfig, query: &str) -> Vec<AdversarialPrompt> {
    let domain_context = match config.domain.as_deref() {
        Some("cheatsheet") => "You are decomposing a query about cheatsheets and reference documentation.",
        Some("methodology") => "You are decomposing a query about project methodology and discipline rules.",
        Some("code") => "You are decomposing a query about source code and implementation.",
        Some("spec") => "You are decomposing a query about OpenSpec specifications.",
        _ => "You are decomposing a general project query.",
    };
    // ... include domain_context in the prompt
}
```

### 2B. Add domain-aware synthesis

**File**: `crates/tillandsias-plan/src/pipeline.rs`

Add a `synthesize_with_rag()` function that:

1. Embeds the query via `/v1/embeddings`
2. Retrieves top-k from the domain-specific index via `spec-retrieve --domain <domain>`
3. Synthesizes the answer using a domain-specific system prompt
4. Builds a verified citation envelope

Each domain gets a distinct synthesis prompt:

| Domain | System Prompt |
|--------|--------------|
| cheatsheet | "You are the cheatsheet expert. Answer using ONLY the retrieved cheatsheet sections. Be concise and reference specific cheatsheet entries." |
| methodology | "You are the methodology expert. Answer using ONLY the retrieved methodology sections. Cite YAML paths." |
| code | "You are the code expert. Answer using ONLY the retrieved code sections. Cite file:line references." |
| spec | "You are the spec expert. Answer using ONLY the retrieved spec sections. Cite section names." |

### 2C. Wire domain into the pipeline dispatch

**File**: `crates/tillandsias-plan/src/pipeline.rs` (run_pipeline)

The pipeline now:
1. Classifies the query tier (deterministic)
2. Determines the domain from the query or config
3. LLM decomposes with domain context
4. Trims variants to tier budget
5. Dispatches concurrently
6. Each dispatch includes domain-specific RAG context
7. CRDT collects validated responses

### 2D. Add domain-aware CLI subcommand

**File**: `crates/tillandsias-plan/src/main.rs`

Add `--domain` flag to `pipeline` subcommand:

```bash
tillandsias-plan pipeline --domain cheatsheet "How do I use podman?"
tillandsias-plan pipeline --domain code "How is the inference tier determined?"
```

---

## Phase 3: Domain-Specific Commit Hooks

### 3A. Extend post-commit-expert-refresh.sh

**File**: `scripts/hooks/post-commit-expert-refresh.sh`

Add domain-specific re-indexing based on which files changed:

```bash
# L1 Domain-specific re-index
_changed_files="$(git diff --name-only HEAD~1 HEAD 2>/dev/null || true)"
_domains_to_reindex=""

# Cheatsheet domain
if echo "$_changed_files" | grep -q '^cheatsheets/'; then
    _domains_to_reindex="$_domains_to_reindex cheatsheet"
fi

# Methodology domain
if echo "$_changed_files" | grep -q '^methodology/'; then
    _domains_to_reindex="$_domains_to_reindex methodology"
fi

# Code domain
if echo "$_changed_files" | grep -qE '^(crates|scripts|images)/'; then
    _domains_to_reindex="$_domains_to_reindex code"
fi

# Spec domain
if echo "$_changed_files" | grep -q '^openspec/'; then
    _domains_to_reindex="$_domains_to_reindex spec"
fi

# Re-index affected domains in parallel
for domain in $_domains_to_reindex; do
    (scripts/spec-index-ensure.sh --domain "$domain" >> "$_log" 2>&1 &) 
done

# Always rebuild combined index (backward compat)
(scripts/spec-index-ensure.sh >> "$_log" 2>&1 &)
```

### 3B. Add nomic-embed-text model pull

**File**: `scripts/dev-inference-ensure.sh`

Ensure the embedding model `nomic-embed-text` is pulled alongside the
generation model. Currently only `qwen2.5:0.5b` is pulled. Add:

```bash
# Pull embedding model for RAG
if ! have_model "$EMBED_MODEL"; then
    pull_model "$EMBED_MODEL"
fi
```

---

## Phase 4: OpenCode "Local Experts" Prompt Mode

### 4A. Add prompt mode to forge OpenCode config

**File**: `images/default/config-overlay/opencode/config.json`

Add a `"prompt"` field with a `"Local Experts"` mode:

```json
{
  "prompt": {
    "modes": {
      "Local Experts": {
        "model": "ollama/qwen2.5:14b",
        "instructions": [
          "/home/forge/.config-overlay/opencode/instructions/local-experts.md"
        ]
      }
    }
  }
}
```

### 4B. Create local-experts.md instruction file

**File**: `images/default/config-overlay/opencode/instructions/local-experts.md`

```markdown
# Local Experts Mode

You are running in Local Experts mode. ALL queries are routed through the
local expert system with domain-separated RAG and adversarial decomposition.

## How it works

1. Your query is decomposed into adversarial variants by the local LLM.
2. Each variant is dispatched concurrently to the local inference endpoint.
3. Domain-specific RAG retrieves relevant context from cheatsheets,
   methodology, code, or specs — each domain has its own embedding index.
4. Responses are collected via CRDT deduplication.
5. The final answer is a cited envelope with domain-specific provenance.

## Available expert domains

- **Cheatsheet Expert**: Reference documentation, tool usage, syntax
- **Methodology Expert**: Project discipline, rules, workflow
- **Code Expert**: Source code, implementation details
- **Spec Expert**: OpenSpec specifications, design decisions

## Query routing

Use the MCP tools to query experts:
- `spec_answer` for cross-domain queries
- `plan_answer` for plan/status queries
- `methodology_ask` for methodology questions
- `plan_decompose` + `plan_collect` for adversarial decomposition

## Rules

- Always cite your sources with file paths and section names.
- If the local model cannot answer confidently, say so — never hallucinate.
- Domain separation is enforced: cheatsheet answers never cite code, and
  vice versa.
```

### 4C. Add to dev host OpenCode config

**File**: Create `.opencode/opencode.json` in the repo root

```json
{
  "$schema": "https://opencode.ai/config.json",
  "autoupdate": false,
  "prompt": {
    "modes": {
      "Local Experts": {
        "model": "ollama/qwen2.5:14b",
        "instructions": [".opencode/instructions/local-experts.md"]
      }
    }
  },
  "provider": {
    "ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Ollama (local)",
      "options": {
        "baseURL": "http://127.0.0.1:11434/v1"
      },
      "models": {
        "qwen2.5:14b": { "name": "Qwen 2.5 14B (local)" },
        "qwen2.5:0.5b": { "name": "Qwen 2.5 0.5B (local)" },
        "nomic-embed-text": { "name": "Nomic Embed Text (local)" }
      }
    }
  }
}
```

### 4D. Create dev host local-experts.md

**File**: `.opencode/instructions/local-experts.md`

Same content as the forge version but with `127.0.0.1:11434` instead of
`inference:11434`.

---

## Phase 5: Update Meta-Orchestration Skill

### 5A. Add local expert query to cycle start

**File**: `.claude/skills/meta-orchestration/SKILL.md`

Add a new step after "Record context" and before "git fetch":

```markdown
### Local Expert Query (NEW)

Before claiming work, query the local expert system to surface pending and
neglected work. This gives the cycle a project-aware starting point.

```bash
# Query all domains
tillandsias-plan pipeline --domain plan "What is pending for this project?"
tillandsias-plan pipeline --domain plan "What has been neglected and forgotten?"
tillandsias-plan pipeline --domain methodology "What methodology rules are being violated?"
```

Record the responses as context for the work-selection step. If the local
experts report findings that match existing plan packets, note the alignment.
If they surface new issues, file them as plan/issues/ work packets.
```

### 5B. Add local expert health check to start-of-cycle

**File**: `.claude/skills/meta-orchestration/SKILL.md`

In the "git fetch + guards" section, add:

```markdown
4a. **Local Expert Health Probe**: Verify the local inference endpoint is
    reachable (`curl http://127.0.0.1:11434/api/version`). If unreachable,
    log a warning but do NOT block the cycle — fall back to filesystem-only
    expert queries. If reachable, verify the embedding model is available
    (`curl $EMBED_ENDPOINT/v1/models`).
```

### 5C. Add local expert query to cycle metrics

**File**: `scripts/cycle-metrics.sh`

Add metrics for local expert usage:
- `local_expert_queries`: number of pipeline queries this cycle
- `local_expert_success_rate`: percentage of queries that returned cited answers
- `local_expert_avg_latency_ms`: average pipeline latency

---

## Phase 6: Verify & Test

### 6A. Unit tests

- `spec.rs`: test `domain_of_root()` for all roots
- `pipeline.rs`: test `decompose_with_llm()` includes domain context
- `pipeline.rs`: test `InferenceConfig` with domain field

### 6B. Integration test

```bash
# Start ollama
OLLAMA_MODELS=~/.local/share/ollama ~/.local/bin/ollama serve &

# Test domain-separated decompose
TILLANDSIAS_INFERENCE_MODEL=qwen2.5:14b \
TILLANDSIAS_INFERENCE_ENDPOINT=http://127.0.0.1:11434 \
./target/release/tillandsias-plan pipeline --domain cheatsheet \
  "How do I use podman for testing?"

# Test domain-separated decompose for code
TILLANDSIAS_INFERENCE_MODEL=qwen2.5:14b \
TILLANDSIAS_INFERENCE_ENDPOINT=http://127.0.0.1:11434 \
./target/release/tillandsias-plan pipeline --domain code \
  "How is the inference tier determined?"
```

### 6C. End-to-end test

```bash
# Full pipeline with domain separation
TILLANDSIAS_INFERENCE_MODEL=qwen2.5:14b \
TILLANDSIAS_INFERENCE_ENDPOINT=http://127.0.0.1:11434 \
./target/release/tillandsias-plan pipeline --domain plan \
  "What's pending for this project, and what has been neglected and forgotten?"
```

---

## File Change Summary

| File | Change |
|------|--------|
| `crates/tillandsias-plan/src/spec.rs` | Add `CORPUS_DOMAINS`, `domain_of_root()` |
| `crates/tillandsias-plan/src/pipeline.rs` | Add domain to InferenceConfig, domain-aware decompose, RAG synthesis |
| `crates/tillandsias-plan/src/main.rs` | Add `--domain` flag to pipeline/decompose subcommands |
| `scripts/spec-index-ensure.sh` | Support `--domain` for per-domain indexing |
| `scripts/hooks/post-commit-expert-refresh.sh` | Domain-specific re-indexing on commit |
| `scripts/dev-inference-ensure.sh` | Pull nomic-embed-text embedding model |
| `images/default/config-overlay/opencode/config.json` | Add "Local Experts" prompt mode |
| `images/default/config-overlay/opencode/instructions/local-experts.md` | NEW: Local Experts instructions |
| `images/default/config-overlay/mcp/lib-dev-env.sh` | Add domain index path helpers |
| `.opencode/opencode.json` | NEW: Dev host OpenCode config with Local Experts mode |
| `.opencode/instructions/local-experts.md` | NEW: Dev host Local Experts instructions |
| `.claude/skills/meta-orchestration/SKILL.md` | Add local expert query at cycle start |
| `.opencode/skills/meta-orchestration/SKILL.md` | Same updates (mirrored) |
| `scripts/cycle-metrics.sh` | Add local expert metrics |
