# plan/index.yaml: duplicate `events:` mapping key in the order-413 packet drops evidence / breaks strict parsers

- date: 2026-07-18
- filed_by: linux-macuahuitl-opus48 (found while YAML-validating an order-414 ledger edit)
- host: linux
- order: 416
- status: ready
- kind: bugfix (ledger integrity)
- deliverable: plan/index.yaml
- related:
  - order 413 (git-mirror-relay-fetch-before-push) — the packet holding the duplicate key
  - openspec/litmus-tests/litmus-git-mirror-yaml-gate-shape.yaml
  - plan/issues/mirror-pre-receive-openspec-yaml-reject-2026-07-12.md (the mirror's YAML gate)

## What happened

The `git-mirror-relay-fetch-before-push` packet (order 413) in `plan/index.yaml`
declares the `events:` mapping key **twice** within the same packet mapping:

```
    - packet_id: git-mirror-relay-fetch-before-push
      order: 413
      ...
      events:                 # (1) type: progress — "Implementation committed (b49b7776) ..."
        - type: progress
          ...
      outcome: >
        ...
      exit_criteria:
        - ...
      events:                 # (2) type: filed — the original observation
        - type: filed
          ...
```

A YAML mapping MUST NOT contain duplicate keys. The consequences split by parser:

- **Strict parsers reject the whole file.** `npx js-yaml plan/index.yaml`
  errors at the second `events:` (`YAMLException: bad indentation of a mapping
  entry` / duplicate key). Any tooling built on a strict loader cannot read the
  ledger at all.
- **Lenient last-wins parsers silently drop data.** Ruby Psych and PyYAML keep
  only the LAST `events:` (the `type: filed` observation) and **discard the
  `type: progress` event** — i.e. the record that 413 was *implemented*
  (commit `b49b7776`) vanishes. A reader concludes 413 is merely "filed", not
  done. Evidence loss with a success-shaped surface — the same false-signal
  failure mode as the mirror bugs this packet series is about.

## Why it matters

`plan/index.yaml` is the machine-read work ledger; `/advance-work-from-plan`
and the coordinator skills query it to decide what is done vs. claimable.
Duplicate keys make the ledger either unreadable (strict) or quietly wrong
(lenient). The mirror's own pre-receive gate validates ledger YAML on push
(mirror-pre-receive-openspec-yaml-reject-2026-07-12); depending on the
validator it either bounces valid pushes or waves through a lossy file.

## Smallest correct fix (exit criteria)

1. Merge the two `events:` sequences in the order-413 packet into a single
   `events:` list (chronological: `filed` then `progress`), so no mapping key
   repeats. No event data is lost.
2. Add a CI/litmus guard that rejects duplicate mapping keys in `plan/index.yaml`
   (and other ledger YAML) — e.g. a strict-loader parse step, or a
   `yaml.constructor` with a duplicate-key check — wired into
   `litmus:git-mirror-yaml-gate-shape` or the plan-lint path. This is the
   durable fix: it turns a silent evidence-drop into a loud CI failure.
3. `npx js-yaml plan/index.yaml` parses cleanly (proxy for "strict-valid").

## Repro

```
npx --yes js-yaml plan/index.yaml   # errors at the 2nd `events:` in packet 413
grep -n '^      events:' plan/index.yaml   # two entries between the 413 packet_id and the next packet
```

## Note

Not fixing it inline in this packet's commit on purpose: the order-413 packet is
recently-landed work from another agent (Hy3); a coordinator should reconcile
the merged event history rather than have a passer-by silently rewrite another
agent's ledger evidence. The durable value is the CI guard (exit criterion 2)
so this class cannot recur unseen.
