# The only path to correct a non-status field is named `status:` (order 635-qpx8)

- Date: 2026-08-09
- Host: windows (windows-next), meta-orchestration cycle 4
- Class: `enhancement/` — documentation and naming, not a code defect
- Related: `627-c9c2` (never edit plan/index.yaml directly), `635-i6vm` (fold discarded status transitions)

## What nearly happened

Closing `635-qpx8` required changing `pickup_role` on three packets. The rules
in force:

- `627-c9c2`: **never edit `plan/index.yaml` directly** — it is a write-write
  concurrency block, and the mirror's pre-receive Psych gate rejects any push
  touching the base at all.
- `plan/index.d/README.md`: fragments carry three channels — `packets:` (G-SET,
  re-adding an existing packet is a no-op), `events:` (a set), and `status:`
  (LWW). The README's Rules section says, verbatim:

  > Events are a set, not a register. Only `status` fields are last-writer-wins.

Read together, those say: a new packet can be added, an event appended, a status
changed — and **no other field can ever be corrected**. Every mis-filed
`pickup_role`, `priority`, `depends_on`, or `title` would be permanent. That
conclusion is wrong, and this cycle came within one step of filing it as a
structural defect.

## What is actually true

`fragments.rs` keys the LWW register on `{packet_id}\u{1}{field}` and applies it
to **any** field:

```rust
// LWW-Register: whole-field updates, highest (ts, host) wins.
if let Some(us) = frag.doc.get("status").and_then(Value::as_sequence) {
    let (Some(pid), Some(field), Some(value)) = (…);
    let key = format!("{pid}\u{1}{field}");
```

The channel is *named* `status:` and its entries carry an explicit `field:` key.
So this is valid and works:

```yaml
status:
  - packet_id: dev-end-user-gating-litmus
    field: pickup_role
    value: linux
    ts: "2026-08-09T23:05:00Z"
    host: windows
```

Verified live: after folding, `query --json` reports
`dev-end-user-gating-litmus => linux`, and the Windows claimable queue dropped
from 7 packets to 6.

## Why the wording misleads

"Only `status` fields are last-writer-wins" reads naturally as *only the status
field*. Its intended meaning is *only the fields carried on the `status:`
channel* — which is any field you put there. The channel name and the sentence
reinforce each other toward the wrong reading, and the README's example uses
`field: status`, so nothing in the document contradicts it.

The cost of the misreading is not a broken write. It is an agent concluding that
the ledger has no correction path, and then either filing a phantom defect or
reaching for the one thing that is genuinely forbidden — a direct base edit,
which `627-c9c2` exists to prevent and which fails at the mirror anyway.

## Suggested resolution (filed as a packet)

Rename the channel to `fields:` with `status:` kept as an accepted alias for
every fragment already written, and reword the README rule to *"the `fields:`
channel is last-writer-wins per (packet_id, field); events are a set"*. Add one
non-status example. No fold behaviour changes — the key already includes the
field name.

## Second finding, same cycle: the checker was reading the wrong population

`scripts/check-pickup-role-grammar.sh`, shipped one cycle earlier, grepped
`pickup_role:` out of `plan/index.yaml` and `plan/index.d/*.yaml`. That is the
**pre-fold text**. An LWW correction changes what every reader sees while leaving
the overridden base line untouched on disk, so after the three corrections landed
the checker still reported all three as offenders while `tillandsias-plan` had
already stopped offering them.

It was caught within minutes because the correction and the check ran in the same
cycle — but it makes the checker an instance of the exact defect it was written
to report: active, internally consistent, and measuring a population the system
does not use.

Fixed to read the folded ledger through the plan binary, and to **refuse** rather
than fall back to the raw grep when no binary is reachable — a fallback that
silently measures a different population is the failure, not the mitigation.

A third defect surfaced while adding the regression guard: an empty input
produced `total=0 … verdict=ok:canonical-roles`, i.e. "no problems found" when
nothing had been inspected. That converts any future breakage of the input into a
passing run. Now `refused:empty-projection`, exit 2.

Both are pinned by new steps in `litmus:pickup-role-grammar-shape`: a structural
assertion that the live path never greps the raw ledger, and a negative control
that an empty projection is not reported as clean.
