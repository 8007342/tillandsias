---
tags: [testing, fixtures, litmus, false-positive, agent-safety, fail-loud, guard-cannot-fail, mention-vs-use]
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

## The other half: a file that talks ABOUT tests is read as a file that claims them

The page so far is about a test nothing runs. This is its mirror: **a mention
read as a use.** A scanner asking "does this file reference test X?" cannot
tell an invocation from a sentence, and neither can a fixture asking "does the
source contain string Y?" Both answer a question about TEXT and report it as a
question about BEHAVIOUR.

Four specimens, all on this fleet, three of them on 2026-09-21 alone:

| Specimen | What it counted | What it reported |
|---|---|---|
| the reset-flag litmus arm, order 1286-4437 | 12 **mentions** of `--reset-state` in the tree | 7/7 green — on a tree whose binary refused the flag, so the release shipped uninstallable |
| the step-enforcement census, order 1329-m8dk | `assert_exit` as a **substring** anywhere in a step block | two steps ENFORCED whose only match was a COMMENT discussing enforcement |
| a fixture's throwaway names, order 1325-ygq5 | five synthetic `litmus:…` names written as literals | `check-litmus-pin-claims.sh` read them as that file's own broken claims — five refusals in a ci-release suite |
| `census-litmus-reachability.sh`, order 1333-jpq5 | two grandfathered-unbound tests named in its header | the same scanner refused the file — whose entire purpose is to REPORT unbound tests |

The last one is the shape at its purest: the file was refused for doing its
job, by a guard that was right to refuse it. Its author had already dodged this
exact trap in the fixture two rows earlier and still walked into it, because
the first dodge was remembered as a fixture trick rather than as a property of
every file that discusses a test by name.

**The second specimen is the load-bearing one**, because it changed a number
two hosts were arguing about. Under a substring reading the census read
42 unenforced-long / 2,166 other; under a key-anchored reading, 43 / 2,167. The
whole disagreement was two comments — prose ABOUT enforcement counted AS
enforcement — and the hosts reconciled exactly once the rule was written down as
`^[[:space:]]*<name>:`, a KEY, never a substring.

### What to do

**Writing a file that names tests:** assemble the prefix so no scanner sees a
token you did not mean as a claim.

```bash
L="lit""mus"            # in shell; the scanner greps for the joined literal
printf 'name: %s:orphan-shape\n' "$L"
```

In Markdown, name them freely — `check-litmus-pin-claims.sh` scans `*.sh` and
`*.c` only, which is why this page can print them and that script could not.

**Writing a scanner or a fixture:** match as a KEY, anchored, never as a
substring — and say in one line what you are entitled to conclude.

```bash
grep -qE '^[[:space:]]*assert_exit:'  "$f"   # a key: this step asserts
grep -qF  'assert_exit'               "$f"   # a mention: someone wrote the word
```

**The test of whether you have this right:** can your check distinguish a file
that USES the thing from a file that DISCUSSES it? If not, you are counting
prose, and prose about a guard is the one text most likely to appear in files
that have no guard at all — because that is what people write while fixing the
absence.

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

The mention-versus-use section was added 2026-09-21 by pirria, from four
specimens: the reset-flag arm that counted mentions and let an uninstallable
release ship (1286-4437); the substring-versus-key census reading that was the
entire disagreement between two hosts' counts (1329-m8dk, on yoga's rule); a
fixture whose five throwaway names were read as its own claims (1325-ygq5); and
`census-litmus-reachability.sh`, refused by that same scanner for naming the
unbound tests it exists to report (1333-jpq5). The last three happened on one
day, to one host, who had already dodged the trap once — which is the argument
for the page rather than a row.
