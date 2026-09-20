---
tags: [grep, awk, msys, git-bash, windows, crlf, carriage-return, exit-status, pipefail, false-negative, false-positive, agent-safety]
languages: [bash, awk, grep]
since: 2026-09-20
last_verified: 2026-09-20
sources:
  - https://www.gnu.org/software/gawk/manual/html_node/Records.html
  - https://www.gnu.org/software/grep/manual/grep.html
  - https://cygwin.com/cygwin-ug-net/using-textbinary.html
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: true
---
# Carriage returns are invisible to grep and awk on MSYS

@trace spec:cheatsheet-tooling

**Version baseline**: Git Bash / MSYS2 on Windows 11 26200, GNU Awk 5.4.0 (API
4.1) and GNU grep as shipped; measured on both fleet Windows hosts
(yolanda-windows and esmeraldinha) 2026-09-19/20.
**Use when**: you are about to answer "does this file have CRLF line endings?"
— especially before concluding that line endings are, or are not, the cause of
a defect.

## The trap in one line

On MSYS both `grep` and `awk` read text streams with the CR **already
stripped**, so a search for `\r` reports **zero on a file that is full of
CRs** — and the obvious workaround, `$'\r'`, can degrade to a literal `r` and
report a match on **every line of every file**. The same question answered two
ways gives two opposite wrong answers, and neither looks wrong.

## Measured

```console
$ printf 'alpha\r\n' > f
$ od -c f
0000000   a   l   p   h   a  \r  \n

$ awk '{print length($0)}' f          # the CR is not in the record at all
5
$ awk '/\r/{c++} END{print c+0}' f    # so a CR pattern matches nothing
0
$ tr -cd '\r' < f | wc -c             # the CR is right there
1
```

And the failure in the other direction, measured on a tree of 1198 plan
fragments that contain **no** CR bytes at all:

```console
$ grep -c $'\r' <one-fragment>        # text mode strips CR -> false negative
0
$ grep -rlU $'\r' plan/index.d/ | wc -l
1199                                  # more files than exist in the directory
```

`1199 of 1198` is the tell: the escape reached grep as a literal `r`, which
matches nearly every line of nearly every file. A plausible-looking number is
what makes this dangerous — `0` reads as "clean" and `1199` reads as
"catastrophically CRLF", and the tree was neither.

## The rule

**Only a byte-level reader answers this question.** Use `od -c`, `tr -cd '\r' |
wc -c`, `cmp`, or `file` (which prints `with CRLF line terminators` when it
means it). Agreement between **two** of them is the measurement; a single one
is a reading.

```bash
# CR bytes in a file — the answer, not a proxy for it
tr -cd '\r' < "$f" | wc -c

# does this file use CRLF?
file "$f" | grep -q 'CRLF' && echo crlf || echo lf
```

Do **not** write `grep -c $'\r'`, `grep -rlU $'\r'`, or `awk '/\r/'` on MSYS
and report the number. If you already did, discard it — it is not evidence in
either direction.

## Why this is not just a Windows curiosity

Line endings are a standing suspect on a Windows checkout, so this measurement
gets run precisely when someone is deciding whether CRLF explains a bug. A
false `0` closes a real CRLF cause; a false `1199` opens a fictional one and
sends the next reader to rewrite `.gitattributes`. On the run that produced
this sheet the truth was `0` — `core.autocrlf=true` was set **and** overridden
by `* text=auto eol=lf`, so the working tree was pure LF — and both grep
readings were wrong before `od` and `tr` settled it.

## The same trap in exit codes: end with the command you are reporting

The CR case is about a *search* tool. The identical shape bites when a wrapper
reports an exit status, and it cost a p1 row filed against innocent tooling
before it was measured (1296-jutd, refuted by its own experiment).

```bash
# WRONG - the compound's status is `tail`'s, which is 0 even when cmd refused
some-tool ... > log 2>&1; echo "EXIT=$?"; tail -40 log

# WRONG - a pipeline's status is its LAST element
some-tool ... | tail -6

# RIGHT - capture on the very next line, before anything else runs
some-tool ... > log 2>&1; rc=$?; tail -40 log; exit "$rc"

# RIGHT - or let the command be the last thing in the wrapper
some-tool ...
```

**A wrapper must end with the command whose status it reports, or capture `$?`
on the very next line.** Measured three ways on a script that refuses with exit
1: in the foreground it reported 1; with a trailing `echo`/`tail` it reported
0; as the sole command it reported 1 again. The tool and the harness were both
correct throughout - the wrapper discarded the status, and the discard was then
read as a defect in the channel.

The same `| tail` also makes a *running* command look hung: a pipeline into
`tail` emits nothing until it ends, so a zero-byte log is what a healthy
in-progress command looks like, not evidence of a stall.

## The class

This is the fourth instrument in one week that answered **silently wrong**, and
the class is worth more than any of the instances:

- BSD awk and `\b` - see `awk-word-boundary.md`
- BSD grep and `-R` - see `recursive-grep-symlinks.md`
- MSYS grep and awk and `\r` - this sheet, in both directions
- a trailing `echo`/`tail` or a `| tail` swallowing an exit status - above

Add to them `grep -q` inside a pipeline under `pipefail`, which inverts on
SIGPIPE, and plain `git rev-parse <missing-ref>`, which **echoes the ref name**
and errors rather than printing nothing - so a comparison against it reads
DIVERGED, meaning "it landed and disagrees", when nothing landed at all. Use
`git rev-parse --verify --quiet`.

Three of these produce a **confident wrong answer** rather than an obvious
failure, which is what makes them worth a sheet. A tool that cannot express
your question does not always say so. When a result is about to become a claim
someone else acts on, confirm it with a tool that works at a different level of
abstraction than the one that produced it.


## Provenance

Measured during the triage of **1293-krrp** (the groundtruth harness parsing
JSON-RPC by line number) on 2026-09-20, while testing whether CRLF on a Windows
checkout explained an empty projection. It did not — the cause was elsewhere —
but the CRLF measurement itself produced both a false negative and a false
positive before the byte-level readers agreed. Cross-checked on the second
Windows host: `awk '{print length($0)}'` on `alpha\r` prints `5` there too, so
this is a property of the host class, not of one machine.
