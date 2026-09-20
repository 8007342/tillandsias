---
tags: [agent-safety, destructive-actions, cli-design, dry-run, fail-loud, plan-ledger]
languages: [bash]
since: 2026-09-20
last_verified: 2026-09-20
sources:
  - https://pubs.opengroup.org/onlinepubs/9799919799/basedefs/V1_chap12.html
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: true
---
# The rule you already wrote does not fire when the thing you are asking about is the tool rather than the data

@trace spec:cheatsheet-tooling

**A tool that writes by default cannot be used to ask whether a flag exists.**
Running it to find out IS the write. The command may even answer correctly —
that is what makes this different from a command that fails silently. You get
the right answer and the side effect, and from the inside the two are one
action.

## The specimen

2026-09-20, yoga, `tillandsias-plan`. I wanted to know whether `set-field`
supported `--value-file`, so I ran it:

```bash
tillandsias-plan set-field <order> verifiable_closure \
    --value-file /dev/null --append --host yoga --evidence x --reason probe
```

It does support it. It also wrote a real ledger fragment appending an empty
dated attribution line to a live row, carrying the throwaway `--evidence x` and
`--reason probe` I had passed only to satisfy the required flags. The fragment
was untracked, never committed, never pushed, and was deleted — nothing reached
origin. The answer to my question was correct and the row was changed anyway.

## Why the existing rule did not catch it

The project's own notes already said, in these words, **never use `set-field` as
a read** — there is no dry-run, and echoing a field "to see what is there"
writes it. That rule is about the DATA: don't ask what a row contains by
writing to it.

This was a read of the **interface**. "Does this flag exist?" is not a question
about the row, so the rule never came to mind, and the flags I had to invent to
make the command well-formed (`--evidence x`, `--reason probe`) went into a live
record as if they meant something.

A rule scoped to the data leaves the tool itself uncovered, and the tool is
exactly what you interrogate when you are new to it or coming back to it.

## What to do instead

| Question | Ask it this way |
|---|---|
| Does this subcommand exist? | `<tool> capabilities` — the set is compiled in, so it describes the binary you are holding |
| Does this flag exist? | the usage text on stdout from the bare subcommand (`tillandsias-plan set-field`) |
| What does this field contain? | `query --json` or `yaml-get`, never the setter |
| Will this write do what I think? | run it against a scratch copy of the ledger (`--index <copy>`) first |

## The tell, and the cheapest guard

The tell is that **"I checked" and "I changed" were the same command and
produced the same `ok:` line**. If you cannot name a distinct thing you would
have run had you only wanted to look, you are not looking.

The guard that would have stopped this is not "check before you write" — that is
advice nobody disagrees with and it did not stop someone who had literally
written the neighbouring rule. It is narrower and it is mechanical: **if a
command requires you to invent argument values in order to run it, you are not
probing it, you are using it.** `--evidence x` and `--reason probe` were the
warning, one line before the write.

## Related

- `exit-status-is-not-an-answer.md` — the adjacent defect, and not the same one.
  There the status lies about the outcome. Here the answer was right; the cost
  was that obtaining it was an action.
