# Zero-tolerance boundary audit — expert + inference stack (2026-07-29)

Classification: `research/` (audit) feeding `enhancement/` packets 523-527.
Produced by an orchestrated 5-way research fan-out with adversarial critique on
macuahuitl (`linux_mutable`), then re-verified by hand where cited below.

Companion to `plan/issues/inference-engine-payload-gpu-bringup-2026-07-29.md`
(the order-406 engine-payload record). That file covers what was FIXED this
cycle; this one covers what the audit found and did NOT fix.

## What "zero tolerance at every boundary" already means here

The doctrine exists but is unnamed and scattered across four load-bearing
clauses:

1. `no_behavioral_ambiguity_allowed` + `all_requirements_must_be_testable`
   — `methodology/philosophy.yaml:20-28`.
2. The **S2 bar** — a constraint is real only when litmus-bound with unambiguous
   success/failure conditions (`methodology/verification.yaml:28-35`), enforced
   at L2 = `block_merge_on_failure` (`:212-221`).
3. The anti-pattern register's `silent-drop-on-unhandled-control-variant`, whose
   *ratified* mitigation is that BOTH dispatchers reply `Error{code:Unsupported}`
   and new variants go into the SHARED dispatcher, never a forked local handler
   — `methodology/multi-host-development.yaml:435-447`.
4. `mechanism_dead_intent_live` — dropping an obligation silently is "the precise
   failure this discipline exists to prevent" (`philosophy.yaml:119-123`),
   verified adversarially with refuted-by-default (`:135-139`).

`tillandsias-plan methodology-ask` cannot answer for this: it is a YAML **path**
query with 10 routed forms and returns `confidence=unsupported` for prose
questions, by design. So the doctrine is real but not queryable as one key.

**Order 486 is NOT a general softness license.** Its scope is exactly "a cold
launch with inference DOWN still reaches the agent prompt"
(`plan/index.yaml:16244`) — launch *continuation*, not defect swallowing inside
the container. The launcher already implements that asymmetry correctly:
warn-and-continue for inference (`main.rs:10767`), hard refusal for the git
mirror (`:3237`). That distinction is this audit's dividing line; every finding
below is a swallowed defect or an ambiguous state, never deliberate soft-degrade.

**The one mechanical rule worth adopting**, reducing "zero tolerance" from a
review posture to something a litmus can enforce:

> A value may not cross a boundary unless the receiving side re-derives its
> trustworthiness with code a litmus can make fail.

Three corollaries cover every defect found: (a) every envelope-emitting exit
point runs its own verifier on its own output and downgrades to `unsupported` on
violation; (b) every argument vector handed to podman is asserted
flag-before-image in a unit test, because the arg vector is the only observable
form of that boundary; (c) every transient state token is bounded on the READ
side, so a killed producer cannot pin a "retry me" state forever.

## R1 — WRONG ANSWER, live at HEAD (packet 523)

The METHODOLOGY EXPERT can cite a corpus file **the engine itself declared
unparseable**, and the caveat is destroyed at the MCP boundary.

`Corpus::load` computes `parse_error` and then pushes
`entries: index_text(&text)` **unconditionally**
(`crates/tillandsias-plan/src/methodology.rs:160-172` — verified by hand), so
entries from an invalid-YAML file are indexed and citable. The only signal is a
stderr warning (`crates/tillandsias-plan/src/main.rs:409-411`) which
`images/default/config-overlay/mcp/forge-plan.sh:297` discards with
`2>/dev/null`.

Reproduced by the auditor: the query returns `confidence=exact`,
`verify-answer` says `ok: envelope verified`, and the rendered span glues one
claim's `limits`/`falsification_signal`/`review_cadence` onto a *different*
claim — so an agent attributes OpenTelemetry field-naming caveats to the
compiled-CLI-orchestration claim.

This is the precise failure the cited-envelope architecture (394b) exists to
prevent, reached through the shipped surface.

Smallest fix: mark a `CorpusFile` untrusted when `parse_error.is_some()` and
refuse to emit a citation into it — return
`unsupported: <rel> does not parse as YAML (<err>) so its spans cannot be trusted`.

## R2 — WRONG ANSWER via the shipped probe order (packet 523)

An expert answer escapes with a citation **the engine's own verifier refuses**,
because nothing on the runtime path calls `verify()` and the envelope carries no
field naming the root its paths are relative to.

`citation_path`/`root_for` (`main.rs:55-77`) derive a private root from
`--index`; the envelope ships `path` + line range but **not that root**.
Reproduced: an index at `<x>/opt/cheatsheets/plan-index.yaml` yields
`confidence=exact` citing `cheatsheets/plan-index.yaml:16084-16106`, and
`verify-answer` against the real checkout **REFUSES** it.
`/opt/cheatsheets/plan-index.yaml` is a live probe candidate
(`forge-plan.sh:52`) and `PLAN_INDEX` is cached for the session once non-empty
(`:145`, `:152`), so this is reachable, not hypothetical.

Smallest fix — and it retires R1's escape too, which is why 523 owns both:
self-verify at the exit point. After building the envelope in
`answer`/`methodology`/`methodology-ask`, run `answer::verify(&env, &root)` and,
if non-empty, print `Envelope::unsupported` naming the violations. That makes the
verifier unavoidable instead of ceremonial.

## R3 — SILENT FLAG LOSS in the compiled launcher (packet 524)

`build_inference_run_args`'s `skip_runtime_pulls` block inserts twice at
`args.len() - 2`, which places `--env TILLANDSIAS_INFERENCE_SKIP_RUNTIME_PULLS=1`
**after the image name** (`main.rs:3373-3379`).

Verified by hand: the vec tail is `[..., image, "/usr/bin/ollama", "serve"]`, so
`len()-2` is the index of `/usr/bin/ollama` and both inserts land behind the
image. The result is container argv, not podman flags, so the env var is **never
set**. The image is ENTRYPOINT-only (`Containerfile:72`) and `entrypoint.sh`
never reads `"$@"`, so the strays are silently discarded, the
`[inference] status-check mode — skipping runtime pulls` line can never print,
and the caller's explicit intent is dropped.

The same block appends a dead `/usr/bin/ollama serve` command that **does not
exist in the image** (ollama self-installs under `${OLLAMA_MODELS}.tools/`), which
would exec-fail the container the day the image switches ENTRYPOINT to CMD.

No litmus can catch either: every SKIP_RUNTIME_PULLS litmus bypasses the function
and passes `-e` straight to podman. Smallest fix: build the env pair BEFORE
extending with the mount/image tail, delete the trailing command, and add the
flag-before-image unit assertion (corollary (b) above).

## R4 — SILENT DEGRADED RUN, mis-attributed (packet 525)

`update-ca-trust` cannot succeed as uid 1000 and the failure is swallowed, so
**ollama's Go TLS never trusts the enclave CA**.

`entrypoint.sh:20-22` runs mkdir/cp/update-ca-trust each with `|| true`; the
Containerfile chowns only `source/anchors` (`Containerfile:35-36`), leaving
`/etc/pki/ca-trust/extracted` root-owned under `USER 1000:1000` (`:64`). Order
486's mitigation exports `CURL_CA_BUNDLE` (`entrypoint.sh:27`), which fixes
**curl only** — `SSL_CERT_FILE` appears nowhere under `images/inference`.

Every `ollama pull` through squid's TLS bump then fails x509, non-fatally, and
the startup context tells the agent `inference_reason=no-models` — collapsing
"TLS trust is broken" into "nothing is cached". Two very different problems, one
indistinguishable message.

Smallest fix: `export SSL_CERT_FILE=/etc/tillandsias/ca.crt` beside line 27
(Go's `crypto/x509` honours it), and replace the three `|| true` with one guarded
block that echoes
`[inference] WARN: system trust store not updated (rc=N) — relying on SSL_CERT_FILE/CURL_CA_BUNDLE`.

## R5 — UNBOUNDED "transient" state (packet 526)

A `building` experts state has no upper bound while the contract advertises it as
transient. `ensure_forge_experts` is forked with no supervisor
(`images/default/lib-common.sh:914`), every state write is `|| true`
(`:836-849`), and both renderers emit `building(<n>s)` for **any** elapsed value
(`:855-882`, `forge-plan.sh:88-97`) while the wrapper tells the agent
"TRANSIENT: the build is still running. Retry this tool in a few seconds"
(`forge-plan.sh:118-120`, `:211-213`).

If the forked shell is OOM-killed, the state file pins `building` forever and the
agent is told to retry a build that no longer exists. Bound it on the READ side
(corollary (c)): past a declared budget, `building` renders as
`degraded(build-abandoned-after-<n>s)`.

## R6 — `OLLAMA_KEEP_ALIVE=24h` contradicts ephemerality-by-construction (packet 527)

`crates/tillandsias-headless/src/main.rs:3302` injects `OLLAMA_KEEP_ALIVE=24h` as
a bare literal with no rationale comment and no litmus pinning it. Combined with
`max_loaded=3`, an **ephemeral** expert model holds VRAM for 24 hours after its
forge is gone — a direct conflict with milestone 391's "EVERYTHING EPHEMERAL …
die on shutdown" rule and with 394e's ephemerality criterion. The teardown litmus
asserts no expert *index* survives; it says nothing about resident VRAM.

Note this now interacts with the order-406 tuning work: a 7B expert at 32768 ctx
holds 5690 MiB, so three pinned-for-24h experts is ~17 GB of a 24 GB card held
against a stack that has already shut down.

## Smaller items (folded into existing packets, not new ones)

- **`sha256sum.txt` (1 472 B) IS published** on the ollama release and is unused
  — the payload download is unverified. Makes order **521** concretely
  implementable rather than requiring a digest-recording scheme of our own.
- **`OLLAMA_VULKAN` defaults to TRUE**, so with both `vulkan/` and `cuda_v13/`
  present, backend selection on a CUDA host is nondeterministic unless pinned.
  Order 406's tier-keyed payload *incidentally* mitigates this by installing
  exactly one accelerator backend per tier (measured: `libdirs=ollama,cuda_v13`),
  but the two multi-backend paths — undetectable CUDA major (ships v12+v13) and a
  future engine-slot lane — still need an explicit pin. Belongs to order 482.
- **`OLLAMA_NUM_PARALLEL=1`** in the entrypoint restated ollama's own default and
  bought nothing while hiding that concurrency was never tuned. Removed by order
  406; the value is now tier-derived and measured.
- **`OLLAMA_DEBUG=1`** is forced on every launch (`main.rs:3300`) — DEBUG-level
  per-request logging is a throughput and log-volume cost, and
  `images/inference/external-logs.yaml:12-27` already declares a curated
  `model-load.log` whose producer is still "pending", which this noise does not
  satisfy.
- Engine version measured this cycle: **ollama v0.32.5**, 54 tar members,
  2 242 628 920 B uncompressed. `bin/ollama` and `lib/ollama` MUST come from the
  same build, so any split baked-floor / later-fetch scheme would silently mix
  versions against the unpinned `releases/latest/` URL (order 521).

## Designs produced and REJECTED this cycle (do not resurrect as-is)

Two designs were generated and then failed adversarial review. Recording the
refutations so the next implementer does not inherit them:

- **Host-class tier matrix** (`inference-tier-matrix.toml` + shared resolver +
  dry-run flag) — the shape is right, but: (i) moving the CDI remedy text into
  TOML turns the source-window assertion at `main.rs:13143-13146` RED, because
  that test greps the literal out of `build_inference_run_args`'s *source text*;
  (ii) it instructs removing a `/dev/kfd` grep that does not exist; (iii) it
  treats `gpu-vulkan` as matrix-only when it is already a live handled tier value
  container-side. Also: new launcher flags must be added to `known_flags`
  (`main.rs:317-348`) or the dry-run surface is dead on arrival — `:349-363`
  exits 2 on any unknown `-`-prefixed arg.
- **Model-lifecycle MCP broker** — "the engine moves to a private alias reachable
  only by the broker" is **not** an access control: `ENCLAVE_NET` is one flat
  `--internal` bridge with no east-west ACL anywhere in the tree, and a network
  alias is a DNS name. Its closure step tested only the front door, so it would
  have passed precisely when the property it claimed to pin was violated. Also
  its `agent_slots = max_loaded - 1 - expert_slots` term is identically zero on
  every host and under both overrides, given `preload-policy.sh:95-103`.
