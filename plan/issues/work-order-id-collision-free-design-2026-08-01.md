# Collision-free work-order IDs — research and design (2026-08-01)

Classification: `research/` → decision record. Requested by The Tlatoāni after a
second order collision in one session:

> *"Issuing new work orders will require some UUID discipline… creating multiple
> work packets concurrently is a common scenario that we must support, without
> triggering manual merges every time… we don't need for work orders to be fully
> numerically sequential, only unique, and we have order given their commit
> numbers and timestamps, so if sequential ids are biting us, let's redesign our
> id system so it doesn't break."*

The direction is right. What follows is what the ledger actually does today —
which changes one part of the proposed design — and the resulting scheme.

---

## 1. What is actually broken (measured, not assumed)

### 1.1 The ledger already contains collisions, and `check` calls them fine

Six order tokens are double-booked at HEAD:

| order | packets sharing it |
|-------|--------------------|
| 160 | `stable-state-codes-research`, `race-safeguards-research`, `microsoft-linux-guest-research` |
| 196 | `macos-litmus-runner-bash-version-gap`, `audit-plan-cross-branch-writes` |
| 197 | `macos-tray-clippy-warnings`, `audit-credential-guard-windows` |
| 201 | `macos-build-check-podman-wrapper`, `litmus-runner-command-backslash-escaping` |
| 224 | `litmus-command-portability-dsl-research`, `forge-gitconfig-quarantine-and-injection` |
| 294 | `brew-ondemand-tool-shims`, `macos-guest-disk-resize-forge-fit` |

`tillandsias-plan check` reports `ok: 497 packets, ids unique, live references
sound` over exactly that state, because it validates `packet_id` uniqueness and
never inspects `order`.

**A second guard does exist, and this correction matters.** `tillandsias-policy
plan-orders` (pinned by `litmus:plan-index-order-uniqueness`) DOES check order
uniqueness and fails exit 1 on a duplicate — but it deliberately GRANDFATHERS
groups whose members are all done/completed, and reports:

```
ok: plan orders unique among open packets (443 packets, 6 grandfathered done-only duplicate groups)
```

All six live collisions are fully `completed`, so the leniency is working as
designed, not failing. An earlier draft of this document said no guard existed;
that was wrong and would have sent someone to build a duplicate of a working
tool.

The accurate reading is narrower and more useful:

- **Detection of OPEN duplicates is already solid.** `plan-orders` would have
  failed on 568/569/570 once both hosts' packets landed on one branch. It never
  got the chance because git conflicted first — the collision surfaced as a merge
  conflict rather than a policy failure.
- **What is missing is not detection but ALLOCATION.** Both guards are
  after-the-fact. Neither prevents two hosts from choosing the same number, and
  the only available repair once they have is renumbering, which is §1.3.
- **`tillandsias-plan check` being silent still matters** because it is the
  surface agents and the plan expert actually query, and it is what reports
  "unique" while six packets are unaddressable.

**Correction to order 566**, which prompted part of this work: it lists fourteen
duplicates (`160 196 197 201 224 246 247 294 392 394 427 429 482 484`). Only the
six above are real. The other eight are child-order *stems* — `246a`/`246b`,
`392a`/`392b`, `484a`…`484e` are DISTINCT tokens, not collisions. One of them,
`427`, has no exact packet at all, only children. An inflated count in a bug
packet sends someone to fix things that are not broken; 566 should be corrected
before it is claimed.

### 1.2 A duplicated order answers with an arbitrary packet

This is the part that matters more than the duplication itself.

`crates/tillandsias-plan/src/lib.rs` keeps two indexes. `by_order_token`
deliberately counts claims and DROPS ambiguous ones, with an explicit rationale
in its own doc comment:

> *"mapping an ambiguous token to whichever packet happened to be parsed last
> would answer a query with an arbitrary packet, which is a worse lie than the
> honest miss this packet was filed to fix."*

But `by_order` — the INTEGER index — is a plain `BTreeMap::insert` at :152, so it
is last-write-wins with no ambiguity detection. And `resolve()` consults the
integer path FIRST (:226), so for a duplicated integer order the honest-refusal
logic is unreachable.

The result, reproducible today:

```
$ tillandsias-plan status 160
160	completed	microsoft-linux-guest-research
```

Confident, well-formed, and silently hiding two other packets that equally claim
order 160. The crate does precisely what its own comment calls "a worse lie",
because the policy was implemented on one index and not the other.

### 1.3 Renumbering is expensive because order numbers leak into immutable artifacts

When this host collided with the sibling on 568/569/570, the renumber to 575+
required chasing references through packet bodies, code comments,
`methodology/agent-observability.yaml`, and a litmus `@trace order:` header.
There are 30 `@trace order:NNN` headers in the tree.

The unfixable category is **commit messages**. Commits already pushed saying
"order 568" now point at the sibling's packet. Nothing can correct them.

**This single fact governs the whole design: any scheme that permits renumbering
after a reference exists reintroduces the cost we are removing.**

---

## 2. What is NOT broken — and it changes the design

### `packet_id` is already a stable, unique, collision-free identifier

Every STRUCTURAL reference in the ledger already uses `packet_id`, never `order`:
`depends_on`, `split_into`, `parent`, `release_target`. `check`'s referential
soundness resolves against packet_ids. Concurrent filing has never corrupted the
dependency graph, and could not.

So `order` is not an identifier. It is a **human-facing label** that happens to
also be a lookup key. That reframes the problem: we are not replacing an identity
system, we are fixing a label that was accidentally given identity duties.

### The schema already tolerates non-integer orders

`392a`, `394b`, `484e`, and a `provisional` sentinel (28 live packets) all exist
and resolve. `order_token()` normalizes any scalar to a lowercase string.

**A suffixed order needs no schema change and no migration of existing packets.**

---

## 3. The design

### D1 — `packet_id` is the identity. `order` is a label. Say so out loud.

Already true in the code; not yet true in doctrine, which is why agents reach for
order numbers when a packet_id would be stable. Everything durable — dependencies,
citations, cross-references in specs and methodology — SHOULD name the packet_id.

### D2 — Order tokens become `<seq>-<suffix>`, allocated once, NEVER normalized

Format: `575-k3f9`. The operator's proposal was `<NEXT-ID>-<RANDOM-UUID>` with a
mediator that validates, accepts, "and only then normalizing as needed".

**Adopt the shape; reject the normalization step.** Normalization is renumbering
under a friendlier name, and §1.3 is what renumbering costs. The suffix must be
PERMANENT — a stable part of the identifier, not a staging device discarded at
acceptance. Two hosts that both pick 575 produce `575-k3f9` and `575-m2p1`: two
distinct, permanent, correct identifiers. Nothing needs reconciling, so the merge
is a text append on both sides rather than a semantic conflict.

That is exactly the operator's own criterion — *"we don't need for work orders to
be fully numerically sequential, only unique"* — taken to its conclusion. Once
sequence is not required, there is nothing left for normalization to achieve.

The `<seq>` prefix is retained deliberately: it preserves rough chronology, keeps
`575-k3f9` readable and sayable, and means the existing corpus stays valid. It is
explicitly NON-AUTHORITATIVE — a prefix appearing twice is normal, not a defect.

### D3 — The suffix is 4 lowercase base32 characters, not a UUID

A full UUID is unusable where these tokens actually live: spoken aloud, typed into
`plan_status`, and embedded in `@trace order:` headers. Four characters from a
32-symbol alphabet give 1,048,576 values. The suffix only has to disambiguate
packets that chose the SAME prefix — realistically two or three hosts in the same
hour — so the collision probability is far below the noise floor, and unlike
today a full-token collision is DETECTED and refused rather than silently
resolved.

Alphabet excludes visually ambiguous characters (`l`, `1`, `o`, `0`) so a token
read off a terminal and retyped resolves to the same packet.

### D4 — The mediator gates ACCEPTANCE, not identity

The operator's mediator/orchestrator role is worth keeping, but it must not own
identity: if a packet's ID is not final until a mediator says so, we have
reintroduced coordination — the exact thing that makes concurrent filing painful.

So identity is self-allocated (D2/D3, needs no coordination), and the mediator
gates **admission to the work queue** — status, shaping quality, release
targeting, duplicate-intent detection. A packet filed concurrently is immediately
valid and immediately addressable; whether it is *ready to claim* is the
mediator's call. That separation is what lets both properties hold at once.

### D5 — Chronology comes from events and git, and is honestly approximate

The operator is right that ordering is recoverable from commits and timestamps —
`events[].ts` and git history already carry it, so nothing is lost by dropping
sequence from the ID.

Worth stating rather than discovering later: neither source is a strict total
order. Git history is a partial order until branches merge, and timestamps come
from host clocks across four platform branches. This is fine for a human-facing
sort and for "what happened around then", and it must NOT be used where a strict
total order is required. Nothing in the ledger currently requires one.

### D6 — Migration is purely additive; nothing is renumbered

Existing integer orders remain valid identifiers forever. `575` and `575-k3f9`
both resolve. Renumbering 497 packets to a new scheme would be the very cost this
design exists to eliminate, applied at maximum scale.

The six existing collisions (§1.1) are the exception and need a one-time
disambiguation, because they are currently unaddressable. They are all
`completed`, so the cost is low — but their packet_ids are already unique, so
even there the correct repair may simply be to null the order and address them by
packet_id.

---

## 4. Two defects to fix regardless of the ID scheme

These are live today and are not fixed by a new format:

1. **`tillandsias-plan check` must SURFACE duplicate order tokens.** It reports
   "ids unique" over six collisions. It should warn (not fail) and name every
   claimant: `plan-orders` already owns the hard gate for open duplicates, so
   duplicating that gate here would fail `check` on a clean checkout over
   historical debt that is deliberately grandfathered. Warning is the right
   severity; silence is not.
2. **The integer lookup must adopt the token path's honest-refusal policy.**
   Answering `status 160` with one arbitrary packet out of three is worse than
   refusing, by the crate's own stated reasoning.

Fixing (2) without (1) would turn six silent wrong answers into six loud misses —
better, but still broken. They land together.

---

## 5. What this does NOT solve

Stated plainly so it is not mistaken for solved:

**The git text conflict is a separate problem.** Two hosts appending packets to
the end of a single `plan/index.yaml` conflict textually no matter how the IDs
are formed. What the ID scheme removes is the SEMANTIC half — the renumbering,
the reference-chasing, the "which 568 did you mean". The remaining conflict is a
mechanical "keep both sides", which is what was done by hand today.

Two candidate follow-ups, neither chosen here:

- **`merge=union` on `plan/index.yaml`** via `.gitattributes`. Cheap, and makes
  append-only conflicts auto-resolve. Risk: union merge DUPLICATES lines when the
  same region is edited on both sides, and events are appended into existing
  packets constantly, so it would eventually produce a malformed or
  double-evented ledger. It is only safe if `check` + a YAML parse run on every
  merge and are trusted to catch it. Do not adopt casually.
- **One file per packet** under a `plan/packets/` directory, with the index
  derived. Structurally removes the conflict — two hosts filing concurrently
  touch different files. Larger change; note `plan/steps/` is a legacy markdown
  format the plan crate does not read, so it is not a head start.

---

## 6. Recommendation

Adopt D1–D6. Fix §4 immediately (small, and the current behaviour actively
misleads). File the allocator, the mediator acceptance gate, and the §5 merge
question as separate packets. Correct order 566's duplicate count before anyone
claims it.
