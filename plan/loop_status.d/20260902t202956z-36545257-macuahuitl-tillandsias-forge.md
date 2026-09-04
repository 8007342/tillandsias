## Cycle 2026-09-02T20:29:56Z — macuahuitl-tillandsias-forge (forge, linux-next)

Story 920-pxg6 (wire the OpenCode Local Experts mode through ONE grounded
pipeline), driven by the macuahuitl-fedora coordinator. Forge cycle, ephemeral
checkout, GPU lane at inference:11434.

THE BRIEF WAS STALE AND CHECKING THAT FIRST IS THE WHOLE CYCLE. The coordinator's
R1-R4 described pipeline.rs:261-283 dispatching with no retrieval, a hardcoded
validated:true/confidence:0.5/citations:[] stamp at 295-311, and validate.lua
discarded at lua_runtime.rs:294-302. All three describe the pre-5656e3d24 state
recorded in the packet's `context:` block. At HEAD the grounded pipeline is
landed, validate.lua is deleted, and 25 of the OpenSpec change's 27 tasks are
done. Implementing R1-R4 as briefed would have rewritten working code.

WHAT ACTUALLY REMAINED, and what this cycle did:

1. UNBLOCKED THE FORGE LANE (964-fwvh, 80335e60e). 22 dirty `.claude/` opsx
   paths read `non-opsx:` and refused the cycle before any work. The order-540
   detector's generated set is anchored to `.opencode/`; the openspec CLI writes
   the same 22 artifacts per harness, so every Claude-launched forge refused.
   Salvaged first (872-c9nd), confirmed generated (`.claude/` byte-identical
   between main and origin/linux-next), widened the detector, pinned it with
   three branches including one proving the wider set still fails closed on real
   dirt. Then took order 540's sanctioned path: `ok:opsx-only` -> commit the sync
   -> re-anchor the boundary.

2. CLOSED TASK 5.10, open since 2026-08-29 because no forge could reach it.
   Covered question -> synthesized prose with a correct `Sources:` line and
   citations narrowed 6->3 to the ones the prose used (exit criterion 3, live).
   Uncovered -> typed `unsupported:` refusal, citations=[], best score 0.56-0.58
   against the 0.62 floor. Both through the `pipeline` CLI arm and over the
   expert-serve HTTP endpoint. The darwin sourdough case now refuses.

3. FOUND WHY NO FORGE COULD REACH IT (ea280c2d9). lib-common.sh derived
   TILLANDSIAS_EMBED_ENDPOINT only from OLLAMA_HOST, which nothing in the forge
   sets, while the TILLANDSIAS_EMBED_MODEL export beside it is unconditional. So
   the launch armed the model and not the endpoint, and expert-serve answered
   `unsupported: no embedding endpoint` with an index published, inference up and
   the server listening — 712-r5x8's fresh-forge gap surviving inside the
   configuration built to close it. Now derives from TILLANDSIAS_INFERENCE_ENDPOINT
   and PROBES before exporting, so a forge with no inference keeps its honest
   refusal.

4. CORRECTED TWO FLEET CONCLUSIONS WITH MEASUREMENT. The model-size floor through
   the full pipeline is 14b, not 7b (darwin's 7b result came from a direct
   replication outside run_grounded). And the tier-budget conflict is not a
   hardware floor: latency here is bimodal — cold 7b 23353ms / 14b 9996ms, warm
   938ms / 1474ms, both inside Quick's 3000ms. Darwin's 10-24s was cold-start
   charged to the tier budget, which changes 927-2q4w's remedy from "raise the
   budget" to "warm the model".

5. FIXED TWO GATE FIXTURES THAT FAIL ON EVERY FORGE FOR AMBIENT REASONS
   (964-fwvh). test-pre-push-empty-ref-list installs a spy at .git/hooks/pre-push
   and the forge sets core.hooksPath globally, so the spy never ran and 5 arms
   read '<none>' — reported as a defect in the pre-push rule (6/11 -> 11/11).
   check-capability-row's ephemeral-identity guard runs before the case dispatch,
   so `fixture` was refused too and build.sh read that as the truth fixture
   breaking (-> 9/9). Both named a defect in the thing under test rather than the
   environment, which is the most expensive shape a red gate can have.

ALSO OBSERVED, not acted on: the archiver's `--check` failed once with
`brew install ruby` failing under attestation verification, then passed on retry
with no change — a lazy first-use install in the brew shim. A transient that
presents as "the plan archiver would CHANGE THE READY SET".

RESIDUAL: task 4.5 (mlua portability, 902-5bf9) needs the darwin/msys lanes, not
this host; the darwin 2026-08-28 report already records `[lua-expert] runtime
initialized` on Darwin, so the darwin half may be answerable from filed evidence
— a fleet call. Then OpenSpec sync/archive. 927-2q4w wants re-deciding.

Gate green (forced) at every push. Claim released to ready.
