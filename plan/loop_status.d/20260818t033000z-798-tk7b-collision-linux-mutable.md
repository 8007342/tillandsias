## Cycle 2026-08-18T02:37Z (cont.) — 798-tk7b was implemented twice, six minutes apart, by two hosts holding no lease

**Result: the fork's 797-p2xa landed, and integrating it surfaced that yoga had
implemented 798-tk7b concurrently with me. Grammar converged onto theirs;
surface ownership filed as 814-iyu7 rather than decided unilaterally.**

- **797-p2xa COMPLETED (fork), `070101b97`.** Half was already done by yoga
  (`97cb255a9`) — the mock's *outer* case already failed closed at exit 97;
  `plan_status` still said `ready` because the expert index was stale. The fork
  did the delta: three **nested** `case` statements (`image`, `secret`,
  `image inspect` without `--format`) where a non-match leaves the arm having
  printed nothing and falls to the trailing `exit 0` without ever reaching the
  outer `*)`. Seven mutation controls, each break→red→restore→green with
  sha256-identical restore. **Silent passes converted to explicit arms: zero** —
  across two full litmus runs the new refusal fired zero times, which *answers*
  the packet's open question ("some callers may depend on the permissive tail —
  unknowable without running everything") instead of assuming it. Litmus
  309→311 PASS, 6→5 FAIL, all deltas accounted for. Filed **813-frih**:
  `secret rm`/`secret inspect` read `$2` instead of `$3`, so `secret rm X`
  exits 0 and the secret survives.

- **The collision.** yoga (`8071b647b`, 20:01:07 PDT) implemented 798-tk7b
  *inside the product* — `format_enclave_service_line`, surfaced via
  `tillandsias --diagnostics`, routed through `PodmanClient::list_containers`
  with no new podman call, since ps JSON already carried ExitCode/ExitedAt/
  Restarts and `ContainerListEntry` simply never surfaced them. I closed the
  same packet at 19:55:48 PDT with a host script wired into cycle-preflight.
  **Neither of us took a lease.** The ledger has the mechanism; the packet sat
  `ready` with `lease: null` and two hosts read it as available inside one hour.
  First observed duplicate-implementation collision in this fleet, on the night
  host parallelism went up. Cost ~4h of duplicated effort.

- **What I converged, because it needed no decision.** Two dialects for the
  packet that explicitly demanded *one vocabulary* would have been a
  self-inflicted violation of the thing it closed. My script now emits yoga's
  spellings exactly where they overlap: `fail:enclave-service-dead`,
  `note:enclave-service-stopped`, `signal=SIGKILL`/`SIGTERM`/`SIGSEGV` rather
  than raw numbers, `restarts` from the same round trip that already had it,
  shared keys in yoga's order with my extras appended. Their dead-vs-stopped
  split is better than my lumping and I adopted it — a clean `podman stop` is
  not a fault, and conflating it with a crash makes the report noisy enough to
  ignore, which is how the blind spot survived five hours in the first place.
  Fixture 11→12 with a scenario pinning the split.

- **What I did NOT decide, and why.** Which surface owns the report. yoga's
  reaches end users inside the enclave and mine does not, which is a strong
  argument for theirs. Mine needs no product build and runs where the *measured*
  blind spot was — five hours of **cycles**, not of end users; a report living
  only in a binary that must first compile does not cover a broken build. Mine
  also names the stale-healthy corpse and can be told what to EXPECT; theirs
  carries `restarts` and lists healthy services too. Deleting a sibling's
  just-landed product code, or my own wired guard, is not a call one host makes
  at 20:30 on the strength of having written one of them. **814-iyu7**, with
  three ranked resolutions.

- **Worth keeping**: two independent implementations, no contact, agreed on the
  diagnosis, the vocabulary family, *and* the stale-healthy observation. That is
  real convergence evidence — just expensively bought. If it happens a second
  time, the lease is not merely unused but unusable, and that is its own packet.
