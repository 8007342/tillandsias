# Generic project expert bootstrap — design + implementation plan (606-z389)

- **Packet:** `generic-project-expert-bootstrap-contract` (order 606-z389)
- **Author:** linux-tlatoani-claude-20260807t021700z, 2026-08-07
- **Kind:** design+openspec — this document IS the implementation plan; the
  normative contract lands as requirements in
  `openspec/specs/forge-environment-discoverability/spec.md` in the same
  commit. Implementation is carried by the three child packets filed with
  this design (619-vwau, 619-pfsj, 619-3y75).

## Why

Every product surface of the EXPERTS theme currently specializes on
Tillandsias itself: the compiled plan engine exists only when the mounted
project carries `crates/tillandsias-plan`, and on any other project the
contract is the deliberate `degraded(no-plan-crate)` refusal
(`images/default/lib-common.sh` — an honest state, but a dead end for the
product's actual promise: forges run on ARBITRARY projects). 606-z389 amends
that contract: new projects, fresh sessions, cleared contexts, and scripted
prompts all receive a warmed expert surface without knowing the repository
type or reading project files manually. The Tillandsias plan expert becomes
an ADDITIVE SPECIALIZATION of a generic contract, not the only supported
shape.

## Signed constraints this design inherits (must not contradict)

From the operator-signed construction decision
(`plan/issues/experts-construction-decision-2026-07-17.md`) and the ratified
§4 envelope contract:

1. **Deterministic first.** The deterministic layer emits answers and
   citations; a model never fabricates either. An uncited answer renders as
   `unsupported:` — refusal over guessing.
2. **Ephemeral by construction.** Expert state is built at launch from the
   freshly mounted checkout, refreshed on commit, dead on shutdown. Nothing
   persists stale knowledge across sessions
   (`litmus:forge-experts-ephemerality-shape` pins this).
3. **Fail-soft, never launch-blocking.** Expert construction backgrounds;
   harness launch and user prompts are never gated on it. Absence is a named
   machine-readable state, not a hang
   (`litmus:forge-plan-expert-build-shape` pins the state grammar).
4. **Capability honesty.** "The project has no answer" and "this artifact
   cannot answer" are distinct, named conditions (order 569).

## The contract (normative text in the spec; summary here)

### C1 — Zero-intervention bootstrap keyed on the project path

The canonical input is **`TILLANDSIAS_PROJECT_PATH`**: the absolute path of
the mounted project checkout. Today `lib-common.sh` derives
`project_dir=/home/forge/src/${TILLANDSIAS_PROJECT}` with a `$PWD` fallback;
the contract names the resolution order explicitly:

1. `TILLANDSIAS_PROJECT_PATH` when set (absolute path, any project shape);
2. else `/home/forge/src/${TILLANDSIAS_PROJECT}` when `TILLANDSIAS_PROJECT`
   is set (compatibility);
3. else `$PWD`.

Bootstrap MUST work for git and non-git directories: git-ness is a detected
property (structured `git_status` vs a named `not-a-git-repository` field),
never a precondition.

### C2 — Ephemeral discovery/index lifecycle

At launch, alongside (not replacing) `ensure_forge_experts`, a generic
discovery pass builds a **project index** under tmpfs
(`FORGE_EXPERTS_STATE_DIR/project-index/`): project type detection (manifest
probes: Cargo.toml, package.json, pyproject.toml, go.mod, flake.nix,
Makefile, …), entry-point commands (build/test/run derived from the detected
manifests), top-level layout, and git facts when present. The index is
rebuilt by the existing post-commit refresh hook and dies with the
container. It never leaves tmpfs, so ephemerality holds by construction and
the existing ephemerality litmus stays green unchanged.

### C3 — Readiness SLA with machine-readable states

The generic engine gets its OWN state line, parallel to (never mutating) the
pinned plan-expert grammar:

    project-expert: ready | building(<n>s) | degraded(<reason>)

with a CLOSED reason vocabulary: `no-project-path`, `unreadable-path`,
`index-failed`, `not-built`. SLA: state transitions to `ready` or a
`degraded(<reason>)` within the same budget discipline the plan expert uses
(`FORGE_EXPERTS_BUILD_BUDGET_SECS`, default 300s, with the same
`build-abandoned` overrun rendering); launch and prompts NEVER wait on it.
Discovery is file-stat cheap (no cargo build), so the expected time-to-ready
is sub-second; the budget exists for pathological trees.

### C4 — One uniform `project_answer` surface

A single MCP tool `project_answer` (and CLI equivalent) answers project
questions in the SAME ratified envelope {answer, citations[], freshness,
confidence}. It routes internally:

- **Specialized lane:** when the project carries a plan expert (Tillandsias
  shape) the existing plan/methodology engines answer, unchanged.
- **Generic lane:** otherwise the project index answers deterministically:
  project type, structured status, discovered commands, and next actions
  (derived from the checkout: failing build markers, TODO manifests, README
  quickstarts) — every claim cited to the file+span that substantiates it,
  exactly like plan citations.

The caller never selects a project-specific tool; `"what's next?"` lands on
plan_next for the specialized lane and on the generic action list otherwise.
A question neither lane can cite is `unsupported:` — never a guess.

### C5 — Deterministic no-inference fallback

When local inference (RAG/synthesis tiers) is unavailable, the generic lane
still answers the deterministic subset (type, commands, status, layout) from
the index alone, and refuses the rest with the standard typed refusal.
Inference adds recall, never authority: citations remain deterministic-layer
products in every configuration.

## Fixture strategy (exit criterion 5)

A committed fresh non-Tillandsias fixture pair under
`openspec/litmus-tests/groundtruth/fixtures/generic-project/`:
`git-project/` (tiny Rust-less repo with package.json + Makefile + .git
built by the litmus at run time from committed sources) and
`plain-dir/` (non-git). A new litmus drives each supported harness's
registration path against them and grades `project_answer` envelopes with
the SAME corpus-agnostic grader (`tillandsias-plan grade --envelope`),
proving usability with no manual registration.

## Implementation rungs (children filed with this design)

- **619-vwau `generic-project-index-and-state`** — the discovery pass, tmpfs
  index, `project-expert:` state line + closed reasons, post-commit refresh
  wiring. (linux, shell+rust)
- **619-pfsj `project-answer-uniform-surface`** — the `project_answer`
  MCP tool + CLI, two-lane routing, cited generic answers, typed refusals,
  budget-bounded envelope. Depends on 619-vwau. (linux, rust+mcp)
- **619-3y75 `generic-project-harness-fixtures`** — the non-Tillandsias
  git/non-git fixtures, per-harness registration litmus, ground-truth query
  set graded against the fixture corpora. Depends on 619-pfsj. (linux,
  testing)

## Constraints folded in from the pre-design audit (2026-08-07 mapping pass)

1. **`TILLANDSIAS_PROJECT_PATH` is not universally exported today** (absent in
   the codex and opencode-web lanes; `export_project_env` may export empty
   non-fatally, with a "first dir under ~/src" fallback). 619-vwau must make
   the export universal OR resolve the path inside the servers; an
   empty/absent path is `project-expert: degraded(no-project-path)` — never
   an accidental `$PWD` index of the wrong tree.
2. **Image builds have no network** (order 459 — podman build cannot reach
   crates.io; the plan expert is launch-built for exactly this reason).
   "Image-baked" therefore means: the DISCOVERY pass ships in the already
   baked shell layer (zero build), and 619-pfsj must choose the generic
   ANSWER engine's packaging explicitly against that recorded constraint
   (prebuilt at init from the Tillandsias checkout, or vendored) — never
   silently contradict it.
3. **`ready` has never meant `can answer`** (orders 531/569). The generic
   engine's readiness MUST be accompanied by a capability manifest analog,
   and capability honesty must be REDEFINED for an engine whose sources are
   not the mounted checkout: "skew" compares the image-baked engine against
   the image, not the checkout.
4. **Post-commit refresh is git-only and gated on a root plan/index.yaml
   today** (<50ms fork budget). C2 refreshes on commit only where that hook
   path exists; non-git projects rebuild at launch (their index is cheap);
   relaxing the hook gate must not add latency to every commit on every
   project.
5. **State grammar is duplicated verbatim** in lib-common.sh and
   forge-plan.sh and pinned by litmus. The `project-expert:` line is NEW and
   parallel; all copies of any shared rendering must move atomically, and the
   informal `degraded(build-abandoned-after-<n>s)` token is noted but not
   formalized here (out of scope).
6. **606-qh3f owns project-info's JSON-RPC hardening.** 619-pfsj builds the
   uniform surface on the POST-qh3f contract (strict framing, typed degraded
   states) — sequencing note recorded on the child packet so the two do not
   collide in the same file.
7. **Harness scope decision:** "each supported harness" = the harnesses with
   an MCP registration surface today (claude, opencode, opencode-web, codex).
   Antigravity has none; it enters scope when it grows one. Recorded here as
   the explicit scoping decision the exit criterion needs.
8. **Index writes are litmus-confined to tmpfs** (`/dev/shm`, `/tmp`,
   `$FORGE_EXPERTS_STATE_DIR`) — a persistent-volume "cache for speed" is the
   exact regression the ephemerality litmus exists to catch.
9. **Spec `### Test:` entries and `openspec/litmus-bindings.yaml` registration
   for the generic-bootstrap requirements land with 619-3y75's litmus**, not
   here — a Test block naming a litmus that does not exist yet would be a
   ghost trace, the class `validate-traces` exists to refuse. The harness
   identity vocabulary the fixture must cover is pinned by
   `environment-runtime` (opencode, opencode-web, claude, codex, antigravity,
   terminal); constraint 7 scopes antigravity out until it has a registration
   surface.
10. **`scripts/check-forge-expert-base.sh` polarity**: its guard grammar
   treats `no-plan-crate` as `ok:` (a normal non-Tillandsias project) while
   the expert state calls it `degraded` — the generic contract makes the
   guard's reading the product truth. 619-vwau must keep that grammar green
   verbatim.

## Non-goals

- No new inference tiers, model downloads, or GPU work (owned by the 397+
  family).
- No change to the pinned plan-expert state grammar, the ephemerality
  litmus, or the `no-plan-crate` reason token — the generic contract sits
  BESIDE them; `no-plan-crate` simply stops being a dead end because the
  generic lane answers.
- No UX surface changes.
