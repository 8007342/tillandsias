---
tags: [grep, ugrep, symlinks, recursive-search, false-negative, agent-safety]
languages: [bash]
since: 2026-09-18
last_verified: 2026-09-18
sources:
  - https://pubs.opengroup.org/onlinepubs/9799919799/utilities/grep.html
  - https://www.gnu.org/software/grep/manual/grep.html
  - https://ugrep.com/
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: true
---
# Recursive grep and symlinked directories

@trace spec:cheatsheet-tooling

**Version baseline**: ugrep 7.8.4 (the fleet's `grep`), GNU grep 3.12 (`/usr/bin/grep`)
**Use when**: you are about to assert a UNIVERSAL NEGATIVE ("nothing in this tree
calls X") from a recursive search, or a scoped search of an alias directory came
back empty.

## The trap in one line

`-r` does **not** descend into a symlinked subdirectory, finds nothing, and exits
**exactly as a genuinely clean tree does**. A broken search and a true negative
print the same bytes and the same exit code. There is no stderr to read.

## Quick reference

| You typed | Symlinked **subdirectory** met during the walk | Symlink **named as the argument** |
|---|---|---|
| `grep -r PAT dir/` | **skipped, silently** | followed |
| `grep -R PAT dir/` | followed | followed |
| `grep -r PAT link/` | n/a | followed |

Measured on pirria-silverblue 2026-09-18, **identical for ugrep 7.8.4 and GNU
grep 3.12**. Both follow a symlink given on the command line under plain `-r`;
neither descends into one found during the walk.

## Two controls, and the contaminated one is the DANGEROUS case

Confirmed on macuahuitl 2026-09-18, independently of the pirria run below.
**Which probe word you pick decides which failure you see**, and the obvious
choice gives you the worse one while looking milder:

| control | probe word | grep | `-r` | `-R` |
|---|---|---|---|---|
| **pure** — word exists ONLY under a symlinked skills dir | `checkpoint` | ugrep 7.8.4 | exit 1, **0 hits** | exit 0, 2 hits |
| **pure** | `checkpoint` | GNU grep 3.12 | exit 1, **0 hits** | exit 0, 2 hits |
| **contaminated** — word ALSO lives in a real dir on the search path | `openspec` | GNU grep 3.12 | **exit 0, 11 hits** | exit 0, **16 hits** |

The contaminated row is the one that bites. `-r` exits **0**, prints eleven
hits, and silently omits five. A green status and a non-empty result set is
what "it worked" looks like to every reader and every script. The pure case at
least returns nothing, which someone eventually questions.

**So when you probe for this defect, choose a word that exists ONLY behind the
symlink.** A word that also lives in a real directory on the same path proves
nothing — you will measure the contaminated regime and read it as health. Order
1238-u84w's original evidence ("0 hits, exit 0") came from a contaminated
control and was relayed fleet-wide overnight as the milder finding; it was
actually a demonstration of the worse one.

**And do not `readlink -f` the bare name `grep` to find out what it is.** On
these hosts `grep` is a shell FUNCTION, so `readlink -f grep` manufactures a
path to a file that does not exist and invites you to report a phantom shim.
Use `type grep`.

## This is not a ugrep quirk — correcting the record

Order 1238-u84w was filed as "`grep -r` on this fleet is ugrep and does NOT
descend into symlinked directories", with the implication that a host carrying
real GNU grep needs no change. **That implication is false.** The `-r` / `-R`
split is the POSIX-described behaviour and GNU grep 3.12 reproduces it byte for
byte on the same fixture, in the same minute, on the same host:

```
$ /usr/bin/grep -rln NEEDLE top/   # top/linked -> ../real, real/f.txt has NEEDLE
$ echo $?
1
$ /usr/bin/grep -Rln NEEDLE top/
top/linked/f.txt
```

Consequence for a fleet survey: **`grep` identity does not partition the hosts.**
Polling every host for its `grep` is not the way to close this — the remedy has
to be identity-independent, because every implementation behaves this way.

Second correction: the packet records **exit 0** on macuahuitl and macbookair.
On pirria the failing search exits **1** (`no match`), for both implementations.
Exit 1 is still the false negative — it is precisely the "absent" answer — but it
is not exit 0, so the packet's stated evidence does not reproduce here. If exit 0
was really observed, something else was in play (`-s`, a pipeline, a wrapper
swallowing the status) and it is worth a separate look.

## The remedy this fleet chose (2026-09-18, order 1238-u84w)

**Change the tree, at the directory level.** `-r` follows a symlink *named on the
command line* but never one it meets during the walk, so an alias tree made of
one symlink **per skill** is invisible, while an alias tree that **is** one
symlink is fully searched:

```
before: .gemini/skills/advance-work-from-plan -> ../../skills/advance-work-from-plan   (16 per tool)
after:  .gemini/skills -> ../skills                                                    (1 per tool)
```

**Verified live, not assumed**: a fresh `claude -p` in a tree with
`.claude/skills -> ../skills` listed all 16 project skills, so collapsing the
per-skill links does not cost skill discovery.

### Only `.gemini/` could take it — and it LANDED. Read this before you "finish the job".

The five alias trees are **not** pure alias trees, and finding that out cost a
`git reset` here. Four of them carry **real, non-symlink content** mixed in with
the links:

| tree | symlinks to `skills/` | real `openspec-*` skill dirs |
|---|---|---|
| `.gemini/skills` | 16 | **0** — converted |
| `.claude/skills` | 16 | **11** — blocked |
| `.codex/skills` | 16 | **11** — blocked |
| `.github/skills` | 16 | **11** — blocked |
| `.opencode/skills` | 16 | **11** — blocked |

`rm -rf .claude/skills && ln -s ../skills .claude/skills` therefore **deletes 11
real skills**. It looks like it is removing symlinks. It is not. The guard that
catches this, run against the staged deletions before you commit:

```bash
git diff --cached --name-status | awk '$1=="D"{print $2}' | while read -r p; do
  [ "$(git ls-tree HEAD -- "$p" | awk '{print $1}')" = 120000 ] || echo "REAL-CONTENT-DELETED: $p"
done
```

Those 44 files are **generated, per-tool, and already three different versions**
— `.claude` carries openspec `generatedBy: 1.11.0`, `.codex` and `.github` a
stale `1.3.1`, `.opencode` a third variant, and the frontmatter differs by tool
(`allowed-tools: Bash(openspec:*)` for Claude, `/opsx:apply` naming for codex).
They are not accidental drift and they cannot be collapsed into one `skills/`
copy without deciding which variant wins and how openspec regenerates them.
That decision is **not** part of this order. `.gemini/` has **zero** openspec
skills at all, which is its own gap.

### Remedies rejected, with the measurement that killed each

- **"Make the wrapper pass `-R`"** — not ours. `grep` is a shell *function*
  injected by Claude Code that execs `$CLAUDE_CODE_EXECPATH` with `ARGV0=ugrep`.
  Measured: a committed `.ugrep` config is **not** honoured under that argv0
  (ugrep auto-loads `.ugrep` only for the `ug` command), so there is no in-repo
  hook on the tool at all.
- **"Warn on stderr"** — ugrep 7.8.4 offers no such option. Nothing to enable.
- **"Replace the symlinks with real files"** — five real copies of every skill.
  Git does not preserve hardlinks across clone, so the copies diverge silently
  per host. This is not hypothetical: it is exactly what the 44 `openspec-*`
  files above already did.
- **"Remember `-R`"** — a habit, unenforceable, and `-R` is not portable to
  every `grep` an agent may meet.

## Still-symlinked paths, and why they are fine

```
GEMINI.md -> AGENTS.md    CODEX.md -> AGENTS.md    .github/copilot-instructions.md -> ../AGENTS.md
```

These are symlinks to a **file**, never traversed by a directory walk, and their
real target `AGENTS.md` sits at the repo root where any `grep -r .` reaches it.
Naming one directly (`grep PAT GEMINI.md`) opens it normally.

## A confident zero: the walk is short, or the population is short

**A search over a population that cannot contain the answer returns zero, and
zero reads as absence.** (yoga-silverblue, 2026-09-18, after getting one wrong.)

Everything else on this page is one instance of that. There are two ways the
thing you searched fails to be the thing you meant to search, and they produce
an identical artifact — a clean, confident, exit-0 nothing:

| | what goes short | example |
|---|---|---|
| **the WALK** | `-r` skips a symlinked directory it meets | `grep -rln PAT .claude/skills/` |
| **the POPULATION** | a hand-picked path list omits a tree | `grep -rln PAT scripts/ build.sh` |

Neither announces what it did not look at.

**THE WORKED EXAMPLE, with a real wrong answer in it.** On 2026-09-18 a host
reported that `scripts/check-skill-canonicalization.sh` was an orphan guard —
"referenced by `build.sh` zero times, appears only in `check-bash-dialect.sh`
and its own test" — and said so to two other hosts with confidence. It is not an
orphan. It is bound by
`openspec/litmus-tests/litmus-skills-canonical-and-mcp-first-shape.yaml`, whose
arms run it and assert its verdict. The grep was over `scripts/` and `build.sh`
only; `openspec/` was never in the search. **The matcher worked perfectly. The
population was wrong.**

### The rule that makes it falsifiable

Write **`0 hits across <paths>`**, never `0 hits`. The first can be checked by a
reader; the second cannot. If you are about to report that something is
unreferenced, unused, or absent, the sentence must carry where you looked.

Before claiming anything is unreferenced, search the WHOLE tree once:

```bash
find -L . -path ./.git -prune -o -type f -print | xargs grep -l 'needle'
```

**`find -L` is not incidental here.** It is the one invocation that survives
BOTH failure modes: it enumerates the whole tree rather than a guessed subset,
and `-L` follows the symlinked directories that `grep -r` would skip. A reader
who fixes only the population problem by reaching for `grep -r` walks straight
into the walk problem, and a reader who fixes only the walk problem with `-R`
still greps the three directories they expected the answer to be in.

### Why this pairs with the contaminated control above

All three failures on this page are the same shape wearing different clothes —
**an instrument answering a narrower question than the one you asked, and
reporting the narrow answer in the vocabulary of the broad one:**

- a contaminated probe word measures a different regime than the one you meant;
- `-r` walks a smaller tree than the one you named;
- a path list searches a smaller corpus than the one you meant.

A fourth, from the same night, for the shape rather than the tool: a host
counted stray processes with `pgrep -c -f 'cargo|rustc'` and got `1` — its own
shell, matching the pattern its command line contained. The instrument counted
the process doing the asking. It believed the zero only after LISTING the
matches instead of counting them.

**So: list what matched, name what you searched, and be suspicious of any zero
you did not have to work for.**

## Common pitfalls

- **Never state a universal negative from one recursive grep.** The failure mode
  here produced "NO release path invokes `bump-version.sh`" — asserted from a
  single `grep -r`, in a message telling a coordinator to check before cutting a
  release. The runbook invokes it twice.
- `2>/dev/null` is not the culprit and removing it changes nothing. **Nothing
  fails.** That is the whole problem.
- A negative control is cheap, and it has to run in **both** directions: search
  for a string you know is present (if that comes back empty, your search is
  broken, not the tree) *and* for one you know is absent (if that comes back
  full, your fix is reporting phantoms).
- `-R` rescues Linux but is not a portable answer; prefer
  `find -L <dir> -type f -exec grep -l PAT {} +` when you need certainty on an
  unknown host.
- **A directory of symlinks is not a directory of only symlinks.** Check before
  you `rm -rf` it. See the guard above.
- The sibling hazard is the same shape: a **PATH-dependent tool identity**
  (`find` resolving to bfs 4.1.1 and inverting a verdict). Identity changing a
  *result* is the 2026-09-13 portability row; identity changing *scope* while
  still reporting success is this one.

## Provenance

- <https://pubs.opengroup.org/onlinepubs/9799919799/utilities/grep.html> (do-not-bundle; sidecar only)
- <https://www.gnu.org/software/grep/manual/grep.html> (do-not-bundle; sidecar only)
- <https://ugrep.com/> (do-not-bundle; sidecar only)
- Derived (project-local measurement, NOT upstream provenance): the three-host
  reproduction, the GNU-grep-is-identical finding, the exit-code discrepancy, the
  `.ugrep`-not-honoured result, and the mixed-content alias-tree census were all
  measured on pirria-silverblue 2026-09-18 under order 1238-u84w. Recorded here
  as derived, per `methodology/cheatsheets.yaml -> provenance.rule`.

## See also

- `utils/fd.md`
- `utils/bash.md`
