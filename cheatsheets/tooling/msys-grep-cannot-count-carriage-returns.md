---
tags: [grep, awk, carriage-return, crlf, msys, windows, false-negative, false-positive, agent-safety]
languages: [bash, grep, awk]
since: 2026-09-20
last_verified: 2026-09-20
sources:
  - https://www.gnu.org/software/grep/manual/grep.html
  - https://www.gnu.org/software/gawk/manual/html_node/Records.html
  - https://www.cygwin.com/cygwin-ug-net/using-textbinary.html
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: true
---
# Counting carriage returns on MSYS

@trace spec:cheatsheet-tooling

**Version baseline**: GNU grep 3.0 and GNU Awk 5.4.0 under
`MINGW64_NT-10.0-26200` (Git Bash) on esmeraldinha, Windows 11.
**Use when**: you are about to report how many CRs are in a file — or that
there are none — on a Windows host. Especially when the answer decides whether
a line-ending problem exists.

## The trap in one line

On MSYS, **`grep` cannot be made to match a carriage return and `awk` cannot
see one**. Both return a number. Neither number is the count of CRs, and one of
the wrong answers is *the right answer by coincidence* on exactly the files you
would test with.

## Minimal reproduction

Measured on esmeraldinha 2026-09-20. `crlf.txt` is three CRLF lines,
`lf.txt` is the same three lines with LF only:

```bash
printf 'alpha\r\nbeta\r\ngamma\r\n' > crlf.txt
printf 'alpha\nbeta\ngamma\n'       > lf.txt

tr -cd '\r' < crlf.txt | wc -c     # 3   <- the truth
tr -cd '\r' < lf.txt   | wc -c     # 0   <- the truth

grep -c $'\r' crlf.txt             # 3   <- RIGHT, BY ACCIDENT
grep -c $'\r' lf.txt               # 3   <- WRONG; there are zero
grep -c '\r'  crlf.txt             # 0   <- WRONG; BRE has no \r escape
awk '/\r/{n++} END{print n+0}' crlf.txt   # 0   <- WRONG
```

`grep -c $'\r' crlf.txt` printing `3` is the dangerous result: it matches the
true count, so a check that tests only a CRLF file concludes the method works.

## Why each one fails

**`$'\r'` degrades to an EMPTY pattern.** MSYS strips the CR byte out of the
command-line argument, so grep receives `""`, and an empty pattern matches every
line. Proof — the two are indistinguishable:

```bash
grep -c ''     lf.txt   # 3
grep -c $'\r'  lf.txt   # 3
```

The same happens mid-pattern: `grep -c 'a'$'\r'` becomes `grep -c 'a'` and
returns 3 on **both** files.

**A pattern file does not rescue it.** The CR is stripped when grep reads the
pattern file too:

```bash
printf 'a\r\n' > pat.txt     # od -c confirms: a \r \n
grep -cf pat.txt crlf.txt    # 2
grep -cf pat.txt lf.txt      # 2   <- pattern became 'a' again
```

**`'\r'` is a literal backslash-r.** POSIX BRE/ERE have no `\r` escape, so the
pattern means "a literal `r`" at best and matches nothing here — hence `0`,
which reads exactly like "this file is clean".

**`grep -P` is not available.** This build has no PCRE support
(`grep -P '' /dev/null` fails), so the one form where grep would interpret the
escape itself is missing.

**`awk` strips the CR before your pattern ever runs.** MSYS awk opens files in
text mode, so the CR is gone from `$0`. Measured — `alpha\r` should be 6
characters:

```bash
awk '{print NR": len="length($0)}' crlf.txt
# 1: len=5      <- the CR is not there
```

Consequently `/\r/`, the octal `/\015/`, and even
`index($0, sprintf("%c",13))` all return `0` on a file full of CRs. This is not
a regex problem; awk is not being shown the byte.

## What to use instead

| method | crlf.txt | lf.txt | trustworthy |
|---|---|---|---|
| `tr -cd '\r' < f \| wc -c` | 3 | 0 | **yes** |
| `od -c f` (read it) | shows `\r` | no `\r` | **yes** |
| `grep -c $'\r' f` | 3 | 3 | no |
| `grep -c '\r' f` | 0 | 0 | no |
| `awk '/\r/' f` | 0 | 0 | no |

**The rule: pass the CR as an escape the TOOL interprets, never as a raw CR
byte in argv.** `tr -cd '\r'` works precisely because `tr` expands `\r` itself —
the byte never has to survive the command line. `od -c` works because it reads
bytes and asks nothing of a pattern.

```bash
# the one-liner worth memorising
cr=$(tr -cd '\r' < "$f" | wc -c | tr -d ' '); echo "$f: $cr CR bytes"
```

## The platform split

| host class | grep `$'\r'` | awk sees CR |
|---|---|---|
| Linux (yoga, lenovinha, macuahuitl, pirria) | matches real CRs | yes |
| Windows / MSYS (esmeraldinha, yolanda) | empty pattern, matches everything | **no** |

A CR check written and tested on a Linux host is correct there and silently
wrong on both Windows hosts — and the Windows host is the one where CRLF
actually happens, so the check is broken exactly where it is needed.

## A DISAGREEMENT THIS SHEET DOES NOT RESOLVE

The finding that prompted this sheet was yolanda's, relayed to this host by the
coordinator, and the relayed version says an `awk /\r/` scan is one of the
methods that **agree** with the truth. **On esmeraldinha it does not** — awk
returns 0 on a file with three CRs, and `length($0)` proves awk never receives
the byte. Both hosts are Windows/MSYS.

Do not treat either reading as the fleet's answer yet. The likely explanation is
different awk builds or a different text/binary mount mode between the two
checkouts, and that is a measurement nobody has taken. **The two trustworthy
methods above are trustworthy on this host by direct measurement, and the
`tr`/`od` pair is the safe recommendation on either reading** — which is why the
rule is stated in terms of those and not in terms of which scanner to trust.

## Sibling traps

[awk-word-boundary.md](awk-word-boundary.md) — `\b` is a GNU extension that BSD
awk silently ignores. [recursive-grep-symlinks.md](recursive-grep-symlinks.md) —
`grep -r` does not follow symlinked directories and exits 0. Same family, third
instance: **a search tool that reports success while seeing nothing, on the
platform running the search.** Here the family gains a new member — a tool that
reports success while seeing *everything*, which is worse, because `3` looks
like an answer and `0` at least looks like an absence.

## Provenance

Original finding: yolanda (Windows), 2026-09-20, recorded on order 1293-krrp.
Every number in the reproduction, the platform table and the "why each one
fails" section was **re-measured independently on esmeraldinha** on 2026-09-20
with the scripts staged as files, not relayed — including the pattern-file arm
and the `length($0)` proof, which are this host's additions. The awk
disagreement with the relayed account is recorded above rather than reconciled,
because reconciling it would need yolanda's exact awk version and mount mode.
Written at the coordinator's request.
