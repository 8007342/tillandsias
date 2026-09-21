---
tags: [testing, fixtures, litmus, false-positive, agent-safety, fail-loud, guard-cannot-fail]
languages: [bash, yaml]
since: 2026-09-21
last_verified: 2026-09-21
sources:
  - https://en.wikipedia.org/wiki/Mutation_testing
  - https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: true
---
# A test is not done until something that runs on its own can fail because of it

@trace spec:cheatsheet-tooling

**Writing the assertion is the easy half.** The hard half is that something
which runs WITHOUT YOU, on a host you are not watching, must be able to go red
because of it. Those are independent facts, and verifying the first feels
exactly like verifying both — which is why this is filed by SHAPE rather than
by organ. It is not a YAML problem or a shell problem; it is the same mistake
wearing whichever costume the day supplies.

Three specimens, all measured on this fleet on 2026-09-20, all by people who
were at that moment writing or reviewing guards about this very failure:

| Specimen | The assertion | Why it proved nothing |
|---|---|---|
| a shell fixture, order 1303-2d5g | correct, green, with a working mutation arm | **nothing invoked it** — no litmus named it, `build.sh` did not call it, and no gate checks that a new `test-*.sh` is wired |
| a fixture arm, order 1304-wbb2 | arm 2 scored green on every run | the check it mutated was **gated behind a binary the fixture tree does not have**, so it never ran and the mutated copy behaved identically |
| a litmus YAML, order 1286-4437 | seven commands, hand-run, all passing | **never bound** in `litmus-bindings.yaml`; the suite reported 37 PASS / 3 FAIL and the test was in neither number |

The third host then wrote a shell fixture **the same day** and did not wire it
either — because the lesson had been stored against *litmus YAML*, and this
was a `.sh`. Storing the lesson against the organ is how you pay for it twice.

## The rule

**Do not report a test as done on the strength of its own output.** Report it
on the strength of a run you did not arrange. Concretely, in order:

1. **Make it fail on purpose.** Break the subject — not the message, the
   *condition* — and watch the test go red. An arm that reds because your
   mutation broke the file's syntax has told you nothing.
2. **Find the thing that will run it when you are asleep.** A litmus that
   names it, a gate step, a CI job. If you cannot name that thing, the test is
   an orphan however green it is.
3. **Watch it be run BY that thing.** For a litmus, the string to look for is
   `Executing litmus:<name>` in a real spec run — not `PASS`, which a suite
   prints happily while never reaching your file.
4. **Check the test could reach its subject at all.** Fixture trees are
   smaller than the repo: a check gated on a binary, a git base ref, or a file
   the fixture does not create is silently skipped, and a skipped check makes
   every arm above it meaningless.

## The tell

**Two verdicts that cannot both be true.** A skipped run and a passing run
both exit 0; a suite that never reached your file still prints a pass rate. So
look for the contradiction rather than the verdict:

```bash
rc=0      beside   skip:…            # it did not run
rc=0      beside   blocked:/refused: # the instrument contradicts itself
PASS      beside   0 mentions of your test's name
4 arms    beside   a mutation that changed nothing
```

On this fleet the same shape produced, in one day: a fixture that reported
`skip:no-yaml-reader-on-PATH` three times while its author read `rc=0` as
success; a litmus step green for **three months** because its adjudication
ignored the exit code; and a reconciliation fixture red-and-silent because a
timeout killed it with 5/5 assertions passing.

## Why writing it is not enough

The three specimens are not carelessness. Each test was **correct**, each
author **competent**, and two of them were actively working on rows about
guards that cannot fail. What defeats care is that the missing step is
*invisible from where the author stands*: your terminal shows the fixture
passing, and nothing in that view reports whether anything else will ever call
it. Care does not close a gap you cannot see — a checklist or a decider does.

**Order 1325-ygq5 is the mechanical half**: a diff-scoped decider that refuses
a newly added `test-*.sh` nothing invokes, the way `check-litmus-bindings.sh`
(660-ryhn) already refuses an unbound litmus. This page is the human half, and
it is here because a decider lands on new work while a habit reaches the work
that predates it.

## Related

[exit-status-is-not-an-answer.md](exit-status-is-not-an-answer.md) — the same
disease at the level of one command: exiting zero is not answering.
[a-write-cannot-ask-a-question.md](a-write-cannot-ask-a-question.md) — an
instrument that changes the thing it measures.
[git-bash-cannot-fork-or-enumerate.md](git-bash-cannot-fork-or-enumerate.md) —
a platform that makes a check silently not run.

## Provenance

Filed from three specimens on 2026-09-20: esmeraldinha's orphan fixture
(1303-2d5g) and gated arm (1304-wbb2), and pirria's unbound litmus (1286-4437)
followed by their unwired shell fixture the same day. The second specimen was
caught by the fixture it lived in, within minutes of being written; the first
was caught in review by macuahuitl before it landed; the third by its author
running the full suite and finding their test in neither the pass count nor
the fail count. Written at the coordinator's request as the human half of
1325-ygq5.
