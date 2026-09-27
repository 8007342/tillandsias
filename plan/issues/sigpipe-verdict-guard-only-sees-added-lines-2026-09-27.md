# The SIGPIPE verdict guard only sees ADDED lines, so a host pays a full gate to discover debt it did not write

Classification: **enhancement**. Found 2026-09-27 on `forge-tillandsias` while
landing packet 1229-2862. Not a p1 and not a blocker: the failure direction is
fail-CLOSED. The cost is a gate cycle, not a wrong verdict.

Reported by `forge-forge-tillandsias-opencode-20260927t135319z` on `linux-next`
at `b52049c2e` (the 1229-2862 scenario-7 classifier).

## What happened

`scripts/land-on-platform-branch.sh linux-next` refused the push with
`refused:land:gate-failed`, first failing line `violation:sigpipe-verdict-added:3`.
The three lines it named were all MINE, in the new `classify_spec_run()`:

```
if [ "$skip" -gt 0 ] \
   && { ! printf '%s' "$line" | grep -q 'skipped_engines=' \
        || ! printf '%s' "$full" | grep -q '^SKIP  .*\['; }; then
```

which is a genuine 1137-da83 hazard: `grep -q` exits at its first match, `printf`
dies of SIGPIPE, and under `pipefail` the `!` can read a MATCH as a non-match. The
refusal was correct, the three lines were correctly located, and the remedy the
refusal itself printed (here-strings: `grep -q PATTERN <<<"$var"`) is what the fix
uses. **The guard did its job.** This file is about the part around that.

## The observation

The guard's own build step announces its scope: `Checking for newly-added
SIGPIPE-decidable verdict pipelines (792-ksr8)`. Diff-scoped is the right default —
a whole-tree scan would block every push forever on pre-existing debt — but the
debt it cannot see does not go away, and it becomes someone else's push:

`scripts/test-groundtruth-corpus-declaration.sh` lines 195 and 203, sixty lines
ABOVE the code the guard refused, are the same class in verdict position and are
untouched by any recent change:

```
195:       && printf '%s' "$full" | grep -q '^STALE .*NOT VALID in this checkout'; then
203:       && printf '%s' "$full" | grep -q '^SKIP  .*NOT GRADED on this host'; then
```

`$full` is the entire `tillandsias-plan grade` output, so a partial write plus an
early-exiting `grep -q` is a reachable 141. Nobody will be told, because the guard
only reads the diff, until an author edits one of those lines for an unrelated
reason — at which point the push is refused for a hazard the author did not write,
and the cost of that discovery is a full `./build.sh --check` cycle. Measured here:
one gate, ~10 minutes, for a three-line fix.

Why it is not a p1: the bad verdict is a real STALE or SKIP reported as
`unaccounted`, which fails the fixture loudly and points at accounting. Fail-closed,
not fail-open. That is the right direction for a guard and is the only reason this
is an enhancement rather than a bug.

## Smallest next action, three options, none of them a new guard

1. **Annotate the known instances.** Two `# sigpipe-ok: <reason>` comments on lines
   195 and 203 make the debt explicit and cost one commit. The guard's own refusal
   text already tells an author this is the accepted escape, so the annotations are
   read by the next person the guard refuses.
2. **One advisory sweep, once.** A `--scan-existing` mode that walks the
   gate-covered shell scripts and PRINTS instances without refusing, folded into an
   existing check that already runs. Nobody has to opt in, and the output can be
   pasted into a follow-up row.
3. **Nothing.** Accepted cost, stated here so the next host that loses a gate to
   this knows it was not their code.

Not filing a packet: this needs a decision about which of the three, not work, and
no host can make that decision for the maintainers. Reducing it to a row before
someone picks an option would put a 1-line change and a 3-hour change in the same
queue with no preference between them.

## What would falsify this

If `scripts/check-sigpipe-verdict-pipelines-added.sh` in fact scans whole files when
the diff is empty or when a file is touched at all, then lines 195 and 203 were
skipped for a different reason and the annotation remedy is redundant. Cheap to
check: add the same three-line pattern to a gate-covered script and read whether the
refusal names lines you did not add.

trace: order 792-ksr8, order 1137-da83, packet 1084-nzqc (the guard's own blind-spot
row, `completed` — its two escapes, `/usr/bin/grep` and a pipeline split across a
line continuation, are BOTH still worth a spot-check, because the three lines the
guard refused me on are line-CONTINUED conditions whose pipelines are each entirely
on one physical line, which is neither of the two shapes 1084-nzqc measured), packet
1229-2862, plan/index.d/20260927t135331z-04a272ed-forge-tillandsias.yaml.
