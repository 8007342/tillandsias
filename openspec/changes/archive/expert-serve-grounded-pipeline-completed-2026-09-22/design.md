# Design: expert-serve — one grounded pipeline, two front-ends

## Context

Order 920-pxg6, provenanced by the 687eb6d57 facade audit (see proposal.md).
The crate already owns every grounded primitive — chunking, cosine top-k,
`build_envelope*` with the only-if-used citation filter, `Envelope`'s
answer-or-refusal constructors, and the 879-gidx index resolution ladder in
groundtruth.rs — but the adversarial pipeline shipped beside them without
touching any of them. The shell `spec_answer` path in forge-plan.sh is the
working reference implementation of grounded synthesis; this change gives
Rust the same pipeline once, and puts two front-ends on it.

Operator decisions recorded 2026-08-28: the nix cache stays per-host until a
shared cache is designed; BigPickle's Lua expert code is salvage (keep what
is useful, discard freely); Lua's sanctioned future is litmus steps
(902-5bf9, entry-gated on portability evidence, NOT this change).

## Goals / Non-Goals

Goals:

- ONE pipeline function both front-ends call; no divergent grounding logic.
- Retrieval only from the published content-addressed index entry.
- Answer-or-typed-refusal dichotomy with no raw-model escape hatch.
- Honest freshness: the entry's own frame, never this process's HEAD.
- An OpenAI-compatible loopback endpoint OpenCode can consume unmodified.

Non-Goals:

- The 902-5bf9 litmus-steps-in-Lua form (entry-gated on mlua portability
  evidence from darwin/msys lanes; deliberately untouched here).
- A fleet-shared index (the index stays per-host, like the nix cache,
  until a shared design exists).
- Restoring the phantom Lua sandbox surface (`expert.query`, `fs.read`) —
  docs now describe only what exists.
- Streaming synthesis through to SSE token-by-token: the pipeline completes,
  then the SSE front-end frames the finished answer.

## Decisions

### D1 — refusals reuse the pinned grammar, rendered verbatim over HTTP

Every refusal is `Envelope::unsupported` — the pinned `unsupported: <reason>`
answer with `confidence=unsupported`, `citations=[]`, a real freshness block.
The HTTP front-end renders the refusal envelope's answer VERBATIM as
completion content with HTTP 200 and `finish_reason: stop`: to an OpenCode
consumer a refusal is a successful completion whose text is the typed
refusal, exactly as MCP consumers already see it. Every preflight failure
(no embedding endpoint, no index, empty domain, dead endpoints) takes this
path — never a 5xx, never an empty body, never a third state.

### D2 — freshness comes from the index entry, never from this process

`Freshness` is built from the resolved entry's `.commit` marker (801-g9nn;
hex-validated, `unknown` when the entry is frameless) plus the entry's
`chunks.jsonl` mtime. Citations are completed with
`with_default_citation_commit(entry.commit)` BEFORE any emit-path HEAD
stamp, so the entry's frame wins wherever the two differ.
`Freshness::for_corpus(repo)` — the 687eb6d57 stamp that presented this
process's HEAD as the frame of spans it never read — is banned from this
path.

### D3 — validation is Rust; Lua keeps tier/trim/collect

`validate.lua` promised validation and delivered dead code (a module table
the loader discards; no bridge ever called it). Validation logic belongs in
Rust where it is deterministic and testable: the pipeline re-verifies each
candidate envelope with `answer::verify` against the checkout root and
downgrades failures. `validate.lua` is DELETED along with its dead bridge
paths. Lua keeps what it actually does: `tier.lua` (classification made
reachable for all of immediate/quick/fine; budgets made REAL via
`tokio::time::timeout` around dispatch), `trim` and `collect.lua` (the
nil-answer crash fixed). `lua_runtime.rs` docs describe only the surface
that exists: the partial stdlib restriction actually applied, the two
bridge functions (`expert.log_info`, `expert.now_ms`), and the trusted-code
status of `lua/` — no phantom sandbox is re-promised.

### D4 — hand-rolled HTTP/1.1 server, loopback only, stdin-EOF lifetime

No new dependencies: a tokio `TcpListener` bound `127.0.0.1` (default port
11436, `--port`/`--root` accepted), hand-rolled request parsing on the
`crates/tillandsias-static-server` precedent. Bare invocation serves until
stdin EOF (a thread reads stdin; `</dev/null` exits immediately, which
keeps litmus:expert-capability-skew-honesty's invoke-every-token sweep
fast). Routes: `POST /v1/chat/completions` (non-stream JSON and
`stream:true` SSE ending `data: [DONE]`; the model id IS the domain:
all|spec|code|methodology|cheatsheet), `GET /v1/models` (the static five),
anything else a 404 JSON error. The index entry is re-resolved per request
(with an mtime-keyed cache), because `current` moves under long-lived
servers. One pinned stderr line on start; nothing ever on stdout.

### D5 — one function: `run_grounded`

`pub async fn run_grounded(runtime, entry, cfg, query) -> Envelope`, used by
BOTH the server and the rewritten `pipeline` CLI arm (whose dishonest
`for_corpus` stamp and hardcoded `validated:true`/`confidence:0.5`/
`citations:[]` paths are deleted). Stages: tier classify →
`decompose_with_llm` (fallback-to-original kept) → trim (the CPU floor) →
per-variant: embed the query → domain-filtered `spec::top_k` (k=6) →
synthesis over the retrieved `=== {key} ({path}) ===` context blocks via the
resurrected `domain_synthesis_prompt` → a per-variant envelope via
`spec::build_envelope_scored` (citations only-if-used) with
`retrieval_only_answer` as the cited fallback on synthesis failure → Rust
validation → collect merge → the best cited response, or
`Envelope::unsupported`. NO code path may return raw model prose without
citations: prose enters an envelope only through the only-if-used filter,
and a prose that used nothing falls back to the cited digest or refuses.

### D6 — one protocol, one client

ALL model calls (decomposition and synthesis) converge on
`POST {base}/chat/completions` via ONE HTTP client helper (the union of the
former pipeline.rs `query_inference_raw` and semantic_expert.rs
`query_inference`: hostname-resolving `to_socket_addrs`, read/write
timeouts, `Connection: close`). Embeddings post
`{TILLANDSIAS_EMBED_ENDPOINT}/embeddings` — the in-process twin of
forge-plan.sh's curl. Endpoint envs: `TILLANDSIAS_EMBED_ENDPOINT` (typed
refusal when unset), `TILLANDSIAS_SPEC_EXPERT_ENDPOINT` defaulting to the
embed endpoint. The embedding model prefers the index entry's `.model`
marker with `TILLANDSIAS_EMBED_MODEL` as the env fallback, and the
`search_query: ` prefix is applied iff the entry records a doc prefix.

DIVERGENCE FROM HISTORY, recorded: scripts/spec-index-ensure.sh's own
harness note (order 864-p2rk) documents that the historical shell query
path applied NO query prefix to any model — so prefixed entries were
queried unprefixed, a silent asymmetry. This pipeline instead keys the
query prefix on the entry's `.prefix` marker: an entry embedded with a doc
prefix gets `search_query: `-prefixed queries; an unprefixed entry gets
bare queries. Retrieval quality against prefixed entries changes (improves)
relative to the historical behavior, deliberately.

The default inference host is restored to `inference` (the enclave DNS
name) where 687eb6d57 had changed it to `127.0.0.1`; and the two panic
seams are fixed: the `json_start > json_end` slice in the decomposition
parser and the non-UTF-8-boundary `&query[..50]` truncation in the log
line.

### D7 — the index entry becomes public infrastructure

The private groundtruth.rs helpers — the 879-gidx resolution ladder
(exact-dir rungs healing over stale overrides, then root/current pointer
rungs: FORGE root, podman volume, XDG cache) and the 394d loader with the
vectors/chunks arity refusal — hoist into a public `spec_index` module as
`SpecIndexEntry { dir, chunks, vectors, commit (hex-validated), model,
prefix }` plus `load()`. groundtruth.rs delegates to it, so grade behavior
is byte-identical; the pipeline and the server read the SAME entry the
grader grades against.

### D8 — two retrieval floors, not one (darwin calibration, 2026-08-29)

Coverage and citation-worthiness are different questions and one scalar
cannot answer both. Measured on the darwin corpus (n=30 — calibrated for
this corpus, not settled): covered best-scores span 0.65–0.87, real
off-topic probes 0.48–0.60, so the original single 0.45 floor refused
NOTHING while raising it alone to 0.62 would also drop ~8% of good
covered citations. Decision: `TILLANDSIAS_RETRIEVE_REFUSAL_FLOOR`
(default 0.62) gates the BEST score — below it the variant is out of
coverage and never reaches synthesis; `TILLANDSIAS_RETRIEVE_MIN_SCORE`
(default 0.45) remains the per-chunk inclusion floor above it. The
retrieval-only digest additionally names WHICH of its three producers
fired (endpoint failed / prose cited no key / synthesis timed out inside
the tier budget) — the timed-out producer was measured wearing the
no-endpoint message on a host whose contract-satisfying model exceeds
the quick budget (927-2q4w owns the budget policy question).

## Risks / Trade-offs

- **mlua portability is an OPEN 902-5bf9 exit criterion.** This change keeps
  the mlua dependency (vendored Lua C build) for tier/trim/collect. If the
  darwin/msys lanes cannot produce portability evidence, 902-5bf9's
  entry gate fails and the Lua remnant here shrinks to Rust — the
  tier/trim/collect surfaces are deliberately thin enough to port in one
  sitting.
- **Index staleness under long-lived servers**: mitigated by per-request
  re-resolution (D4); a stale entry still serves its OWN frame honestly
  (D2), and `verify-answer`'s exit-3 stale verdict remains the reader-side
  backstop.
- **Small models paraphrase away section keys**, collapsing the only-if-used
  filter to the retrieval-only fallback often. Accepted: the fallback is
  cited and verifiable, which beats fluent uncited prose by construction.
- **Port 11436 collisions**: the server refuses to start (bind error on the
  pinned stderr line) rather than hunting ports; the forge lifecycle block
  is fail-soft, so a collision degrades the agent to MCP experts, never
  blocks launch.

## Migration

- The `pipeline` CLI arm now emits the ratified envelope instead of the
  ungrounded `{tier, ..., responses}` JSON. Both instruction files that
  described the old shape are rewritten in this change; no other consumer
  is documented anywhere in the tree.
- `local-experts` agents in both configs move from `ollama/qwen2.5:14b` to
  `tillandsias-experts/all`. When `expert-serve` is not running the agent's
  requests fail fast at connect; the rewritten prompt tells the agent to
  fall back to the forge-plan MCP tools.
- forge relaunch skew: a forge whose installed binary predates this change
  has no `expert-serve` subcommand; the lifecycle block probes
  `capabilities` output first and skips silently, and
  `expert_capability`'s skew line (order 569) already names the
  relaunch-required state.

## Open Questions

- Should the collect merge rank variants by citation score rather than
  first-cited? Deferred until groundtruth cases exist for multi-variant
  disagreement.
- Whether the forge overlay should also expose the endpoint to sibling
  containers (currently loopback-only inside the forge network namespace).
- Live OpenCode session verification (agent tool-disable support in the
  shipped OpenCode build) is an open item for the operator's next forge
  relaunch.
