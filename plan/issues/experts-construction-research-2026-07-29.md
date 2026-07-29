# DECISION RECORD: what an "expert" IS, mechanically (order 393, wave 2)

- Date: 2026-07-29
- Packet: `experts-construction-research` (order 393, kind: research, multi_cycle)
- Status: **decision proposed — awaiting Tlatoāni sign-off** (393's third exit
  criterion). Wave 1 (`plan/issues/experts-construction-decision-2026-07-17.md`)
  is SIGNED and stands except where amended in §7.
- Consumers: 394 (plan+methodology expert), 395 (OpenCode affordance),
  396 (refresh-on-commit), 397/401/402 (tiers), 457 (cheatsheet expert),
  400 (code expert), 456 (plan MCP), 458 (context hooks).
- Method: code survey at HEAD (linux-next) + two measurements taken on this
  host (§2). Every claim about existing code carries file:line.

---

## 0. The decision in one paragraph

**An expert is a cited retrieval surface behind an MCP tool. The model is an
optional last-mile prose renderer, never the knowledge store.** Experts are
built in three layers: **L0** a compiled Rust query engine over the corpora
that are already machine-readable (plan graph, methodology YAML paths,
cheatsheet frontmatter, spec `@trace` graph, code symbols via LSP); **L1** a
deterministic lexical retriever over prose that returns `file:line` spans;
**L2** an optional local model that is handed ONLY L0/L1 spans and whose output
is discarded if it cites nothing. For the **plan ledger the answer is "no model
at all"** — L0 already answers the flagship queries exactly, in 20 ms, with
zero VRAM (§2), and a paraphrase layer over exact data can only subtract. Rung
1 of 394 therefore ships **zero inference** and is unblocked by the entire
inference stack, the tier matrix, and order 486's cold-start races.

### Recommendation table

| Corpus | Size at HEAD | Construction | Model? | Build cost at launch | Owns |
|---|---|---|---|---|---|
| Plan ledger `plan/index.yaml` | 1.42 MB / 24 307 lines / 419 packets | **L0 only** — `tillandsias-plan` + `forge-plan.sh` MCP (both exist) | **NO** | 5.3 s compile, 0 s index | 394 r1, 456 |
| Methodology (`methodology.yaml` + `methodology/`) | 16 KB + 453 KB YAML | **L0** (YAML path query → block + `file:line`), L2 optional | NO for rung 1 | ~0 s (parse at query time) | 394 r1 |
| Specs + `@trace` graph | 167 specs, 1.30 MB | **L0** (trace graph) + **L1** for requirement prose | NO for rung 1 | seconds (index) | 400 |
| Cheatsheets | 266 files, 2.0 MB, structured frontmatter | **L1 primary** (frontmatter is L0-structured), **L2 earns its keep here** | YES (optional) | seconds (index) | 457 |
| Code | 195 `.rs`, 4.97 MB | **L0 via rust-analyzer/LSP** + git-trajectory L0, embeddings last | NO for rung 1 | LSP already in image | 400 |

**Rejected outright**: fine-tune / LoRA / any training (§1d), and
"Modelfile stuffing as the knowledge store" (§7 amendment).

---

## 1. Q1 — the four constructions, scored against our constraints

Scoring axes are the ones 393 asks for: launch build time (must be
seconds-to-low-minutes, ephemeral), accuracy + **citability**, hardware, and
NO-PYTHON feasibility (`methodology.yaml:169-181`, `tlatoani_hard_no_python`;
the base64 smuggling ban at `:186-202` closes the obvious loophole).

### (b) Compiled deterministic query tool + MCP — **RECOMMENDED, ships first**

This is not a proposal; it is 90 % built and measured.

- `crates/tillandsias-plan/src/lib.rs:155-163` `blocked_by` — the flagship
  query ("what is blocked by X") is a typed graph filter, not a similarity
  search. `:166-183` transitive closure, `:186-197` `ready(role)`,
  `:200-208` `milestone_children`, `:223-270` the invariant-core integrity
  check, `:385-449` the format-preserving validated edit module.
- Open-world by construction (`lib.rs:24-37`, `:312-330`): unknown fields
  survive; the schema is data loaded from the checkout (`:332-376`), so a
  ledger-shape change is a commit, never a rebuild of an expert.
- CLI surface: `crates/tillandsias-plan/src/main.rs:11-25`
  (`check|status|blocked-by|blocked-closure|ready|burndown|append-event`).
- MCP wrapper landed 2026-07-28 (a61aade2):
  `images/default/config-overlay/mcp/forge-plan.sh:82-89` exposes six tools;
  `:58-70` shells out to the binary; registered at
  `images/default/config-overlay/opencode/config.json:55-59`.

Scores: **build time 5.3 s** (measured, §2) and **0 s of index**; **accuracy
100 %** — the answer IS the data; **citable by construction** — every row is a
`packet_id` + `order` + `status` resolvable back to `plan/index.yaml`;
**hardware: none** (12.5 MB RSS, no GPU); **NO-PYTHON: native Rust**.
Freshness cost is **zero** — the engine reads the file at query time
(`lib.rs:60-65`), so it can never be stale, which is a property no index and no
model can offer at any price.

### (a) RAG / embeddings index served by the local model — **DEFER, not reject**

- Nothing in the tree can produce an embedding today: there is no embedding
  model baked (`images/inference/Containerfile:39-46` bakes only a model
  *directory*; `images/inference/entrypoint.sh:236` pulls `qwen2.5:0.5b` and
  nothing else) and no vector store in any crate. First run would have to pull
  ~270 MB through squid, on the same path that produced the documented
  ollama-manifest EOF class (`images/inference/entrypoint.sh:198-204`) and the
  order-486 cold-start race.
- Cost is not the embedding call, it is the **bookkeeping**: to be citable at
  all, every chunk must carry `path + line_start + line_end`. Once you have
  built that map you already have L1, and L1 answers without a model.
- NO-PYTHON: feasible but only as new Rust (no `sentence-transformers`, no
  `faiss`, no `chromadb` — all Python).
- **Verdict: embeddings are a strict *addition* on top of L1, purchased only
  when a graded query set shows lexical retrieval missing answers.** Buying
  them first inverts the evidence order and violates
  `monotonic_reduction_of_uncertainty_through_verifiable_constraints`.

### (c) Fine-tune / LoRA at launch — **REJECTED (now on hard grounds)**

Wave 1 rejected this on correctness and cost. Wave 2 adds a **policy-hard**
reason the 2026-07-17 record did not have: every practical training toolchain
(torch, peft, transformers, unsloth, axolotl) is Python, and
`methodology.yaml:169-181` forbids Python for anything committed or
recurring; `:186-202` forbids smuggling it. `llama.cpp`'s C++ finetune path is
the only non-Python option and it produces a model that **memorises instead of
citing** — the exact failure mode our evidence invariant
(`methodology.yaml:151` `traces_and_litmus_tests_provide_falsifiable_evidence`)
exists to prevent. Reject permanently, not "defer".

### (d) Hybrid deterministic + embeddings — **the endpoint, reached incrementally**

The right shape, but it is where §0's L0+L1+L2 lands *after* L1 is graded.
Do not start here.

### Cross-cutting: when the answer is "no model needed" — the plan ledger, argued

1. The query classes agents actually ask (`blocked-by`, `ready`, `closure`,
   `burndown`, `status`) are **joins and filters over a typed graph**, already
   implemented exactly (`lib.rs:155-208`). There is no linguistic ambiguity to
   resolve.
2. The corpus is ~350 k tokens. **No tiny model can hold it.** Therefore every
   model-based construction is *a retrieval system with a paraphrase layer
   bolted on* — you pay for the retrieval either way.
3. The paraphrase layer can only introduce error on data that is already exact,
   and the only thing it adds — natural-language phrasing — is done better by
   the caller, which is a large cloud model (`config.json:6`
   `opencode/big-pickle`).
4. Freshness: L0 is free; any index or model must be refreshed (order 396).
5. Ephemerality: L0 has nothing to tear down.

**PLAN EXPERT = MCP over the compiled engine. The name "expert" is kept as the
agent-facing affordance; no model is built for it.** This should be reflected
in 394's outcome text by the coordinator (this agent does not edit
`plan/index.yaml`).

---

## 2. Measurements taken on this host (2026-07-29, linux-next @ e57b6a3d)

| Measurement | Result | How |
|---|---|---|
| Cold build of the plan engine, warm cargo registry | **5.33 s** | `CARGO_TARGET_DIR=<scratch> cargo build --release -p tillandsias-plan` |
| `blocked-by 394` over the full 24 307-line ledger | **0.02 s wall, 12.5 MB RSS** (3 runs, identical) | `/usr/bin/time ./target/release/tillandsias-plan blocked-by 394` |
| `check` (parse + id uniqueness + referential soundness, 419 packets) | **0.02 s** | `tillandsias-plan check` |
| `ready linux` | **0.02 s** | `tillandsias-plan ready linux` |
| Binary size | 585 KB | `ls -la target/release/tillandsias-plan` |
| Corpus sizes | plan 1.42 MB; methodology 16 KB + 453 KB; cheatsheets 266 files / 2.0 MB; specs 167 / 1.30 MB; code 195 `.rs` / 4.97 MB | `wc -c` / `find` |

Against 393's "budget: experts may finish building ASYNC after launch" — the
plan expert does not need async. It is a 5-second compile that can be warm-cached.

**Still to measure (394.4 owns it)**: L1 index build time over cheatsheets +
specs, and — only if L2 is enabled — first-token latency of a 0.5B model on
the CPU tier. Those are the residual "per-tier measured" numbers 393 asks for;
they are not needed to decide the construction, and rung 1 does not consume them.

---

## 3. Q2 — the launch-time build pipeline (where it hooks, how it stays off the critical path)

### The blocking gap found by this survey

**`tillandsias-plan` is never built into, copied into, or installed in the
forge image.** `forge-plan.sh:36-47` probes `$HOME/.local/bin`,
`/usr/local/bin`, `/usr/bin`; nothing in `images/default/Containerfile`
(`:116` copies only the MCP *scripts*, `:145` chmods them) or in
`images/default/lib-common.sh` produces that binary. So the MCP server
registered at `config.json:55-59` returns
`"ERROR: tillandsias-plan binary not found"` (`forge-plan.sh:61-64`) for every
call today. **Order 456 shipped the wrapper without the payload.** This is the
single highest-value fix in the whole EXPERTS family and it is rung 1 slice 1.

Index resolution, by contrast, already works: `forge-plan.sh:24-32` probes
`$HOME/src/tillandsias/plan/index.yaml`, which is exactly where the clone-only
forge puts the checkout.

### Why the binary must be built at launch, not baked

- The forge image has **no network during `podman build`** — the operator's own
  finding recorded on order 459 (`plan/index.yaml`, operator_note: "image build
  could never curl (no enclave network during podman build)"). A `cargo fetch`
  in a Containerfile cannot work.
- But the toolchain **is** in the image: `images/default/Containerfile.base:23`
  installs `rust cargo clippy rustfmt rust-analyzer cargo-deny`, with
  `CARGO_HOME` on the persistent project cache (`lib-common.sh:838`) and
  `.crates.io` allowlisted through the enclave proxy
  (`images/proxy/allowlist.txt:18`).
- So: **build once at first run into the cache volume, reuse warm thereafter.**
  Idempotent, ephemeral where it must be (the *index* dies; the *binary* is a
  build artifact, not knowledge), and it self-heals on a source change by
  keying the cached artifact on the crate's source hash.

### Hook point (exact)

`images/default/entrypoint-forge-opencode.sh:55-56` is the precedent verbatim:

```
ensure_forge_prebuilt_tools >>/tmp/forge-lifecycle.log &
ensure_forge_harnesses      >>/tmp/forge-lifecycle.log &
```

Backgrounded, log-redirected, fail-soft, never gating the agent. Add
`ensure_forge_experts >>/tmp/forge-lifecycle.log &` **immediately after
`clone_project_from_mirror` (`:65`)** — it needs the checkout, which lines 55-56
do not. It performs, in order:

1. `cargo build --release -p tillandsias-plan` with `CARGO_TARGET_DIR` on the
   project cache; `install -m0755` to `$HOME/.local/bin/tillandsias-plan` —
   the first path `forge-plan.sh:39` already probes. **No wrapper change needed.**
2. Build the L1 prose index into `/dev/shm/tillandsias-experts/` (tmpfs → dies
   with the container: ephemerality by construction, no reaper).
3. Write `/dev/shm/tillandsias-experts/state` = `building|ready|degraded:<reason>`.

### Non-blocking discipline (order 486's precedent)

`crates/tillandsias-headless/src/main.rs:10637-10642` is the shape to copy: the
launcher *warns and continues* when inference is not ready, with an explicit
comment that local models are optional. `entrypoint-forge-opencode.sh:94-100`
does the same in-container. Expert construction inherits this exactly:
**a cold launch is never gated on an expert.** `inject_startup_context`
(`lib-common.sh:2799-2843`) already prints a truthful `READY / NOT-READY(reason)`
line for inference (`:2810-2817`, `:2839`); add one peer line reading the state
file — `experts: ready | building (<n>s) | degraded (<reason>)` — never
"may still be building". Upgrade `forge-plan.sh:61-64`'s error text to name the
`building` state so an agent that queries too early gets a truthful transient,
not a permanent-looking failure.

### Freshness on commit (order 396)

Cheap, because of the layering:

- **Plan + methodology (L0): nothing to refresh.** The engine reads the file at
  query time (`lib.rs:60-65`). A commit changes the answer instantly. 396's
  first exit criterion is satisfied *by construction* for these corpora.
- **L1 indexes**: the post-commit hook re-indexes only the corpora whose files
  the commit touched (`git diff --name-only`), backgrounded and bounded, into
  the same tmpfs dir with an atomic rename. The forge already owns a hooks path
  (396's deliverable names it).
- **Rebuild the binary only when `crates/tillandsias-plan/**` changed.**

---

## 4. Q3 — citability (hard requirement)

An expert that cannot cite is a liability under
`traces_and_litmus_tests_provide_falsifiable_evidence`
(`methodology.yaml:151`) and `centicolons_report_residual_obligations_not_proof`
(`:154`). The contract:

**Every expert answer is a JSON envelope with a non-empty `citations` array.
The deterministic layer emits the citations. The model never does. An answer
with zero citations is returned as "no supported answer" — never a guess.**

```
{ "answer": "<prose or table>",
  "citations": [ { "path": "...", "line_start": N, "line_end": M,
                   "kind": "plan|methodology|spec|cheatsheet|code",
                   "authority": { ... } } ],
  "freshness": { "source_commit": "<sha>", "indexed_at": "<ISO>" },
  "confidence": "exact|retrieved|unsupported" }
```

Per-kind `authority` payload — all of it already exists in the tree:

| kind | authority fields | source |
|---|---|---|
| plan | `packet_id`, `order`, `status` | `lib.rs:147-151`, `main.rs:27-42` |
| methodology | dotted YAML path + `file:line` | `methodology.yaml` / `methodology/*.yaml` |
| spec | spec name + requirement heading + `@trace` | `openspec/specs/spec-traceability/spec.md:25-38` pins the `@trace spec:<capability>` grammar; `:103` makes `@cheatsheet` a peer annotation |
| cheatsheet | `tier`, `authority`, `status`, `last_verified` | frontmatter, e.g. `cheatsheets/build/cargo.md:1-19`; validated by `crates/tillandsias-policy/src/main.rs:11-21` (`check-cheatsheet-tiers`, `check-cheatsheet-sources`) |
| code | `file:line` + symbol (rust-analyzer) + module `@trace` | LSP in image (`Containerfile.base:23`); `config.json:61` `"lsp": true` |

Three rules that make this falsifiable rather than decorative:

1. **Resolvability litmus**: for every citation, the path exists, the line range
   is non-empty, and the cited span contains the answer's key token. A seeded
   fabricated citation must turn the litmus red.
2. **Staleness is surfaced, not hidden**: a cheatsheet whose `last_verified`
   exceeds the FRESHNESS threshold (`methodology.yaml:263-289`) is cited with a
   `STALE` marker. The expert reports the residual obligation; it does not
   quietly answer from aged text.
3. **L2 is span-constrained**: the renderer receives only the retrieved spans
   and is instructed to answer strictly from them. Its output is a *rendering*
   of a citation set that was computed before it ran — so a hallucinated
   sentence still ships with citations an agent can check, and an empty span
   set short-circuits to `unsupported` without ever calling the model.

Note for 457/458: the tombstoned `cheatsheet-mcp-server` spec
(`openspec/specs/cheatsheet-mcp-server/spec.md:1-20`) explicitly requires that
"any future MCP-backed cheatsheet query surface must be specified as a new,
narrower spec with an executable litmus boundary." The envelope above is that
boundary.

---

## 5. Q4 — corpus split, with the "is this expert worth building" verdict

- **Plan ledger — L0, no model, already built.** Worth "building" only in the
  sense of *shipping the binary* (§3). Serving it with a model would be a
  regression from an exact 20 ms answer.
- **Methodology — L0, no model for rung 1.** `methodology.yaml` is a 290-line
  YAML whose invariants are *named keys* (`:145-166`); the honest query is a
  path lookup returning the block plus `file:line`, not a paraphrase. The
  `methodology/` directory (453 KB ≈ 113 k tokens) does not fit any tiny-model
  context, which settles the matter.
- **Specs + `@trace` — L0 graph + L1 prose.** The graph half (spec→code,
  code→spec) is deterministic and is what 400's audit answer actually needs.
- **Cheatsheets — L1 primary, and the one place L2 earns its keep.** The
  frontmatter is structured (`cargo.md:1-19`) and `INDEX.md:1-14` is already
  regenerated from it by a **Rust** tool
  (`scripts/regenerate-cheatsheet-index.sh:1-20` →
  `tillandsias-policy regenerate-cheatsheet-index`). The genuine synthesis use
  case — `tellme howto "<query>"` — already exists as bash keyword-RAG
  (`images/default/cli/tellme:89-127` builds context from the top 3 matching
  cheatsheets; `:139-158` streams `qwen2.5:0.5b` via `/api/generate`). **457
  should upgrade `tellme howto` in place — better ranking, the citation
  envelope, `last_verified`/`tier` surfaced — not build a parallel expert.**
- **Code — L0 via LSP + git-trajectory, embeddings last.** Structural queries
  belong to rust-analyzer, which ships already. The temporal/trajectory and
  convergence signals the operator asked for
  (`plan/issues/code-expert-file-trajectory-and-convergence-2026-07-17.md:88-104`)
  are **deterministic metrics over `git log`** — a Rust computation, not an
  inference problem, and the convergence flag is *more* trustworthy for being
  deterministic.

**Not worth building at all**: a "plan expert" model, a "methodology expert"
model, and any embedding index purchased before L1 is graded.

---

## 6. Q5 — the 394 slice proposal (forge-cycle-sized, falsifiable)

Each slice fits the 600 s in-forge envelope
(`methodology/distributed-work.yaml:893-905`, `forge_cycle_budget`: one packet
per cycle, split rather than overrun). Ordered; each is independently valuable.

**394.1 `plan-expert-binary-shipping`** — close the §3 gap. `ensure_forge_experts`
builds and installs `tillandsias-plan` to `$HOME/.local/bin`, backgrounded after
`entrypoint-forge-opencode.sh:65`, cache-keyed on crate source hash.
*Exit*: (i) in a fresh forge, `tillandsias-plan check` on PATH prints
`ok: <n> packets…`; (ii) an MCP `tools/call plan_blocked_by {"reference":"394"}`
returns packet rows, not `ERROR: … binary not found`; (iii) a litmus asserts
both, and asserts the launch reaches the agent prompt with the build still
running (non-blocking).

**394.2 `expert-answer-envelope`** — pin the §4 JSON envelope; add a
`plan_answer` MCP tool returning it; upgrade `forge-plan.sh`'s not-found text to
the truthful `building` state.
*Exit*: (i) envelope schema pinned by litmus; (ii) a fixture query returns ≥1
citation whose `path`+line-range resolves and whose span contains the claimed
`packet_id`; (iii) a seeded fabricated citation turns the litmus RED.

**394.3 `methodology-expert-layer0`** — a YAML path-query subcommand (new
subcommand on an existing crate — no new crate, no new dependency) returning
block + `file:line` over `methodology.yaml` and `methodology/*.yaml`; exposed as
an MCP tool beside `forge-plan`.
*Exit*: (i) 10 canonical discipline questions (e.g. "may a forge cycle drain two
packets?", "is Python allowed in a committed script?") answer with the exact
YAML path and a resolvable `file:line`; (ii) each answer's cited span contains
the governing rule text; (iii) an unknown path returns `unsupported`, never a
guess.

**394.4 `expert-groundtruth-harness`** — 393's residual, and the milestone's
grading gate. A committed query set (plan + methodology) with expected exact
answers, graded by comparison against the L0 engine.
*Exit*: (i) harness runs inside the forge in < 60 s; (ii) it is GREEN at HEAD;
(iii) injecting a wrong expected answer turns it RED (the harness can fail);
(iv) it is reusable verbatim by 457 and 400.

**394.5 `expert-launch-state-and-ephemerality`** — the startup-context state line
+ tmpfs placement + teardown proof.
*Exit*: (i) `inject_startup_context` prints
`experts: ready|building(<n>s)|degraded(<reason>)` — never an ambiguous
"may still be building"; (ii) a cold launch with inference DOWN still reaches
the agent prompt (486's soft-degrade preserved); (iii) after stack shutdown, no
expert index remains anywhere (ephemerality litmus) — the binary in the cache
volume is explicitly out of scope, it is a build artifact, not knowledge.

**Explicitly NOT in 394 rung 1**: any model, any embedding, any tier work. That
means 394's stated `depends_on: [inference-startup-cleanup]` (order 392) is
**not a real dependency for rung 1** and should be dropped by the coordinator —
rung 1 needs no inference container at all. It also makes the milestone's
"tier matrix proven on ≥2 host classes" trivially satisfiable for rung 1 (an
L0 expert is CPU-only and tier-independent), de-risking 397/401/402.

Rung 2 (optional L2 rendering, the cheatsheet synthesis case) is 457's, and it
inherits 394.2's envelope and 394.4's harness.

---

## 7. Amendments to the 2026-07-17 signed decision

The wave-1 record (`plan/issues/experts-construction-decision-2026-07-17.md`)
is correct in its core judgement — *no training anywhere; deterministic
structure for the plan; RAG only for prose* — and its §49-57 amendment
(the deterministic layer as a shared compiled engine) is exactly what shipped.
Three items need amending against facts that postdate it:

1. **"METHODOLOGY EXPERT: Ollama Modelfile stuffing" (wave 1 §1) — SUPERSEDED.**
   Two reasons. (a) **Engine**: order 478 concluded llama.cpp/llama-server is
   the correct default engine on every host class
   (`plan/issues/heterogeneous-inference-cpu-gpu-npu-research-2026-07-24.md:54-63`),
   and `Modelfile` + `keep_alive` are **ollama-only APIs**. Building the
   methodology expert on them would couple the EXPERTS milestone to an engine
   we have already decided to migrate off. Any L2 must speak the
   OpenAI-compatible `/v1` surface both engines serve — which the forge already
   points at (`config.json:18-24`). (b) **Fit**: `methodology.yaml` is 16 KB
   (~4.5 k tokens), at or past the default context of a 0.5B-class deployment
   unless `num_ctx` is set explicitly, and `methodology/` (453 KB) does not fit
   at any setting. Replaced by L0 path query (§5, slice 394.3).
2. **"Serving: transparent in-container proxy" (wave 1 §3) — DEFERRED.**
   A shim that makes experts look like model names was the right idea when
   experts were models. Now that rung 1 has no model, the affordance is MCP,
   which the forge already wires (`config.json:39-59`) and which 456/458 own.
   Revisit only if L2 ships. This also simplifies 395: it becomes "register the
   expert MCP tools + one instruction line", not a provider-entry exercise.
3. **"Ephemerality: tmpfs index + keep_alive eviction" — narrowed.** tmpfs
   stands (`/dev/shm`). `keep_alive` disappears with the Modelfile mechanism.
   Add the explicit carve-out that the **compiled binary in the cache volume is
   not an expert artifact** — it is a build product, subject to idempotency
   (rebuilt when its source hash changes), not to ephemerality.

Unchanged and reaffirmed: fine-tune/LoRA rejected (now on policy-hard grounds,
§1c); graph-aware deterministic retrieval for the plan (now: deterministic
*only*); delta refresh on commit (now: free for L0).

---

## 8. Risks and open questions carried forward

1. **`cargo build` inside the forge on first run needs crates.io through the
   proxy.** Allowlisted (`images/proxy/allowlist.txt:18`) and `CARGO_HOME` is
   cache-persisted (`lib-common.sh:838`), but a cold first run with a cold
   registry pays a download. Mitigation: fail-soft (the MCP degrades to a
   truthful `building`/`degraded` state), and consider vendoring the plan
   crate's two dependencies if the measured cold cost is material. **Measure in
   394.1; do not pre-optimise.**
2. **Two MCP servers wrapping the same binary** (`forge-plan.sh` today, whatever
   456 lands) would be duplication. 456's packet says "compiled Rust MCP server
   in ramdisk"; the shell wrapper already exists and works. Recommendation for
   the coordinator: 456 becomes *"harden and complete the existing wrapper"*
   (or replace it with a Rust `--mcp` subcommand on `tillandsias-plan`), not a
   second server. Either way, exactly one process answers plan queries.
3. **Hot-path placement (order 329/437)**: the audit
   (`plan/issues/v0.4-forge-audit-macos-2026-07-28.md:72-77`) argues experts
   need the tmpfs checkout. True for L1 indexing throughput; **not** a blocker
   for L0 at 20 ms/query over virtiofs-class latency. Rung 1 is not gated on it.
4. **`tellme howto` divergence**: `images/default/cli/tellme:89-158` is a second,
   uncited retrieval path. If 457 builds a parallel cheatsheet expert we will
   have two answers to the same question with different provenance discipline.
   457 must *replace* `tellme howto`'s internals, not sit beside them.
5. **Unmeasured**: L1 index build time and L2 latency (§2). 393's "per-tier
   measured recommendation" exit criterion is only fully closed once 394.4's
   harness reports them; this record closes the *technique* question, which is
   what 394/457/400 are actually blocked on.

---

## 9. Sign-off

- [ ] **The Tlatoāni** — approves §0 (expert = cited retrieval surface; plan
      expert ships with no model), §6 (394 rung-1 slicing), §7 (amendments to
      the 2026-07-17 record).
- Coordinator follow-ups if signed (this agent does not edit `plan/index.yaml`):
  drop 394's `depends_on: inference-startup-cleanup`; file 394.1-394.5 as
  children with the exit criteria above; re-scope 456 per risk 2; note in 457
  that it replaces `tellme howto`'s internals.
