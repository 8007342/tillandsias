# expert-serve-grounded-pipeline

## ADDED Requirements

### Requirement: R1 — one pipeline, two front-ends
The grounded expert pipeline SHALL exist as exactly one function
(`tillandsias_plan::pipeline::run_grounded`), and both the `expert-serve`
HTTP endpoint and the `pipeline` CLI arm SHALL obtain their answers by
calling it. No front-end may carry its own retrieval, synthesis, validation,
or refusal logic.

#### Scenario: CLI and server agree
- **WHEN** the same query, domain, index entry, and endpoint configuration
  are presented to `tillandsias-plan pipeline` and to
  `POST /v1/chat/completions` on `expert-serve`
- **THEN** both produce an envelope from the same `run_grounded` call path —
  the same citations-only-if-used filter, the same typed refusal grammar,
  the same freshness frame

#### Scenario: no divergent copy
- **WHEN** the crate is searched for grounding logic
- **THEN** `run_grounded` is the only function that turns retrieved chunks
  plus model prose into an answer envelope for these front-ends

### Requirement: R2 — retrieval only from the published index
The pipeline SHALL retrieve exclusively from a published content-addressed
spec-index entry resolved through the 879-gidx ladder
(`spec_index::SpecIndexEntry`), and SHALL refuse — typed, before any model
request — when no usable entry resolves or when the entry holds no chunks in
the requested domain.

#### Scenario: no usable entry
- **WHEN** no rung of the resolution ladder names a directory containing
  `vectors.jsonl`
- **THEN** the pipeline returns `confidence=unsupported` with an
  `unsupported: `-prefixed answer naming the missing index, `citations=[]`,
  and no model endpoint is contacted

#### Scenario: empty domain
- **WHEN** the resolved entry contains chunks, but none whose kind matches
  the requested domain
- **THEN** the pipeline returns the typed refusal naming the domain and the
  entry directory, and no model endpoint is contacted

#### Scenario: arity refusal
- **WHEN** the entry's vector count does not equal its chunk count
- **THEN** loading refuses (the index is stale) rather than retrieving from
  a shifted pairing

### Requirement: R3 — answer or typed refusal, no third state
Every pipeline outcome SHALL be either an envelope whose citations
verifiably support it, or `Envelope::unsupported` with the pinned
`unsupported: <reason>` answer, `confidence=unsupported`, and
`citations=[]`. There SHALL be NO code path that returns raw model prose
without citations — no raw-model fallback under any failure.

#### Scenario: synthesis endpoint dead
- **WHEN** retrieval succeeds but every synthesis request fails or times out
- **THEN** the pipeline returns the CITED retrieval-only digest (keys
  present by construction), never uncited prose and never a crash

#### Scenario: embedding endpoint dead
- **WHEN** the embedding endpoint is unset or unreachable
- **THEN** the pipeline returns the typed refusal naming the embedding gap

#### Scenario: the dichotomy is machine-checkable
- **WHEN** any envelope leaves the pipeline
- **THEN** `confidence != unsupported` implies `citations` is non-empty, and
  `confidence == unsupported` implies the answer starts with
  `unsupported: ` and `citations` is empty

### Requirement: R4 — citations survive only if used
Per-variant envelopes SHALL be built through the `spec::build_envelope`
family, which keeps a retrieved chunk's citation ONLY when the answer prose
actually contains its key; an answer that used no retrieved key SHALL NOT
ship those citations as decoration.

#### Scenario: subset usage
- **WHEN** synthesis over retrieved chunks A and B produces prose that
  mentions only A's key
- **THEN** the envelope carries exactly A's citation, and B's is stripped

#### Scenario: zero usage falls back cited
- **WHEN** synthesis produces prose that mentions no retrieved key
- **THEN** the prose is discarded and the cited retrieval-only digest (whose
  keys are present by construction) is served instead

### Requirement: R5 — freshness from the entry's own frame
The envelope's freshness SHALL be built from the resolved index entry: the
`.commit` marker (801-g9nn, hex-validated; the literal `unknown` when the
entry is frameless) as `source_commit`, and the entry's `chunks.jsonl`
mtime as `indexed_at`. Citations SHALL be completed with
`with_default_citation_commit(entry.commit)` BEFORE any emit-path HEAD
stamp. `Freshness::for_corpus` over the process's own checkout SHALL NOT be
used on this path.

#### Scenario: entry commit propagates
- **WHEN** the entry records `.commit` = C and the process's HEAD is H ≠ C
- **THEN** the envelope reports `freshness.source_commit = C` and every
  citation's commit is C, never H

#### Scenario: frameless entry is honest
- **WHEN** the entry records no `.commit`
- **THEN** `freshness.source_commit` is the literal `unknown` — never a
  fabricated sha, never this process's HEAD

### Requirement: R6 — OpenAI-compatible loopback endpoint
`tillandsias-plan expert-serve` SHALL serve an OpenAI-compatible surface on
127.0.0.1 (default port 11436): `POST /v1/chat/completions` accepting the
model id as the domain selector (all|spec|code|methodology|cheatsheet), in
non-stream and `stream:true` SSE forms (the stream terminated by
`data: [DONE]`), and `GET /v1/models` listing exactly those five ids; any
other route answers 404 with a JSON error body. Refusal envelopes SHALL be
rendered VERBATIM as the completion content with HTTP 200 and
`finish_reason: stop`. The process SHALL serve until stdin EOF (immediate
exit under `</dev/null`), print one pinned line on stderr at start, and
write nothing to stdout.

#### Scenario: completion shape
- **WHEN** a client POSTs `/v1/chat/completions` with `model: "spec"` and a
  user message
- **THEN** the response is `object: "chat.completion"` with
  `choices[0].message.role = "assistant"`, `finish_reason: "stop"`, and a
  top-level `rag_source_commit` equal to the served entry's `.commit`

#### Scenario: streaming shape
- **WHEN** the same request carries `stream: true`
- **THEN** the response is `text/event-stream` whose data frames carry
  `chat.completion.chunk` objects and whose final frame is `data: [DONE]`

#### Scenario: refusal over HTTP
- **WHEN** the pipeline refuses (e.g. no embedding endpoint)
- **THEN** the HTTP status is 200 and `choices[0].message.content` begins
  `unsupported: ` — the typed refusal verbatim, never an HTTP error

#### Scenario: stdin EOF lifetime
- **WHEN** `expert-serve` is started with stdin at EOF
- **THEN** it exits promptly, keeping capability-sweep litmus runs fast
