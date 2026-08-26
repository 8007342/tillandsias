# A host's FIRST capability row cannot be published — the fold drops it and the release preflight then blocks every push

- Date: 2026-08-25
- Host: calmecacpilli, `linux_immutable`, branch `linux-next`
- Class: `blocked` / `enhancement`
- Relates to: 889-ewvt (capability-row truth), 846-idhn (no base representation), 843-624y, 850-bif2

## Observation

This host published its first capability row, generated (never hand-assembled)
by `host-capability-probe.sh --fragment`. The ledger fold then reported:

    dropped-entry: plan/index.d/20260825t232809z-capability-row-calmecacpilli.yaml:
      a `capabilities:` row for calmecacpilli/bare-metal — the compacted base
      carries no row for that host and locus, so consuming this fragment would
      lose it
    incomplete: 614 packets from a PARTIAL corpus — 1 fragment entry the fold
      could not use

and the pre-push hook refused every push on the consequence:

    ✗ pre-push refused: release preflight says blocked:plan-ledger-incomplete

Isolated: removing this one file returns `ok: 614 packets`. Removing yoga's
capability row instead does NOT clear it. yoga's folds because the base already
carries a yoga row; this one is the first row this host has ever published.

So the refusal is not about the file's content. It is structural, and the
generator is behaving correctly — `check` and `fragments` both report
`malformed=0`.

## Why this matters beyond one host

**A NEW host cannot publish its first capability row without blocking its own
pushes.** That closes the loop macuahuitl is chasing in 889-ewvt from the other
end: a missing capability row may mean not "the host is ignoring the
convention" and not only "the host never built the tray", but **the host tried
and the ledger would not accept it.** Every silent host is a candidate for this,
and the failure is invisible from outside — from the fleet's side it looks
identical to indifference.

It compounds with the routing consequence already recorded on 889-ewvt: a
missing row routes nothing, so a host in this state is both unroutable and
unable to fix its own unroutability.

## The mechanism, as the fold itself states it

`capabilities:` is an LWW-style channel with no base representation yet
(846-idhn), and compaction deliberately refuses to fold it (843-624y). The fold
will not consume a row whose (host, locus) key is absent from the compacted
base, because consuming it would DISCARD it — a correct refusal given the
current data model. The gap is that nothing creates the first base row, so
there is no path from "host has never reported" to "host has a base row".

## Smallest next action

Not fixed here, deliberately: the remedy is a decision about the channel's data
model, which belongs with 846-idhn's owner, not with the first host to trip it.
The candidates, in the order I would try them:

1. Let the fold ACCEPT a row whose (host, locus) is absent from the base, since
   there is nothing to lose by consuming it — the refusal protects against
   overwriting a base row that does not exist.
2. Give `capabilities:` a base representation (846-idhn) so a first row has
   somewhere to land, and teach compaction to fold the channel.
3. An explicit seeding path — a documented, generator-produced way to write a
   host's first base row — if 1 and 2 are both larger than they look.

Option 1 looks like the smallest change that unblocks a joining host, but it
inverts the refusal that the current model relies on, so it is a decision, not
a patch.

## State left behind

This host's generated row is NOT committed — it is held out of the push so it
does not block the trunk, and this host therefore remains ABSENT from
`capability-matrix` despite having produced a valid row. The generated fragment
is preserved outside the checkout so it can be published the moment the channel
accepts it. The row's content, for anyone routing in the meantime: i7-4650U,
2 physical / 4 logical cores, 7.7 GB RAM, `engines: []`, iGPU present but
`usable: false` (`intel-compute-runtime-missing`), battery present,
`legacy_tier: cpu`.
