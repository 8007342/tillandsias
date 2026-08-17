## Cycle 2026-08-17T08:34Z (linux_mutable macuahuitl — night-2, release-held)

**Result: 788-mj37 completed inline (the OBSERVED-vs-INFERRED shaping rule is
now methodology and routable); 795-h8er and 796-4ydb delegated. Release still
parked on the windows idiomatic-layer work.**

Between-cycle integrations: 787-f7dh (an unparseable fragment is now a typed
exit-3 failure with position, and the guard counts any non-zero rc as
unexamined) and 765-mza8 (diff-scoped litmus selection with eight fail-CLOSED
refusal paths and a gate-stamp veto, so a scoped run can never be blessed by
pre-push). Both integrations taught something: the first failed its fixture on
the merged tree until the plan binary was REBUILT — merging a fork that
touches the binary is not done until you rebuild, because every shell guard
resolves it by execution; the second hid two genuinely-red tests on its first
measured use, which is precisely the cost the veto exists to bound.

- 788-mj37 COMPLETED: methodology/distributed-work.yaml gains
  work_shaping_protocol.observed_vs_inferred. The why clause names all five
  falsifications by order rather than asserting a principle. Deliberately NOT
  a gate — a checker that tried to classify prose as observation-or-inference
  would be the false signal 741-2izr warns about.
- Forks in flight, both outside the windows lane: 795-h8er (the operator's own
  nix-cache request — persistent store on the daemonless rung, with
  concurrency and GC as first-class exit criteria) and 796-4ydb (the fold
  warns that its answers are incomplete and exits 0; brief asks for a
  deliberate refuse-vs-degrade split rather than a blanket hard-fail, since a
  reader that dies on a bad fragment could wedge the very tooling needed to
  fix it).
- Also wired check-tray-string-corpus-drift.sh, orphaned on arrival from
  windows (792-77bt), as the report it is. Activation audit 47/47, orphan 0.
- Siblings merged; ledger 1020 packets.
