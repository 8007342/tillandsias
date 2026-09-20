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

## Why each method fails, and the one that looks right

Measured on BOTH Windows hosts (esmeraldinha and yolanda), same results.
`crlf.txt` is three CRLF lines; `lf.txt` is the same three lines with LF only.
The LF file is the control, and it is the whole point: without it, one method
below looks correct.

```bash
printf 'alpha\r\nbeta\r\ngamma\r\n' > crlf.txt
printf 'alpha\nbeta\ngamma\n'          > lf.txt

tr -cd '\r' < crlf.txt | wc -c    # 3   <- the truth
tr -cd '\r' < lf.txt   | wc -c    # 0   <- the truth

grep -c $'\r' crlf.txt            # 3   <- RIGHT, BY ACCIDENT
grep -c $'\r' lf.txt              # 3   <- WRONG; there are zero
grep -c '\r'  crlf.txt            # 0   <- WRONG; BRE has no \r escape
awk '/\r/{n++} END{print n+0}' crlf.txt   # 0   <- WRONG
```

**`grep -c $'\r' crlf.txt` printing the TRUE COUNT is the most dangerous line
on this page.** Anyone who tests only the positive case concludes the method
works and ships it.

**`$'\r'` degrades to an EMPTY pattern.** MSYS strips the CR out of argv, so
grep receives `""`, and an empty pattern matches every line. The two are
indistinguishable:

```bash
grep -c ''    lf.txt   # 3
grep -c $'\r' lf.txt   # 3
```

Mid-pattern too: `grep -c 'a'$'\r'` becomes `grep -c 'a'`. This is the same
stripped argv that produces the false POSITIVE above — one mechanism, two
faces: an empty pattern that matches everything, or a bare `r` that matches
nearly everything.

**A pattern file does not rescue it.** The CR is stripped when grep reads the
pattern file as well:

```bash
printf 'a\r
' > pat.txt      # od -c confirms the CR is in the file
grep -cf pat.txt crlf.txt     # 2
grep -cf pat.txt lf.txt       # 2   <- the pattern became 'a' again
```

**`'\r'` is a literal backslash-r.** POSIX BRE/ERE have no `\r` escape, so it
means "a literal r" at best — and returns `0`, which reads exactly like "this
file is clean".

**`grep -P` is not available** in this build (`grep -P '' /dev/null` fails), so
the one form where grep would expand the escape itself does not exist here.

**awk never receives the byte.** MSYS awk opens in text mode, so the CR is gone
from `$0` before any pattern runs. `/\r/`, the octal `/\r/` and
`index($0, sprintf("%c",13))` all return 0 on a file full of CRs. This is not a
regex problem.

| method | crlf.txt | lf.txt | trustworthy |
|---|---|---|---|
| `tr -cd '\r' < f \| wc -c` | 3 | 0 | **yes** |
| `od -c f` (read it) | shows `\r` | no `\r` | **yes** |
| `grep -c $'\r' f` | 3 | 3 | no |
| `grep -c '\r' f` | 0 | 0 | no |
| `awk '/\r/' f` | 0 | 0 | no |

**The rule: pass the CR as an escape the TOOL interprets, never as a raw CR
byte in argv.** `tr -cd '\r'` works precisely because `tr` expands `\r` itself,
so the byte never has to survive the command line; `od -c` works because it
reads bytes and asks nothing of a pattern.

```bash
# the one-liner worth memorising
cr=$(tr -cd '\r' < "$f" | wc -c | tr -d ' '); echo "$f: $cr CR bytes"
```

**Always include the LF control.** A method that is right on a CRLF file and
wrong on an LF file is not a method, and only the control shows it.

## grep -c prints a value AND signals failure

A sibling of the exit-code rule below, worth its own line because the usual
reflex corrupts the data rather than losing it. `grep -c` prints `0` and exits
`1` when nothing matches, so:

```bash
count=$(grep -c PATTERN f || echo 0)    # WRONG: yields "0\n0"
[ "$count" -eq 0 ]                      # -> integer expression expected
```

The `|| default` habit appends a SECOND zero. Measured on esmeraldinha
2026-09-20 inside a mutation harness that was itself testing a row about
ignored exit codes: it reported four literals as not-load-bearing while the
code under test was correct.

```bash
count=$(grep -c PATTERN f); rc=$?      # rc 1 means "no match", not "error"
[ "$rc" -le 1 ] || { echo "grep failed"; exit 2; }
```

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
- `grep -c` printing a value AND exiting 1, so `|| echo 0` yields two zeros

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


## Sibling sheet

`git-bash-cannot-fork-or-enumerate.md` covers a different MSYS hazard on the
same hosts: MSYS cannot fork `sh` at the push script's depth, so git's
`!`-helper never runs and the push goes anonymous; and an inline `wsl.exe`
string that loses a variable makes `find` enumerate the repo root (59 where
the truth was 795). Different mechanism, same lesson about what the shell
layer does to a command before the tool sees it.

## Provenance

Measured during the triage of **1293-krrp** (the groundtruth harness parsing
JSON-RPC by line number) on 2026-09-20, while testing whether CRLF on a Windows
checkout explained an empty projection. It did not — the cause was elsewhere —
but the CRLF measurement itself produced both a false negative and a false
positive before the byte-level readers agreed. Cross-checked on the second
Windows host: `awk '{print length($0)}'` on `alpha\r` prints `5` there too, so
this is a property of the host class, not of one machine.

FOLDED 2026-09-20 from esmeraldinha's `msys-grep-cannot-count-carriage-returns.md`,
which is deleted in the same commit so one hazard has one sheet. The method table,
the empty-pattern and pattern-file proofs, the missing `grep -P`, the
right-by-accident coincidence and the `grep -c` exit-code twist are esme's
measurements on esmeraldinha; the exit-status half, the `grep -rlU` false positive
and the class are yolanda's. Both hosts measured `length($0)` of `alpha\r` as 5.

That folded sheet carried a section calling the awk arm an OPEN DISAGREEMENT between
the two hosts. It is closed and there was never a difference: the claim that awk
agreed with od and tr was mine, written before I had measured my own awk, retracted
the same cycle, and it reached esme as a stale relay. The refutation rests on TWO
instruments, od -c and tr -cd, and never on three.
