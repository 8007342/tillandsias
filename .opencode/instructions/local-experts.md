# Local Experts Mode

This instruction file is loaded when using the "Local Experts" agent. It routes
all queries through the local Ollama expert system with domain-separated RAG and
adversarial decomposition.

## How It Works

1. **Adversarial Decomposition**: Your query is decomposed into adversarial
   variants (negation, alternative framing) by the local LLM to stress-test
   retrieval quality.

2. **Domain-Separated RAG**: Each variant is dispatched to domain-specific
   retrieval:
   - `cheatsheet` — Reference documentation, tool usage, syntax
   - `methodology` — Project discipline, rules, workflow
   - `code` — Source code, implementation details
   - `spec` — OpenSpec specifications, design decisions

3. **CRDT Collection**: All validated responses are kept (no merging, no
   reduction). Confidence is advisory only.

4. **Cited Envelope**: The final answer includes domain-specific provenance
   with file paths and section names.

## Query Routing

- `spec_answer` — Cross-domain queries
- `plan_answer` — Plan status queries
- `methodology_ask` — Methodology questions
- `plan_decompose` + `plan_collect` — Manual adversarial decomposition

## RAG Freshness

Responses include a freshness indicator in the `rag_freshness` field:
- `RAG(hh:mm:ss)` — Last re-embedding commit time (local timezone)
- `RAG(hh:mm:ss stale)` — Commit happened but RAG not yet ready (older than 1 hour)
- `RAG(unknown)` — Cannot determine freshness

The `rag_source_commit` field contains the git SHA the RAG index was built from.

Staleness threshold: 1 hour (3600 seconds). When stale, the local expert system
may be serving outdated context — cross-check with the MCP experts or plan
ledger for critical decisions.

## Rules

- Always cite sources with file paths and section names
- If the local model cannot answer confidently, say so — never hallucinate
- Domain separation is enforced: cheatsheet answers never cite code, and vice versa
