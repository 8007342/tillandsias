# Fleet runtime infrastructure and build-loop research — 2026-10-11

## Scope, freshness, and evidence strength

Research-only deliverable owned by this session. Baseline:
`research/litmus-lua-performance-20261011` at
`cdba630cee433fa52366d29b3d5888a5d6177825`. `git fetch --no-tags origin`
succeeded; refreshed `origin/linux-next` equals that exact commit. Other
refreshed heads: main `d3e8c872963702dde1fc5ea6fad222a14a69a851`,
windows-next `b38f7105262afdd2805e947e50d126ea58a4cbfa`, osx-next
`49731c152273395cf95fd9f63249844cac707a57`. This report does not claim those
platform heads were merged or tested here. Pre-existing `opencode.json`
modification belongs to other work.

MCP plan experts were consulted first. Broad topic questions returned typed
`confidence=unsupported`, with `source_commit=cdba630ce…` and
`indexed_at=2026-10-11T20:07:41Z`. Exact `plan_status`, `plan_burndown`, and
`plan_blocked_on` calls subsequently worked. Capability probe reported
`skew=rebuild-required`, `experts state: degraded(not-built)`, index present,
embedding endpoint reachable, model `nomic-embed-text`; the running server
reported `forge-plan=93f7aec53db2`. These are session observations, not live
Macuahuitl GPU or fleet-service measurements.

Fallback reason **unavailable** applies to the refused topic answers; repository
reads through project-info then verify the results. Freshness caveat: an
envelope's current source commit does not prove the long-lived MCP shell or
compiled expert is current. The repository explicitly documents that failure
mode (`scripts/check-mcp-live-build.sh`, “WHY THE HEALTH PROBE CANNOT CATCH IT,
EVER” and “NOT THE SAME QUESTION AS 801-m9tk”). Packet statuses below are the
folded expert result, checked against definitions and relevant amendment/closure
fragments; original `status: ready` declarations alone are not completion truth.
`project-info.search_code` uses basic regex while `grep_code` uses extended
regex (`images/default/config-overlay/mcp/project-info.sh`, `tools/call`
dispatch arms `search_code` and `grep_code`),
so initial alternation searches yielding no matches were not accepted as absence.

**Evidence vocabulary:** “landed/source-present” means implemented in this
checkout; “completed” means the folded ledger carries that status; “measured”
quotes a dated recorded experiment; “proposal” is a recommendation below.
None means a running installation has adopted it. No production files, branches,
commits, pushes, credentials, host configuration, or network authentication were
changed. No build gate, destructive smoke, model pull, or infrastructure launch
was run for this research. New architecture proposals here are review input,
not newly assigned implementation packets.

## Executive findings

1. **Macuahuitl is the intended hub, not a proven fleet endpoint yet.** Its
   recorded September capability row has an RTX A5000, about 62.4 GiB RAM,
   20 CPU cores, GPU container/native lanes and an Ollama engine. Its Intel
   NPU is `engine-missing`; there are no measurements in that row. Do not
   reuse an August “schedulable: none” note as current hardware truth, or
   infer today's GPU utilization/model inventory from September capabilities
   (`plan/index.yaml:188-283`; older narrative `plan/index.yaml:11240-11253`).
2. **Cloudflare OAuth login is landed and ledger-completed; account setup and
   fleet networking are separate work.** The real client ID still defaults to
   an unregistered placeholder. The PKCE/fake-server gates are not proof of
   an operator-registered App or a joined fleet (`crates/tillandsias-headless/src/cloudflare_oauth.rs`, `CLOUDFLARE_APP_CLIENT_ID`;
   `plan/index.d/20261003t221800z-1548-8ii6-cloudflare-login-chain-and-fleet-wan-rows-closed-yoga.yaml:4-33,54-100`).
3. **The updated architecture is LAN-first, Mesh off-LAN, with pinned per-host
   CA authentication.** The Worker/DO is a discovery/lease/status control
   plane. The old shared expert bearer is superseded; logins gate admission,
   not each connection. The Pi is out of v1 scope
   (`plan/issues/fleet-wan-rendezvous-design-2026-10-03.md:22-88`).
4. **A signed per-host Nix cache and direct container Nix lane exist.** A
   fleet remote builder/shared cache is still roadmap. The direct Nix lane
   cannot transparently execute the full Cargo/test gate as presently coded
   (`scripts/with-nix-builder.sh`, `_nix_builder_can_serve`, `_nb_entry`,
   and the `_NB_DIRECT` sourced-invocation refusal branch).
5. **Shared cache correctness is a first-order constraint.** Today's
   completed 1599-egzz fixes a real shared-target false green by touching gate
   inputs. Its measured cost cannot simply be optimized away. Cross-host
   compilation reuse needs immutable keyed artifacts, not a shared mutable
   `target/` (`plan/index.d/20261011t142158z-30fc4a3b-yoga.yaml:7-28`).
6. **GPU assistance belongs in retrieval, ranking and research; deterministic
   litmus verdicts remain executable authority.** Compiling a checker is not
   provenance. Distribution needs signed, content-bound binary/index/evidence
   artifacts in addition to source-currency probes.

## What exists, and what is still proposed

### GPU models, embeddings, and local experts

Source-present local serving is `tillandsias-plan expert-serve`: an
OpenAI-compatible endpoint on `127.0.0.1:11436`, retrieval domains
`all|spec|code|methodology|cheatsheet`, grounded pipeline and verbatim typed
refusals. The current server config has no fleet bind/auth fields, and the
listener is hard-coded loopback. Thus fleet serving must not be described as
shipped from the existence of the local endpoint
(`crates/tillandsias-plan/src/expert_serve.rs`, `ServeConfig`, `MODEL_IDS`,
`DEFAULT_PORT` and `serve`).

The MCP spec path separately reads embedding and synthesis endpoints, defaults
to `nomic-embed-text`, checks binary capabilities/index availability before
spending an embedding call, and issues `/embeddings` requests
(`images/default/config-overlay/mcp/forge-plan.sh`, `spec_answer_envelope`). The inference
image has a separate cached-fast-path embedding-model pull; failure is named
and nonfatal, and disabling it does not claim a working retrieval tier
(`images/inference/entrypoint.sh`, `EMBED_MODEL_PULL` block and
`tillandsias_report_pull_failure`). Hardware presence, a reachable HTTP
endpoint, a cached embedding model, a compatible index, and a cited answer are
five distinct prerequisites. This session established only what its capability
probe reported, not that the endpoint was GPU-backed.

Index production already stages immutable entries, atomically renames them,
records the model and document prefix, and records the first publisher's source
commit. Existing older entries can be frameless by design
(`scripts/spec-index-ensure.sh`, `stage` publication block, `.commit` write
and `_publish_current`). Delta reuse is explicitly model-sensitive
(`scripts/spec-index-ensure.sh`, `EMBED_MODEL` / `.model` equality in the delta
reuse block). The server resolves the current entry
per request and caches parsing by directory and chunk-file mtime
(`crates/tillandsias-plan/src/expert_serve.rs`, `CachedEntry` and
`ServerState::entry`). These are useful local
mechanisms, not a signed multi-ref fleet publication protocol.

**Proposal:** use Macuahuitl for a measured embedding+synthesis pool; let a
smaller secondary host serve an explicitly measured fallback. Build one
incremental index per corpus/ref frame on the mirror holder, while retaining
checkout-aware local experts for unlanded work. Return ref, exact source commit,
index digest, embedding model/revision/prefix and serving identity in every
answer. Never silently join text from two refs into one citation frame. A
model may propose likely relevant files, rank candidate tests, explain failures
or draft patches; its output cannot mark a packet complete or supply PASS/FAIL.

Before sizing models/concurrency, measure GPU placement during actual embed and
chat calls, model residency/VRAM, TTFT and total p50/p95, cold/warm behavior,
index delta cost, queue contention with builds, and low-end/wifi round trips.
No new model-size or speed claim is made here. Existing 1289-ggsb specifically
requires those placement/staleness/auth/latency choices to be measured before
implementation (`plan/index.d/20260920t060422z-1289-ggsb-shared-local-experts-over-a-fleet-git-mirror-macuahuitl.yaml:23-43`).

### Cloudflare login and the fleet transport/trust revision

The completed chain is 1505-svve (fake server), 1505-kyx8 (OAuth), 1505-iky3
(names), 1505-iysn (Vault/rotation), and 1505-kc5f (CLI receivers/logout).
The October 3 closure fragment records real-binary-against-fake outcomes,
rotation controls and naming tests; the tray stored-signal waiter was explicitly
left to 1505-hfim, rather than silently counted as done
(`plan/index.d/20261003t221800z-1548-8ii6-cloudflare-login-chain-and-fleet-wan-rows-closed-yoga.yaml:54-100`).

Login uses Authorization Code + PKCE S256, not a fabricated device grant.
Discovery supplies endpoints; state is checked before exchange. Loopback,
QR-to-relay and terminal paste are receivers of that flow
(`crates/tillandsias-headless/src/cloudflare_oauth.rs`, `begin`, `exchange`
and `device_grant_note`;
`plan/index.d/20260929t205532z-1505-sm2j-cloudflare-login-and-fleet-vpn-milestone-macuahuitl.yaml:346-394`).
The canonical names are now `tillandsias-enclave-vpn` and
`tillandsias-enclave-vpn-<github_login>`, not the original account-ID-based
`tillandsias-vpn` table (`crates/tillandsias-headless/src/cloudflare_names.rs`,
`network_name`, `team_name` and `service_route`).

The superseded host-daemon/guest-install/proxy-spoke children 1505-bhsb,
1505-g6zc and 1505-m63i fold **obsoleted**, not completed. The replacement
sidecar research/join packets 1506-euvq and 1506-t97c both fold **ready**.
Their current critical-path role is confirmed by amendment notes
(`plan/index.d/20261003t183941z-1548-9n28-amendment-events-yoga.yaml:60-86`).
Do not follow the original sudo/host-daemon next action.

**Concrete live blockers:** registered private OAuth client, exact accepted
redirects, exact scope catalogue IDs, Zero Trust org/Mesh setup, Worker account
and DNS secret setup. These are operator-side prerequisites, not resolved by
fake gates. The approved relay domain is `rendezvous.tlatoani.net`; the checklist
still calls loopback acceptance and scope IDs unverified
(`plan/issues/fleet-wan-rendezvous-design-2026-10-03.md:481-539`). This report
does not revalidate Cloudflare's public APIs/quotas on October 11; upstream
claims there were researched October 3 and need confirmation at setup time.

The later ruling is authoritative for the design: same-host → LAN → Mesh
off-LAN; image/download bulk traffic remains plain internet; direct IPv6 WAN
is later. Per-host CA public keys are pinned in peer records/roster, private CA
keys remain local, and a lapsed login must not break established fleet-service
authorization. Mesh's shared service-token identity is insufficient by itself
(`plan/issues/fleet-wan-rendezvous-design-2026-10-03.md:54-88`).

### Git mirrors: durability, freshness, and identity

The existing per-project mirror contract relays exactly the received refs in
one explicit `git push --atomic` before acknowledging receive-pack. A
post-receive-only relay, `--mirror`, or `--all` is not equivalent. Local-only
state is classified distinctly. Credential failure must fail the push, and
Vault Agent/AppRole is the service credential path, not forge credential
injection (`openspec/specs/git-mirror-service/spec.md:171-230,261-285`;
actual atomic push `images/git/relay-refs.sh`, `OUTPUT` assignment executing
`git push --atomic "$PUSH_URL" "$@"`).

This is upstream durability and authenticated transport, **not** proof every
commit is cryptographically signed. The fleet proposal preserves commit bytes
and adds pushing SSH-principal attribution in the mirror log; shared GitHub App
credentials do not make committer identity or that log a signed artifact
attestation (`plan/issues/fleet-wan-rendezvous-design-2026-10-03.md:444-479`).

**Latest happenings, verified rather than inferred:**

- 1606-25nf **completed** at 16:56Z October 11, merge `febbcf79b` / #329.
  Rewritten work refs follow upstream only when the tracking twin's current or
  reflogged values prove upstream held every dropped commit. Otherwise the
  mirror exposes divergence; tracking history has an explicit 30-day bound.
  Rollout requires each host's next git-service image rebuild
  (`plan/index.d/20261011t165648z-05d38011-yoga.yaml:7-28`;
  `images/git/reconcile-exported-heads.sh`, `BEGIN-1606-REFLOG` and
  `BEGIN-1606-FOLLOW` blocks).
- 1607-8bq5 **completed** at 19:50Z, merge `69167a303` / #331. The carried
  guard fetches divergence markers and reports `taken-by-unknown:<ref>:diverged`
  instead of treating a stale tip as ownership
  (`plan/index.d/20261011t195051z-0b589dc2-yoga.yaml:7-28`).
- This corrects an actual October 11 stale rewritten work-ref incident. It does
  not prove running images on every host have the fix. Mirror freshness must
  be checked per requested ref, not inferred from a generic healthy process.

Fleet-wide two-mirror chaining is still 1548-7onc **ready**, not deployed.
Its proposed forced command admits only upload/receive-pack, logs the pusher's
principal, retains GitHub as authority, and tests acknowledgement timing through
both mirrors plus loud direct-upstream fallback. Its live LAN and Mesh pushes
remain required (`plan/index.d/20261003t183941z-1548-9n28-fleet-wan-rendezvous-milestone-yoga.yaml:579-633`).

### Nix builders, binary caches, sccache, and CI

Nix cache serving is source-present through Harmonia and a read-only persistent
store. Clients need **both** transport trust (stack-CA TLS leaf) and content
trust (ed25519 cache signatures with `require-sigs`), with no
`trusted-substituters` bypass. Secret cache signing keys are outside images/repo;
cross-host export requires an operator decision
(`openspec/specs/nix-cache-service/spec.md:29-113`;
`scripts/nix-cache-service.sh`, `ensure_keypair`, `ensure_tls_leaf`,
`write_harmonia_conf` and `do_ensure`).

The adopted lane is **per host**: named `/nix` builder volume, local writable
`/host-store` publication mount, copy+pin after build, runtime-injected public
key/CA/endpoint. The local `nix copy --no-check-sigs` is an explicit trusted
local-publication boundary because Harmonia signs at serve time; it is not
permission to import arbitrary unsigned remote outputs
(`openspec/changes/nix-cache-build-lane/design.md:90-128`;
`images/builder/nix.conf`, `substituters`, `trusted-public-keys` and
`ssl-cert-file` directives). A compromised writer to the served store can
therefore become trusted signed content: read-only cache serving alone does not
secure the publication path. Restrict who can write/populate before extending it
across the fleet.

**Measured historical latency:** August 25 cache-only fresh-store build was
96 s (563 substituted paths + five local builds); upstream-assisted seed was
113 s; coverage went from zero substitution to about 99.8% after seeding the
correct pin family. These are that host/target/pin's historical numbers, not an
October benchmark or a cross-platform guarantee. WSL2/VFR and floor-linking
measurements were deferred (`openspec/changes/nix-cache-build-lane/design.md:1-76`).

**Important implementation/design discrepancy:** 873-b1nx folds
**implemented**, not completed. The design claims the env opt-in routes
`./build.sh` and that integration was delivered
(`openspec/changes/nix-cache-build-lane/design.md:22-26,133-141`), but the
current wrapper explicitly refuses a sourced full `build.sh` under that opt-in;
the image has no Cargo. `build.sh` sources that wrapper. The usable declared
lane is direct `scripts/with-nix-builder.sh nix build .#<output>`, with
non-Linux/container guards, not a universal accelerated test gate
(`build.sh:53-61`; `scripts/with-nix-builder.sh:97-120,350-446`). <!-- cite-ok: pinned cdba630ce infrastructure implementation audit; exact span is evidence -->
These exact pinned callsites establish the discrepancy between the design's
full-script routing claim, the sourcing call and the wrapper's refusal. This needs
reconciliation under 873-b1nx before promising transparent gate acceleration.

Crane dependency derivations already normalize source through `mkDummySrc`;
source edits do not automatically invalidate the entire dependency closure.
The flake documents measured source/metadata/lock behavior and warns against an
over-narrow hand-built dependency filter. It now reads the pinned Rust toolchain
from `rust-toolchain.toml` (`flake.nix`, `rustPin`, `rustToolchain`,
`commonCraneArgs` and the `ORDER 765-8hc3` dependency-caching explanation).
Full runtime assets are
still release inputs. Reduce scan/evaluation overhead without dropping required
embedded assets or assuming a plan-only commit cannot affect a release.

sccache is a **compile-unit** cache, distinct from Nix output substitution and
from gate-verdict memoization. 1287-w9s4 remains **ready**: local cold/warm
baseline first, then hit rate on a second host which did not populate the cache,
compiler/flags partitioning, and benefit as a fraction of whole-gate time.
A negative result is a valid closure
(`plan/index.d/20260920t055154z-1287-w9s4-sccache-lan-lenovinha-silverblue.yaml:21-79`).
961-flnk remains **ready** for floor-image lld/sccache with persistent storage
and musl regression proof (`plan/index.yaml:44343-44374`). Neither row is
evidence a LAN sccache service is already installed or fast.

Release CI already uses Nix/Crane and cosign-signed artifacts; the Linux cache
action is keyed by runner OS + `flake.lock`, restores by OS prefix, and currently
has `save: false` (`.github/workflows/release.yml`, Linux `Nix Cache` step
with `id: nix-cache`, and the artifact loop calling `cosign sign-blob`). 1272-95ng
remains **ready**, documenting unchanged-input release cache misses and requiring
two subsequent comparable release logs. `save: false` is a concrete audit lead,
not a proven full root cause without those restore/save logs
(`plan/index.d/20260919t183857z-1272-95ng-release-linux-job-nix-cache-misses-on-unchanged-inputs-macuahuitl.yaml:17-58`).
No hosted release or full gate was triggered here.

## Shared-cache correctness and compiled provenance

### Today's shared-target correction must survive acceleration

1599-egzz is **completed**, merge `379140a52` / #324. Two shared-target
worktrees reproduced B running A's source and `include_str!` input because
Cargo considered B's older differing files fresh. The gate-start touch fixed
the actual A/B gate probe. Recorded costs: Linux +59 s same-checkout,
+10–18 s above the approximately 180 s checkout-switch cost; Darwin about
+216 s. The first queue gate was 1193 s versus roughly 1023 s per PR in two
prior runs; that is a contextual observation, not a controlled universal delta
(`plan/index.d/20261011t112948z-1599-egzz-shared-target-mtime-freshness-runs-another-worktrees-code-tlatoanis-macbook-air.yaml:18-45`;
`plan/index.d/20261011t135916z-18e8ab57-yoga.yaml:17-32`;
`plan/index.d/20261011t142158z-30fc4a3b-yoga.yaml:7-28`).

Proposal: share immutable dependency/compiler outputs, keep worktree-specific
runtime fixture roots, and preserve the current gate repair until a
content-correct replacement passes older-mtime A/B sources, VERSION/includes,
features/profile/target changes, deletion, and concurrent-build controls.
Today's runtime-manifest-dir cleanup is separate: 1610-d6ra and 1613-bpd3 fold
in_progress at this snapshot. Do not duplicate their Rust changes. 1603-iwh2
also folds in_progress for linked-worktree build-script reruns. These are owned
ongoing work, not new tasks for this report.

### Compilation is not attestation

Existing binary currency uses an embedded source revision and validator-surface
hash, rebuilt on declared inputs (`crates/tillandsias-plan/build.rs`, `main`,
`source_revision` and `validator_surface_hash`).
The validator hash is FNV-1a over its manifest-selected paths/bytes and lock
stanzas (`crates/tillandsias-plan/src/validator_surface.rs`,
`validator_surface_inputs`, `validator_surface_hash` and `lock_stanza`). This is a
useful accidental-skew detector, **not** cryptographic provenance or a signature.
A correct `build-id` claim does not attest the compiler, included Lua checks,
test inputs, dependency/toolchain origin, or produced verdict.

The compiled Rust runtime also loads Lua predicate source from files. Cacheable
predicates memoize by source/name/argument and validate the digests of bytes
actually read; observing predicates never memoize
(`crates/tillandsias-plan/src/lua_predicate.rs`, `PredicateRegistry::register_file`,
`PredicateRegistry::eval` and `CacheEntry::still_valid`). Thus “compiled
checker” must not be used to imply every rule/test is baked into one binary,
or that live-network/GPU state can safely reuse a pure-source verdict.

**Proposed signed artifact envelope**, separate from model prose:

- Cryptographic digest of binary and any external Lua/rule/test payloads.
- Exact source commit/tree, dirty-input manifest where allowed, dependency lock,
  compiler/toolchain identity, target triple, features/profile/flags, evaluator
  schema/version and complete declared content inputs.
- For indexes: chunks and vectors digests, embedding model immutable revision,
  dimensions and prefix, corpus/ref frame and publishing identity.
- For verdicts: evaluated artifact/input digests, predicate/test identity,
  captured stdout/stderr separately, completion/timeout status, run identity,
  environment/capability regime, and evidence digest. Observational results
  carry measurement time/regime and are not promoted to timeless cache entries.
- Signature from an explicitly authorized artifact publisher, with pinned trust,
  expiration/revocation/rollback policy, verification before execution/import,
  and a loud “unknown/untrusted/stale” outcome on failure.

Release cosign signing provides a precedent for content-bound artifact signing
(`.github/workflows/release.yml`, artifact loop calling `cosign sign-blob`
and asserting the produced `.cosign.bundle`); fleet CA authentication and Nix
narinfo signatures solve different trust problems. Neither automatically
attests a gate result or a RAG index. Source/citation verification remains
necessary even after signing: a trusted producer can faithfully sign a wrong
result.

### Cross-host cache design proposal

1. Macuahuitl owns the first Linux builder/publisher; retain per-host stores as
   local fallback. Share outputs over authenticated read-only service, not a
   cross-host writable SQLite store or common Cargo target directory.
2. Seed and root each active flake/toolchain/target family. Partition by actual
   derivation/system, compiler, features and flags. A Linux container can reuse
   Linux outputs on a guest; that does not make a Linux artifact a native
   Darwin/Windows tray. The Pi can serve foreign-system bytes; native/cross
   build capability is a separate measured requirement.
3. Grant publishing/signing only to authorized builders; consumer credentials
   are read-only. Distribute public verification keys through the admitted/pinned
   trust path. Do not copy private cache keys fleet-wide. Never broaden the
   local `--no-check-sigs` publication exception to remote ingestion.
4. Pin roots and retention by active family; atomically publish manifests and
   immutable outputs; use epoch fencing for any mutable “current” advertisement.
   A mutable leader lease is routing, not permission to overwrite artifacts.
5. Cache absence is slow local fallback; invalid signature/digest is a named
   trust failure, not accepted bytes. For runtime experts the named fallback
   remains local, with the answer's actual frame preserved.
6. Measure evaluation, substitute/copy, compile/link, fixture/guard and upload
   phases separately. Track cross-host hit rate, bytes, queue wait, p50/p95 and
   whole-gate wall time. Warm-cache success cannot validate an unexecuted test.

This composes with 884-shrd (**pending**, v0.8) rather than pretending its remote
builder and pooled inference are shipped. Its exact status probe additionally
reports `blocked-on-parked` for the container-cache prerequisite at
**implemented**: that prerequisite is not a completed dependency
(`plan/index.yaml:36100-36177`).
1290-5833 remains a **ready research** row for Pi topology; later v1 rulings
exclude Pi deployment, so refine that older recipe against the new scope before
acting (`plan/index.d/20260920t060422z-1290-5833-raspberry-pi5-fleet-server-for-mirrors-caches-and-transient-storage-macuahuitl.yaml:23-46`;
`plan/issues/fleet-wan-rendezvous-design-2026-10-03.md:70-74`).

## Remaining scan/latency opportunities outside peer-owned Rust work

These are source-reviewed opportunities, not newly measured speedups. The
in-progress packet query was checked; the ongoing native executor, Lua-runtime,
manifest-dir, linked-worktree build and platform-gate work is not taken here.
Only this issue file is changed. Recheck ownership before any implementation;
absence from a partial structured query is not proof no peer has a file open.

| Surface | Verified current behavior | Scoped proposal and correctness condition |
| --- | --- | --- |
| MCP `search_code` | `find .` enumerates all matching files, including ignored outputs; newline/xargs handling and basic regex differ from `grep_code` (`images/default/config-overlay/mcp/project-info.sh`, `tools/call` dispatch arms `search_code` and `grep_code`). | Define one source-search universe and regex contract. Prefer tracked + nonignored untracked candidates using NUL-safe enumeration; explicitly expose ignored/generated search as an option. Test files with spaces/newlines, invalid regex and zero matches; cap results, never silently cap candidate files. |
| MCP `find_files` / `project_structure` | `find_files` scans broadly and silently caps at 200; structure caps at 100. In this session recursive `*nix*`/`*mirror*` searches actually returned `target/` artifacts (`images/default/config-overlay/mcp/project-info.sh`, `tools/call` dispatch arms `find_files` and `project_structure`). | Default to source universe/pruned build trees with a truncation indicator and deterministic order; preserve an explicit all-files mode. A file locator must not say “absent” because it truncated another arbitrary subtree first. |
| MCP `grep_code` | Prunes `.git` and `.claude/worktrees`, but not `target/`, `out-cache/` or other build outputs; materializes all file names/hits before returning 50 (`images/default/config-overlay/mcp/project-info.sh`, `tools/call` dispatch arm `grep_code`, `files` and `all_hits` assignments). | Root the enumeration in the requested source subtree, share the candidate index with other search tools, and report totals/truncation without collecting unbounded content. Git index/tree identity is an optimization input, not sufficient freshness for dirty/untracked bytes. |
| Expert image bootstrap key | `_forge_experts_source_hash` traverses the crate, sorts paths, concatenates source contents and lockfile (`images/default/lib-common.sh`, `_forge_experts_source_hash`). | Consolidate with the binary's declared source-input inventory; hash path, type/mode where relevant, lengths and bytes rather than unframed concatenation. Missing/read-failed inputs must produce unknown, not a plausible partial hash. Cache inventory only with correct dirty/deletion invalidation. This is bounded crate work, not justification to remove source currency. |
| Launch cheatsheet inventories | Per-project and global Markdown scans and full oldest-first cache inventory are present (`images/default/lib-common.sh`, `project_cs`, `pull_rows` and `victims` enumeration blocks). | Publish immutable baked-image inventories at image build; update only runtime additions, and enumerate eviction candidates only when over budget. Preserve source-license/provenance policy and quota semantics. Measure launch impact before changing it. |
| Hooks | The mover scan is already Git-enumerated and batched. Its comments record rejecting a broad `find .` because 132 s vs 2.3 s and wrong ignored-file semantics (`scripts/hooks/pre-push-local-gate.sh`, `_movers` assignment and `WHY NOT find . -newer` explanation). | Keep this prior optimization. The bounded `find` at `scripts/hooks/pre-push-local-gate.sh:1161-1162` is diagnostic after a stale verdict, not an unconditional hot-path scan; this exact callsite audit distinguishes it from the unconditional mover enumeration. Replacing it has lower priority. Do not replace content-correct gate/staleness checks with mtimes for speed. | <!-- cite-ok: pinned cdba630ce infrastructure implementation audit; exact span is evidence -->
| Skills | Inspected skill scans include bounded smoke-evidence directories and an explicit tracked conflict-marker check, not evidence of a universal full-tree scan (`skills/smoke-curl-install-and-test-e2e/SKILL.md:1528`; `skills/advance-work-from-plan/SKILL.md:887`). | Avoid filing a speculative “all skills scan the tree” defect. Reuse MCP inventories where appropriate, but keep scope/evidence checks. Active health-check Lua port 1584-ik5v is peer work. |
| Nix/CI | Release source collection deliberately retains embedded assets; dependencies already use Crane dummy-source normalization (`flake.nix`, `craneSrc`, `commonCraneArgs` and the `ORDER 765-8hc3` explanation). CI restore exists but save is disabled (`.github/workflows/release.yml`, Linux `Nix Cache` step with `id: nix-cache`). | Prioritize 1272's restore/publication evidence and actual phase timing over another dependency filter or unrestricted source scan removal. New test derivations/gate integration need their own design; release `commonCraneArgs.doCheck = false` is not a test gate (`flake.nix`, `commonCraneArgs`). |

## Exact next packets and dependencies at the pinned snapshot

“Ready” is a recorded status, not a promise it is dependency-clear, unleased,
operator-authorized for live setup, or presently claimable. Do not close from
this report. The current useful sequence is:

| Packet / folded status | Concrete next action / blocking fact |
| --- | --- |
| 1548-ym32 / ready | Produce the signable decision record from the existing design, naming the remaining `til:compute:*` authorization question; operator signature events are the closure, not more parallel research. |
| 1506-32k5 / ready → 1548-cii8 / ready → 1548-ciq2 / ready | Establish per-host Noise identity, one canonical peer schema/checker, then enrollment matching both owner pins. Login prerequisite 1505-kc5f is completed; peer/trust work is not. |
| 1548-5t00 / ready → 1548-2ilf / ready | Worker+DO signed-heartbeat/lease core after peer schema; resident heartbeat/leadership after that core. 1548-dylo's score implementation is completed, not the whole rendezvous. |
| 1505-6w7d / ready; 1506-euvq / ready; 1506-t97c / ready | Account init and sidecar feasibility/join for Mesh. Requires operator account setup and actual sidecar outcome; do not resurrect obsoleted host-daemon children. |
| 1548-h7qh / ready; 1548-u5wv / ready | Measure LAN first; Mesh matrix after join. Render strict host/principal trust after peer schema and reachability. A successful LAN query does not close the Mesh arm. |
| 1548-pg32 / ready | Sole DNS writer and LAN/Mesh resolver after the lease/sidecar chain. Transient host public-DNS review remains constrained by the design note. |
| 1548-7onc / ready | Fleet mirror implementation after 1548-2ilf, 1548-u5wv, 1548-pg32; prove two-mirror upstream-ack timing/fallback and live LAN/off-LAN arms. |
| 1505-br88 / ready; 1548-q2fr / ready | Reuse bind plumbing under the amended CA rule, not the old bearer contract. q2fr directly awaits 1548-2ilf, 1548-7onc, 1548-u5wv and br88; widen index frames and test certificate/no-live-token/fallback arms. |
| 1505-wteh / ready; 1505-hfim / ready | Amended fleet provider resolution/auth and local fallback, then remaining tray signal/rows under recorded UX governance. Login completion did not complete these. |
| 1288-5qpn / ready | Per-host credential-free host push dogfooding/lifecycle and real delegated-mode proof. Existing forge relay is not proof this broader row is complete. |
| 1289-ggsb / ready | Refine the shared-expert measurements/design by citing 1548's now-decided topology/trust; avoid creating a competing fleet design. |
| 873-b1nx / implemented | Reconcile full-gate promise with the actual direct-Nix-only wrapper; finish the WSL/VFR/floor and store-topology obligations, then scope test-derivation integration. |
| 1287-w9s4 / ready; 961-flnk / ready | Separate local linker/cache improvement from two-host sccache measurement. Read actual cross-host hit stats before adoption. |
| 1272-95ng / ready | Compare comparable release restore/save logs; audit `save: false`, expose key/hit evidence, meet its two-cut criterion. |
| 1290-5833 / ready; 884-shrd / pending v0.8 | Refine later Pi/shared-builder topology and publisher trust. Pi bring-up is not required for v1 Macuahuitl serving. 884-shrd depends on the container-cache lane. |

Dependency/next-action evidence is in
`plan/index.d/20261003t183941z-1548-9n28-fleet-wan-rendezvous-milestone-yoga.yaml:117-296,346-575,579-675`,
with scope/auth amendments in
`plan/index.d/20261003t183941z-1548-9n28-amendment-events-yoga.yaml:24-86`.
The original 1505 child definitions are
`plan/index.d/20260929t205532z-1505-sm2j-cloudflare-login-and-fleet-vpn-milestone-macuahuitl.yaml:394-737`;
they must be read together with the amendments and folded statuses above.
The older cache/mirror research definitions and direct implementation evidence
are cited in the preceding sections. No new order numbers are invented here.

## Readiness and unresolved uncertainty

**Available building blocks:** local grounded endpoint, embedding/index producer,
completed fake-tested Cloudflare login chain, existing atomic per-host mirror,
per-host signed Nix cache/direct Nix build lane, completed score/affinity code,
and today's mirror/shared-target repairs. Macuahuitl is preferred for mirror and
experts in `plan/fleet/services.yaml:1-7`.

**Not yet ready to promise:** reachable certificate-authenticated fleet experts,
two-mirror fleet relay, off-LAN sidecar routing on every substrate, transparent
shared Nix test gate, LAN sccache gains, or signed fleet verdict/index publication.
The October 9 Linux release note proves artifact execution/checksum success for
v56.10.9.1, while explicitly leaving curl-install-over-signed-in-host unmeasured;
it is not a fleet-runtime smoke (`plan/issues/smoke-e2e-findings-v56.10.9.1-linux-2026-10-09-macuahuitl.md:1-9`).

Remaining uncertainties are measurable: live GPU/model placement, client-ID and
scope registration, peer certificates/revocation deployment, LAN/Mesh endpoint
matrix, image rollout of October 11 mirror changes, current pin-family cache
coverage, per-platform store/link performance, compiler/flags partitioning,
whole-gate cache benefit, and artifact-publisher authorization. The findings
above separate these from completed ledger work; source presence alone resolves
none of their live arms.

Recommended first tranche: reconcile decision/implementation records, establish
peer trust and LAN reachability, then fleet mirror and ref-aware experts. In
parallel, measure/reconcile the direct Nix lane and local compilation cache
without weakening gate content correctness. Extend to Mesh and shared builders
only with their named measurement and trust prerequisites. GPU ranking stays
advisory throughout; executable litmus verdicts and verified content-bound
evidence remain authoritative.
