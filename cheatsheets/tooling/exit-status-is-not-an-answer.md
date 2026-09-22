---
tags: [exit-status, portability, bash, date, false-negative, agent-safety, fail-loud]
languages: [bash]
since: 2026-09-20
last_verified: 2026-09-20
sources:
  - https://pubs.opengroup.org/onlinepubs/9799919799/utilities/date.html
  - https://www.gnu.org/software/coreutils/manual/html_node/date-invocation.html
  - https://man.freebsd.org/cgi/man.cgi?date(1)
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: true
---
# A command that can succeed wrongly cannot be guarded by its exit status

@trace spec:cheatsheet-tooling

**Check what it produced.** `cmd || fallback`, `if cmd; then`, and
`cmd && return 0` all ask one question: *did it exit zero?* That is the wrong
question whenever the command can exit zero without answering — and a
surprising number can. The fallback then never fires, the guard vouches for
nothing, and the failure is invisible because the shape of success is present.

Four specimens, all measured on this fleet on 2026-09-20, all in code written
that day by people who knew better:

| Specimen | What exits zero | What was believed |
|---|---|---|
| A binary that does not know a subcommand | a stub answering `exit 0` to every argument | "this binary is current" — the plan-only lane vouched for every pre-1287-h6qn binary, wrapper and stub in the fleet |
| The same, one layer down | the same stub, in `check-plan-binary-current.sh` | "content verified" — so it minted no stamp and silently removed the fallback ladder |
| `date -u -d` on BSD | BSD `date` accepts `-d` and prints garbage | the `\|\| date -u …` fallback beside it could never run (relay fix `4897877b7`) |
| `date +%s%N` on BSD | BSD has no `%N`; it prints a literal `N` | `$(( … ))` kept going with nonsense instead of failing |
| A function called inside `$(…)` | the subshell exits zero having set its globals | the caller read the global as empty, because a subshell's globals never cross back (yoga, same evening) |

## The rule

Validate the OUTPUT against the shape it must have, and ignore the status:

```bash
# WRONG — accepts whatever a BSD date printed
_epoch() {
    date -u -d "$1" +%s 2>/dev/null && return 0
    date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null && return 0
    return 1
}

# RIGHT — an epoch is digits; anything else is not an answer
_epoch() {
    local out
    out="$(date -u -d "$1" +%s 2>/dev/null)"
    case "$out" in ''|*[!0-9]*) ;; *) printf '%s\n' "$out"; return 0 ;; esac
    out="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null)"
    case "$out" in ''|*[!0-9]*) ;; *) printf '%s\n' "$out"; return 0 ;; esac
    return 1
}
```

The same move for a tool that answers a question — require the answer line, not
the exit code:

```bash
# WRONG — a binary that never heard of the subcommand exits 0 and is believed
if "$bin" validator-surface-hash --check; then fresh=1; fi

# RIGHT — only the literal answer is a pass; everything else falls through
case "$("$bin" validator-surface-hash --check 2>&1)" in
    ok:validator-surface:*)    fresh=1 ;;
    stale:validator-surface*)  fresh=0 ;;
    *)                         : ;;   # cannot ask -> the older ladder decides
esac
```

## The same family, one substitution over

`$(…)` is a subshell. A function that reports by SETTING A GLOBAL reports
nothing when it is called that way, and the call still exits zero:

```bash
_probe() { RESULT="found it"; }        # reports via a global

out="$(_probe)"                        # exit 0, stdout empty...
echo "${RESULT:-<empty>}"              # ...and RESULT is <empty> out here
```

The failure reads identically to "the probe found nothing", which is why it
survives review: both the exit status AND the visible output are exactly what a
genuine negative looks like. If a function reports through a global, call it
plainly; if it must be called in a substitution, make it report on stdout.

## Milliseconds without `%N`

`SECONDS` is a bash builtin, integral, and bash-3.2 — so it works on the macOS
lane, which `date +%s%N` does not:

```bash
t0=$SECONDS
run_the_thing
echo "took $(( SECONDS - t0 ))s"
```

## Why this keeps happening

The wrong version is shorter, reads correctly in English ("if the date command
works, use it"), and passes every test written on the platform where the command
behaves. It fails only on the platform nobody ran it on, and it fails SILENTLY
there, so the first symptom is a wrong answer somewhere downstream rather than
an error.

`scripts/check-bash-dialect.sh` catches the `date -d` family in about a second
and is wired into the gate. It is a source scan: run it before a SHA, not after
a refusal.

## Related

- The mute-binary specimens and their fix: order 1287-h6qn, and
  `scripts/test-plan-binary-freshness.sh`'s three arms for the present-and-mute
  state — a binary that runs, exits zero and says nothing.
- A named `skip:` is an answer too, and is not a failure (1273-4mak, 1309-fhxb).
  The mirror image of this page: do not read a refusal into a non-zero exit that
  came with a `skip:` line.
- [[recursive-grep-symlinks]] is the same family with a different organ: there
  the tool exits zero over a population it never walked.

## Four of them at once — a worked specimen

Measured on yolanda-windows, 2026-09-22. One command, **four** distinct ways
the status was not the answer, stacked so that each hid the next.

```bash
git add plan/index.d/*.yaml 2>/dev/null   # 1,771 files
git commit -q -m "..."
bash scripts/push-plan-fragments-to-trunk.sh
# → ok:fragments-on-trunk:a76ac5de3:3
```

That success line is **true**. The commit carried nothing.

1. **A hidden error.** The glob exceeded the MSYS argv limit, `git` never ran,
   and `2>/dev/null` discarded the only evidence — `Argument list too long`.
   See [git-bash-cannot-fork-or-enumerate](git-bash-cannot-fork-or-enumerate.md).
2. **An exit code from the pipeline, not the command.** `$?` read 0 because the
   status belonged to the shell's exec and the surrounding pipeline, not to
   `git`.
3. **A true success line beside a silent failure.** The push genuinely did push
   three fragments. Nothing it printed was wrong. It simply was not reporting
   on the thing that had failed.
4. **A lane whose CORRECT behaviour made the wrong outcome look right.** The
   plan lane carries *untracked* fragments by design — so the fragments landed
   even though the commit was empty, and the resulting verdict looked exactly
   like a healthy push.

### The one nobody writes down

**A push lane that carries untracked files makes a FAILED COMMIT INVISIBLE.**

There is no defect in the lane; carrying untracked fragments is what it is for.
The consequence is that a broken commit and a healthy one produce the same
output, and no amount of reading the verdict separates them.

**So verify the ARTEFACT, not the verdict.** The failure surfaced only on
asking a different question — *is the report on the remote?* — rather than a
louder version of the same one:

```bash
git ls-tree -r --name-only origin/linux-next -- plan/issues | grep -c "$NAME"
# 0   ← the commit never carried it
```

### Why it is worth a page rather than a note

The person who wrote this had relayed *"never `2>/dev/null` on a state-changing
command"* to another host **two hours earlier**, as a trap worth recording, and
then committed it. That is the argument for the check rather than the rule:
**knowing a rule does not apply it, only a check does.**
