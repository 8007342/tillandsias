# Compaction folded 231 unquoted timestamps into the base and broke the Ruby status-vocab gate

- Order: 720-24u6
- Class: `enhancement/`
- Filed: 2026-08-13, linux_mutable, during a meta-orchestration cycle
- Trigger commit: `61125b0e` (compact 192 ledger fragments into base index)

## What happened

`tillandsias-plan compact` folded 192 fragments into `plan/index.yaml`. The fold
is text-level and byte-preserving by design (order 582-4wdi) — which is exactly
the property that made this bite. 231 event timestamps written by fragments as

```yaml
          ts: 2026-08-12T15:31:54Z      # bare scalar
```

were copied verbatim into the base. Ruby's `Psych.safe_load` resolves a bare
ISO-8601 scalar to the `Time` class, which is not in the permitted class list,
so `YAML.load_file('plan/index.yaml')` raised `Psych::DisallowedClass`. The
`./build.sh --check` step "plan/schema status-vocab divergence (440)" loads the
index with Ruby and therefore failed — with a 20-line Psych backtrace and the
verdict `plan/index.yaml and plan/schema.yaml status vocabularies diverge (440)`,
which names the wrong cause. The vocabularies were fine; the file would not load.

Every fragment involved passed its own gates: `added-fragments-parse` checked
them (yq/serde parse a bare timestamp happily), `check` passed, `set-field` and
hand-authored fragments both produce this shape. The base was Ruby-loadable
before the fold and not after, so the defect is only observable at the moment of
compaction — and compaction had run on the real ledger exactly twice before.

## Why this is a real gap, not a one-off

Three separate properties collide:

1. Fragments are validated by parsers (yq, serde_yaml) that accept bare
   timestamps. Ruby's restricted loader does not.
2. Compaction is deliberately byte-preserving, so it launders fragment text into
   the base without normalizing it.
3. The only consumer strict enough to notice is a gate that reports the failure
   as a *vocabulary divergence*, so the message points away from the cause.

A host that compacts and pushes without running the full `--check` (or that reads
the verdict line and believes it) lands an index that a Ruby consumer cannot
load.

## Immediate remediation (done this cycle)

All 231 bare `ts:` scalars in `plan/index.yaml` were quoted. `ruby -ryaml -e
"YAML.load_file('plan/index.yaml')"` now succeeds and `./build.sh --check` is
green. This is a repair of the base, not of the mechanism.

## Reduction — the smallest verifiable slices

1. **Fragment-write normalization.** `tillandsias-plan set-field` /
   `append-event` / `loop-status-append` emit `ts:` quoted. Verifiable: a fixture
   fragment written by the tool contains no bare-timestamp scalar.
2. **Fragment gate parity.** `added-fragments-parse` additionally rejects a bare
   ISO-8601 scalar, so a hand-authored fragment fails at the fragment, not three
   hosts later at the fold. Verifiable: a fixture fragment with `ts: 2026-01-01T00:00:00Z`
   fails the gate; the quoted form passes.
3. **Honest gate verdict.** The status-vocab check distinguishes "index did not
   load" from "vocabularies diverge" and says which. Verifiable: an intentionally
   unloadable index fixture produces a load-failure verdict, never a divergence
   verdict.

Slice 3 is worth doing even alone: the false verdict cost more diagnosis time
here than the defect itself.
