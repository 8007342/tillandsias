# Implementation: portable building-block primitives for litmus `command:` fields — 2026-07-06

- class: enhancement (depends on research)
- filed: 2026-07-06
- owner: any
- status: ready
- depends_on: litmus-command-portability-dsl-research (must land its design
  decision + working prototype first — do not start this packet from an
  unresolved research doc)
- trace: plan/issues/litmus-command-portability-dsl-research-2026-07-06.md,
  plan/issues/litmus-runner-command-backslash-escaping-2026-07-06.md

## Outcome

Implement the mechanism the research packet designs: a small library of
named, portable primitives (e.g. `match_literal`, `match_regex_escaped`,
`count_matches_at_least`, `for_each_file_require`, `collect_lines_null_delim`)
that `scripts/run-litmus-test.sh` resolves per-host, so litmus `command:`
authors write meaningful, stable text instead of hand-computing multi-layer
backslash escaping for GNU-vs-BSD `grep`/`awk`/bash-3.2-vs-4+ dialect
differences.

## Work

1. Land the primitive library (shape decided by research — most likely a
   sourced `scripts/litmus-stdlib.sh` with per-host branching internal to
   each function, per the research packet's recommendation) with its own
   unit coverage (each primitive tested standalone on this host, plus a
   litmus self-test analogous to `litmus:litmus-runner-backslash-escaping-shape`
   pinning that the resolution mechanism itself doesn't regress).
2. Wire `scripts/run-litmus-test.sh`'s command execution to source/resolve
   the library before running each step's `command:`.
3. Convert the specific files this cycle's fixes touched as the first real
   migration batch (concrete, motivated, already-understood examples — not
   speculative): `litmus-forge-environment-discoverability-install-shape.yaml`
   (`\\|` bracket-workaround), `litmus-forge-opencode-onboarding-bootstrap-shape.yaml`
   (`\\[` bracket-workaround), `litmus-zen-default-with-ollama-shape.yaml`'s
   rollback `command:` (`\\$` bracket-workaround), and
   `litmus-versioning-shape.yaml` (the `wc -c` BSD-padding fix) — each of
   these currently carries either a raw dialect-sensitive workaround or a
   comment explaining a manual escape derivation; converting them to the new
   primitives is the proof that the mechanism actually removes the pain it's
   meant to remove, not just adds a second way to write the same bug.
4. Write the authoring guide (where do new litmus files live in relation to
   the stdlib; when to use a primitive vs. an escape-hatch raw `command:`;
   how to add a new primitive if the library is missing one) — likely a new
   `cheatsheets/` entry per the project's documentation-policy convention
   (`CLAUDE.md`: durable process claims live in `cheatsheets/` with
   provenance, not ad hoc).
5. Add the "no new raw dialect-sensitive escape" drift-protection litmus (the
   research packet's migration-strategy recommendation, option c) so a future
   `command:` reintroducing e.g. `\\|`/`\\[` without the primitive form fails
   the suite instead of silently landing.

## Exit Criteria

- `scripts/run-litmus-test.sh --phase pre-build --size instant` (or broader)
  is green on both a Linux host and a macOS host after the migration batch
  lands, with no new failures introduced by the stdlib wiring itself.
- The 4 files in step 3 above no longer contain a hand-derived
  backslash-escape workaround comment; they use named primitives instead,
  and produce byte-identical runtime behavior to what they did before
  conversion (same PASS/FAIL verdict, same matched content).
- `./build.sh --check` passes on macOS (this repo's now-working
  first-ever-green baseline from order 201 — don't regress it).
- A litmus test pins that the stdlib resolution mechanism itself doesn't
  silently regress (mirrors `litmus:litmus-runner-backslash-escaping-shape`'s
  role for order 201).
- An authoring guide exists and is linked from wherever new litmus files are
  documented (methodology/ or a new cheatsheet).

## Explicitly out of scope for this packet

- Migrating all ~90 litmus files in one pass — this packet proves the
  mechanism on a small, already-understood batch; broader migration is
  follow-on work once the pattern is validated in practice.
- Any change to the actual product code the litmus files check — this is
  pure test/tooling infrastructure.
