# 746-htj9 — the sanctioned YAML reader, and where it is proven to exist

- order: `746-htj9`
- host: yoga (linux_immutable, with `tillandsias-builder` toolbox), `linux-next`
- date: 2026-08-26

## What landed

`tillandsias-plan` gained the two subcommands that let a gate read YAML without
an interpreter, and `check-plan-schema-divergence.sh` — the script whose two
rewrites caused the 2026-08-15 double outage — now uses them:

- `validate-yaml <file>...` → `ok:yaml-loads:` / `blocked:yaml-load-failed:` /
  `blocked:yaml-unreadable:`
- `yaml-get <file> <dotted.path>` → sequence, space-joined

**Why `tillandsias-plan` and not `tillandsias-policy`,** which already had an
identical `validate-yaml`: availability is the entire point of this packet, and
only `tillandsias-plan` has it. `scripts/cycle-preflight.sh` rebuilds it at the
top of every cycle. `tillandsias-policy` is not built by default and its facade
falls through to `cargo run` — a multi-minute build in a fresh forge, needing a
network the enclave may not grant. This follows the packet's own `notes`.

## Availability evidence — run, not asserted

Exit criterion 2 says *"an executable check proves availability in each
environment rather than asserting it"*. `scripts/check-yaml-reader-availability.sh`
is that check. Verdicts recorded 2026-08-26 on yoga:

```
HOST:    ok:yaml-reader:host:./target/release/tillandsias-plan
TOOLBOX: ok:yaml-reader:toolbox:./target/release/tillandsias-plan
```

**The forge leg is NOT evidenced here, and I am not claiming it.** macuahuitl
noted on 2026-08-25 that the forge and toolbox halves cannot be evidenced from
a mutable Linux host alone; yoga is immutable *with* a builder toolbox, which
is why two legs are real. Producing the third needs a forge lane to run the
check and paste its verdict. The instrument now exists, which is the part that
was missing.

## One correction to the packet's own table

The context table lists `python3` as `present (FORBIDDEN)` and omits `cargo`.
On this Silverblue host `cargo` **is** present (`~/.cargo/bin/cargo`, rustup).
That does not change the verdict — a `cargo run` fallback is still unusable in
a fresh forge for the timing reason above — but the table shouldn't be read as
saying the host has no Rust toolchain.

## Negative control (720-24u6), proven not vacuous

A file that will not load must never be reported as a vocabulary mismatch. Both
verdicts were produced from the same script on the same day:

```
# valid files, diverging vocabulary
blocked:status-vocab-diverges: plan/index.yaml=(pending ready …) vs …=(pendingXX ready …)
# unparseable file
blocked:index-load-failed: …/bad.yaml: blocked:yaml-load-failed:… while parsing a flow node
```

They are different strings from different branches, so the control distinguishes
something real. `scripts/test-yaml-reader-availability.sh` pins all of it (9/9)
and is wired into `./build.sh --check` — an unregistered test is inert.

The 720-24u6 regression is checked against **the real `plan/index.yaml`**, not a
fixture, as the exit criteria demand: its bare ISO-8601 timestamps are what
Ruby's `safe_load` rejected without `permitted_classes: [Time, Date]`.

## A bug the 721-nyev guard caught in this very change

My first version hardcoded `./target/release/tillandsias-plan`. Every forge
exports `CARGO_TARGET_DIR` to the cache volume, so `./target/` does not exist in
the mounted checkout — the hardcoded path would have been absent *in precisely
the environment this packet is about*. All three scripts now resolve through
`scripts/plan-binary-probe.sh`.

## What remains — this is a slice, not the close

Interpreter executions in `scripts/`, counted as **lines that actually execute**
(the raw `grep -l 'ruby|yq'` figure of 21 files / ~120 hits is mostly prose):

| | at claim | now |
|---|---|---|
| files | 9 | 8 |
| lines | 26 | 23 |

Remaining: `run-litmus-test.sh` (9), `hooks/pre-push-local-gate.sh` (4),
`test-set-field-yaml-shapes.sh` (3), `with-tillandsias-builder.sh` (2),
`archive-plan-packets.sh` (2), `with-wsl2-builder.sh` (1),
`test-litmus-diff-scope.sh` (1), `local-ci.sh` (1). The `with-*-builder.sh` hits
are toolbox provisioning, not YAML reads, and should be triaged before migration.

---

## Second tranche (yoga, cycle 9, same day)

`yaml-get` learned numeric path segments (`status.0.value`), and
`yaml-type <file>` was added, printing yq's own spelling (`!!map`, `!!seq`, …)
so call sites that already compare against `!!map` need no edit. Both verified
against the tools they replace on the same inputs:

```
status.0.value  ->  in_progress     (tillandsias-plan)
                ->  in_progress     (ruby -ryaml)
yaml-type       ->  !!map / !!seq   (tillandsias-plan)
                ->  !!map / !!seq   (yq eval 'type')
```

### `test-set-field-yaml-shapes.sh` — a gate that could not run here at all

Its precondition refused unless `ruby` was on PATH. Confirmed on this host:
**neither `ruby` nor `yq` is installed**, so the fixture exited 2 rather than
checking anything. It now runs on the host: **14 passed, 0 failed**.

Still non-vacuous — with no binary it refuses loudly rather than passing:
`fail:set-field-yaml-shapes:no-runnable-plan-binary`.

The fixture now validates with the same binary that wrote the fragments. That
is deliberate and not circular for what it asserts: the claim is that the
*writer* emits YAML that round-trips, and the reader is serde_yaml — the
library the ledger's real consumers use. The independent ruby cross-check above
was run by hand at migration time and agreed.

### The trunk's only gate was stricter on some hosts than others

`pre-push-local-gate.sh` ran two checks under yq — parse, and `type == !!map` —
and when yq was absent it delegated to `tillandsias-plan check` with a note.
**The delegation could not express the second check.** So the map-shape
assertion was enforced on hosts with yq and silently skipped on hosts without,
including this one. That is this packet's defect one level up, in the gate that
protects the trunk.

Both tiers now enforce **both** checks. The yq tier is retained only for a host
with yq and no built binary, and is no longer the weaker path.

### Surface

| | at cycle-8 claim | after cycle 8 | after cycle 9 |
|---|---|---|---|
| files | 9 | 8 | 7 |
| executing lines | 26 | 23 | 20 |

`pre-push-local-gate.sh` still counts 4 yq lines — deliberately. They are the
transitional equal-strength tier described above, not a remaining gap.

Of the rest, three are **not YAML reads** and should not be migrated blind:
`with-tillandsias-builder.sh` / `with-wsl2-builder.sh` are toolbox package
lists (`ruby perl-FindBin`, `jq yq ripgrep`), and `test-litmus-diff-scope.sh`
is a `printf` label. The real remaining work is `run-litmus-test.sh` (9 sites,
several using `select(...)` filters that `yaml-get` deliberately does not
implement) and `local-ci.sh` (1, same shape). Those need either a richer query
or restructuring, and are worth a decision before more code.
