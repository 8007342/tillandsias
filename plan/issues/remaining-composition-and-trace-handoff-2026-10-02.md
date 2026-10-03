# Remaining composition and trace handoff

@trace order:1538-pwdr, order:1539-dt84, order:1384-aixy

## Provenance and scheduling

Astra performed a read-only immutable-source audit at
`c1923a651b6d662126cf2ad513550747e817628f` on 2026-10-02. No builds,
implementation edits or native claims came from this audit. MCP tools were
unavailable; cited repository symbols were inspected through Git. The source
audit found no `proc.select`, `proc.all`, `proc.chain` or `p:on_exit` at that
candidate. Re-audit the actual landed 1534 head before implementation.

1538 is the next dependent runtime slice, unclaimed until 1534 lands. Research
estimates 100–135 minutes for implementation and targeted verification,
excluding full integration gates and repairs; a verified 90-minute closure
is not promised. 1539 remains a separate, approximately five-hour multi-cycle
trace packet dependent on both 1534 and 1538. Its first claim is a two-hour
vertical slice, not permission to close the whole trace or parent 1384.
Native-platform obligations remain native-host work. The preflight port 1520
must not start while its parent 1384 is unfinished. No recurring timer was
armed; this is a durable dependency-ordered work schedule.

## Implementation seams

Use `crates/tillandsias-plan/src/lua_process.rs` symbols `Host::pump`,
`Host::wait`, `Handler` and `Dispatch`, not a second dispatcher in the
predicate or runner modules. 1538's ownership list must include this file.

`crates/tillandsias-exec/src/managed.rs` `supervise` queues `Event::Finished`
before publishing `Process::result`. Exit callbacks therefore need a pending
completion barrier: invoke outside the dispatch mutex only once the actual
typed result exists, after preceding queued line callbacks. Observation by
wait/select/all must follow the callback; completion ordering must survive
the publication race, including already completed handles.

`lua_process.rs` `outside_callback` and scope latching must cover new
composition methods. Caught callback or reentrancy errors must not reopen a
closed scope. Lua callbacks run only on the Lua thread; no post-cancellation
callback execution is required.

`crates/tillandsias-plan/src/lua_predicate.rs` `prepare_proc` combines
validation with authorization and consent consumption. Whole-chain parsing
must instead validate and snapshot every stage without consuming consent or
starting a child, then authorize each actual execution. Do not reread mutable
or metatable-backed request fields after a yield. Preserve the same resolved
cwd in policy and execution. Reuse `proc_result_to_lua` for byte-preserving
results. A chain must pump outstanding stream callbacks rather than call the
public synchronous run bridge blindly.

`crates/tillandsias-plan/src/script_run.rs` `run_to_verdict` owns teardown.
Composition must retain every terminal verdict latch, including valid
advisory, and cacheable capability absence.

## Unspecified API choices to resolve and test before coding

These are proposals, not newly activated contract requirements:

- Select returns the original handle; expiry can return `nil, "timed_out"`
  without killing children or inventing a child exit code. Explicitly pin
  absent and zero timeout behavior rather than assuming the run-door default.
- All returns full results in argument order; empty all may be vacuous, empty
  select an error. Reject duplicate, foreign, forged, sparse and unexpected
  list fields before waiting; use private host-bound handle identity.
- Chain runs every stage in order per original design, not fail-fast. Preserve
  all typed results, aggregate `ok` and a one-based `first_failure`. Pin empty
  chain and later-stage explicit stdin behavior; no silent override. Policy
  refusal must stay visible even if a later stage succeeds.
- Exit callback receives the full typed result exactly once. Pin replacement
  before dispatch and refusal after delivery consistently with line handlers.

## Suggested named conformance coverage

1. Acknowledged overlapping select with inverted argument/completion order.
2. Selection deadline without child cancellation or fabricated status.
3. Argument-order all while pumping other producers' callbacks.
4. Empty, duplicate, foreign, forged and sparse list validation.
5. Binary stdin passed between chain stages; every result retained.
6. Nonzero, signal, timeout, truncation and policy failure before later success.
7. All-stage validation before execution or consent consumption.
8. Per-execution authorization with snapshotted cwd and request bytes.
9. Exit callback after lines and before wait/select/all observations.
10. Exactly-once, same-thread exit callback and reentrancy refusal.
11. Caught callback error leaves scope closed and owned children stopped.

Existing live ACK, CPU-loop, dropped-handle, cleanup, capture, policy and
shell-string refusal regressions must remain unchanged and green. Preserve
8 MiB per-fd prefix capture and record the older 1 MiB-tail contract drift;
no UX/default-deny/filesystem-capability change or native claim is authorized
by this handoff. Parent forced integration and remote ancestry are required
for each bounded packet's closure.
