# Push-transaction FSM as a FlowSource: model the forge->mirror->GitHub push pipeline as explicit states on the FlowState channel (2026-07-24)

- **Date**: 2026-07-24
- **Class**: research+impl (research half MUST land first, operator standing rule)
- **Area**: git-mirror pipeline / control-wire event propagation / tray observability
- **Severity**: P2 as a packet (the individual stranding bugs have their own fix
  packets — orders 462, 424); the CLASS it closes is P1-generating
- **Owner**: linux (mirror image + headless emitter; trays consume on all three hosts)
- **Discovered-by**: operator synthesis 2026-07-24 — "playing whack-a-mole with .git
  states": agents intermittently fail to push, salvage branches strand, relay
  rejections are silent; every instance was DISCOVERED LATER, never OBSERVED live
- **Status**: proposed
- **Desired release**: v0.5
- **Sibling (transport this rides on)**: `plan/issues/research-flow-state-event-channel-2026-07-23.md`
  — its draft `FlowSource` enum covers only `Login{provider}` and
  `DependencyNode{node}`; THIS packet adds `PushTransaction{repo, ref}`

## Motivation — the pipeline has no modeled states, so failures surface as archaeology

A forge push traverses: forge commit -> `git://` push to the mirror -> pre-receive
YAML validation -> synchronous relay (`relay-refs.sh`) -> credential mint (Vault
Agent + credential.helper) -> GitHub ack. NOT ONE of those stages is a modeled
state anywhere; the only trace is a log file inside the mirror container
(`images/git/relay-refs.sh:7`, `/var/log/tillandsias/git-push.log`). Three recent
incidents, three different stages, one shared shape — the failure was invisible
until someone went looking for a branch that wasn't there:

- **Order 462** (`mirror-pre-receive-blocks-all-new-branches`): pre-receive
  full-tree YAML validation rejected EVERY new-branch push; the windows observer
  discovered it live 2026-07-23 08:50Z only while salvaging an already-stranded
  worktree. Terminal state that should have been emitted: `rejected{pre-receive-validation}`.
- **Order 424** (`git-mirror-credential-lifecycle`): live max-TTL evidence
  2026-07-23T03:03:47Z — "[vault-renewer] WARNING: git-mirror Vault token can no
  longer be renewed" ~1h into a session; the consequent relay push strands in the
  mirror volume until a lane relaunch re-mints (449/450 startup reconcile).
  Terminal state that should have been emitted: `stranded{credential-expired}`.
- **MOT-02** (`plan/issues/optimization/meta-orchestration-technique-audit-2026-07-23.md:142`):
  ~38 minutes of out-of-order publication — a claim was observable while the work
  was not, and a downstream agent consumed an unpublished intermediate SHA. With
  per-`{repo,ref}` transaction states, "committed locally but not github-acked"
  is a queryable condition, not a trap.

## Evidence — the stages exist in code, unmodeled (file:line)

- `images/git/pre-receive-hook.sh:160` — "Push rejected: YAML validation failed" (order-462 reject site).
- `images/git/pre-receive-hook.sh:164-171` — relay helper invocation; ":171" is the silent-to-the-tray "upstream did not durably accept" rejection.
- `images/git/pre-receive-hook.sh:175` — "Relay verified: upstream durably accepted the ref transaction" — the order-318 verified ack, the ONLY legitimate ground truth for `github-acked`.
- `images/git/relay-refs.sh:29` — no-upstream local-only accept (a distinct terminal state, not an error).
- `images/git/relay-refs.sh:92-94` — Vault Agent token expired / credential unavailable branches (order-424 stranding site).
- `images/git/git-credential-tillandsias.sh:29-31` — per-operation credential mint (`get`; store/erase no-ops) — the mint stage.
- `images/git/post-receive-hook.sh:5-8` — post-receive is bookkeeping only; it cannot carry ack semantics (githooks(5), per order 318).
- `crates/tillandsias-control-wire/src/lib.rs:106-107,291-293,369` — `#[non_exhaustive] ControlMessage`, `Subscribe`/`SubscribeAck`, `SubscriptionTopic`: the additive push channel the sibling packet extends and this FlowSource rides on.

## Proposed model

Define a `PushTransaction` FSM, one instance per `{repo, ref}` transaction:

    committed -> mirror-accepted -> relay-queued -> github-acked
                       |                  |
                       v                  v
              rejected{reason}     stranded{cause}

- `committed`: forge-local commit exists, push initiated.
- `mirror-accepted`: receive-pack admitted the ref transaction (pre-receive validation passed).
- `relay-queued`: transaction awaiting/inside upstream relay. Today the relay is
  synchronous in pre-receive (order 318), so the happy path transits this state
  near-instantly — but the startup-reconcile path (449/450: stranded refs flushed
  after relaunch) and any future async transport from order 322 live here for
  minutes-to-hours. This state IS the whack-a-mole zone; making it visible is the point.
- `rejected{reason}`: validation or relay refusal, reason from the stable-code vocabulary
  (`pre-receive-validation`, `non-ff`, `bulk-delete-guard`, `relay-upstream-refused`).
- `stranded{cause}`: accepted locally but not durably upstream, no active progress
  (`credential-expired`, `upstream-unreachable`, `no-upstream-configured` if unexpected).
- `github-acked`: derived EXCLUSIVELY from the order-318 verified-ack path — the FSM
  must not invent a second ack signal.

Transitions are emitted as `FlowStatePush` frames (sibling packet's wire shape) with
`source: PushTransaction{repo, ref}`. Trays and agents subscribe: a push stuck in
`relay-queued`/`stranded` is VISIBLE within seconds, not discovered as a lost branch.

## Investigate / prototype

- **Emitter seam**: hooks are POSIX sh inside the mirror container; `FlowStatePush`
  is emitted by the guest headless over vsock. Candidate bridges: headless tails the
  structured push log (`external-logs.yaml` precedent), a hook-written state file per
  transaction in the mirror volume, or a tiny hook->headless socket. Pick one; measure latency.
- **Transaction identity**: `{repo, ref, newsha}` vs a minted transaction id; how the
  startup-reconcile flush (449/450) re-attaches to a `stranded` instance after relaunch.
- **Unification, not duplication**: order 330's observability requirements (relay
  queue depth, last relay per ref, divergence, ack latency) should be DERIVABLE from
  this event stream; order 322's transport migration must only re-site emission
  points, not change the state set.

## Exit criteria (each verifiable)

- **State table pinned by parser/test**: the FSM is a Rust enum with a total transition
  function; a unit test exhaustively enumerates legal transitions and rejects illegal
  ones (compile-time exhaustive match + table-driven test, no prose).
- **Wire additivity proven**: `FlowSource::PushTransaction{repo, ref}` round-trips
  through the existing postcard encode/decode tests with NO `WIRE_VERSION` bump; an
  old peer degrades via the `UnknownVariant` path (`lib.rs:407` precedent).
- **Three incident replays emit the right terminal state (litmus)**: fixture replays
  of (a) an order-462-class new-branch rejection emit `rejected{pre-receive-validation}`,
  (b) an order-424-class expired-credential relay emits `stranded{credential-expired}`,
  (c) an ack-without-relay scenario (order 318's fixture) can NEVER emit `github-acked`
  — extending `scripts/test-git-mirror-relay-verified-ack.sh` or a new litmus binding.
- **Visibility bound measured**: a litmus asserts a subscriber receives the first
  non-terminal transition within a stated bound (target <5s) of push initiation, and a
  `stranded` transition within a stated bound of the causing fault, in fixture.
- **Cross-tray consumption sketch**: exact handler slot-in points for the three trays
  (per the sibling packet's push-listener enumeration), folded through the
  stable-state-code renderer — one vocabulary, no parallel taxonomy.

## Non-goals / scope

- NOT fixing the underlying strandings — orders 462 (new-branch validation) and 424
  (credential lifecycle) own their fixes; this packet makes the CLASS observable.
- NOT defining the FlowState channel/transport itself — that is the sibling packet;
  this packet contributes one FlowSource and its state vocabulary.
- NOT changing push transport or ack semantics — order 322 owns transport; order 318's
  verified ack remains the sole ground truth for `github-acked`.
