> Research snapshot (Codex, branch research/litmus-lua-performance-20261011, frame cdba630ce). Kept verbatim for provenance. Its claims were re-verified against trunk ed7a73185 and the measured 2026-10-11 gate in plan/issues/gate-performance-research-distillation-2026-10-11.md (order 1604-fsxu), which is the current verdict; where the two disagree, the distillation stands.

# Research: compiled provenance and a shared snapshot/index for fast litmus checks

Date: 2026-10-11. Research branch: `research/litmus-lua-performance-20261011`.
Audited source: `cdba630cee433fa52366d29b3d5888a5d6177825` (`cdba630ce`).
Status: research/design proposal, not an approved implementation or measured speedup.
Owner/scope: this report only. No production changes, branch changes, builds, full
gate, destructive tests, commits, or pushes were performed for this research.

## Decision in brief

Keep Lua as the small decision language and Rust as the execution, parsing,
snapshot, and index host. Precompute an **exact full-text index plus typed
relations from one immutable byte snapshot**, then run an explicit manifest of
Lua checks against it in a bounded batch. Do not translate nested shell loops
into nested Lua loops that continue loading files or spawning the reader.

Distinguish four identities: compiled Rust host, shipped Lua bundle, optional
development Lua override, and the actual repository bytes checked. A compiled
Lua interpreter is already shipped; the ordinary Lua check sources are **not**
currently compiled into that interpreter's artifact. Embedding/compiling them
can bind shipped decision bytes to an artifact but cannot authenticate their
author, establish that their assertions are sufficient, or attest an honest
execution without an independently trusted builder/verifier.

Performance acceptance is a **>=10x TARGET**, measured over the same selected
deterministic check workload, including snapshot validation and reporting. It
is not a result of this audit. GPU/inference retrieval may assist research;
it must never select, decide, waive, or supply evidence for deterministic gates.

## 1. Evidence method and current authority

- Read MCP first: `forge-plan methodology_path`, capability probe, and
  `project-info` find/read/grep tools. The `*lua*` methodology-path query was
  unsupported (it matches key names, not rule text); the capability probe was
  called as required. File reads through MCP located the actual rules.
- Live probe: source/binary behavior skew was `rebuild-required`, capabilities
  present, expert state `degraded(not-built)`, spec index present, embedding
  endpoint reachable. This is session infrastructure evidence, not proof that
  the running binary implements this checkout. No benchmark uses that binary.
- Filesystem fallback used for **verification**: numbered reads of the cited
  build, Lua load, memo, test, and hot-loop spans. Git status/ref verification
  confirmed the branch and SHA above; the pre-existing `opencode.json` edit
  was not part of this research. No startup-context file was present.
- Current normative source for new gate deciders/fixtures is
  `openspec/specs/ci-release/spec.md:43-101`: Lua on `script run`, one terminating
  verdict, host-provided text/YAML/JSON/fs primitives, argv process execution.
  This is not a mandate to reimplement host primitives in Lua.
- `methodology/convergence.yaml:556-790` defines the current carried-obligation
  rules; `shell-to-lua` is gentle, area-scoped, with a <=150-line carried item
  or a waiver. The old wording “each new Lua requires +1” was withdrawn as
  wording, not intent. A report-only change does not touch that migration area.
- `openspec/specs/command-runtime/spec.md:246-266` requires no script-created
  coroutines, no `string.dump`, and text-only Observing `load`. Its header
  (`:1-12`) still describes the spec as draft with an open change. Treat its
  requirements and implemented regressions as evidence, not an assertion that
  the whole runtime change is ratified/complete. Approved new-gate policy is
  the ci-release requirement above.
- The earlier design is historical context, not present implementation:
  `plan/issues/scripting-runtime-lua-no-pipes-design-2026-09-26.md:9-15` and
  `:101-117` describe Rust primitives/Lua orchestration. Several process gaps
  described there have since changed. Current code and tests take precedence.

## 2. What “compiled Rust / compiled Lua” actually means here

| Surface | What the source actually does | Trust/freshness consequence |
| --- | --- | --- |
| Native host and Lua VM | `crates/tillandsias-plan/Cargo.toml` `[dependencies].mlua` selects vendored Lua 5.4, send, serialization, async. | The C interpreter is compiled alongside Rust. This says nothing about which `.lua` policy bytes run. No Lua JIT/AOT-native-policy path is selected here. |
| Expert tier/trim/collect | `crates/tillandsias-plan/src/lua_runtime.rs:304-356` (`load_all_scripts`, `load_file`, `reload`) walks the runtime Lua directory, sorts it (init last), reads sources, loads/executes them; reload preserves globals. The module's security/provenance documentation explicitly limits its claims. | A rebuilt Rust host does not freeze these scripts. Deleting a previously loaded function's source on reload need not remove its old global. A replacement snapshot/runtime should be constructed afresh, then swapped, rather than overlaying new globals. | <!-- cite-ok: pinned cdba630ce runtime algorithm audit; exact source span is evidence -->
| Gate runner | `crates/tillandsias-plan/src/script_run.rs:724-780`, `:788-814`, `:994-1020` (`run_to_verdict`, `cli_run`) creates a fresh environment/runtime and reads/compiles each named source at runtime. | Separate CLI calls pay process startup, VM/registrar setup, compilation and often repeated input reads. `@class cacheable` chooses capability shape; this runner does not call PredicateRegistry's memo. | <!-- cite-ok: pinned cdba630ce runtime algorithm audit; exact source span is evidence -->
| Predicate registry | `crates/tillandsias-plan/src/lua_predicate.rs:1701-1745`, `:1762-1800` (`PredicateRegistry::register`, `register_file`, `eval`) compiles/executes once to validate registration, stores a source String, then loads/executes again in a fresh VM on a memo miss. | “Compile it once” in the registration comment is syntax validation, not retained compiled-function reuse. Memo hits re-read/hash dependencies (`CacheEntry::still_valid`, `:1684-1693`). Registration itself executes top-level Lua; do not make untrusted registration a side-effecting precompile step. | <!-- cite-ok: pinned cdba630ce runtime algorithm audit; exact source span is evidence -->
| Embedded hooks | `crates/tillandsias-plan/src/discipline_hooks.rs` `template`, `run_hook` embeds Lua **text** with include_str, prefers a project override, then loads/evaluates the chosen text. | Useful shipped-bundle precedent, but embedding is not build-time Lua compilation and a runtime override changes the decision artifact. Record which carrier was chosen. |
| Embedded runtime assets | `crates/tillandsias-headless/build.rs` `main`, `collect_assets`, generated `EMBEDDED_RUNTIME_ASSETS` enumerates images/observatorium/skills and two named scripts, emits rerun inputs and include_bytes assets. | Existing packaging infrastructure can carry approved Lua source and a manifest. It does not presently embed all scripts/lib or scripts/lua; inspect each carrier, do not assume all checkout scripts are bundled. |
| scripts/lib | `scripts/lib/tool-materialize.sh` `materialize_tool`, `fast_tool` caches/verifies an extracted native tool and resolves it outside loops. `scripts/lib/tool-dispatch.sh` remains a shell dispatch carrier. | Reuse the resolve-once principle. A tool passing --version is runnable, not authenticated. These shell libraries are not a compiled Lua library/module system. |

### 2.1 Build-source identity gaps

`crates/tillandsias-plan/src/source_revision.rs:14-62` (`source_revision`, `collect_sources`) hashes sorted relative <!-- cite-ok: pinned cdba630ce runtime algorithm audit; exact source span is evidence -->
paths and bytes of `.rs` files plus capabilities.txt using FNV-1a. It excludes
Lua, Cargo manifests/lockfile, non-Rust included assets, and workspace dependency
source outside this crate. Read errors are silently skipped. It is a useful
diagnostic revision, not a cryptographic artifact/provenance identity.

`crates/tillandsias-plan/build.rs:27-37` (`main`) explicitly tracks src/tests/capabilities; <!-- cite-ok: pinned cdba630ce runtime algorithm audit; exact source span is evidence -->
`:53-66` tracks validator manifest, Cargo.lock, and enumerated surface files.
The manifest at `crates/tillandsias-plan/validator-surface.manifest:17-26` names
only main.rs, this crate's Cargo.toml, and seven selected dependency stanzas.
Consequently **editing lib.rs/fragments.rs/ledger_cache.rs without editing a
listed file can change fold behavior without changing the embedded validator
surface hash**. The ledger cache keys on precisely that hash
(`crates/tillandsias-plan/src/ledger_cache.rs:40-89`, `fingerprint`, `fingerprint_for`), despite its comment <!-- cite-ok: pinned cdba630ce runtime algorithm audit; exact source span is evidence -->
claiming fold-code identity. This is a source-level invalidation gap, not a
tested stale-cache exploit in this session.

Include_str/include_bytes dependencies may independently make Cargo rebuild
their Rust compilation units; that does not enlarge these custom hashes.
Likewise “Cargo rebuilt” is not an authenticated builder statement. Generate
one explicit transitive behavioral-input manifest for the host, including
workspace path dependencies, build scripts, Cargo.lock/manifests, features,
target/toolchain, bundled policies, parser/index schema versions, and the
compile-time included assets. Separate diagnostic revision from artifact SHA-256
and from authenticated build provenance. Missing required inputs must be unknown
or refused, never silently omitted from a valid-looking identity.

Cargo's worktree issue is already documented and mitigated:
`build.sh` `_touch_gating_checkout` touches every tracked file before gating to force shared-target
units to rebuild from the gating checkout. Preserve that mitigation until a
content-qualified build-output strategy is tested across worktrees. An index
cannot certify stale compiled Rust. Runtime CARGO_MANIFEST_DIR fixes locate the
test's subject, not the compiled code's origin.

### 2.2 Recommended shipped/development Lua model

1. Shipped checks: a generated manifest of script IDs, source SHA-256, header
   class/capabilities, approved inputs, host ABI, and bundle digest. Embed text
   in the Rust artifact initially; compile text once per executing VM/worker and
   retain private function handles. Report compiled Rust and Lua source/bundle
   identities separately. No implicit current-directory code loading.
2. Development predicates: preserve the existing ability to test uncommitted
   policy without rebuilding Rust (`crates/tillandsias-plan/src/lua_predicate.rs`
   `PredicateRegistry::register_file` and its operator-directive documentation).
   Explicitly label an override as development/unattested and pin its actual
   bytes/digest; do not claim it ran the shipped bundle. Approval of this split
   is needed before changing runtime selection; this report grants none.
3. If build-time Lua bytecode is subsequently justified by measurements, only
   the Rust host may load builder-produced, manifest-bound chunks. Pin Lua
   version, bytecode ABI/numeric representation, target, compile options and
   source-to-bytecode digest mapping. Verify authentication before loading.
   Do not accept arbitrary cached/downloaded bytecode or expose dump/binary-load
   to scripts. Current bytecode prohibition and the threat behind it remain
   intact (`crates/tillandsias-plan/src/lua_predicate.rs`
   `build_environment_logged`, text-only `load` wrapper; command-runtime
   requirement above).
4. A digest detects substitution only against an independently trusted expected
   digest. A signature authenticates an authorized signer/artifact, not policy
   correctness. A build attestation identifies inputs/builder under its trust
   assumptions, not an honest later run. A local runner writing “PASS” can
   fabricate its own receipt if it is the adversary; compilation is not remote
   attestation or a defense against a forged/replaced binary. Preserve forge
   containment and capability restrictions as separate controls.

## 3. Precise repeated work and existing reuse

| Hot path | Repeated work and complexity | Replace/reuse |
| --- | --- | --- |
| Bindings lookup | `scripts/lua/check-litmus-bindings.lua:66-85`, `:108-133` enumerates/reads the population; `file_named` at `:152-158` reads the corpus again for every name. Callers at `:202-220`, `:246-269` repeat that lookup; added-name × registry-pair join scans pairs again. With B names and F files this has up to O(B*F) file reads plus O(A*bindings) comparisons. | One name-to-source relation with ordered occurrences and one binding adjacency map. Preserve legacy first-substring-match semantics initially; switch to parsed exact declarations only as an explicit correctness change with controls. | <!-- cite-ok: pinned cdba630ce runtime algorithm audit; exact source span is evidence -->
| Runner extractability | `scripts/lua/check-litmus-bindings.lua` `parses` and its added/bound-name loops (`:240-269`) spawn run-litmus-test.sh --parse-only per selected name, sometimes again in advisory coverage. The shell runner's parse-only dispatch supports multiple files (`scripts/run-litmus-test.sh:3041-3132`). | Immediate reuse: one/bounded batched invocation of the **actual** extractor, retaining per-file outcomes. End state: shared extraction library, not a second imitation of its grammar. | <!-- cite-ok: pinned cdba630ce runtime algorithm audit; exact source span is evidence -->
| Litmus metadata | `scripts/run-litmus-test.sh:455-475` (`_yaml_jq`) spawns plan yaml get (or yaml-json+jq) per query. Calls at `:852`, `:871`, `:920`, `:945`, `:978`, `:1018`, `:1049` reload test/bindings bytes for field selection. `crates/tillandsias-plan/src/main.rs:3297-3320` reads/parses on each YAML invocation. | Parse bindings once and every test once; select and project phase/host/size/inputs/steps from retained typed documents. Batch metadata handoff to the existing launcher while preserving fallback/default and CRLF contracts. | <!-- cite-ok: pinned cdba630ce runtime algorithm audit; exact source span is evidence -->
| YAML validation | `scripts/lua/check-litmus-yaml-parses.lua:28-73` (`BATCH` loop) already batches 100 paths, verifies answer cardinality, but probes capabilities and starts the host again per batch. | Reuse nonempty/cardinality checks and parser; eliminate nested self-CLI calls by an in-process snapshot parse-errors API. Valid YAML is still not proof of runnable steps. | <!-- cite-ok: pinned cdba630ce runtime algorithm audit; exact source span is evidence -->
| Anchor resolution | `scripts/lua/check-cheatsheet-source-anchors.lua:58-76`, `:83-107` (`find_declared_elsewhere`, source-entry loop) reads each target per anchor; each failed declaration can walk/read live index and archive again. | Precompute order declaration -> ordered source locations and sources -> anchors. Preserve live-first/archive-byte-order diagnostics; do not resolve prose mentions as declarations. | <!-- cite-ok: pinned cdba630ce runtime algorithm audit; exact source span is evidence -->
| Requirements | `scripts/lua/check-requirement-ids.lua:77-124`, `:134-161` (specs/contents and ID-occurrence loops) walks specs, builds all line tables and retains contents, then scans again for duplicate IDs. It already avoids a second disk read itself. | Share a Rust requirement/id occurrence relation across checks, preserving numbered headings, tombstones, immediate-next-line rules and trailing heading failure. Avoid making an extra full-copy Lua corpus per check. | <!-- cite-ok: pinned cdba630ce runtime algorithm audit; exact source span is evidence -->
| YAML bridge | `crates/tillandsias-plan/src/lua_std.rs:218-228` (`yaml_table`) parses each string then converts the whole object into Lua. `json_table` query similarly converts/compiles filters (`:183-211`). | Cache parsed Rust documents by bytes+parser identity; project only requested fields/results through immutable handles. No parse per field/guard. | <!-- cite-ok: pinned cdba630ce runtime algorithm audit; exact source span is evidence -->
| Predicate memo | `crates/tillandsias-plan/src/lua_predicate.rs:1684-1693`, `:1771-1800` (`CacheEntry::still_valid`, `PredicateRegistry::eval`) hashes each recorded file on every hit; stores full source in memo keys; miss creates/loads another VM. | Reuse read-log semantics and class boundary, but compare dependencies to a snapshot digest table once per epoch; bound memo entries/bytes; private compiled handles per worker. | <!-- cite-ok: pinned cdba630ce runtime algorithm audit; exact source span is evidence -->
| Ledger | `crates/tillandsias-plan/src/lib.rs:470-532` (`Ledger::load_with_doc`, `collect_archive`) reads/parses base and archives; `crates/tillandsias-plan/src/fragments.rs:167-185`, `:198-212` independently reads/parses fragments for `load_all` and `malformed`. | Shared ParsedDocument with parse error, raw bytes and spans; reuse fold/from_doc and archive-aware resolution. Do not erase malformed-input visibility just because permissive lookup skips it. | <!-- cite-ok: pinned cdba630ce runtime algorithm audit; exact source span is evidence -->
| Ledger cache | `crates/tillandsias-plan/src/ledger_cache.rs:47-89`, `:160-206`, `:226-249` (`fingerprint_for`, `get_ledger`, `get_packet`) enumerates/stats base/fragments/archive for fingerprints, then JSON-deserializes the whole snapshot or opens redb for a packet. | Reuse disposable derived state, atomic publication and absolute-index separation. Upgrade content identity and fold identity. It is not currently a zero-I/O or immutable in-process snapshot. | <!-- cite-ok: pinned cdba630ce runtime algorithm audit; exact source span is evidence -->

The ledger fingerprint explicitly tolerates same-size/same-mtime stale reads
(`crates/tillandsias-plan/src/ledger_cache.rs` `fingerprint` documentation).
That tradeoff is not acceptable for deterministic
gate evidence: mutable fields, destructive edits, adversarial invalidation, and
deletions must be judged against exact bytes. Read availability is not gate
freshness. Cached data may fall back to rebuild; a cache error must not become
an empty passing population.

### 3.1 Existing indexes and local experts

- Reuse `methodology::Corpus` path/span indexing and parse-error separation
  (`crates/tillandsias-plan/src/methodology.rs` `Corpus::load`, `query`,
  `untrusted_hit`). It currently
  walks/loads/parses each file for each new Corpus, not a persisted exact index.
- Reuse `spec::Chunk` and Markdown/YAML/code span helpers, deterministic order,
  and declared corpus coverage (`crates/tillandsias-plan/src/spec.rs`
  `chunk_corpus`, `chunk_corpus_filtered`, `corpus_coverage`).
  `chunk_corpus_filtered` still chunks the entire corpus first.
  `walk_files` uses path.is_dir (not the script runner's no-descendant-
  symlink policy); its pruning/extension/root rules must not become a universal
  gate population accidentally. Images' copied cheatsheets are intentionally
  pruned for retrieval; a check of embedded-copy agreement still needs them.
- Published index precedent: `scripts/spec-index-ensure.sh:477-536` chunks <!-- cite-ok: pinned cdba630ce runtime algorithm audit; exact source span is evidence -->
  **before** fingerprint comparison, SHA-256 keys chunks/model/prefix, publishes
  immutable directories/current atomically. `_prune_entries` bounds retained entries.
  Reuse publication/delta/retention ideas, not the embedding dependency or the
  cost of rechunking to answer every “is it fresh?” question.
- `SpecIndexEntry::load_dir` reads/parses vectors and chunks, checks arity and
  takes commit/model markers (`crates/tillandsias-plan/src/spec_index.rs`
  `SpecIndexEntry::load_dir`, `read_marker`).
  Equal counts and a hex commit marker are not authentication of the content or
  vector/text pairing. Chunks are not a full byte-for-byte source store.
- `crates/tillandsias-plan/src/expert_serve.rs:57-102` (`CachedEntry`, `ServerState::entry`) caches an Arc entry by directory+chunks.jsonl mtime; <!-- cite-ok: pinned cdba630ce runtime algorithm audit; exact source span is evidence -->
  changes to vectors/markers alone do not change that key. It relies on immutable
  publication. Do not reuse this key for dirty mutable gate input.
- `crates/tillandsias-plan/src/groundtruth.rs` grader methods `ledger`, `corpus`,
  `spec_index`, `cheatsheets` already retain folded ledger, methodology corpus,
  spec entry, and cheatsheet chunks per grader; this is a good shared-session
  precedent. Local experts remain a cited/refusal research surface, not gate
  adjudicators. Their source commit frame is distinct from a dirty checkout.
- Existing exact-byte hashing precedent is `scripts/gate-stamp.sh` `compute`:
  path/type/content/modes, deletion membership, symlink target text and batched
  hashes. Preserve its staging/mode semantics at gate integration; do not replace
  it with a HEAD-only, mtime-only, or clean-status-only index stamp.

## 4. Rust test audit: scans, duplicated parsing, and what must remain real

The search covered Rust integration tests and inline test modules in the plan
crate, plus workspace Rust scan/read/parse/include carriers and the relevant
litmus/source-check crate. The following are the repeated-corpus candidates;
ordinary scratch filesystem/process tests are not mislabeled corpus overhead.
No tests were executed in this report-only session.

1. **Exact demonstrable duplicate**: `crates/tillandsias-plan/tests/lua_source_agreements.rs:157-196` (`explicit_manifest_cases_match_their_expected_guard_verdicts`) computes <!-- cite-ok: pinned cdba630ce runtime algorithm audit; exact source span is evidence -->
   the full outcomes once, then calls outcomes() again for each of **eight**
   negative IDs: nine complete evaluator runs in that one test. Each call reads
   the real module, creates a VM, parses the explicit manifest in Lua, and reads
   all named sources (`crates/tillandsias-plan/tests/lua_source_agreements.rs`
   `outcomes`, `outcomes_at`; `scripts/lua/source-agreements.lua`
   `source_agreements_text`, `source_agreements`).
   Manifest() also parses YAML independently in Rust for expected values.
   Reuse the actual outcome map inside this assertion; keep the independent
   expected-value parser and malformed-manifest negative controls.
2. **CLI evidence is intentionally separate**:
   `crates/tillandsias-plan/tests/lua_source_agreements.rs`
   `production_script_run_preserves_pinned_exit_stdout_and_stderr_bytes`
   spawns the production runner per manifest case and pins exit/stdout/stderr.
   A batched API needs equally explicit per-case evidence, and at least one
   genuine single-call path control. Do not erase the integration distinction
   merely to achieve a performance number. Its `repo_root` still uses compile-time
   manifest-root discovery, unlike recently corrected modules: include this
   target in cross-worktree subject/code identity verification.
3. **Repeated live ledger parse**: `crates/tillandsias-plan/src/answer.rs`
   `tests::live_ledger` calls base-only `Ledger::load`; multiple tests call it
   independently, including `already_is_not_a_ready_intent_but_the_ready_token_still_is`
   and `a_fixture_query_returns_a_resolvable_citation_whose_span_contains_the_packet_id`.
   `crates/tillandsias-plan/src/lib.rs` `tests::live_ledger` does likewise.
   That loader's `Ledger::collect_archive` reads archives
   every time. Share a pinned immutable live fixture within the test process;
   keep base-only vs folded expectations separate, and keep mutation-owned
   fixtures isolated. `crates/tillandsias-plan/src/forgotten.rs`
   `the_ranking_is_invariant_under_a_uniform_clock_shift` adds another live load.
4. **Repeated methodology corpus builds**: `crates/tillandsias-plan/src/methodology.rs`
   `tests::corpus` constructs a fresh corpus. Its tests
   `all_ten_canonical_questions_answer_with_an_exact_path_and_a_resolvable_file_line`,
   `an_unknown_path_returns_unsupported_never_a_guess` and
   `an_unrouted_or_ambiguous_question_is_refused` independently build/query it;
   verification also rereads cited files (the canonical-questions assertion
   calls `verify` again on failure). Share immutable corpus bytes
   across live tests, but retain independent citation reread/oracle controls
   rather than certifying index evidence against itself.
5. **Broad real corpus scan**: `crates/tillandsias-plan/src/spec.rs`
   `pruned_prefixes_are_not_indexed` chunks the whole live repository
   to assert pruning and extension-less coverage. Preserve this end-to-end
   inclusion test; most other chunk tests in that module use small synthetic
   strings/dirs. Do not force every test through a whole-repo snapshot just to
   save one scan. `crates/tillandsias-plan/src/groundtruth.rs` test helpers
   `committed_set`, `committed_sets` and `load_all` callers load committed
   YAML query sets/vector fixtures; grader retention already amortizes a run's
   corpus. Shared immutable query-set parsing is appropriate, not replacing
   the mutated/arity/wrong-frame fixtures with the live entry.
6. **Existing invalidation controls**: `crates/tillandsias-plan/src/ledger_cache.rs`
   tests `a_snapshot_from_another_binary_fails_closed`,
   `a_changed_corpus_is_a_miss_not_a_stale_answer`,
   `an_absent_cache_is_a_miss_not_a_failure`,
   `the_cache_serves_the_folded_value_not_the_base` and
   `snapshot_round_trips_folded_ledger` test different binary identity,
   new fragment, absent cache, folded value and snapshot reload.
   `crates/tillandsias-plan/tests/lua_predicate_classes.rs`
   `a_cacheable_verdict_is_re_evaluated_when_a_file_it_read_changes` tests
   changed-file memo invalidation; `fs_list_is_observing_only_and_absent_from_the_cacheable_class`
   pins listing to Observing. `crates/tillandsias-plan/src/lua_predicate.rs`
   tests `re_registering_a_predicate_invalidates_its_memo`,
   `read_log_authenticates_bytes_returned_to_lua` and
   `a_dangling_in_root_symlink_is_refused_by_every_write_verb` include source
   replacement, read-observation and missing/dangling-path containment controls.
   These need extending,
   not removing: same-size/restored-mtime edits, delete/rename, worktree split,
   parse-error state, membership and binary/input-manifest changes.
7. **Capability/process regression suite**: integration targets
   lua_predicate_classes, lua_observing_boundary, lua_proc, lua_proc_trace,
   lua_listen_unix, lua_std and lua_verdict_grammar, plus inline script_run and
   lua_process tests, protect boundaries/cleanup/outcomes. Their child-process
   invocations mostly test actual lifecycle behavior, not duplicate YAML work.
   Retain them. `crates/tillandsias-plan/tests/lua_std.rs`
   `no_caller_of_the_unsandboxed_opt_in_remains` does a real git grep for zero unsandboxed
   callers; it needs explicit tracked-file semantics in any indexed replacement.
   `crates/tillandsias-plan/tests/set_field_archive.rs` `fragments` enumerates
   the scratch fragment directory for `set_field_refuses_an_archived_order`;
   this is mutation verification, not a shared production-corpus scan.
8. **Existing structural Rust engine worth reusing**:
   `crates/tillandsias-litmus-rust/src/lib.rs:309-370` (`check_litmus_file`, `check_query`) parses litmus YAML then <!-- cite-ok: pinned cdba630ce runtime algorithm audit; exact source span is evidence -->
   reads/parses the Rust source per query, even when queries name the same file.
   TreeSitter adds a parse and Syn still runs; RustAnalyzer only probes --version
   (`parse_with_tree_sitter`, `parse_functions`, `rust_analyzer_version`), so
   do not promise semantic name/type resolution it does not do.
   Its `tests::check_source` helper drives owned source fixtures. Expose parse-from-snapshot
   entrypoints and reuse one per-file syntax product per parser identity.
9. **Workspace corroboration**: `crates/tillandsias-headless/tests/cache_peer_routing.rs`
   `test_cache_peer_directive_syntax`, `test_localhost_subdomain_acl_definition`,
   `test_cache_peer_access_rules` (and subsequent tests) repeatedly read the same squid.conf with
   cwd-relative fallbacks. A pinned test fixture can amortize this. Headless
   `crates/tillandsias-headless/src/main.rs`
   `every_inference_start_site_is_behind_the_kill_switch` and
   `the_kill_switch_scan_can_actually_fail` embed/rescan source or a fixture for kill-switch callsites
   with 400/1500-byte text windows, duplicating a scanner in a negative control.
   `crates/tillandsias-headless/src/vsock_server.rs` `scan_region`, `scan_until`,
   `scan_region_is_red_when_its_end_anchor_is_renamed` likewise has text-region helpers and an end-anchor
   control. Source embeddings bind compile-time bytes; runtime indexes must
   explicitly choose which frame is being tested. Structural queries can remove
   fragile proximity windows, but must preserve nonempty populations and real
   negative controls. This is a later targeted opportunity, not a blanket test
   migration or a claim that all Rust tests are slow.

## 5. Proposed Rust-hosted snapshot and precomputed full-text API

### 5.1 One authoritative byte frame per batch

Proposed internal components (names are design, not existing APIs):

```text
RepositorySnapshot
  identity: canonical worktree root + git-dir/common-dir identities + epoch
  manifest: sorted path bytes, kind, modes, symlink target, content SHA-256,
            absent/unreadable distinctions, source scope and ignore policy
  blobs: exact bytes + newline offsets; no lossy UTF-8/CRLF normalization
  parsed: Result<typed YAML / Rust syntax facts / section facts, ParseError>
  indexes: exact text candidates + structural relations + reverse dependencies
  producer: host artifact/behavior digest, parser/index ABI, policy bundle IDs
```

Read/parse once for the batch and expose bounded immutable Rust handles, not a
huge mutable Lua table copied into every VM. Suggested Lua surface:

```lua
local s = snapshot.open { scope = "litmus-source", expected_id = arg[1] }
local files = s:paths { glob = "openspec/litmus-tests/*.yaml" }
local doc = s:yaml("openspec/litmus-bindings.yaml")
local errors = s:parse_errors { kind = "yaml", paths = files }
local hits = s:search { literal = "name: litmus:example", scope = files }
local bindings = s:relation("litmus_bindings", "litmus:example")
-- Checks still own decisions, exceptions and established verdict grammar.
```

Every result carries snapshot identity and source path/span/digest. All glob
and text semantics must be specified (direct-child vs recursive, byte order,
tracked vs untracked/ignored, symlink policy, byte vs decoded text). Missing,
unreadable, unparseable, out-of-scope, empty-selected and too-large states are
distinct typed failures; absence is not an empty successful table.

Cacheable capability extension requires approval and a pinned allow-list test:
this is an immutable manifest **argument**, not ambient live fs.walk/list.
Existing listing is Observing-only by explicit ruling
(`crates/tillandsias-plan/tests/lua_predicate_classes.rs`
`fs_list_is_observing_only_and_absent_from_the_cacheable_class`). Keep it so. Cacheable code should
only receive already supplied snapshot handles; opening/validating a live
snapshot belongs to the observing Rust coordinator. New data dependencies
include membership/absence and relation inputs, not just positive file reads.

### 5.2 Precomputed full text, not embeddings

Build a path/extension inventory, exact blob table, newline offsets and byte-
trigram postings for selected textual gate roots (including scripts/lib,
scripts/lua, gate steps, litmus/bindings, methodology, authored and embedded
sources where the particular check requires them). Literal searches intersect
postings then verify matches against exact snapshot bytes. Short strings and
regex without safe required literals scan the declared snapshot scope. Never
assume the trigram prefilter is a regex engine or that tokenization/BM25 gives
complete substring results. Rust regex does final matching; unsupported syntax
fails explicitly. Binary/non-UTF-8 handling is per operation, not silently
converted into missing files. Index every byte required by those populations,
not just retrieval chunks or their first few thousand characters.

Add structural relations in separate versioned products:

- litmus ID -> declaration occurrences/file, phase/host/size/input globs,
  validated step AST/extractability; spec <-> binding edges; duplicate IDs and
  retired/grandfathered status are data, not overwritten map entries;
- requirement stable ID -> all heading/source/span occurrences, trace/order
  declarations -> locations, cheatsheet source anchors -> their targets;
- folded packet graph with archived/fragment provenance and existing ambiguity
  handling, dependency/release/split edges; never conflate active scheduling
  population with archived lookup history;
- Rust function/item/impl/call/argument syntax facts using existing Syn/
  TreeSitter foundations; full lexical identities rather than name-only first
  match. Macro expansion/cfg/name resolution are explicitly unknown unless a
  real semantic compiler query supplies them. AST containment is not proof of
  control-flow dominance or reachable execution.

Source relations cut repeated cross-file joins; Lua iterates results once and
applies policy. A build/parse alone is not a policy verdict. Preserve exact
legacy semantics and fixture-seam roots first, then propose intentional
semantic corrections separately (e.g. substring names vs parsed declarations).

### 5.3 Batched execution without global-state or process contamination

An explicit ordered manifest selects scripts and arguments. A Rust batch
coordinator owns one snapshot and a small worker pool. Each task has a fresh
capability environment, verdict slot, args, scope, deadline, read/dependency
log, stdout/stderr buffers and receipt. Compiled functions may be reused only
within isolated environments/worker-local safe factories; a mutable _ENV or
LuaTable must never escape one check into another. Reuse Rust parse/index and
bounded compiled artifacts, not polluted globals from reload.

The existing `cli_run` in `crates/tillandsias-plan/src/script_run.rs` exits the process; it cannot
simply be called in a loop. Extract an internal typed run result and adapt the
single-call CLI to it. Retain the existing classifier/verdict precedence,
no-verdict refusal, panic/timeout distinction, cancellation hooks and child
cleanup. Scope/out/trace ownership must be per task: READ_ROOTS is currently
process-global (`crates/tillandsias-plan/src/script_run.rs:217`, `:591-593`, `:882`; `READ_ROOTS`, `register`, `emit_timing`), output goes <!-- cite-ok: pinned cdba630ce runtime algorithm audit; exact source span is evidence -->
directly to process stdout/stderr, and signal installation is per CLI. These
need explicit ownership before parallel batch execution is safe.

Static snapshot-only checks may memoize complete typed verdicts with dependency
coverage and code identity. Observing/process/environment/clock checks always
execute fresh; their parsed immutable inputs may be reused. Bound external
processes through existing tillandsias-exec policy/supervision. Do not parallelize
independent-looking checks that mutate a shared fixture tree or observe each
other's environment. Report results in manifest order, not completion order;
all selected checks must produce exactly one terminal result.

## 6. Invalidation, races, and resource limits

### 6.1 Freshness contract

1. Enumerate the actual declared population using one batched tracked/untracked
   inventory plus explicit fixture roots. Capture dirty bytes even with unchanged
   HEAD; include added and untracked files when the check's scope includes them.
   Do not treat git status as a content proof. Record the selection/ignore/cfg
   policy itself as an input. A check using tracked git grep keeps tracked scope.
2. Hash each included current file once per gate epoch. Keep a content-addressed
   committed baseline and dirty overlay/tombstones; reuse parsed products and
   postings by content+parser/schema digest. Metadata/watchers can identify likely
   changes, but timestamp/size/inode equality cannot authorize a gate cache hit.
   Watch overflow/unknown state forces enumeration/revalidation. A full content
   validation is the safe default until a stronger trusted filesystem-change
   mechanism is demonstrated. This cost is included in the 10x target.
3. Deletes remove membership and outgoing relations; renames change path identity
   and glob eligibility even if content blobs are reusable. Negative dependencies
   (failed reads, missing IDs/files, empty directories) and duplicate/ambiguity
   sets invalidate when they become present or change. Mode/symlink changes and
   declared external-read roots have their own identities; never follow links
   outside approved roots. Preserve the existing gate stamp's index/worktree
   mode distinction on integration.
4. Cache namespace includes canonical worktree root and git-dir identity, not
   just common repo/HEAD. Shared content blobs are safe across worktrees; mutable
   manifests/verdicts are not. Scratch --index/fixture corpora cannot share live
   ledger state. No compile-time CARGO_MANIFEST_DIR is used as subject discovery.
5. Code keys include host behavioral manifest and artifact hash, Lua bundle or
   actual override bytes, class/ABI, arguments, selection/scope, parser/index
   schema, and any declared observing input. Environment/process results are
   not persisted as pure verdicts. A content change in a folding workspace
   dependency invalidates products even if main.rs and the ledger are unchanged.
6. Build snapshots into immutable content-addressed entries; publish manifest
   and completion marker atomically after verification. Revalidate membership
   and content at batch completion before accepting a gate receipt. A race
   produces snapshot-changed/refusal or one bounded retry, never an old green.
   Exact start/end validation cannot detect an adversarial change-and-restore
   between the two, and stat-before/after is not atomic snapshot isolation.
   Checking copied immutable bytes proves that captured frame; claiming a gate
   for the live tree needs the primary's final exact-byte stamp and, for stronger
   adversarial guarantees, a trusted immutable filesystem frame/writer exclusion.

### 6.2 Boundedness (proposed initial budgets, to be calibrated)

- Start with 1 indexing writer and min(4, available CPUs) static workers; global
  process/IO budget shared with the executor, not one unconstrained pool per
  script. CPU-only cold/warm deterministic checks must work offline.
- Initial configurable ceilings: 256 MiB resident snapshot/query products,
  32 MiB Lua heap per worker, 64 MiB compiled/memo products total, 3 published
  snapshots / 1 GiB disk. Record actual peak RSS and per-product sizes. These
  are design ceilings, not measured corpus-fit claims.
- Keep blobs once (mmap/read-only spill for large corpora), intern paths, retain
  projections instead of full YAML Lua copies, and stream paginated occurrences.
  Bound regex/filter caches too: `crates/tillandsias-plan/src/script_run.rs:468-482` (`register`'s `re_of`, `CACHE`) currently has a thread- <!-- cite-ok: pinned cdba630ce runtime algorithm audit; exact source span is evidence -->
  local HashMap with no eviction. Lua pairs creates and sorts key arrays
  (`crates/tillandsias-plan/src/lua_std.rs` `determinism`, its Lua `keys`
  helper); prefer sequences/projected views in large hot paths.
- Every request has maximum returned rows/bytes, deadline and cancellation;
  clipping is explicit and cannot count as exhaustive success. Large files
  can use streaming exact scans without silently leaving the gate population.
  Cap parser depth/expansion and indexing work; malformed/adversarial YAML and
  huge text must produce typed bounded failures. Lua memory limits need actual
  host implementation; do not imply current set_hook limits allocation.
- Coordinate readers with immutable handles; prune only unpinned entries, use
  atomic writes and corruption checks. Cache corruption/unwritable disk falls
  back to an equally bounded rebuild or typed cannot-run, never stale success.

## 7. Implementation order and acceptance

All steps below are proposals for separately owned implementation packets.
There is no nested migration assignment in this research report.

1. **Identity and counters first.** Generate complete behavioral/build-input
   manifests; fix ledger fold identity; add host/Lua/subject provenance fields.
   Count file opens/bytes, directory listings, YAML/AST parses, VM creations,
   policy compilations, spawns, result-cache hits, CPU/wall/RSS. Keep primary
   gate touch/worktree controls. Baseline an explicit static workload without
   running the full gate for every experiment.
2. **Snapshot service/library.** Immutable blobs/newline tables, parse products,
   typed failures, manifest identity, dirty overlays/deletes/renames and fixture
   roots. Reuse existing fold/from_doc/methodology/chunk/query parser code via
   parse-from-bytes APIs; no competing YAML implementation.
3. **Exact index and relations.** Precompute text postings and litmus/name/spec/
   order/requirement edges; expose bounded Rust and Lua read-only handles.
   Differentially verify completeness against direct scans before using indexes
   for gate decisions. Reuse actual step extraction, not an approximation.
4. **Typed batch coordinator.** Refactor runner result/output/read-root ownership;
   compile shipped text per isolated worker; run immutable checks in manifest
   order with bounded parallelism and per-check receipts. Keep Observing cases
   fresh and process cancellation semantics unchanged. Explicit approval covers
   cacheable snapshot capability and shipped/override selection policy.
5. **Pilot consumer cuts.** Bindings/name and parse-extractability batch,
   anchor-resolution relations, then litmus metadata handoff. Cut data access
   at these seams; keep Lua decision/exception code small. No corpus-wide shell
   loop translation. Fix source-agreements repeated outcomes locally as a
   separately verified test cleanup; keep CLI oracle coverage.
6. **Broaden only after proof.** Share immutable test corpus fixtures, add
   structural Rust relations for fragile source windows, and integrate gate
   receipts/stamps on the primary. Preserve native Windows/macOS/Linux controls;
   do not infer native process conformance from Linux or cfg-gated tests.

### Acceptance benchmark protocol (>=10x TARGET)

Use baseline and candidate release artifacts with recorded artifact SHA-256,
host/toolchain/features/target, source/bundle identity, canonical worktree,
fixture/corpus manifest digest and exact selected check IDs. Exclude neither
snapshot creation/validation nor report output from the applicable end-to-end
timer. Do not time a stale expert binary or invoke full/destructive gates in
the research worker. The primary owns eventual full-gate verification.

| Scenario | Required evidence / acceptance |
| --- | --- |
| Fixed static suite: YAML validation, bindings/name resolution, requirement IDs, anchor checks and selected source agreements | Exact same selections, exit/verdict/stdout/stderr ordering and per-check terminal count; independent negative controls. Warm end-to-end median **>=10x faster TARGET**, and p95 **>=10x TARGET** over paired runs. If either fails, report shortfall rather than claim acceptance. |
| Cold index absent, unchanged index warm, one dirty edit, same-length/restored-mtime edit, add/delete/rename, mode and symlink changes | Separate numbers for every state; cold build amortization break-even disclosed. Warm validation reads/hashes each input at most once per epoch; unchanged docs have zero fresh YAML/AST parses; changed docs parse once per parser identity. No same-mtime stale pass. |
| N checks × shared F files, doubled N and F | Opens/listings/parses do not multiply as N*F. Exact queries use postings/relations; a legitimate regex full scan is counted explicitly. No per-field YAML reader, per-name whole-corpus lookup or per-file self-CLI process. |
| Two worktrees, shared CARGO_TARGET_DIR, dirty source/test/Lua/host dependency only, unchanged HEAD | Each receipt names its own subject, host artifact and bundle/override; source skew cannot pass as current. Deleting a policy or relation input must invalidate/reject, not retain old globals or stale rows. |
| No index, corrupt/incomplete index, unwritable cache, vector service/GPU/network absent | Deterministic suite still executes equivalently by rebuild/direct snapshot scans or gives a typed cannot-run. No inference-generated answer or index error becomes PASS. |
| Malformed/duplicate-key YAML, missing file, zero selections, duplicate declarations, query clipping, OOM budget, worker panic/timeout/signal | Each remains visible and non-green where required, with no abandoned children and exactly one terminal state. Cache hits name the evaluated frame and dependency set. |
| Native Linux, Windows, macOS; one/multiple workers | Byte-equivalent deterministic outcomes and ordered diagnostics, reproducible source-frame receipts; caps respected, concurrent fixture mutations excluded. Report wall and CPU separately to expose parallel-only speedup. |

After 3 warmups, collect at least 30 interleaved paired runs per steady-state
scenario; use fresh cache namespaces for at least 10 cold runs without dropping
host caches destructively. Publish raw times, p50/p95, confidence/dispersion,
CPU/RSS/open/parse/spawn counters and per-check output hashes. Small isolated
microbenchmarks explain causes but cannot substitute for suite acceptance.
Runtime/external process tests and Cargo compile time are separate populations:
do not promise a 10x improvement to full build.sh --check because static checks
accelerate. Measure the primary full gate later and report its actual fraction.

## 8. Research outcome

The largest evidenced opportunities are shared parse/snapshot products,
precomputed structural joins and batched execution; build-time Lua bytecode is
secondary and carries a trust/ABI cost. Existing Rust code supplies most of the
necessary semantics, but its caches do not yet provide a complete content-bound
gate frame or authenticated policy provenance. The proposed implementation
starts with honest identities/invalidation and operation counters, then exact
indexing and batched consumers. No speedup or attestation guarantee is claimed
without the measurements and trust assumptions above.
