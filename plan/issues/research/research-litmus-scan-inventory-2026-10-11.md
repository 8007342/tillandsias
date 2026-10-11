> Research snapshot (Codex, branch research/litmus-lua-performance-20261011, frame cdba630ce). Kept verbatim for provenance. Its claims were re-verified against trunk ed7a73185 and the measured 2026-10-11 gate in plan/issues/gate-performance-research-distillation-2026-10-11.md (order 1604-fsxu), which is the current verdict; where the two disagree, the distillation stands.

# Research: litmus, script, Lua, and gate scan inventory

Date: 2026-10-11. Research snapshot: `cdba630cee433fa52366d29b3d5888a5d6177825`, branch `research/litmus-lua-performance-20261011`.
Disposition: research proposal for the primary investigator, not an implementation or approval to change gate coverage.

## Main finding

There is substantial avoidable work in **repeated source interpretation**, not just shell launch overhead. The highest-confidence candidates are name-to-file lookup in the binding checker, repeated registration-surface searches, independent overlapping tree walks, per-file external parsers, and historical floor retrieval. Porting a shell checker to Lua does not automatically remove its repeated scans: several ports intentionally preserve the old algorithm.

Target **at least 10x reduction in the static-check subsystem**, with exact verdict/coverage parity and measured before/after timing. A 10x reduction in the entire build gate is **not established** here. If static checks account for fraction `f` of total gate time, even a 10x static-check improvement yields only `1 / ((1-f) + f/10)` overall. A whole-gate 10x claim needs the primary investigator's profile, including compilation and behavioral fixtures.

## Scope, provenance, and read method

* Exhaustive tracked-file lexical census of `scripts/check*` direct children, `scripts/test*` direct children and support subtree, every `scripts/lua/` file, and all `openspec/litmus-tests/` files: **1,269 files**. Non-test data/readmes/groundtruth fixtures are retained in the inventory rather than silently excluded.
* Gate census includes every `scripts/gate-steps.d/*.step`, plus registration references in `build.sh`, `scripts/local-ci.sh`, and `scripts/hooks/*.sh`.
* Reads first used `project-info` file discovery, content search, and file reads. MCP discovery results cap at 200 entries and cannot expose an aggregate lexical census. **Filesystem fallback reason: not exposed**; read-only Node programs used `git ls-files -z` and `fs.readFileSync` to enumerate the entire population. No Python was used.
* Methodology wildcard lookup returned `confidence=unsupported`; capability query was then performed as required. It reported degraded/not-built experts and a source/binary behavior skew requiring rebuild. **Fallback reason: unavailable** for that lookup; `project-info_read_file` supplied `methodology.yaml` → `methodology.runtime_language_policy`. No runtime binary's behavior is assumed to match this checkout merely because it advertises a subcommand.
* Detailed human inspection focused on candidates surfaced by the exhaustive census. This is **not a claim that all 1,269 files were individually semantically reviewed**. Appendix A reproduces every file, every matching line number, gate registrations, policy-token lines, and repeated literal command-path references.
* Runtime implementations in Rust and the litmus runner/dispatcher are assigned elsewhere. Their paths appear here as **test inputs and registration references**, not as reviewed implementations. Only a published `rust_queries` example was inspected to establish the existing authoring seam.
* Work consisted of reads, three safe static-guard microbenchmarks, and this report. No entire build gate, runtime/destructive fixture, branch operation, commit, push, or production edit was performed. Existing `opencode.json` dirt was present at start.
* Parallel independent MCP reads/searches were used. This session exposes no agent-spawn/Task tool; no separate research workers were created here. This report is the bounded scan-inventory contribution to the requested parallel research.

## 1. Exhaustive population and lexical counts

| Population | Files | Bytes | Lines | Scan-marker lines | Enumeration-marker lines | Read-marker lines | Loop-marker lines | Process-marker lines | Predicate-marker lines |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `scripts/check*` | 125 | 1,265,338 | 25,036 | 365 | 67 | 300 | 413 | 1,258 | 345 |
| `scripts/test*`, including support | 524 | 4,429,249 | 89,123 | 2,761 | 69 | 1,786 | 945 | 9,420 | 2,746 |
| `scripts/lua/**` | 80 | 580,898 | 11,571 | 230 | 8 | 141 | 613 | 892 | 449 |
| `openspec/litmus-tests/**` | 540 | 2,805,759 | 42,945 | 2,099 | 44 | 441 | 643 | 4,949 | 2,101 |
| **Total** | **1,269** | **9,081,244** | **168,675** | **5,455** | **188** | **2,668** | **2,614** | **16,519** | **5,641** |

These are **matching source lines, not executed process counts, tree walks, or measured CPU operations**. Definitions and regexes occur in strings; inline comments and YAML scalar prose can contribute. Full-line `#`/`--` comments are excluded. Marker families overlap. The enumeration column deliberately uses the original lexical pattern (git ls-files/grep, find, glob); a separate `fs.walk` census finds **49 marker lines across 40 files**, including inline explanatory mentions. Appendix A preserves the exact patterns so neither census is oversold as an AST analysis.

Population details:

* 124 `scripts/check-*.sh` files and one additional `scripts/check*` file (`scripts/checksum.sh`).
* 521 shell paths under the test-prefix population, including four `scripts/test-support/*.sh` helpers; one PowerShell test; remaining test-prefix entries are data. This is not 521 directly runnable top-level tests.
* 80 Lua files: **42 `check-`**, **32 `test-`**, and six auditor/grading/entrypoint/module files.
* 540 litmus-tree files: **527 YAML files**, including groundtruth/fixture YAML, and **519 direct `litmus-*.yaml` definitions**.
* All 519 direct definitions contain at least one lexical `command:` line; total **3,096 command-key lines**, including rollback and other contexts. **518** contain `critical_path:` and **2,751** lexical step-key lines. **239** names contain `shape`.
* Only **one** direct definition declares `rust_queries:`; **zero** declare top-level `steps:`. This is a precise authoring-format observation, not proof that no structured assertions exist inside commands or that every shape test is useless.
* Only **25** direct definitions have `inputs:`, with **92** input-glob lines. Thus adding a fast index alone does not make all legacy tests safely diff-selectable; undeclared dependencies still need fail-closed full selection.
* Literal phases: 466 `pre-build`, 16 `post-build`, 12 `retired`, 10 missing; the other 15 include numeric and other phase strings. Their actual routing/validity is for the runner investigation; this inventory does not adjudicate them.

### Repeated literal source targets inside command-key lines

| Target | Command lines mentioning it | Distinct definitions | Example test evidence |
|---|---:|---:|---|
| `crates/tillandsias-headless/src/main.rs` | 128 | 54 | `openspec/litmus-tests/litmus-accel-envelope-reaches-the-forge.yaml:53,58` | <!-- cite-ok: pinned cdba630ce algorithm/callsite audit; exact span is evidence -->
| `images/default/lib-common.sh` | 119 | 35 | `openspec/litmus-tests/litmus-accel-envelope-reaches-the-forge.yaml:63,73` | <!-- cite-ok: pinned cdba630ce algorithm/callsite audit; exact span is evidence -->
| `scripts/plan-binary-probe.sh` | 81 | 32 | `openspec/litmus-tests/litmus-added-fragment-parse-gate-shape.yaml:44,51` | <!-- cite-ok: pinned cdba630ce algorithm/callsite audit; exact span is evidence -->
| `crates/tillandsias-headless/src/tray/mod.rs` | 59 | 21 | `openspec/litmus-tests/litmus-agent-selection-menu.yaml:33` | <!-- cite-ok: pinned cdba630ce algorithm/callsite audit; exact span is evidence -->
| `build.sh` | 52 | 30 | `openspec/litmus-tests/litmus-build-cache-transparent.yaml:21,37` | <!-- cite-ok: pinned cdba630ce algorithm/callsite audit; exact span is evidence -->
| `images/default/config-overlay/mcp/forge-plan.sh` | 42 | 8 | `openspec/litmus-tests/litmus-expert-capability-skew-honesty.yaml:202,207` | <!-- cite-ok: pinned cdba630ce algorithm/callsite audit; exact span is evidence -->
| `scripts/cycle-metrics.sh` | 37 | 7 | `openspec/litmus-tests/litmus-build-test-timing-telemetry-shape.yaml:54,62` | <!-- cite-ok: pinned cdba630ce algorithm/callsite audit; exact span is evidence -->
| `images/inference/entrypoint.sh` | 37 | 8 | `openspec/litmus-tests/litmus-inference-model-preload-policy.yaml:89,108,116,124` | <!-- cite-ok: pinned cdba630ce algorithm/callsite audit; exact span is evidence -->
| `images/git/entrypoint.sh` | 36 | 16 | `openspec/litmus-tests/litmus-git-mirror-yaml-gate-shape.yaml:70,84,95` | <!-- cite-ok: pinned cdba630ce algorithm/callsite audit; exact span is evidence -->
| `crates/tillandsias-headless/src/vault_bootstrap.rs` | 33 | 13 | `openspec/litmus-tests/litmus-codex-api-key-env-var.yaml:34,44,63` | <!-- cite-ok: pinned cdba630ce algorithm/callsite audit; exact span is evidence -->

Counts are deduplicated per command-key line, not per file access. They include execution/source/grep arguments and can undercount variable-built paths and multiline YAML values. They demonstrate shared inputs and index opportunities, **not 128 measured reads** of `main.rs`.

## 2. Worst offenders: concrete algorithms and rewrite plans

| Candidate and evidence | Current avoidable work | Exact proposed replacement; preserve the property |
|---|---|---|
| `scripts/lua/check-litmus-bindings.lua:69-86,151-159,210-243,259-278` | Builds a disk-name set, then `file_named()` rereads the entire litmus tree until a substring match for each queried name. The touched-corpus advisory calls this for every bound name and launches `run-litmus-test.sh --parse-only` per non-retired file. Worst-case lookup is bound-names × 540 files, independent of shell removal. | Parse the corpus once into `name -> ordered candidates`, file bytes, declared specs, phase, and extraction outcome. O(1) map lookup; parse-only outcomes in a single bulk request using the **same runner parser**, not a new approximation. Preserve substring/first-byte-order legacy selection initially, including prefix ambiguity, and change to exact names only with explicit compatibility tests. Preserve new-binding refusal versus existing advisory and retired/grandfathered cases. |
| `scripts/check-added-test-is-referenced.sh:82-133,145-153,170-194` (`_is_referenced`, `_grandfathered`) | The invariant surface list is already hoisted; however the standing-count loop still performs basename extraction and `grep -rqlF` over the surface per top-level test. This is tests × surface bytes. | Build the declared surface once; use multi-pattern literal matching for **all candidate basenames** and retain hits in a map. Preserve substring semantics at first: comments currently count and a simple token parser may silently change answers. Added candidates, standing counts, missing patterns, warning/refusal flag, and grandfathering remain distinct. | <!-- cite-ok: pinned cdba630ce algorithm/callsite audit; exact span is evidence -->
| `scripts/lua/audit-guard-activation.lua:57-100,104-154` | Good existing byte/read cache eliminates repeated I/O, but `find_invoker()` still scans surface contents for each guard. It audits only shell guards, not migrated Lua guards; this limitation is explicitly documented `:29-35`. | One multi-pattern pass over ordered surface files creates `guard -> first invoker`, excluding self/auditor exactly. O(surface bytes + matches), rather than guards × surface bytes. Keep literal/comment semantics for parity; a subsequent scoped shell/YAML invocation parser can strengthen activation only as a separate approved change. Widening coverage must not be hidden in a performance port. |
| `scripts/check-litmus-dead-inputs.sh:33,43-76` (`tracked`, `globs`, `checked` loops) | 519 awk launches even though only 25 files are annotated; 92 globs each linearly walk 11,068 tracked paths until first match. | One sanctioned YAML parse, one tracked-path manifest, compiled Bash-compatible glob set and prefix buckets; reuse one result per unique glob. Preserve `[[ path == glob ]]` semantics: `*` crosses `/`, not git pathspec semantics. Check empty populations/unreadable metadata explicitly without disguising them as valid no-input definitions. | <!-- cite-ok: pinned cdba630ce algorithm/callsite audit; exact span is evidence -->
| `scripts/check-litmus-pin-claims.sh:56-58,78-107,153-176` (`scan_corpus`, `existing`, `bound`) | Separate names/bindings parsing, `find` + per-script grep/sed, then per-line token-extraction grep/sed. Existing membership checks correctly avoid SIGPIPE and forks but still search newline-framed strings. | Extract claim tokens once while indexing shell/C source; hash sets for declared/bound names; preserve wrapped-token exclusion and current scan suffixes. The pin-checker's population differs from the broader activation auditor; retain separate projections over the shared index. | <!-- cite-ok: pinned cdba630ce algorithm/callsite audit; exact span is evidence -->
| `scripts/check-litmus-line-windows.sh:65-86,94-100` (`scan`, `DISPO`) | One basename+awk pair per YAML and disposition grep per hit. Separate corpus pass from other litmus guards. | On already-parsed YAML, inspect only critical-path commands, use a disposition set keyed exactly as today (test, not moving line). Scoped shell parsing distinguishes actual grep flags from quoted patterns/rollback. Preserve strict versus advisory modes and justified fixture windows. | <!-- cite-ok: pinned cdba630ce algorithm/callsite audit; exact span is evidence -->
| `scripts/check-litmus-steps-can-fail.sh:59-88` (`branch_token`, `tail_expr`) | Reads every file line in Bash; two `tr`/`sed` branch-token pipelines for each candidate. It sees a raw line, not necessarily a parsed executable command. | A shared shell command representation compares the relevant final success/failure output branches; initially reproduce quote normalization and FIRST-word comparison before strengthening. Keep valid `echo A`/`echo B` with different verdicts. | <!-- cite-ok: pinned cdba630ce algorithm/callsite audit; exact span is evidence -->
| `scripts/check-litmus-mutation-arms-mutate.sh:84-162` (`strip`, `mutates`, `flush_step`) | Already ONE awk invocation across corpus: do not misidentify it as per-file process explosion. But it independently reparses YAML step boundaries and textual write idioms. | Reuse parsed steps + shell effect summaries; delegated fixtures remain accepted and are separately tested. Verify an intended mutation actually applied and caused the required red; a write token alone is not behavioral proof. Preserve legacy boundary asymmetry during parity migration or explicitly approve its correction. | <!-- cite-ok: pinned cdba630ce algorithm/callsite audit; exact span is evidence -->
| `scripts/check-litmus-grep-escapes.sh:91-92` (`checked`, `hits`, `AWK_RULE`) | Two find traversals: count and extraction; xargs awk is already batched. | Share corpus enumeration and parsed command regex arguments. Keep portable grep-versus-Rust-regex distinctions; do not ban escape characters in arbitrary quoted data. | <!-- cite-ok: pinned cdba630ce algorithm/callsite audit; exact span is evidence -->
| `scripts/check-source-slice-bounds.sh:46-68,74-114` (`crate_src`, `needle`, `_needle_re` loops) | Per Rust file, walks parents looking for Cargo.toml; each symbol-shaped split needle launches escaping sed plus recursive grep over its crate. Comment says one pass per crate, actual inner lookup can scan the crate per needle. | Build crate ownership and scoped Rust item-declaration index once (including modifiers and macros); resolve all split-bound references against the right crate in O(1) map lookups. Then replace source tests' neighbor-name split ranges with balanced item scopes. Preserve absence detection; do not match the split literal itself as a declaration. | <!-- cite-ok: pinned cdba630ce algorithm/callsite audit; exact span is evidence -->
| `scripts/check-spec-script-paths.sh:51-62,70-102` (`rows`, `seen`, `in_baseline`) | Per-spec awk, string-growing `seen` set and baseline substring membership, repeated stat resolution per distinct pair. | One Markdown token extraction over indexed spec files; ordered `(spec,path)` set, parsed baseline set and path-existence map. Keep line-local exemptions and the existing first-seen dedup semantics initially; maintain zero-population/unavailable verdict. | <!-- cite-ok: pinned cdba630ce algorithm/callsite audit; exact span is evidence -->
| `scripts/check-dead-env-branches.sh:201-291,305-362` (`reads`, `gating`, `assigns`, `docs`) | Several whole-source-tree passes for reads, gating reads, assignments, joined Rust statements and documentation; additional evidence extraction. | One pass yields environment read/write/default/doc records with file spans; hash-set joins produce tunable/unassigned/dead classifications. Shell and Rust parsing must distinguish doc comments, examples, scoped env assignments, wrapper `.set`, and nonempty defaults. This is not permission to erase its self-test/negative controls. | <!-- cite-ok: pinned cdba630ce algorithm/callsite audit; exact span is evidence -->
| `scripts/lua/check-bash-dialect.lua:90-93,143-154,598-609,628-736` | Repeated line/regex passes per file, repeated `lines_of(full)` allocation, `enclosing_function()` backward/forward search at stat sites, per-site function-wide searches. The Lua port has already eliminated external grep spawns; 63 lexical scan markers are mostly its own matcher vocabulary. | Parse/tokenize a shell file once, retain line offsets, command substitutions, heredocs, function intervals, invocation argv and scoped portability facts. O(1) enclosing-function lookup and function-level GNU/BSD stat pairing. Compile rules once; dispatch prefiltered rules without copying full line arrays repeatedly. Preserve Bash-3.2 edge cases, explicit markers and site allowlist tests. |
| `scripts/lua/check-shell-ratchet.lua:54-118,222-264` | Walks scripts, litmus, gate data and Lua separately. For each of two floors, lists its git history and launches git show for HEAD and every historical commit. At snapshot, 58 and 39 relevant history commits: **99 potential git-show launches + 2 logs** on the full descent path (not measured launches). | Share present-tree index; obtain floor blob IDs in one git history query and stream all unique blobs using `git cat-file --batch`. Compute the per-key intersection/minimum across reachable history, preserving the CURRENT-floor-versus-EVERY-earlier-version rule. Cache by exact history/HEAD and dirty floor content, never only filename or mtime. Do not weaken to predecessor-only comparison. |
| `scripts/check-jq-callsite-ratchet.sh:67-100,104-116,150-187` (`population`, `filter_of`, `resolve_plan`) | Already batches grep counting; separate population/allowlist/floor parsing and per-new-site filter extraction/CLI classification remain. | Shared shell/YAML argv index, count map, floor hash join, one batch classifier call for new filters. Preserve historical floor, bootstrap population, file-specific new debt and could-not-run-on-empty behavior. | <!-- cite-ok: pinned cdba630ce algorithm/callsite audit; exact span is evidence -->
| `scripts/check-terminology.sh` (`parse_dict`, `DICT_ROWS`, `_hits`); `build.sh` (`_term_memo`, `_term_t0`) | Already improved to one awk per locale with values × dictionary rows and input-digest memoization. Old 14–33s comments are historical, not current measurements. | If primary profile still shows cost, parse TOML values and wrong-variant dictionary once; multi-pattern matcher over values; preserve report ordering and current matching/exemption behavior. Keep memo invalidation on dictionary, locale and checker inputs. Do not count obsolete historical slowness as a fresh win. |
| `scripts/check-no-python-scripts.sh`, `scripts/check-cheatsheet-sources.sh`, `scripts/check-cheatsheet-tiers.sh` (`resolve_target_binary`, `POLICY_BIN`) | Already Rust-backed policy guards. Each wrapper still calls cargo build and binary discovery. Repeated invocations across gate, local CI or fixtures can repeat Cargo resolution/startup. | One explicit policy build/precondition per gate, pin a runnable source-attested binary, dispatch existing commands or a proposed bulk policy interface. Preserve redirected CARGO_TARGET_DIR and cross-platform run-don't-stat tests. Rust policy implementation performance is owned by the other investigator. |

### Overlapping Lua scan families (individual deciders)

All 42 Lua `check-` files were included in the census. The following are the actual walker-oriented source families; the remaining nonwalking checks are still inventoried in Appendix A. A walk is often **subtree-scoped**, not a repository-wide scan.

* Crate/source corpus: `scripts/lua/check-ca-path-literals.lua:49-65` (crates/scripts/images), `scripts/lua/check-state-root-literals.lua:37-55`, `scripts/lua/check-secure-wire-single-reader.lua:33`, `scripts/lua/check-framing-raw-decodes.lua:60`, `scripts/lua/check-wsl-exe-single-constructor.lua:33`, `scripts/lua/check-manifest-dir-env.lua:48`, `scripts/lua/check-seam-writers-canonical.lua:26`, `scripts/lua/check-podman-sync-budgets.lua:29`, `scripts/lua/check-enclave-membership-documented.lua:55`, `scripts/lua/check-exec-argv-vector-workarounds.lua:37`, `scripts/lua/check-unique-bin-names.lua:23` (Cargo manifests also matter). These can share reads/parsed items; predicates and baselines remain separate. <!-- cite-ok: pinned cdba630ce algorithm/callsite audit; exact span is evidence -->
* Shell/script corpus: `scripts/lua/check-bash-dialect.lua:114,745`, `scripts/lua/check-backgrounded-jobs-redirect-stderr.lua:53`, `scripts/lua/check-bash-composition-hazards.lua:52`, `scripts/lua/check-portability-idioms.lua:59`, `scripts/lua/check-fixture-prunes-checkout.lua:37,39`, `scripts/lua/check-no-spawn-in-if-not.lua:32-53` (tracked enumeration rather than fs.walk). Share shell tokenization and root/fixture effect facts; keep historical scope and exemptions. <!-- cite-ok: pinned cdba630ce algorithm/callsite audit; exact span is evidence -->
* Litmus/source agreements: `scripts/lua/check-litmus-bindings.lua:71`, `scripts/lua/check-litmus-yaml-parses.lua:38`, `scripts/lua/check-shell-ratchet.lua:64`, and the shell guards above all revisit the litmus tree. **The YAML parse guard already batches 100 files per validate-yaml request** (`scripts/lua/check-litmus-yaml-parses.lua` `BATCH` and its reader loop); improve parse reuse instead of claiming it has a one-process-per-file defect. <!-- cite-ok: pinned cdba630ce algorithm/callsite audit; exact span is evidence -->
* Documentation/registration corpus: `scripts/lua/check-cheatsheet-refs.lua:49,58-62,90-106` walks cheatsheets twice and rereads them for annotation and See-also passes; `scripts/lua/check-cheatsheet-source-anchors.lua:67,83`, `scripts/lua/check-requirement-ids.lua:77`, `scripts/lua/check-centicolon-ratchet.lua:62`, `scripts/lua/check-toolchain-pinned.lua:71`, and `scripts/lua/audit-guard-activation.lua:110,147` can share enumerations and documents. Use line/section records and a path set, not repeated `fs.exists` for every repeated reference. <!-- cite-ok: pinned cdba630ce algorithm/callsite audit; exact span is evidence -->
* Ledger/fragment corpus: `scripts/lua/check-all-fragments-intact.lua:81`, `scripts/lua/check-fragment-backlog.lua:36`, `scripts/lua/check-fragment-status-loss.lua:72`; reuse raw fragment parse records when the exact tree/base is shared, but do not substitute raw YAML facts for folded status/LWW results. `scripts/lua/check-launch-artifacts-untracked.lua:65` combines filesystem and git state, which needs both identities in any cache. <!-- cite-ok: pinned cdba630ce algorithm/callsite audit; exact span is evidence -->
* Four independent shell-ratchet populations are at `scripts/lua/check-shell-ratchet.lua:54,64,112,117`. Pure source agreements already use explicitly named files and do not walk or spawn (`scripts/lua/source-agreements.lua` `read`, `evaluate_case`, `required_fields`); a proposed index should improve reuse without turning them into full-tree scans. <!-- cite-ok: pinned cdba630ce algorithm/callsite audit; exact span is evidence -->

### Exhaustive shell-check enumeration-marker set

The lexical census identified 36 `scripts/check*` files with enumeration markers. For completeness, these are all of them (some enumerate a **diff** or fixture, not a full source tree):

* `scripts/check-added-fragments-parse.sh:110`; `scripts/check-added-test-is-referenced.sh:146`; `scripts/check-arrival-routing.sh:172`; `scripts/check-cheatsheet-frontmatter.sh:61`; `scripts/check-dead-env-branches.sh:203,232,265`; `scripts/check-declared-closures-added.sh:69`. <!-- cite-ok: pinned cdba630ce algorithm/callsite audit; exact span is evidence -->
* `scripts/check-enclave-network-internal.sh:134`; `scripts/check-exact-version-literal-added.sh:53,61`; `scripts/check-fragment-closure-evidence-added.sh:77`; `scripts/check-fragment-ts-skew.sh:63`; `scripts/check-host-tools.sh:111`; `scripts/check-issue-citation-convention.sh:109`. <!-- cite-ok: pinned cdba630ce algorithm/callsite audit; exact span is evidence -->
* `scripts/check-jq-callsite-ratchet.sh:69,71`; `scripts/check-litmus-dead-inputs.sh:33,90`; `scripts/check-litmus-expression-pinning-added.sh:103`; `scripts/check-litmus-grep-escapes.sh:91,92`; `scripts/check-litmus-pin-claims.sh:79`; `scripts/check-macos-stock-binaries.sh:41`. <!-- cite-ok: pinned cdba630ce algorithm/callsite audit; exact span is evidence -->
* `scripts/check-markdown-distillation.sh:69`; `scripts/check-no-tracked-binaries.sh:70`; `scripts/check-packet-tier-declared.sh:56`; `scripts/check-plan-binary-probe-usage.sh:112,118,119,237,314`; `scripts/check-purge-clears-vault-credentials.sh:56,83`; `scripts/check-refusal-affordance-added.sh:101,114,121`. <!-- cite-ok: pinned cdba630ce algorithm/callsite audit; exact span is evidence -->
* `scripts/check-rust-source-pin-added.sh:130,135`; `scripts/check-scorable-obligation-added.sh:135`; `scripts/check-script-exec-bits.sh:47,98,154`; `scripts/check-sigpipe-verdict-pipelines-added.sh:89,90,103,261,332`; `scripts/check-skill-canonicalization.sh:94,185,186`; `scripts/check-skills-single-source.sh:80,107,146,160,187,205,206,217`. <!-- cite-ok: pinned cdba630ce algorithm/callsite audit; exact span is evidence -->
* `scripts/check-source-slice-bounds.sh:46,114`; `scripts/check-spec-script-paths.sh:51`; `scripts/check-tracked-files-unwritten.sh:53`; `scripts/check-tray-string-corpus-drift.sh:62`; `scripts/check-unrunnable-platform-arms.sh:131`; `scripts/check-windows-tray-clippy.sh:58,86`. <!-- cite-ok: pinned cdba630ce algorithm/callsite audit; exact span is evidence -->

Appendix A also emits all 45 test-prefix files and 30 litmus-tree files with enumeration markers, plus every zero-marker file. Those fixture enumerations are not automatically waste: scratch repo state and clean teardown are meaningful test inputs.

## 3. Gate registrations, repetitions, and process-heavy fixtures

**161 `.step` files**: 154 `STEP_SCRIPT`, seven `STEP_LUA`; all 161 have `STEP_SECOND_REGIME`. The directory's 162nd tracked entry is README.md. No two `.step` entries name the same literal target at this snapshot. Literal STEP_PLATFORM/STEP_CLASS fields were absent; do not infer lack of platform or change-class behavior from that lexical observation.

Gate-loop evidence: `build.sh` `_run_gate_steps` at `build.sh:1934-1954,2012-2015,5247`; `_preflight_roster` at `build.sh:640-663`; `_pf_predecide` is called by `_pf_launcher` at `build.sh:585` and the reporter at `build.sh:1117`. It repeats several header sed/head pipelines and the preconditions awk for each guard (`build.sh:471-576`). Proposed improvement: parse each header and registry once, share its decision between launcher and reporter, and use a single ordered registration model. Preserve arguments, serial declarations, gate-only restrictions and could-not-run versus refusal classifications. The current deadline/polling implementation is not reviewed here. <!-- cite-ok: pinned cdba630ce algorithm/callsite audit; exact span is evidence -->

Registration overlap is **evidence to profile, not permission to delete a guard**:

* **Confirmed duplicate call sites in the same --check arm:** `scripts/test-land-queue.sh` is a `STEP_SCRIPT` target (`scripts/gate-steps.d/286-1461-5rm6.step:13`) run by `build.sh` `_run_gate_steps` at `build.sh:5247`, and is called again inline at `build.sh:5618-5619`. Both are within the `FLAG_CHECK` arm beginning at `build.sh:2606`; the step has no custom skip declaration. A successful uncached full --check reaching both sites runs the fixture twice. Keep one registered execution with all 16 current arms and second-regime evidence, and remove only the duplicate invocation after primary confirmation. No current fixture timing was measured; the 10s/14s source comments are historical. <!-- cite-ok: pinned cdba630ce algorithm/callsite audit; exact span is evidence -->
* `scripts/check-plan-binary-current.sh` occurs in step 095 and at `build.sh:1039`; different preflight/gate contexts can legitimately require separate probes. <!-- cite-ok: pinned cdba630ce algorithm/callsite audit; exact span is evidence -->
* `scripts/verify-version-monotonic.sh` occurs in step 170 and at `build.sh:1676`, plus local CI. Check control flow and changed state before memoizing. <!-- cite-ok: pinned cdba630ce algorithm/callsite audit; exact span is evidence -->
* Sixteen step targets also have non-comment literal references in local CI: base64, container-bases, enclave-expect-none, spec-index-resolution, cheatsheet-tiers, markdown-distillation, tracked-binaries, no-python, cheatsheet-frontmatter, version-monotonic, gate-fast-refusals, spec-index tier/repo-rung fixtures, activation audit, centicolon grade/ratchet. A literal reference can be an existence/error branch, not invocation; Appendix A gives the exact rows. `scripts/local-ci.sh:1806-1830,1901-1958` concretely runs dead-input, activation and policy guards. Reuse only when snapshots and regimes really match. <!-- cite-ok: pinned cdba630ce algorithm/callsite audit; exact span is evidence -->
* Hook coverage: base64 executes on the plan-only pre-push lane (`scripts/hooks/pre-push-local-gate.sh:1650-1666`); added-test references are checked at `scripts/hooks/pre-push-local-gate.sh:2183-2207`. Guards protecting a lane bypassing the main gate cannot be dropped just because the gate also registers them. <!-- cite-ok: pinned cdba630ce algorithm/callsite audit; exact span is evidence -->

Examples of high **lexical** process-marker counts (not measured process totals):

| Fixture | Process-marker lines | Scan-marker lines | What to retain |
|---|---:|---:|---|
| `scripts/test-relay-preflight.sh` | 130 | 16 | Real scratch Git repos, branching/refuse/order behavior (`_run`, `_clone`, `CLONE_A`, `CLONE_E`); repeated cloning/seeding can use immutable seed objects and isolated worktrees, not mocked Git semantics. |
| `scripts/test-check-bash-dialect.sh` | 126 | 4 | Rule/control matrix and real stock-shell compatibility; move pure guard evaluation into an in-process table while retaining CLI/platform integration cases. |
| `scripts/test-land-queue.sh` | 112 | 14 | Queue/merge/refusal transitions; batch assertions over captured outputs and share safe immutable setup, but never share mutable queue state across arms. |
| `scripts/test-check-credential-channel.sh` | 91 | 22 | Credential channel negatives and injected failures; do not replace actual secret-transport behavior with source-word checks. |
| `scripts/lua/test-carried-obligations.lua` | 89 | 16 | Constructed diff and obligation transitions; in-process pure decision cases plus retained real CLI/Git path. |
| `scripts/test-plan-only-lane-structural.sh` | 75 | 11 | Mutant non-empty/intended-edit/syntax checks and behavioral refusals (`_mut_intended`, `MUT_A`, `MUT_B`, `MUT_C`, `MUT_D`). These are valuable despite their grep/sed setup. |

Fixture setup reuse is a secondary optimization, not a license to collapse different behavioral states. Prioritize source-predicate batching first; isolated subprocesses are necessary when testing exit, signal, environment, stderr/stdout, filesystem permissions, CLI or cross-platform semantics.

## 4. Behavior versus source-string checkboxes

`shape` naming is not a reliable classifier. Three concrete categories:

1. **Useful behavior fixtures** execute the product/helper with controlled input and assert output/state. `openspec/litmus-tests/litmus-inference-model-preload-policy.yaml` (`critical_path` steps "default policy on a 32GB host emits the exact pinned line", "sourced mode is SILENT and exports the derived limit (entrypoint owns the single log line)", and "every transport failure maps to a NAMED reason from the closed vocabulary") exercises RAM policy, overrides, silent sourced behavior and stubbed endpoint failures. Keep these. Its source-only steps concerning entrypoint orchestration, startup-context wiring and never-block guards should be indexed/scoped separately, not used to justify deleting the behavioral half.
2. **Useful structural assertions** prove wiring or forbidden bypasses that are difficult to exercise on every host. Prefer item/command-scoped syntax predicates and kill controls over whole-file word searches. Existing Rust authoring seam: `openspec/litmus-tests/litmus-podman-idiomatic-launch-routing.yaml` (`rust_queries` IDs `podman-idiomatic-patterns.rust.run-opencode-web-debug-param@v1` and `podman-idiomatic-patterns.rust.caddy-reload-shared-podman-command@v1`) declares two queries with explicit file/method/parameter/type/usage, alongside the retained cargo test `tests::idiomatic_podman_launch_paths_do_not_bypass_shared_layer` in `critical_path`. This is the only such top-level definition in this census. The operational availability/implementation of bulk processors is not established by that example.
3. **Source-string checkboxes** only find words that can be present in comments, unreachable code or unrelated functions. `openspec/litmus-tests/litmus-git-mirror-yaml-gate-shape.yaml` (`critical_path`) repeatedly greps the same hook for `plan/`, `ruby`, `exit 0`, `exit 1`, `mktemp`, and function words. Its step "functional gate tests pin warn-only grammar and salvage routing (tests 5-6)" searches for `Test 5`, `Test 6`, and a salvage string in a fixture; that proves mentions, not that the fixture runs or discriminates. The correct replacement is execute existing pre-receive fixtures for push acceptance/rejection and structurally assert only remaining hook/config wiring. Preserve original test IDs and failure causes in a batched result envelope.

A row named MUTATION must mutate or delegate, but the mutation-arm checker is itself only a textual effect approximation (`scripts/check-litmus-mutation-arms-mutate.sh` `mutates`, `flush_step`). Actual mutant discrimination remains essential. `scripts/test-plan-only-lane-structural.sh` (`_mut_intended` and the `MUTATION SETUP` checks) specifically prevents empty/truncated mutants from being mistaken for useful red controls. Do not remove that coverage to speed the gate.

## 5. No-Python, base64, generated scripts, and evasion

Canonical authority: `methodology.yaml` → `methodology.runtime_language_policy.tlatoani_hard_no_python` and `methodology.runtime_language_policy.base64_script_injection_ban`. No Python runtime/harness/repository scripts; executable scripts concealed in base64 are forbidden regardless of language. Ordinary base64 data encoding is not the banned property.

### Current scans and their limitations

* No-Python guard is already Rust-dispatched (`scripts/check-no-python-scripts.sh` `resolve_target_binary`, `POLICY_BIN`, and the `check-no-python-scripts` exec). This audit does not inspect its runtime implementation and makes no claim about its exact scan cost or evasion coverage.
* Base64 guard (`scripts/lua/check-no-base64-script-injection.lua` `DECODE`, `EXECUTABLE`, `res`, `candidates`) searches **all tracked files** with git grep, excluding itself, Markdown, plan/archive and methodology.yaml, then rereads candidate files. It refuses when shell decode and `chmod +x`/PODMAN-bin text occur **anywhere in the same file**. This is a heuristic, not producer-to-execution dataflow.
* The same base64 guard's `res.status`/`res.code` candidate filter treats real git errors like no matches; its `pcall(fs.read, f)` loop silently skips unreadable candidate files. These can yield an unexamined clean verdict. A Rust-backed replacement must distinguish exit 1/no match from command/IO failure and report examined population.
* Same-file conjunction can false-positive on legitimate data decoding next to an unrelated executable stub. Conversely it can miss `decode | bash`, `bash decoded.sh` without chmod, PowerShell FromBase64String/EncodedCommand, library decode APIs, generated paths, cross-file producers and string-assembled interpreter names. These are coverage classes to test, not claims of live violations in runtime implementation.

### Concrete scoped examples

* **Legitimate data:** `scripts/test-codex-device-auth.sh` (`VAULT_CAPTURE`, `VAULT_ARGV_LOG`, `encoded_fixture`) transports credential JSON through stdin/base64, decodes to JSON, compares the document and checks it did not leak into argv. `scripts/test-codex-oauth-harvest.sh` (`VAULT_VALUE`, `HISTORY_DIR`) decodes captured vault documents. `scripts/test-provider-device-auth.sh` (`DOC`, `STUB` heredoc) writes a visible shell stub whose response is encoded JSON data; the encoded object is not the stub script. `openspec/litmus-tests/litmus-browser-isolation-e2e.yaml` (`OTP_TOKEN`, `OTP`) generates random base64url OTP data. Do not ban these merely because chmod or shell text also exists in the file.
* **Decode-and-execute path requiring policy disposition:** `scripts/test-macos-vsock-inference-closure.sh:159-218` (`ONESHOT`, `INST` heredocs) writes guest shell scripts openly; `scripts/test-macos-vsock-inference-closure.sh:221-227` (`B1`, `B2`) encodes those scripts and sends `echo $B1 | base64 -d ...; echo $B2 | base64 -d ...; bash /tmp/i.sh` to the guest. The install script installs the decoded oneshot executable (`scripts/test-macos-vsock-inference-closure.sh:202-214`). This is script materialization plus execution, not base64 credential data. The encoded values are computed from visible fixture files rather than committed base64 literals, so whether this transport has an authorized exception needs the owning policy/fixture review; no exception was established here. Do not infer deliberate intent from the mechanism. Replace transport with a managed file-transfer/guest-install API while retaining LIVE versus DEAD closure behavior, or record the required policy ruling. This destructive/VM fixture was not run. <!-- cite-ok: pinned cdba630ce algorithm/callsite audit; exact span is evidence -->
* **Visible synthetic fixture text is not hidden execution:** `scripts/test-relay-preflight.sh` (`_lower`, `CLONE_E`) assembles a Bash-4 syntax mutant to avoid its own lexical guard flagging fixture data. `scripts/lua/test-shell-ratchet.lua` (ARM 6, `wr`, `check`, `shell-strings`) assembles the allow_shell_strings marker to test counting. These expose a source-scanner context problem; they are not evidence of a production interpreter bypass.
* **Echo verdict circumvention:** a command whose two branches echo the same expected token passes regardless of the predicate. The dedicated guard `scripts/check-litmus-steps-can-fail.sh` explains the concrete defect using the `USERNS_KEEP_ID_SET` example and normalizes branch outputs in `branch_token` before comparing `ok_branch` and `fail_branch`. Distinguish this from legitimate different success/failure tokens and from echoing data to a JSON fixture. No new same-token defect was found by the measured guard.

### Proposed indexed policy representation

Use sanctioned shell/YAML/Rust/PowerShell parsers to retain command launchers, heredoc context, string literals and decoded-data destination facts. Proposed (not existing API) facts: `decode(source,destination)`, `write_script(destination,language)`, `execute(interpreter,destination)`, `interpreter_swap(destination)`, `data_use(destination,kind)`. Join only connected producers/consumers, retain spans and uncertainty, and never execute a decoded payload during analysis. No-Python should inspect **execution intent**, not prose/package names or tokens merely returned by stubs. Dynamic command names/unknown encoding need a named review outcome, not false confidence. Keep current bans/exemptions during performance parity; improve policy precision as a separately reviewed behavior change with positive and negative fixtures.

## 6. Measured safe static baselines

Three sequential runs per guard, Node `process.hrtime.bigint` around `spawnSync('bash', [path])`, 30s per-run timeout, same checkout/session. No whole gate or runtime fixture was run. All nine runs exited 0 with empty stderr. These are local-session measurements under contemporaneous host load, not controlled cold-cache benchmarks.

| Guard | Run 1 ms | Run 2 ms | Run 3 ms | Median ms | Actual verdict | Proposed 10x median acceptance target |
|---|---:|---:|---:|---:|---|---:|
| dead inputs | 2243.338 | 2266.460 | 2237.174 | 2243.338 | `ok:litmus-dead-inputs:92 glob(s) across 25 annotated test(s)` | ≤224.334 ms |
| steps can fail | 185.427 | 184.557 | 194.781 | 185.427 | `ok:litmus-steps-can-fail:519 file(s) checked` | ≤18.543 ms |
| line windows | 712.085 | 676.339 | 707.239 | 707.239 | `ok:litmus-line-windows:7-recorded` | ≤70.724 ms |

These targets are proposals, **not demonstrated improvements**. Measure both cold standalone and shared-index marginal evaluation; do not compare a cold old command against a new zero-work memo hit and call that an algorithmic win. A small guard's 18ms target may require same-process batching because a standalone CLI's launch floor can dominate.

Reproduction of the baseline:

```sh
node <<'NODE'
const cp = require('child_process');
for (const path of ['scripts/check-litmus-dead-inputs.sh', 'scripts/check-litmus-steps-can-fail.sh', 'scripts/check-litmus-line-windows.sh']) {
  for (let n = 0; n < 3; n++) {
    const t = process.hrtime.bigint();
    const r = cp.spawnSync('bash', [path], {encoding: 'utf8', timeout: 30000});
    console.log(JSON.stringify({path, run: n + 1, ms: Number(process.hrtime.bigint() - t) / 1e6,
      rc: r.status, signal: r.signal, error: r.error?.code, stdout: r.stdout, stderr: r.stderr}));
  }
}
NODE
```

## 7. Implementation proposals and measurable exit criteria

1. **Rust-backed immutable test-source index.** Enumerate each declared corpus once, retain bytes/line offsets, compile multi-pattern literals/regexes once, parse YAML/TOML/Cargo/Markdown once per content identity, and parse Rust items/shell invocation structure lazily. Keep scope projections: tracked versus untracked, depth, suffix, hidden/ignored/symlink behavior, file-order and binary/UTF-8 handling must not silently change. One global recursive walk over target/.git would be a regression.
2. **Bulk predicate evaluator, not one Rust CLI process per predicate.** First batch lookup/activation/claim/dead-input/window checks with one result per current guard/test ID. Proposed envelope fields: ID, outcome, exit, diagnostic, input identity, examined population and source spans. No command implementation or existing subcommand availability is implied by these proposed names. Existing `rust_queries` in `openspec/litmus-tests/litmus-podman-idiomatic-launch-routing.yaml` is the initial typed authoring seam, not evidence that a complete index/batch service already exists.
3. **Scoped structure conversion.** Convert source-only checkboxes to Rust AST item/call/argument predicates, shell command/assignment/effect predicates, YAML key-path predicates and TOML value predicates. Use syn/tree-sitter only for syntax they actually represent; macros/cfg/generated sources and Bash-3.2 quirks need explicit unresolved handling. Comment presence remains a separate documentation predicate; unreachable/disabled code must not satisfy execution claims. Do not pin neighboring function names or formatting windows as semantic scopes.
4. **Remove repeated mechanics, retain obligations.** Share binding name maps, activation surfaces and parsed corpora across deciders, batch parse-only with the runner's actual parser, stream historical floor blobs, and build policy once per verified gate context. Keep separate IDs, severity, advisory/refusal/skip behavior, declared second regimes, known baselines and valuable fixtures. Deleting a test is not the proposed optimization.
5. **Content-identity invalidation.** Key on canonical root, exact file bytes/deletions, parser/evaluator/binary source identity, scope declaration, frozen diff base, registry/baselines, relevant env and platform. Test dirty/untracked sources, same bytes under different roots, concurrent edits, deleted files and invalid UTF-8. Live probes/Git transitions/permission/transport tests remain uncached unless their changing inputs are explicitly represented. Retain existing source-attestation and run-don't-stat safeguards.
6. **Parity and performance acceptance.** Run old/new evaluators against identical immutable snapshots; compare every outcome/count/span ordering or document intentional differences. Require planted bad/safe/empty/unreadable/comment/quote/heredoc/duplicate-key cases, intended mutations that provably land, and CLI integration fixtures. Measure elapsed/CPU, child exec count, file-read count/bytes, allocations and parse invocations. Aim ≥10x for the full static subsystem, not selectively chosen matcher CPU; report standalone cold, indexed warm and memo-hit cases separately. The primary's full gate remains the integration acceptance owner.

Priority: (P0) name/activation/reference indexing and litmus metadata sharing; (P1) bulk scoped predicates over the highest-shared source files; (P1) policy dataflow/error handling review; (P2) history blob batching, header parsing and policy-build dedup; (P2) fixture setup/process reduction only where preserved behaviors and profiles justify it.

## 8. Gaps and explicit boundaries

* Exhaustive **static lexical** coverage is achieved for the tracked scope; exhaustive semantic proof and actual dynamic execution counts are not. Appendix A captures every file, including no-hit files, so follow-up researchers can classify them without relying on the prose shortlist.
* Untracked/ignored fixtures and dynamically constructed paths, generated shell, multiline YAML command values, sourced helper transitive work, platform-only branches and opaque macros can escape literal counts. The parent profile and structural parser inventory must cover these.
* No full-gate speedup or Rust runtime performance conclusion is made. Historical comments are not fresh baselines. Gate/local-CI/hook overlaps require control-flow/regime verification before reuse.
* Binding parser reuse and batch Rust predicates require coordination with the runtime owner. This report did not inspect or modify those implementations.
* The policy-review example is filed here with evidence and the smallest remedy; its owner/operator must resolve authorization and retain closure coverage. No destructive verification was performed.
* Verification: the embedded census was extracted and executed against committed HEAD; all population/byte/line/marker and authoring-field totals reproduced. Forty-six explicit full-path citation spans were checked for path existence and line bounds before the final registration clarification; abbreviated same-file spans and prose claims were inspected separately. Final workspace status also contained other workers' `research-fleet-runtime-infra-2026-10-11.md` and `research-gate-costs-2026-10-11.md`; they were not edited by this investigator.
* Citation-convention follow-up: general explanations now cite stable functions, variables, query IDs or named fixture steps; retained census/algorithm/callsite spans carry the explicit pinned-snapshot justification. `scripts/check-issue-citation-convention.sh` was run with `TILLANDSIAS_ISSUE_CITATION_DIR` set to this report and `TILLANDSIAS_ISSUE_CITATION_BASE` set to the full research snapshot commit. It exited 0 with `ok:issue-citation-convention:0 checked` (the counter counts unwaived numeric-citation lines, not documents examined). No full gate was run for this correction.

## Appendix A — machine-reproducible exhaustive inventory

Run this read-only Node program from the repository root. It writes JSON to stdout only. `--head` inventories committed snapshot bytes, isolating this audit from another worker's dirty tree; omit it to inspect tracked working files. Optional `--paths-only` reduces output to aggregate counts and paths. The census used tracked working files at the named snapshot; rerun `--head` for archival verification. This code is research tooling embedded in the report, not a new recurring gate.

```javascript
const fs = require('fs'), cp = require('child_process');
const args = process.argv.slice(2), committed = args.includes('--head');
const list = cp.execFileSync('git', ['ls-files', '-z'], {encoding: 'utf8'}).split('\0').filter(Boolean);
const read = p => committed ? cp.execFileSync('git', ['show', `HEAD:${p}`], {encoding: 'utf8'}) : fs.readFileSync(p, 'utf8');
const scope = list.filter(p => /^scripts\/(check[^/]*|test[^/]*(?:\/.*)?|lua\/.*)$/.test(p) || p.startsWith('openspec/litmus-tests/'));
const patterns = {
  scan: /\b(?:git\s+grep|rg|grep|find)\b/,
  enumerate: /git["', ]+(?:ls-files|grep)|fs\.glob|\bfind\s|\bglob\(/,
  read: /fs\.read|read_to_string|\b(?:cat|sed|awk)\b/,
  loop: /\b(?:for|while)\b/,
  spawn: /proc\.run|\b(?:bash|sh|cargo|ruby|perl|jq|git|rg|grep|sed|awk|find|xargs)\b/,
  predicate: /text\.(?:is_match|find|match)|:find\(|:match\(|grep|\brg\b/
};
const totals = {}, inventory = [], policyTokens = [], walks = [], pathRefs = new Map();
const fields = {}, phases = {};
for (const p of scope) {
  const s = read(p), lines = s.split('\n');
  const family = p.startsWith('openspec/') ? 'litmus' : p.startsWith('scripts/lua/') ? 'lua' : p.startsWith('scripts/check') ? 'check' : 'test';
  const row = {path: p, family, bytes: Buffer.byteLength(s), lines: lines.length - 1};
  const t = totals[family] ||= {files: 0, bytes: 0, lines: 0};
  t.files++; t.bytes += row.bytes; t.lines += row.lines;
  for (const [key, re] of Object.entries(patterns)) {
    row[key] = lines.flatMap((l, i) => !/^\s*(?:#|--)/.test(l) && re.test(l) ? [i + 1] : []);
    t[key] = (t[key] || 0) + row[key].length;
    t[key + 'Files'] = (t[key + 'Files'] || 0) + (row[key].length ? 1 : 0);
  }
  inventory.push(row);
  lines.forEach((l, i) => {
    if (/^\s*(?:#|--)/.test(l)) return;
    if (/fs\.walk/.test(l)) walks.push({path: p, line: i + 1, text: l});
    if (/base64|FromBase64String|EncodedCommand|python[23]?/.test(l)) policyTokens.push({path: p, line: i + 1, text: l});
  });
  if (!/^openspec\/litmus-tests\/litmus-.*\.yaml$/.test(p)) continue;
  for (const [key, re] of Object.entries({command: /^\s*-?\s*command:/, steps: /^steps:/, rust_queries: /^rust_queries:/,
    inputs: /^inputs:/, critical_path: /^critical_path:/, shape: /^name:.*shape/, assert: /^\s*assert:/, step: /^\s*-?\s*step:/})) {
    const n = lines.filter(l => re.test(l)).length;
    const f = fields[key] ||= {files: 0, lines: 0}; f.files += n ? 1 : 0; f.lines += n;
  }
  const phase = s.match(/^phase:\s*(.*)$/m)?.[1] || '<missing>'; phases[phase] = (phases[phase] || 0) + 1;
  lines.forEach((l, i) => {
    if (!/^\s*-?\s*command:/.test(l)) return;
    const hits = [...l.matchAll(/(?:crates|images|scripts|openspec|cheatsheets|locales|methodology)\/[A-Za-z0-9_./-]+\.(?:rs|sh|lua|yaml|toml|md)|\bbuild\.sh/g)].map(m => m[0]);
    for (const target of new Set(hits)) {
      const r = pathRefs.get(target) || {target, sites: [], tests: new Set()};
      r.sites.push(`${p}:${i + 1}`); r.tests.add(p); pathRefs.set(target, r);
    }
  });
}
const steps = list.filter(p => /^scripts\/gate-steps\.d\/.*\.step$/.test(p));
const surfaces = ['build.sh', 'scripts/local-ci.sh', ...list.filter(p => /^scripts\/hooks\/.*\.sh$/.test(p))];
const gateRows = steps.map(p => ({path: p, fields: read(p).split('\n').flatMap((l, i) => /^STEP_/.test(l) ? [{line: i + 1, text: l}] : [])}));
const overlap = [];
for (const step of gateRows) {
  const target = step.fields.map(f => f.text.match(/^STEP_(?:SCRIPT|LUA)="([^"\n]+)"/)).find(Boolean)?.[1];
  if (!target) continue;
  for (const surface of surfaces) {
    read(surface).split('\n').forEach((l, i) => {
      if (!/^\s*#/.test(l) && l.includes(target)) overlap.push({step: step.path, target, surface, line: i + 1, text: l});
    });
  }
}
const repeatedTargets = [...pathRefs.values()].map(r => ({target: r.target, commandLines: r.sites.length, tests: r.tests.size, sites: r.sites})).sort((a, b) => b.commandLines - a.commandLines);
const header = {head: cp.execFileSync('git', ['rev-parse', 'HEAD'], {encoding: 'utf8'}).trim(), committed,
  tracked: list.length, scope: scope.length, totals, fields, phases, gateSteps: steps.length};
console.log(JSON.stringify(args.includes('--paths-only') ? {...header, paths: inventory.map(r => r.path)} :
  {...header, inventory, walks, policyTokens, gateRows, overlap, repeatedTargets}, null, 2));
```

The committed-mode implementation intentionally uses git show per file for simple reproducibility, **not as the proposed performant production index**. It is an audit command, not part of the timings above. Use a batch blob reader if this research census itself becomes recurring tooling.
