# Podman sqlite storage-lock stall cascade under SIGKILL (2026-07-15)

- **Type**: exploration (incident root-cause + shaped reductions)
- **Filed by**: linux-tlatoani-claude-20260715T2107Z (meta-orchestration cycle)
- **Status**: open — reductions shaped, none implemented
- **Host**: linux_mutable (macuahuitl, Fedora 44, podman 5.8.4, sqlite db backend)

## Incident

During this cycle's `./build.sh --ci-full --install` pre-build gate, five
podman-dependent litmus tests failed by timeout in a cascade:

- `litmus:clickable-trace-index-observatorium-skeleton` (step 1, 120s)
- `litmus:forge-gitconfig-bidirectional-quarantine` (60s)
- `litmus:forge-runtime-ca-trust` (timeout)
- `litmus:forge-standard-gitconfig-path` (120s)
- `litmus:forge-config-trust-cross-platform-parity` (300s)

None were code regressions. Every `podman` invocation on the host — including
a bare `podman ps` — blocked ~90–100s (sqlite busy-retry, near-zero CPU,
`hrtimer_nanosleep`, fd open on `~/.local/share/containers/storage/db.sql`),
then either recovered or blew the litmus step budget.

## Root cause (verified live)

1. A litmus step timeout **SIGKILLed a podman process mid-sqlite-write**.
   Evidence: hot journal `db.sql-journal` (mtime 14:41) + podman pid 65439 in
   state **`Zl`** — thread-group leader dead (defunct) but threads surviving,
   so its fd table and sqlite lock stayed live for ~7 minutes (14:41→14:48).
2. While the half-dead process held the lock, every podman call sat in
   sqlite's busy-retry (podman's busy_timeout ~100s ≈ the observed stall).
   When the last thread exited, `podman ps` returned in 91.9s; the very next
   call took 19ms.
3. **Reproduced immediately**: stopping the tainted ci-full run mid-litmus
   SIGKILLed another in-flight podman and stamped a fresh hot journal
   (mtime 14:49) — the failure mode regenerates any time a podman writer is
   hard-killed, which is exactly what `timeout`-style step budgets do.
4. Contributing pressure: podman was already contended before the kill — the
   observatorium `container create` took **138s** (journal 14:38:32,
   m=+138.49) against a 120s step budget, because pre-build litmus fixtures
   run podman work concurrently with the gate's own podman traffic under a
   host load of ~12-16 (cargo release builds).

## Why it matters

One hard-killed podman writer poisons EVERY subsequent podman-dependent
litmus in the same gate run (~100s stall each), producing a wall of
environmental FAILs indistinguishable from real regressions — the whole
run's verdicts are tainted and the gate must be rerun. Cost today: one full
ci-full pre-build pass + diagnosis time.

## Addendum (same cycle, rerun): two more signatures of the same class

The ci-full rerun (healthy podman at start) reproduced the *family* twice
more, without the sqlite lock:

5. **Runner hang via inherited stdout pipe**: the parity fixture
   (`litmus:forge-config-trust-cross-platform-parity`) backgrounds a
   compiled `tls-server`; the step hit its 300s budget, `timeout` SIGTERMed
   the direct child, but `tls-server` IGNORES SIGTERM (verified live: kill
   needed SIGKILL) and inherited the step-output pipe write-end. The
   runner's command-substitution read (`$(timeout … bash -c cmd 2>&1)`)
   blocked in `anon_pipe_read` for 10+ minutes PAST its own step budget —
   the whole gate hung until the stray was hand-killed (pid 112364 held
   `pipe:[241334]`, runner fd 3). A step timeout must bound the RUNNER's
   wait, not just the child's lifetime.
6. **Cargo target-lock contention inside the gate**:
   `litmus:headless-init-status-check-source-built` (fake backend, no real
   podman) timed out at 180s with a 0-byte log, then passed standalone in
   0.22s — its `cargo test` sat on the target-dir lock behind another
   gate-spawned cargo. Same class: budgets assume uncontended resources.
   (Observatorium step 1: 120s FAIL in-gate, 0.47s standalone — same run.)

## Shaped reductions (verifiable, smallest-first)

1. **Runner step-capture + kill-ladder hardening**
   (`scripts/run-litmus-test.sh` `execute_test_command`): (a) capture step
   output to a FILE and `cat` it after `timeout` returns — a surviving
   grandchild holding a pipe write-end can no longer block the runner
   (addendum item 5); (b) `timeout --kill-after=10s` so TERM-ignoring
   fixtures still die (addendum item 5) and podman writers get a rollback
   window before KILL. Verifiable: fixture backgrounds a TERM-ignoring
   sleeper inheriting stdout; the step must return within budget+grace.
2. **Podman-responsiveness preflight for podman litmus tests**: a cheap
   `timeout 5 podman ps` probe emitting `eligible|skip:podman-stalled`
   (same falsifiable-verdict grammar as `scripts/e2e-preflight.sh`); on
   `skip:` record ONE environmental verdict instead of N cascading FAILs.
   Verifiable: litmus asserting the probe's output grammar.
3. **Serialize podman-heavy fixtures under the smoke lock** (or a
   podman-access lease) during the pre-build gate so step budgets are
   measured against an uncontended podman. The observatorium create's 138s
   under load vs 120s budget is the concrete driver.
4. **Step-budget audit**: observatorium step 1 (120s) and the forge config
   fixtures (60s) assume uncontended podman; either raise budgets to
   measured-under-load values or depend on reduction 3.

## Related

- Recovered pre-restart fixture fixes (commit de0b5829) solved the
  *image-absent* half of pre-build podman litmus fragility; this issue is
  the *lock-stall* half.
- `plan/issues/agent-concurrency-collisions-2026-06-20.md` (concurrent-cycle
  discipline), order 265 (forge heartbeat/liveness vs timeout inference —
  same "hard kill considered harmful" family).
