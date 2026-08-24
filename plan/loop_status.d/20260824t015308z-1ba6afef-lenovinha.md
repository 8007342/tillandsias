## Cycle — lenovinha (linux_immutable) 2026-08-24T01:53:08Z — the lying litmus is fixed, in one change instead of 121

Full-mode cycle on lenovinha (linux_immutable, Silverblue, linux-next). Batch epic=convergence-velocity-milestone seed=lenovinha size=10 budget=10.

GUARDS all green. Daily gate reads current:2026-08-23 and that is CORRECT, not stale — the marker is keyed to LOCAL date and it is still 2026-08-23 PDT at 01:53 UTC. Checked rather than assumed, since the UTC date had rolled.

CLAIMED 799-tb7q and fixed the false-failing litmus I recorded last cycle. litmus:skills-canonical-and-mcp-first-shape STEP 6 reported FAIL here because its command is a bare `yq` absent from this host, while the methodology it asks about is present and correct. The obvious remedy — convert callers to the documented dispatch — means editing 121 bare yq/jq/rg calls across ~30 litmus files, and it never ends, because the next author writes the 122nd.

A SECOND, WORSE DEFECT DECIDED THE APPROACH. run-litmus-test.sh's OWN yaml_get and get_litmus_tests_for_spec guard on `command -v yq` and fall back to grep approximations whose own comment says "not perfect but functional". Those parse phase, size, host_kind, inputs and the per-spec test list — so a host without yq reads its own test METADATA through an approximation. Converting 121 call sites would not have touched that.

WHAT LANDED: the runner materialises the toolbox's yq ONCE into target/litmus-runtime/bin — the directory it already generates its podman wrapper into and already prepends to PATH. One extraction, then native speed (a toolbox round trip measures ~0.29s and the runner calls yq once per metadata field per file; on a full suite that is minutes). Verified before trusted: the binary is dynamically linked, so a copy that will not answer --version is deleted and the grep fallbacks apply unchanged. Strictly additive; hosts that ship yq are untouched. target/ is gitignored so the tree stays clean.

ORDERING IS LOAD BEARING, learned the confusing way. My first version put the extraction AFTER the runtime bin joined PATH. The block WAS reached — I instrumented it and saw yq=none toolbox=/usr/bin/toolbox — and still produced nothing, because that directory contains the runner's podman WRAPPER, toolbox shells out to podman, and the wrapper is not a podman. The tool the extraction needed had been replaced two lines earlier. Extraction now precedes the PATH export and the comment says why, so nobody tidies it back.

VERIFIED COLD: deleted the shim, ran the suite, it re-provisioned (13,934,432 bytes, yq v4.53.3) and STEP 6 went FAIL -> OK, suite PASS.

FILED 868-p8xi: ci-release is RED on linux-next for an unrelated reason. litmus:sidecar-arch-derivation STEP 3 prints `ok: staged-arch-matches` — one of the three alternatives its own expectation lists — and the matcher rejects it, because the expectation is written as a regex alternation and behavior_matches_output compares literally. So the step cannot pass on ANY of its three legitimate outcomes. VERIFIED NOT CAUSED BY MY CHANGE: identical failure with the shim removed and yq off PATH, and selection is unchanged (26 executed both ways).

I COULD NOT EXPLAIN WHY THIS SUITE WAS GREEN HERE YESTERDAY and I recorded that as unknown rather than inventing a cause. The matcher has an empty-expectation short circuit (`[[ -z "$expected_lc" ]] && return 0`, :735), so a step whose expectation parses empty always passes — the likeliest way it was green — but expected_behavior is parsed by a bash regex over the raw line, not by yq, so I have no mechanism for it parsing empty then and non-empty now. That short circuit deserves its own look: an expectation that fails to parse becomes an unconditional pass, which is the absence-reads-as-success shape this ledger keeps recording.

SWEEP RESCOPED and now smaller: litmus callers need no conversion. What remains is the ~50 SCRIPT callers, split as before — dev-host scripts take the dispatch, shipped diagnostics (tray-diagnose.sh, diagnose-macos-provision.sh) run where no toolbox exists and need a different answer.

FRESHNESS: scripts/summarize-package-json.sh, verdict=refreshed, exercised both paths (exit 2 with no manifest; three sections and exit 0 against a synthetic react/express/typescript manifest). Note in the stamp, deliberately not acted on: detection is substring `grep -q` over the raw file rather than jq over the dependency maps, so `grep -q 'react'` matches a package merely NAMED react-something and `grep -q 'next'` matches the word anywhere. Being generous is arguably right for an orientation hint rather than a gated fact, and changing one of six siblings in isolation would break the family's uniformity — if tightened, tighten all six and say which way the bias goes.

ADVISORY: compaction not eligible. Deslop not due. flow overhead_ratio ~4 over 13 cycles.
