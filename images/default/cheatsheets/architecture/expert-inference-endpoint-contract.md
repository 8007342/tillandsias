---
tags: [experts, inference, endpoints, mcp, fail-loud, tiers]
languages: [rust, bash]
since: 2026-08-29
last_verified: 2026-08-29
sources:
  - plan/index.yaml order:718-ja7g
  - plan/index.yaml order:920-pxg6
  - plan/index.yaml order:760-hzi4
  - crates/tillandsias-plan/src/pipeline.rs
  - crates/tillandsias-plan/src/experts_probe.rs
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
---

# The expert inference endpoint contract

**Use when**: wiring a dev host for the expert tiers, or working out why spec_answer refuses while a local model is plainly running.

Which endpoint variable unlocks which expert tier, the two shapes that fail
silently (`https://` and an Ollama root url), and the one probe that says what is
actually live on this host.

**Order 718-ja7g. Measured on lenovinha (Fedora Silverblue) 2026-08-29 against a
live Ollama serving `qwen2.5:0.5b` and `nomic-embed-text`.** Every claim below
was executed, not read off the source. Where a figure came from reading code,
it says so.

## Why this file exists

Three variables were **read in five places and written in none**:
`TILLANDSIAS_INFERENCE_ENDPOINT` (`semantic_expert.rs`, `lib-inference-state.sh`,
`project-info.sh`), `TILLANDSIAS_EMBED_ENDPOINT` and
`TILLANDSIAS_SPEC_EXPERT_ENDPOINT` (`pipeline.rs`, `forge-plan.sh`). A host could
not satisfy the contract because nothing stated what satisfying it meant.

## The tiers

| Tier | What it does | Needs | If missing |
|------|--------------|-------|------------|
| **L0** | `plan/`, `methodology/`, spec envelope lookups | **nothing** — reads the working tree at query time | never missing |
| **L1** | retrieval over the prose corpus | **both** `TILLANDSIAS_EMBED_ENDPOINT` **and** a built spec index | grounded pipeline refuses typed (`confidence=unsupported`); the raw model is **not** a fallback |
| **L2** | synthesis, adversarial decomposition | a chat-completions base | no synthesis; L0 and L1 unaffected |

**L0 always answers, with citations, on a host with no endpoint at all.** That is
the contract's floor and it is guarded by a test
(`experts_probe::tests::l0_is_ready_even_with_nothing_configured`) and verified
end to end — `tillandsias-plan answer "what is the current Direction?"` returns a
cited answer with every endpoint variable unset. Degradation here is
*silent-free*, never *answer-free*.

L2 without L1 is a real, supported state. The probe reports the tiers
independently rather than as a ladder.

## The variables

| Variable | Shape | Feeds |
|----------|-------|-------|
| `TILLANDSIAS_EMBED_ENDPOINT` | **`/v1` base** | L1 retrieval. Also the default for the synthesis base. |
| `TILLANDSIAS_SPEC_EXPERT_ENDPOINT` | **`/v1` base** | L2 synthesis. |
| `TILLANDSIAS_INFERENCE_ENDPOINT` | **root url**, no `/v1` | L2 only, via `+ "/v1"`. |
| `TILLANDSIAS_INFERENCE_MODEL` | model id | synthesis model. Default `qwen2.5:0.5b`. |
| `TILLANDSIAS_EMBED_MODEL` | model id | embedding **fallback**; the index entry's own `.model` marker wins. |

Precedence, read from `InferenceConfig::default` (`pipeline.rs`) rather than
restated — a second copy of a precedence chain drifts, and a drifted diagnostic
reports a configuration the engine does not use:

- **embed_base** ← `TILLANDSIAS_EMBED_ENDPOINT`. **No fallback.** Unset means no L1.
- **synth_base** ← `TILLANDSIAS_SPEC_EXPERT_ENDPOINT` → embed_base →
  `TILLANDSIAS_INFERENCE_ENDPOINT` + `/v1` → `http://inference:11434/v1`.

### The trap that follows from that asymmetry

`TILLANDSIAS_INFERENCE_ENDPOINT` **alone does not unlock retrieval.** It feeds
`synth_base` and nothing feeds `embed_base`. Measured:

```
TILLANDSIAS_INFERENCE_ENDPOINT=http://127.0.0.1:11434   # root url, real Ollama, 2 models
  lib-inference-state.sh : READY (models=2, warm=nomic-embed-text,qwen2.5:0.5b)
  experts-probe          : l1=unset  l2=ready
```

Both probes are truthful about what they asked. `inference_state=ready` answers
*"is there an Ollama"*, **not** *"can the experts work"*. Before 718-ja7g nothing
said so, and the optimistic answer was the one an operator was most likely to
read.

## Two hard constraints

### 1. The transport is `http://` only

`pipeline::parse_base` — the crate's single URL parser, used by every model call
— begins `url.strip_prefix("http://")?`. An `https://` base yields `None` at the
first hop, before any request. This is not local to one call site; it is the
transport the whole crate speaks.

Previously this failed **silently**: the caller fell back to a default endpoint
the operator never chose. It is now named:

```
$ TILLANDSIAS_EMBED_ENDPOINT=https://host/v1 tillandsias-plan experts-probe
experts_probe: l0=ready l1=scheme-unsupported l2=ready … advice=embed-scheme-https: this crate
dispatches over http:// only (pipeline::parse_base); an https:// base is dropped before any
request is made
```

### 2. `/v1` vs the root — the most common live failure

Ollama serves its **native** api at the root (`/api/tags`, `/api/generate`) and an
**OpenAI-compatible** api under `/v1` (`/v1/models`, `/v1/chat/completions`,
`/v1/embeddings`). This crate speaks only the OpenAI shape.

So `http://host:11434` is a perfectly healthy Ollama **and** a broken value for
these variables. Every root-probing health check on the host says READY while
the expert path 404s. The probe names the distinction rather than reporting a
bare "did not answer", which would send the reader to inspect a server that is
fine:

```
$ TILLANDSIAS_EMBED_ENDPOINT=http://127.0.0.1:11434 tillandsias-plan experts-probe
… advice=embed-unreachable: http://127.0.0.1:11434 has no /v1 path — if that is an Ollama ROOT
url its OpenAI-compatible base is http://127.0.0.1:11434/v1 (the root serves Ollama's NATIVE
api, which this crate does not speak); set the variable to the /v1 base
```

### Not a constraint any more

718-ja7g was filed citing `addr.parse::<SocketAddr>()` in `semantic_expert.rs`,
which accepted only numeric `IP:port` and so made hostnames — including the
enclave's own `inference:11434` — silently unusable. **Order 920-pxg6 (D6)
removed it**; dispatch now goes through `pipeline::http_post_json`, which
resolves hostnames via `to_socket_addrs`. Asserted by test
(`hostname_endpoints_are_usable_the_socketaddr_trap_is_gone`) rather than trusted
to the comment that claims it.

## The probe

```
$ tillandsias-plan experts-probe
experts_probe: l0=ready l1=ready l2=ready embed=http://127.0.0.1:11434/v1 synth=http://127.0.0.1:11434/v1 advice=-
```

One line. Per-tier closed vocabulary: `ready | unset | unreachable | no-index |
scheme-unsupported | malformed | unknown`. `advice=` carries **one** next
action — never a list, because a diagnostic offering three suggestions invites
trying all three, and two will be wrong.

**Exit code is advisory, not a gate**: `0` when every configured tier answers, `1`
otherwise. A dev host with no endpoint is a normal supported state, so a caller
treating non-zero as "broken" is reading it wrong — the *line* is the answer.

Both MCP servers consume it through `images/default/lib-experts-probe.sh` instead
of deriving reachability themselves:

- `forge-plan.sh` — its `spec_answer` refusals carry the probe's advice, so a
  missing or root-url embed base explains itself.
- `project-info.sh` — synthesis refusals now report `experts_l1=` / `experts_l2=`
  alongside `inference_state=`, keeping the two questions visibly distinct.

A missing helper or a pre-718-ja7g binary reports `unknown` with a named reason
(`probe-binary-missing`, `probe-subcommand-missing`), never `unset` and never
`ready`. An absent probe reporting a verdict is the lie order 531 recorded as
`experts: ready`.

### L1 needs *both* halves, and they fail independently

An answering embeddings endpoint is **not** sufficient. Measured on lenovinha
2026-08-29:

```
$ env -u FORGE_SPEC_INDEX_DIR scripts/spec-index-ensure.sh --where
spec-index:serving=/var/home/…/volumes/tillandsias-spec-index-tillandsias/_data
spec-index:serving-exists=yes
spec-index:entries=0

$ tillandsias-plan experts-probe
experts_probe: l0=ready l1=no-index l2=ready … advice=no-spec-index: the embeddings endpoint
answers but no usable index is published (needs vectors.jsonl) — build it with
scripts/spec-index-ensure.sh; L1 retrieval needs BOTH an endpoint and an index
```

`serving-exists=yes` with `entries=0` is a **cold tier, not a lost index**: the
serving root is present and nothing has ever been published into it.

This case is also a correction to this probe's own first cut, which reported
`l1=ready` from endpoint reachability alone — the identical over-optimism it
exists to expose in `lib-inference-state.sh`. A diagnostic is not exempt from
the failure mode it diagnoses.

## Recipes

```bash
# Ollama on the host, both tiers (the /v1 suffix is the whole trick)
export TILLANDSIAS_EMBED_ENDPOINT=http://127.0.0.1:11434/v1
export TILLANDSIAS_SPEC_EXPERT_ENDPOINT=http://127.0.0.1:11434/v1
export TILLANDSIAS_EMBED_MODEL=nomic-embed-text

# Inside the enclave, the DNS alias works — hostnames resolve since 920-pxg6
export TILLANDSIAS_EMBED_ENDPOINT=http://inference:11434/v1

# L1 also needs an index — the endpoint alone is half the tier
scripts/spec-index-ensure.sh

# Verify, always, rather than assuming
tillandsias-plan experts-probe
```
