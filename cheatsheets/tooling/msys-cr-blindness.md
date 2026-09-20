---
tags: [grep, awk, msys, git-bash, windows, crlf, carriage-return, false-negative, false-positive, agent-safety]
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

## The class

This is the third instrument in one week that answered **silently wrong on one
platform**, and the class is worth more than the three instances:

- BSD awk and `\b` — see `awk-word-boundary.md`
- BSD grep and `-R` — see `recursive-grep-symlinks.md`
- MSYS grep and awk and `\r` — this sheet

A search tool that cannot express your question does not always say so. When a
search result is about to become a claim someone else acts on, confirm it with
a tool that works at a different level of abstraction than the one that
produced it.

## Provenance

Measured during the triage of **1293-krrp** (the groundtruth harness parsing
JSON-RPC by line number) on 2026-09-20, while testing whether CRLF on a Windows
checkout explained an empty projection. It did not — the cause was elsewhere —
but the CRLF measurement itself produced both a false negative and a false
positive before the byte-level readers agreed. Cross-checked on the second
Windows host: `awk '{print length($0)}'` on `alpha\r` prints `5` there too, so
this is a property of the host class, not of one machine.
