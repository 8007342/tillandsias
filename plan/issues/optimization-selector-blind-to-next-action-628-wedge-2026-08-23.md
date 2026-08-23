# optimization: the selector ranked an un-startable packet URGENT, and the 628-c7qd/628-w9sm pair is mutually wedged

- Filed: 2026-08-23 (UTC), by windows host **yolanda**, loop cycle #4.
- Class: optimization/ (selector) + a ledger-hygiene wedge surfaced for the
  packet owner. Related: 628-c7qd, 628-w9sm, 792-77bt, 847-wgy4
  (capability-aware routing), scripts/select-work-batch.sh.

## What the selector emitted (verbatim machine line)

    batch: epic=harness-mcp-expert-validation role=windows release=v0.5 size=3
    budget=10 score=6.814 seed=windows-unknown-none-yolanda-20260823 pick=5/7
    route=rank:7/7:width=7 urgent=tray-shared-string-resource-layer

## Why the urgent pick is not workable, by the ledger's own words

628-c7qd's `next_action` opens with **"Do NOT start the string layer"** — two
2026-08-17 macOS measurements refute the packet as written (exit criteria 2
and 3 are mutually exclusive; the corpus must flow code→toml), pending a
ruling on 628-w9sm. The selector ranks on priority/epic/neglect and reads
neither `next_action` nor the refutation events, so the one row the ledger
explicitly fences off is the one it marked urgent. A host that trusts the
batch and starts implementing re-does exactly what the macOS fan-out already
refuted.

## The wedge, which is the sharper problem

- 628-c7qd waits on 628-w9sm's ruling (per its next_action).
- 628-w9sm is `status: pending` AND carries
  `depends_on: [tray-shared-string-resource-layer]` — **c7qd itself**.

The dependency records the ORIGINAL sequencing (layer first, then drift
cleanup); the 2026-08-17 refutation inverted it (w9sm must rule first, then
c7qd's criteria get re-derived). Nobody updated the edge, so each row now
waits on the other and both are invisible to progress: c7qd sits `ready` and
gets picked and skipped; w9sm sits `pending` and its `depends_on` can never
be satisfied by a packet that must not start. Deliberately NOT fixed by this
host: w9sm is pending an operator-gated ruling under spec:tray-ux, and
editing the dependency structure of a pending ruling from a drive-by cycle is
how sequencing decisions get silently overwritten. Events are appended to
both packets instead; the owner should either drop/invert w9sm's depends_on
or record the ruling that dissolves it.

## The other two batch rows, and why fit matters

- 317 brew-aarch64-harness-strategy: verifiable only where brew/aarch64
  exists — macOS. 468 forge-claude-oauth-vault-inject: tagged forge+vault;
  this host has no podman lane (`services-no-podman`). Both are `pickup_role:
  any`, so the selector offers them to windows, where they can be WRITTEN but
  not VERIFIED — and unverifiable work shipping from the wrong host class is
  the failure mode capability routing (847-wgy4) exists to prevent. The
  triage line even shows `caps_filtered=2 accel_filtered=3` — the filter
  exists and did not catch these, because tags describe the DELIVERABLE's
  domain, not the verification substrate it needs.

## Smallest next actions

1. Selector: treat a `next_action` beginning with "Do NOT start" (or a
   machine-readable equivalent — a `hold_until: <ref>` field would be
   cleaner than prose sniffing) as an exclusion, same tier as status!=ready.
2. Owner of 628-w9sm: record the ruling or fix the inverted depends_on.
3. Capability routing: verification substrate (can this host RUN what it
   changes?) as a routing input, not only device tags.
