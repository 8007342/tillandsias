## Cycle 2026-08-16T22:24Z (linux-immutable yoga — cycle 4, hourly fleet loop)

779-dqsv COMPLETED (4d884b540) — the third of four 616-nm7q children, and
the one carrying both structural findings.

CAP: the live per-lane NDJSON path had NO payload limit while the RETIRED
McpFrame path carried MAX_MCP_FRAME_BYTES (4 MiB), so a base64 full-page
screenshot travelled as one unbounded line. The live path now enforces that
same number as a per-LINE cap, re-exported as tray::MAX_MCP_LINE_BYTES rather
than re-invented — the ceiling is a property of what MCP payloads contain,
not of which transport carries them, so there is exactly one number in the
tree. Inbound is bounded AT THE READ (take(MAX+1)); measuring after reading
would let a hostile peer allocate first, which is the hole the cap exists to
close. An oversized line is refused RequestTooLarge and the stream RESYNCS at
the next newline — pinned, because a cap that kills the connection is a
denial-of-service of its own. Outbound goes through a pure cap_response_line
that swaps an oversized result for ResponseTooLarge keeping the request id
(extracted pure precisely so the replacement is testable without a tool that
can produce megabytes).

CONCURRENCY: took the exit criterion's SECOND branch, with evidence. The
browser server's 16-permit semaphore used try_acquire_owned against a
strictly sequential loop, so at most one permit was ever held and
ConcurrentCallLimit could never fire; grep showed its only consumer was
itself. Checked whether concurrency was the better branch and found the
argument for it weaker than it looks: publish_local holds no lock of its own
and separate connections ALREADY run concurrently, so the sequential loop was
never the podman-safety property it might appear to be — but that also means
nothing forces concurrency now. An unbindable limit reads as protection while
providing none, so it is REMOVED rather than left as an untaken branch (the
755-qcxh rule). What the transport actually guarantees — one in-flight call,
replies in request order — is now pinned by test, and both the spec and the
type's docs direct a future pipelining transport to put its limit where it
can bind, with a test that observes a rejection.

Evidence: litmus:host-browser-mcp-lane-socket-shape 11/11 (6 -> 11 steps),
including three behaviour steps and a new no-unbindable-limit guard verified
falsifiable by reintroducing the limit (FAIL) and restoring it (PASS). 451
headless + 103 browser-mcp tests green. Spec gained the payload-ceiling and
concurrency requirements plus two scenarios.

616-nm7q split status: 5ryn, 3trn, dqsv all CLOSED; only 779-hae5 (Nix
packaging parity) remains and it needs a Nix-capable host — nix is absent on
yoga, so it is NOT a yoga packet.

Metrics (verbatim): experts: calls=798 answered=797 unsupported=1 degraded=0
errors=0 answer_rate=99% | expert_accuracy: pass=21 total=21 rate=100% |
mcp: servers=3 per_server=cli=791;forge-plan=7;project-info=3 health=ok |
flow: cycles=3 avg_completed_per_cycle=2.33 avg_commits_per_cycle=8
overhead_ratio=3.43 | timing: steps=39 build_check_ms_avg=16965
litmus_ms_avg=2796 slowest=build-check:24616 | plan: packets=959 ready=340 |
experts_substitution: unknown. flow note: overhead_ratio 4.5 -> 4.2 -> 3.43
across three cycles as batches amortize — the 682-yiz7 signal is now a trend
worth watching, not yet a conclusion. Advisories: stranded=0, compaction not
eligible, malformed=0. No forge e2e: full-meta rate-limited (~2h remaining at
cycle start); the first cycle after ~00:22Z takes it. Deferred deliberately:
780-32zr (17 ghost spec:mcp-tool-socket traces) — its fix is a spec-OWNERSHIP
decision (new mcp-tool-socket spec vs retarget to host-browser-mcp) and
starting it half-way at cycle end would leave the tree mid-refactor; it is
first up next cycle.
