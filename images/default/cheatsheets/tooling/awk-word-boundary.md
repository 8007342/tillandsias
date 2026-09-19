---
tags: [awk, regex, word-boundary, bsd, macos, false-negative, agent-safety]
languages: [bash, awk]
since: 2026-09-19
last_verified: 2026-09-19
sources:
  - https://pubs.opengroup.org/onlinepubs/9799919799/utilities/awk.html
  - https://www.gnu.org/software/gawk/manual/html_node/GNU-Regexp-Operators.html
  - https://man.freebsd.org/cgi/man.cgi?query=awk
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: true
---
# `\b` in awk patterns

@trace spec:cheatsheet-tooling

**Version baseline**: BSD awk (`awk version 20200816`, `PROGRAM:awk PROJECT:awk-40`)
on macOS 27.0 arm64; GNU awk on the Linux hosts.
**Use when**: an `awk` search came back empty and you are about to report the
absence — especially as a claim about code structure someone else can see.

## The trap in one line

`\b` is a **GNU extension**. POSIX awk has no word-boundary assertion, so BSD
awk does **not error** on `/foo\b/` — it quietly matches **nothing**. An empty
result from a broken pattern and an empty result from a genuinely absent string
print the same bytes and the same exit status. There is no stderr to read.

## Minimal reproduction

Measured on macneo (Tlatoanis-MacBook-Neo), 2026-09-19:

```bash
echo "if foo" | awk '/^if\b/{print "MATCHED"}'            # -> no output
echo "if foo" | awk '/^if[[:space:]]/{print "MATCHED"}'   # -> MATCHED
```

## The platform split

| host class | awk | `\b` behaviour |
|---|---|---|
| Linux (yoga, lenovinha, macuahuitl, pirria) | GNU awk | honoured as a word boundary — patterns work |
| macOS (macneo, macbookair) | BSD awk `awk-40` | silently matches nothing, exit 0 |

This asymmetry is the dangerous part. A pattern written and tested on a Linux
host works there and fails **silently** on both Macs, and it is the Mac that
then reports the absence as a fact.

## The rule

1. **Never use `\b` in an awk pattern on this fleet.** Use `[[:space:]]`,
   `[[:punct:]]`, an explicit character class, or anchor the match.
   `/^(if|case|while|for)[[:space:][]/` is the shape that works everywhere.
2. **Run a positive control before reporting any awk-reported absence.** Give
   the pattern a line you KNOW matches, in the same file, and confirm it is
   found. An empty awk result is not evidence until the pattern has been shown
   to work on that input.

## What it cost, and how it was caught

While tracing which block of `build.sh` encloses the plan-archiver step for
order 1132-r4mt, macneo ran:

```bash
awk 'NR<=3138 && /^(if|case|while|for)\b/ {print NR": "$0}' build.sh   # -> nothing
```

and reported "no column-0 `if`/`case`/`while` encloses it; cause untraced".
macuahuitl, on Fedora, found the line immediately:

```
build.sh:1651  if [[ "$FLAG_CHECK" == true ]]; then
```

Re-run on macneo with a POSIX class, the same file yields `1442`, `1565`,
`1651`. The line had been there the whole time.

Two agents therefore held contradictory readings of one file, and the macOS
side had reported a **broken search as a positive claim about the codebase's
structure**. It was resolvable only because that claim had been stated as a
failed search rather than as a fact — the same discipline that caught the
sibling trap.

The same investigation came within one step of the opposite error: an earlier
awk reported `_prepare_ci_full_install_inputs` as the enclosing scope, which
would have inverted the other host's observation. It was caught by checking the
function's brace balance — it closes ~1800 lines before the step.

## Sibling trap

[recursive-grep-symlinks.md](recursive-grep-symlinks.md) — `grep -r` does not
descend into symlinked directories and exits 0, so a broken search and a clean
tree are indistinguishable. Same failure class, different tool, one week apart:
**a search that reports success while seeing nothing, on the platform running
the search.** When a search tool returns empty on one platform and not another,
suspect the tool before the tree.

## Provenance

Found on macneo 2026-09-19 during order 1132-r4mt, from the disagreement
between macneo's and macuahuitl-fedora's readings of `build.sh`. Recorded at
the coordinator's request. Both readings, and the retraction that followed, are
on that row's events.
