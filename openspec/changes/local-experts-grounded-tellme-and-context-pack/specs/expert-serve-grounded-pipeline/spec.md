## ADDED Requirements

### Requirement: tellme answers through the grounded pipeline

When `127.0.0.1:11436` answers, `tellme howto` and free-form `tellme about` SHALL send the question to expert-serve as an OpenAI-shaped chat completion with model id `cheatsheet` (howto) or `all` (about). The keyword-grep path SHALL run only when the port does not answer. Its prompt SHALL NOT tell the model to use general knowledge, and it SHALL use `TILLANDSIAS_INFERENCE_MODEL` when that variable is set.

#### Scenario: expert-serve is up

- **WHEN** expert-serve is listening and the user runs `tellme howto "run a database container"`
- **THEN** tellme sends exactly one `/v1/chat/completions` request with model `cheatsheet` and prints the grounded answer or the typed refusal

#### Scenario: expert-serve is down

- **WHEN** the port is closed
- **THEN** tellme uses the grep fallback, its prompt contains no "general knowledge" text, and the request names `TILLANDSIAS_INFERENCE_MODEL` if that is set

### Requirement: a project-derived context pack leads every synthesis prompt

At forge launch, the system SHALL write `.forge-expert-context.md` of at most 4800 bytes. Its contents SHALL be:

- the universal forge constraints, always;
- the project's identity, branch-discipline level and declared agent instructions (`CLAUDE.md`/`AGENTS.md`, methodology), read from that project;
- Tillandsias-specific rules, only when the project is Tillandsias.

The pack SHALL contain no timestamp or per-query text. Every synthesis system prompt, from both `domain_synthesis_prompt` and tellme, SHALL begin with the pack's exact bytes, followed by the retrieved chunks.

#### Scenario: a forge runs a project that is not Tillandsias

- **WHEN** a forge launches on a project at discipline level 0 that has an `AGENTS.md` and no methodology
- **THEN** the pack names level 0, includes an excerpt of the `AGENTS.md`, includes the universal forge constraints, and contains no Tillandsias branch rule such as `linux-next` or `work/<order>`

#### Scenario: prefix reuse

- **WHEN** two different questions are synthesised in one forge
- **THEN** both system prompts begin with the same bytes, and those bytes equal the pack

### Requirement: the forge's hard constraints are retrievable

`cheatsheets/runtime/forge-constraints.md` SHALL state the forge's hard constraints and SHALL be listed in `cheatsheets/INDEX.md`. The constraints are:

- rootless podman with all capabilities dropped;
- no docker and no nested container daemon;
- a tmpfs workspace;
- egress only through the enclave proxy;
- inference at `inference:11434`;
- push through the git mirror.

#### Scenario: a container question

- **WHEN** an agent asks the cheatsheet expert "how do I run docker in the forge"
- **THEN** a chunk from `forge-constraints.md` is among the top three retrieved, and the answer does not recommend `docker run`

### Requirement: the Quick tier does not decompose

`run_grounded` SHALL skip adversarial query decomposition on both `LatencyTier::Immediate` and `LatencyTier::Quick`, and SHALL keep it on `LatencyTier::Fine`.

#### Scenario: a Quick query

- **WHEN** a query runs at the Quick tier
- **THEN** no decomposition request is made to the inference service

### Requirement: synthesis context is budgeted by model size

Every synthesis request SHALL run with an explicit context window of at least 8192 tokens for 7b-and-larger models, and a smaller window for 0.5b/3b models. The retrieved context SHALL be capped by a token budget:

- 0.5b/3b models: the pack plus at most 4 chunks;
- 7b/14b models: the pack plus at most 8 chunks.

#### Scenario: a small model

- **WHEN** a 0.5b model synthesises an answer and retrieval returned 8 chunks
- **THEN** the prompt holds the pack and at most 4 chunks, and stays within the token budget

### Requirement: expert-serve caches answers per index revision

expert-serve SHALL keep a bounded answer cache, refusals included, keyed by the resolved index entry revision, the model id and the normalised query. A change of index revision SHALL make every older entry unreachable.

#### Scenario: a repeated question

- **WHEN** the same question is asked twice against an unchanged index
- **THEN** the second answer is served without retrieval or synthesis
- **AND** after the index is refreshed, the same question is synthesised again

### Requirement: refusal by score margin and lexical overlap

The pipeline SHALL refuse a question as out of coverage when either:

- the margin between the best retrieval score and the median of the top-k is below its calibrated threshold; or
- no content word of the query occurs in the best chunk.

The absolute floor SHALL remain a hard lower bound. The margin thresholds SHALL be adopted only on a recorded calibration run over `scripts/refusal-calibration/*`.

#### Scenario: a flat top-k

- **WHEN** the top-k scores are all high but nearly equal
- **THEN** the pipeline returns a typed out-of-coverage refusal instead of an answer
