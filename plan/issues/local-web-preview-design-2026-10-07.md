# Local web preview — design and implementation handoff

- **Status**: ready (design handed to parent; implementation and evidence pending)
- **Owner host**: linux / yoga
- **Branch**: linux-next, parent owns integration; no child commit/push
- **Specs**: `openspec/specs/local-web-preview/spec.md` (draft v1)
- **Depends on**: completed 357, 363, 364; new graph below

## Operator direction

2026-10-07 delegated direction: Astra designs; Sol and Terra implement. Existing
MCP service controls launch a sibling Wrangler `dev --local` process against the
project's LIVE forge worktree. Host browser uses local HTTPS routing. Start,
status, stop, explicit runtime reload, automatic uncommitted file watch are in
scope. Cloudflare local-runtime semantics preferred; static publish compatibility
retained. Test the assets-only `tillandsias.org` sibling (`./var/html`, no `main`,
preview script `wrangler dev`). Production deploy and a Chromium sibling are out
of scope. This direction does NOT authorize tray UI changes or installing host
CA trust. Do not treat this packet as such approval.

## Bootstrap receipt before edits

Intent `spec_authoring`; role Astra design, exclusively plan/OpenSpec writes.
Read methodology.yaml; bootstrap/router; spec-system; litmus; verification;
provenance; multi-host-development; distributed-work schema pointers; plan.yaml;
plan/index.yaml; plan/steps/README; step 357; existing catalog, web-image, routing,
MCP/discoverability references and runtime source spans.
Host `yoga.ayahuitlcalpan.com`, Linux; worktree
`/var/home/tlatoani/opencode/tillandsias`; branch linux-next.
Observed via ls-remote: linux-next/HEAD `95350b0c805532e8b63a4ff9182c1f851c866542`,
main `52e3bc32ec063c7a7090d0c8dca35bb8ade3c844`,
windows-next `b38f7105262afdd2805e947e50d126ea58a4cbfa`,
osx-next `49731c152273395cf95fd9f63249844cac707a57`.
No child pull/merge while sharing the parent's worktree; remote active head
already equalled HEAD at observation. Seed discipline level 2; parent owns
work-ref/integration handling and required pre-push gate.

MCP fallback reason **unavailable**: discovery exposes no project-plan or
project-info tools, corroborating parent report. Read-only filesystem plus
`scripts/plan-binary-probe.sh`-resolved plan CLI used. This records the degraded
read path, not evidence that either server implementation is broken. Do not
change server configuration as part of preview implementation.

## Existing implementation and measured design gaps

CLI folded status: 357 `web-publish-local-mvp`, 363
`publish-local-mcp-tool-and-handler`, 364 `publish-local-e2e-litmus` are completed.
The historical packet's HTTPS statement does not match current source:
The pre-change `main.rs` `publish_local_service` published busybox with
`host_project_root()/project:/var/www:ro,Z`, returns HTTP and has no runtime
reload; status maps every inspect failure to stopped. This is not proof of live
forge source identity. `tray/mod.rs` `handle_mcp_jsonrpc` already advertises/dispatches the
three lifecycle tools using session identity. Preserve this path.
`images/router/base.Caddyfile` explicitly disables auto HTTPS; routing spec pins
one HTTP loopback ingress. TLS is an implementation delta, not a URL string fix.
`web-image` mandates Alpine/busybox/<10MB; use a separate Wrangler image to retain
that contract. `cheatsheets/runtime/caddy-reverse-proxy.md` is draft and cannot
justify claiming L1 or activation. These gaps are owned by the graph below.

## Contract and architecture decisions

The complete wire contract is in `spec:local-web-preview`. Keep category WEB;
add optional runtime auto/static/wrangler to publish and service_reload(category).
No arbitrary command/path/image fields. Auto detects exactly one supported root
Wrangler config; invalid/ambiguous config fails rather than serving project root.
Resolve project AND lane from authenticated socket state. One service per
project; active cross-lane mutations fail rather than swapping another lane's
worktree. Sol must prove how the ephemeral source is shared (shared project
mount or supported live-mount resolution), not substitute the bare host checkout.
Use sibling-private runtime scratch, pinned image, local-only bindings; no
package-script execution, token injection or deployment.

## Scoped dependency graph and ownership

1. **1552-238z / local-web-preview-runtime** — Sol. Core lifecycle, live mount,
   profile selection, readiness and HTTPS router integration. Own
   `crates/tillandsias-headless/src/main.rs`, new
   `crates/tillandsias-headless/src/local_web_preview.rs` if extracted,
   `crates/tillandsias-headless/src/local_projects.rs`,
   `crates/tillandsias-headless/src/ca.rs`, `images/router/`, and runtime unit tests.
   Depends only on this design. Inform Terra of exported helper signatures first.
2. **1552-mqvf / local-web-preview-image-mcp** — Terra. Managed Wrangler image,
   build/materialization registration, MCP descriptors/dispatch/discovery.
   Own `images/web-wrangler/`,
   `crates/tillandsias-headless/src/container_deps.rs`,
   `crates/tillandsias-headless/src/runtime_assets.rs`,
   `crates/tillandsias-headless/src/tray/mod.rs`,
   `images/default/config-overlay/mcp/` and sibling tool-discovery instructions
   only where required. Depends on design; integrate against Sol's contract.
   Do not edit main.rs or router while Sol owns them. Request scope transfer
   through parent if embedding registration actually lives elsewhere.
3. **1552-e3wf / local-web-preview-live-acceptance** — parent/integrator, depends
   on both implementation packets. Own new preview tests, OpenSpec litmus bindings
   and scoped reconciliation of routing/MCP/discoverability specs after behavior
   exists. Run real target through its forge; record host trust separately;
   activate draft only after required evidence. Parent may assign bounded tests
   to implementers but must avoid overlapping writes.

Recommended Rust seam: a preview request/profile type with auto default; a
typed status/result carrying legacy state/url plus runtime/watch/tls diagnostics;
publish/status/stop/reload async helpers taking authenticated lane context.
Keep a wrapper for existing CLI `publish_local_service(project,category,debug)`
if needed; resolve a unique live lane or refuse unavailable/ambiguous, never
derive a bare host source to make CLI pass. Shared implementation, not two launch
paths. Concrete Rust type spelling is implementer-owned; JSON behavior is fixed.

## Acceptance matrix (must become executable before closure)

- **A source**: write a unique untracked nonce asset from the real forge; read it
  through published URL without commit/copy. Edit twice; uncached GET sees each
  change within a 30-second observation deadline. Compare git HEAD unchanged.
  Negative: same-named bare host/mirror file differs and is NOT served. Stop
  preview leaves source untouched. Two-lane identity and missing-forge refusal.
- **B runtime**: assets-only JSONC (comments, no main, ./var/html) returns expected
  page; config/project secrets outside assets are not served. A tiny Worker
  fixture proves local workerd execution and watch/reload. Invalid config and
  remote-enabled binding fail explicitly; no auth/deploy command or token needed.
- **C MCP**: tools/list discovers reload and runtime enum; publish, repeated
  publish, status, reload, stop twice via real existing socket. Bad category,
  runtime/type and spoofed path/project are refused/ignored as identity selectors
  with no side effects. Observe one container/route, stable URL, unrelated routes
  unchanged. Inject inspect/router/start failures; never false running/stopped.
- **D HTTPS**: verify SNI/SAN for www.<project>.localhost using local CA and actual
  returned port; inspect loopback-only router mapping and no preview host port.
  Route ready only after Caddy reload succeeds. Browser opens URL when already
  trusted; otherwise explicitly record trust blocker. Compare trust-store state
  before/after to prove no install; `curl -k` cannot pass this criterion.
- **E compatibility**: static project without Wrangler still publishes/reloads;
  run existing web-image shape, catalog allowlist, MCP identity/discovery and
  router regression tests. No tray labels/dialogs touched.

Each runtime observation has bounded startup/watch deadlines, version/image
identity and source lane evidence. Unit/fixture failure controls run in scratch
directories; live E2E uses the requested target forge, without resetting substrate
or mutating the sibling host checkout. Implementation-complete is not live-E2E
complete. Missing host trust is a named remaining acceptance obligation, not
permission to install it or a reason to claim browser success.

## Evidence / next action

Design-only source inspection, no runtime pass claimed. Parent launches Sol and
Terra with above scopes, integrates, adds executable coverage and runs gates.
Design validation: plan strict-fragment/schema and diff checks; results reported
to parent. No source edit, commit or push by Astra. Future sessions first query
the three folded rows and read the draft, then resume the first unmet criterion.

Validation completed: resolved plan CLI `check --strict-fragments` exited 0,
`ok: 1471 packets, ids unique, live references sound (16 parked-block edges)`;
all three new folded status rows read `ready`; `git diff --check` exited 0.
Checker also reported existing missing-title schema advisories and one organic
reference-debt warning on other rows; no new packet was named by those warnings.
These are recorded here as validation context, not repaired in this scope.
`ca.rs` in Sol's scope is an optional new extraction path, not an assertion that
such a module already exists; existing CA helpers are in main.rs.

## Integrator bootstrap receipt — acceptance harness

Selected intent `code_implementation`; role parent integration/acceptance on
Linux, host yoga, branch `work/1552-e3wf`. Read methodology entry/router,
spec-system, CI, litmus, verification, multi-host-development, plan root/index
and step template, the local-web-preview draft and design/proof checkpoints.
Governing trace is `spec:local-web-preview`; shared-source mechanism and browser
trust remain unverified. MCP read fallback remains **unavailable**. Observed
sibling heads are those in the design receipt above; fetch confirmed active
HEAD equals origin/linux-next before creating the work ref. Discipline CLI
reports seed/derived/effective level 2. Scope: an opt-in Rust integration harness
and its litmus binding, never implementer-owned runtime/image/MCP files.
Verification: compile hermetic harness tests, then explicitly run the live test
against a provisioned real lane; a missing lane is a failed prerequisite, not
a passing or silently skipped live test. No substrate reset, host checkout edit,
browser launch or trust-store installation is permitted.

### Acceptance harness checkpoint

Added `crates/tillandsias-headless/tests/local_web_preview_e2e.rs` and
`openspec/litmus-tests/litmus-local-web-preview.yaml`, with a draft binding at
zero verified coverage. The live test requires an explicitly supplied real
lane socket, forge and CA; it refuses to interrupt a pre-existing preview. It
checks two uncommitted asset writes, publish/reload/stop/restart, invalid runtime
arguments, actual HTTPS SNI/CA verification, unchanged git HEAD and unchanged
host CA-anchor listing. Browser-specific trust, cross-lane ownership, kernel RAM
caps and Worker behavior require separate evidence; this harness is not complete
draft coverage and no live pass is claimed.

First compile command (default features),
`toolbox run --container tillandsias-builder cargo test -p tillandsias-headless --test local_web_preview_e2e https_target -- --nocapture`,
failed during concurrent implementation: E0433 at new main.rs workspace helpers
referencing `local_projects`, which was still gated to tray/listen-vsock. Sent
the exact failure to Sol for its owned source fix. Tray-enabled harness compile
started separately; results pending. Do not treat this transient compile failure
as a completed runtime proof or discard implementer edits.
The tray-enabled harness compile also stopped on the in-progress core seam:
main.rs referenced `local_web_preview::cleanup_departed_lane` before that helper
was present. Defer further compilation until Sol reports its coherent core patch;
these interim failures do not establish the final patch's build result.

### Image/MCP implementation checkpoint (Terra report)

Terra completed its scoped image/MCP surfaces without commit/push: managed
`images/web-wrangler/` pins Wrangler 4.42.0 with a transitive npm integrity lock
and workerd 1.20251001.0; runtime assets/build embedding registration, existing
MCP runtime validation and `service_reload`, authenticated instance forwarding,
OpenCode guidance and Codex host-services registration are present. Static
`images/web` is unchanged. Reported passing checks: local image build/version,
MCP lifecycle validation, seven core preview unit tests, runtime embedding/COPY
tests, Codex registration fixture, owned Rust formatting and whitespace.
These are implementer-reported checks, not parent live acceptance.

Parent requested a follow-up real backend smoke using disposable assets-only
JSONC and Worker fixtures, automatic uncommitted watch and private writable
state. Keep the managed image for integrated live acceptance; remove only owned
test containers. A version command alone does not prove workerd starts or serves
assets under the production read-only runtime restrictions. Remote-binding
refusal remains core-owned, and browser trust remains unverified.

### Parent verification checkpoint

After the coherent core patch, the tray-enabled integration harness compiled;
`https_target_preserves_explicit_port` and `https_target_refuses_http` both
passed. The ignored real-lane test was filtered out, not executed. The earlier
default/tray compile failures were intermediate source seams, now fixed per
Sol's default check/tray clippy report.

The parent `./build.sh --check` run found two unstable source-line citations in
this new design intake; replaced them with `publish_local_service` and
`handle_mcp_jsonrpc` symbol citations. The next run passed formatting and all
fast refusals, including ledger obligations/citations and enclave-membership
documentation. It exceeded the command's 120-second limit while compiling the
workspace clippy dependency graph, so it is NOT a passing complete gate. Restarted
with a 600-second allowance. Full gate, image/backend smoke and live-lane
acceptance are pending; no push or spec activation yet.

### Runtime-language approval boundary

The implemented config inspection invokes Node with a JavaScript adapter to
the pinned Wrangler configuration parser. Wrangler itself is the explicitly
requested Node-based runtime, but the additional Tillandsias-owned adapter is
not one of methodology.yaml's default approved runtime-script languages.
Parent requests explicit operator approval for this narrow adapter before
committing/publishing it, rather than assuming permission for arbitrary Node
scripts. This question does not request approval for production deployment,
host trust changes, package scripts or any expanded UX scope.

### Independent live MCP/HTTPS acceptance — parent PASS

The retained fixture used the real confirmed `tillandsias.org` project identity,
real accepting lane listener, enclave mirror clone, and bounded shared source
volume. Fixture receipt `/tmp/opencode/sol-preview-fixture.json` identified lane
`sol1552`, source volume
`tillandsias-source-a0d8449633df982321e8d52c205a84ae07d1c60b87f8f2690b3265247cc6c980`,
and local CA `~/.local/state/tillandsias/ca/intermediate.crt`.

Parent ran the ignored `live_forge_assets_https_mcp_lifecycle` integration test
with the three `TILLANDSIAS_PREVIEW_E2E_*` variables supplied via `env` INSIDE
the builder toolbox (host-prefixed variables were sanitized by Toolbox on the
first attempt, which failed the SOCKET prerequisite without exercising runtime).
The corrected invocation used:
`cargo test -p tillandsias-headless --features tray --test local_web_preview_e2e live_forge_assets_https_mcp_lifecycle -- --ignored --exact --nocapture`.
Result: **1 passed**, 21.64 seconds, signal
`ok:local-web-preview:live-assets-watch-reload-stop-ca-verified; host-browser-trust=unverified`.
This independently verifies the authenticated tool list, invalid-runtime refusal,
assets-only Wrangler auto selection, two uncommitted asset edits on live source,
CA/SNI-verified HTTPS, stable URL on repeated publication/reload/restart, stop
idempotence, absent reload refusal, unchanged git HEAD and unchanged CA anchors.
The harness leaves its preview stopped and removes only its own nonce asset.

Sol additionally reports live Worker watch/reload, pinned config-generation
remote-edit refusal, missing-config and symlink refusal, and source recreation;
those additional observations remain attributed evidence, not parent reruns.
The normal launcher still refuses a checkout/enclave version downgrade, so this
fixture pass is NOT a normal installed-launcher compatibility pass. Injected
cleanup/deadline failures, abrupt listener death, broader cross-instance teardown,
browser-specific trust and full gate remain separate obligations. No production
deployment or host trust installation occurred. Adapter-language approval still
pending; do not commit/publish the owned JS adapter on an inferred approval.

### Operator approval — contained parser adapter

2026-10-07T19:23:18Z operator explicitly approved playing nicely with Wrangler's
dependencies provided the small JavaScript adapter is contained, documented,
and its spread constrained; a Lua-only alternative may be evaluated later.
Approval applies to the preview-only adapter invoking the already pinned npm
Wrangler parser in a no-network configuration inspector. It does not add an npm
dependency or authorize a generic JavaScript harness, caller scripts, package
scripts, production deployment, host trust changes or expanded UX. Exact raw
config bytes are returned internally to Rust for the approved effective
generation and must not appear in agent responses/diagnostics. The prior
approval-pending note is historical and resolved by this explicit decision.

### Final focused checks and fixture cleanup

Parent reruns after safety repairs passed **10 preview unit tests**, **15 MCP
tests**, and `scripts/test-codex-mcp-registration.sh`; whitespace check passed.
Signalled `/tmp/opencode/sol-preview-fixture.stop` after independent live
acceptance. A subsequent Podman listing contained neither the named fixture
forge nor its mirror, while unrelated workloads were preserved. Managed image
remains available. Real parent session identity obtained from OpenCode is
`ses_ee869e2e5ffe9cYnHKi1h0AhiF`; integration receipt uses that actual identity.
Full gate completion and commit/push evidence are still pending at this entry.

### Reproduction boundary for future sessions

The ignored core `live_target_fixture_1552` test creates the controlled mirror,
default-clone RAM-backed forge and real lane listener when explicitly authorized
with `TILLANDSIAS_PREVIEW_FIXTURE_OK=1552-238z`. It requires an already confirmed
project identity and locally built managed images; it refuses to overwrite an
existing fixture or user preview. The sibling seed resolves from compile-time
workspace location, not Cargo's package-specific working directory. Before
recreating a fully cleaned fixture, remove only its stale
`/tmp/opencode/sol-preview-fixture.stop` marker. Run the ignored core test with
`--features tray --bin tillandsias local_web_preview::tests::live_target_fixture_1552 -- --ignored --exact --nocapture`,
then use the emitted JSON receipt to supply socket/forge/CA for the independent
integration test. Signal the documented stop file after acceptance. This is a
fixture route around the named normal-launcher version prerequisite, not a
change to the production downgrade guard.

### Full-gate blocker and narrow test-observer repair

The complete 30-minute-allowance `./build.sh --check` run reached the workspace
suite and failed one of 2,933 tests:
`lua_proc::managed_script::cleanup_observer_rejects_acknowledged_live_group_before_accepting_its_stop`.
Its `/proc` read returned Linux ESRCH after the acknowledged process exited;
the observer recognized only ENOENT/NotFound as absence. The file was unchanged
from origin/linux-next, confirmed by a scoped git diff. This is a measured gate
blocker, not an accepted known-red and not evidence that preview behavior failed.

Parent made a narrow test-only repair under the existing `spec:ci-release`
trace: classify ESRCH and ENOENT as absent, while retaining fatal handling of
permission/I/O errors and the existing PID-start identity/live-group controls.
Added deterministic ENOENT/ESRCH positive and EACCES/EIO negative controls.
No production Lua behavior, test baseline, skip list or gate policy is changed.
Run the whole lua_proc target and full gate again before push; the prior full
run is failed, not green. Work checkpoint `d74d07f4b` is local-only pending gate.
The first isolated lua_proc rerun compiled the pre-repair 48-test target: the
original observer test passed, but
`a_terminated_runner_takes_its_script_owned_child_with_it` failed on runner exit
1 instead of expected SIGTERM exit 143. The test suppresses stderr, so no cause
is claimed from that observation alone. A fresh whole-target rerun with the
ESRCH regression controls is underway. Do not weaken the SIGTERM assertion,
accept a new known-red, or change production Lua behavior to force publication.
The post-repair whole lua_proc rerun passed **49/49**, including the new
ESRCH/ENOENT versus EACCES/EIO controls, the original live-group observer and
the unchanged strict SIGTERM exit assertion. No test was skipped or baseline
entry added. Full repository gate must still pass before remote publication.
The next complete gate passed workspace and tray/listen-vsock tests (the latter
executed 957 tests) then refused duplicate open order declarations in two of our
new correction fragments. Original packet IDs/orders are not duplicates; the
corrections had used `packets:` where the ledger requires its `status:` LWW
channel for field updates. Repaired those unpublished correction encodings to
LWW entries, preserving the original design packet declarations and every event.
No renumber, compaction of unrelated fragments, production policy change or
test-baseline exception is needed. Re-run order policy and full gate before push.
After the encoding repair, `cargo run -p tillandsias-policy -- plan-orders`
passed: 1,471 packets, 740 fragment packets, zero duplicate groups. Strict
fragment/schema/reference validation also passed. Whitespace check passed.
The next fast refusal showed that the source-only scorable-obligation guard
does not consume LWW field corrections. Now that the live guard exists and was
actually executed, the unpublished original packet closures name
`litmus:local-web-preview` directly, explicitly retaining additional negative
controls/Worker/compatibility criteria. This is not a future or invented pin and
does not claim complete draft coverage. Packet identities/orders remain intact.
The full gate subsequently reached litmus binding enforcement and found that
the new live guard's unquoted step name was valid YAML but not extractable by
the runner. Quoted the step scalar; this changes no command or acceptance
criteria. Verify with run-litmus-test.sh --parse-only before another full gate.
The uncapped full-gate run completed the jq/yq selection fixture successfully
(28 selected tests, identical in both regimes), ruling out a persistent hang
there in this run. It then refused five missing requirement IDs in the new
preview spec. Stamped only this spec with the canonical stable-ID tool; no
requirement text or existing IDs changed. The Lua ID decider now passes all
740 requirements. The failed gate stopped before work-ref push or landing.

## Parent checkpoint — 2026-10-07T18:33:24Z

Design accepted; Sol `ses_ee8603d90ffeSAKCT1FPJTL6Qu` started core/runtime.
Terra `ses_ee860f82effeDX5Ffp1sqrdbJ9` is first doing a read-only rootless Podman
live-tmpfs export/sharing proof, then image/MCP implementation. Feasibility is
not yet established. Parent owns integration/acceptance after both dependencies;
parent identity was not supplied and no parent lease is fabricated. Local claim
events use the actual provided session IDs; remote publication/claim confirmation
remains parent's responsibility, not an asserted completed operation.

Agreed concrete Rust seam supersedes the earlier implementation-latitude note:
`crate::local_web_preview::{publish(project,instance,runtime,debug),
status(project,instance),stop(project,instance,debug),reload(project,instance,debug)}`,
all async `Result<serde_json::Value,String>`. Project/instance are authenticated
socket identity. Sol owns implementation; Terra owns callers.

Audits relayed by parent: listener and lifecycle are currently tray-feature-only.
Initial phase requires a tray-enabled build and live listener; feature lift is
out of scope and listener failure must be truthful. Existing routes are HTTP
only. Existing source derivation is `host_project_root()`; do not misdescribe
that implementation as proof of a default clone-only forge. The requested host
checkout is `/var/home/tlatoani/opencode/tillandsias.org`, but that directory
MUST NOT replace the agent's actual live tmpfs source. Parent preflight reports
rootless Podman available, with only unrelated ollama running; leave it alone.
Parent fetched and confirmed HEAD==origin/linux-next `95350b0c8`.

Draft routing reconciliation is deliberately additive: preserve the existing
HTTP loopback mapping and permit one extra loopback TLS ingress on the SAME
router for previews; no published admin or preview-container port. Recorded in
the draft, with active routing spec unchanged until integration evidence exists.

Parent full gate caught a real design-filing defect:
`violation:scorable-obligation-missing:3`. Astra independently reproduced it.
The three closures were prose-only; original strict schema validation did not
prove gate compliance. Append-only correction now explicitly says
`unscoreable: unpinnable-until-the-guard-exists` and names future
`openspec/litmus-tests/litmus-local-web-preview.yaml`. This is not a fake pin,
passing test, or activation. Parent must add/bind the guard with implementation.

Repair verification (18:34Z): `check-scorable-obligation-added.sh` changed from
`violation:scorable-obligation-missing:3` to
`ok:scorable-obligations:6 checked` with three accepted folded corrections.
`check-declared-closures-added.sh`: `ok:declared-closures:8 checked`.
Strict plan check passed (existing advisories remain); diff whitespace check
passed. Field updates used `set-field`; its prose-loss protection correctly
refused replacement, then `--append` preserved all prior acceptance text.
Folded rows now read runtime/image-MCP `in_progress`, acceptance `blocked` with
its two declared prerequisites. These results validate ledger repair only, not
runtime behavior, the full parent build gate, or draft activation.
