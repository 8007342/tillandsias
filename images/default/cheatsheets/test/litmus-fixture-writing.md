---
tags: [litmus, testing, fixtures, fail-loud, yaml, negative-control, falsifiability]
languages: [bash, yaml]
since: 2026-08-29
last_verified: 2026-08-29
sources:
  - plan/index.yaml order:748-tkjx
  - plan/index.yaml order:921-vtf4
  - plan/index.yaml order:925-erjs
  - plan/index.yaml order:721-77yu
  - plan/index.yaml order:677-33be
  - plan/index.yaml order:776-cm74
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: true
---

# Writing litmus fixtures that can actually fail

@trace spec:cheatsheet-tooling, spec:spec-traceability

**Use when**: authoring or converting a litmus step, or writing any fixture that
greps this repository's own source.

Every rule below cost a measured incident on this fleet between 2026-08-15 and
2026-08-29. They are ordered by how expensive the mistake is, not by how
likely — the cheap-looking ones near the top are the ones that produced
multi-day standing reds.

## The one rule that subsumes most of the others

**Ask what result would have falsified your assertion. If nothing would have,
you measured your own input.**

A test that cannot fail when the behaviour inverts is worse than no test,
because it spends credibility. Three examples, all measured 2026-08-29 under
order 925-erjs:

| Pin | Why it could not fail |
| --- | --- |
| `grep -A 30 'pub fn is_transient' … \| grep 'StreamError'` | asserted the type NAME, so it passed whether the arm mapped to `true` or `false` |
| `grep -A12 '<match arm>' … \| grep -F 'ErrorCode::Unsupported'` | matched the arm's own COMMENT two lines in; the code beneath was unpinned |
| `grep -A 2 'pub fn enclave_network_name' … \| grep 'tillandsias'` | a substring the crate path itself satisfies; `tilla-{}-enc` passed it |

Assert the **mapping**, not the name. `StreamError\(_\) *=> *true`, not
`StreamError`.

Its runtime twin, from the darwin lane the same night (920-pxg6 verification,
tillandsias-91): **a green gate tells you the check passed, not that the
property holds — the cheapest way to tell those apart is to run the thing on
real hardware and read what it actually says.** The three findings that
mattered that night were all this shape and none looked like a failure: a
readiness probe reporting NOT-BOUND over a working port (socat absent from the
VZ guest), an expert answering an off-topic question with six real-but-
irrelevant citations (no similarity floor), and a coverage tool answering
`0-spec(s)` for a changeset a dozen specs cover (BSD awk died and `2>/dev/null`
ate the corpse). Two surfaced only because something was actually RUN; the
third nearly shipped inverted until a tier-budget confound was stripped by
isolating the variable on hardware.

## Never anchor an assertion on a comment

Order 921-vtf4, first-red commit `f58079555`. A pin read

```bash
grep -l 'lib/tool-dispatch.sh' scripts/tray-diagnose.sh scripts/diagnose-macos-provision.sh
```

to enforce "these shipped diagnostics do NOT source the shared lib". A docs
commit then added the comment `WHY THIS DISPATCH IS INLINE AND NOT
scripts/lib/tool-dispatch.sh` to both files — and the pin matched the comment.

**The commit that documented the exception broke the test that guards the
exception**, and it stood red for three days while the behaviour was never once
violated. Match the construct, not the string:

```bash
# the invariant is a SOURCE STATEMENT, so require one
grep -lE '^[[:space:]]*(\.|source)[[:space:]]+[^#]*lib/tool-dispatch\.sh' <files>
```

## Bound by syntax, never by a line count

`grep -A<N>` measures FORMATTING. Insert a comment above the anchor and the
target slides out; the test fails on correct code while naming the pinned
behaviour, so the reader investigates working code. 748-tkjx records two such
false failures in one hour.

Use the range idiom this corpus already uses:

```bash
awk '/^fn build_inference_run_args\(/,/^}/' crates/…/main.rs   # top-level fn
awk '/pub fn is_transient/,/^    }$/'       crates/…/client.rs # impl method
awk '/gpu-cuda\)/,/;;/'                     images/…/entrypoint.sh  # case arm
awk -v s='[target.x86_64-pc-windows-msvc]' \
    'index($0,s)==1{f=1;next} /^\[/{f=0} f' .cargo/config.toml       # TOML section
```

For a doc comment above a signature, buffer the contiguous comment block rather
than counting backwards with `-B2`:

```bash
awk '/^[[:space:]]*\/\//{buf=buf $0 "\n"; next}
     {if ($0 ~ /pub fn can_start_project/) {print buf; exit} buf=""}' file.rs
```

### The subtlest form: a truncated comparison input

`litmus:terminal-status-vocabulary-shape` read a status list through `grep -A3`
and **compared** it against another list. An ordinary rustfmt reflow of the
`matches!` makes the window see ONE status where the function has four — and the
step then reports the *compared-against guard* as drifted.

**A window that truncates an input to a comparison does not fail. It accuses
something else.** Measured 2026-08-29: `-A3` saw `completed`; the awk range saw
all four.

## Verify every negative control on a mutated copy

Not by reasoning — by running it. The loop that works:

```bash
cp real/file.rs /tmp/neg.rs
sed -i 's/=> true,/=> false,/' /tmp/neg.rs
<your assertion against /tmp/neg.rs> && echo 'STILL PASSES (bad)' || echo 'fails (correct)'
```

Under 925-erjs every one of 25 conversions was checked this way: flipping a
match arm, weakening `0o600` to `0o644`, emptying `rustflags`, renaming a format
string, deleting a `@trace`, replacing `exit 1` with `true`, pointing a CUDA
device at `/dev/null`.

## EXECUTE the decoded command — reviewing the diff cannot work

**YAML double-quoted scalars eat backslashes, and awk needs them.**

Writing `\\"$OLLAMA_LIBDIR` in a YAML `command:` produces `"$OLLAMA_LIBDIR` in
the shell — the backslash escaped the quote, not the dollar. awk then reads `$`
as end-of-line, the range matches nothing, and the step fails closed. The edit
looks right in the diff.

Extract and run what the harness will actually run:

```bash
tillandsias-plan yaml-get openspec/litmus-tests/<test>.yaml critical_path \
  | grep '^command: ' | sed "s/^command: //" \
  | while IFS= read -r c; do c="${c%\'}"; c="${c#\'}"; c="${c//\'\'/\'}"; bash -c "$c"; done
```

In an awk regex, an anchor you mean literally needs `\$` — which is `\\$` inside
a YAML double-quoted scalar.

### Same family: backticks in shell heredocs

Writing a ledger event with an unquoted heredoc silently executed
`` `proxy` `` as a command and left a GAP in the recorded text. Quote the
delimiter (`<<'EOF'`) whenever the body is prose you want verbatim, and prefer
writing long ledger prose as a fragment file over passing it as an argument.

The ARGUMENT variant is worse and was measured twice in one day (macuahuitl
heredoc 2026-08-29 early; macbook double-quoted args 2026-08-29 late): a ledger
event summary passed as a double-quoted shell argument command-substitutes
every backticked span, and the prose STILL READS FLUENTLY while no longer
naming a single command — "I ran the python check via a  heredoc". Append-only
ledgers make the damage permanent. Remedy: write the body to a file and pass
`"$(cat body.txt)"` — file content is not re-scanned — then grep the WRITTEN
fragment for identifiers you know must be present before committing it.

Third instance, same family (macbook 2026-08-29): inner double quotes in a
double-quoted `git commit -m "…"` terminated the string and the remainder
became pathspecs — the COMMIT failed while the packet's set-field succeeded,
leaving the ledger claiming an SHA that did not exist until `git log` was
checked. Remedy: `git commit -F file`. The family rule: any prose that passes
through a shell argument can be silently rewritten by the shell; pass files,
then verify the written artifact.

## An edit script must ASSERT its anchor matched

Adjacent family, different mechanism. The shell cases above are *your text got
rewritten*; this one is *your operation never happened and told you it did*.

Measured (926-bin4, macbook 2026-08-29): a patch script did

```python
s = s.replace(old, new, 1)      # no assert
open(p, 'w').write(s)
print('route matrix updated')   # prints whether or not it matched
```

The anchor had drifted, `replace` returned the string unchanged, the file was
rewritten identically, and the success line printed anyway. Every later build
shipped a guest that ADVERTISED a capability while its dispatch matrix REFUSED
the variant — a contradiction no build could catch, because both halves
compiled. It surfaced only on a live probe, as `variant PtyOpenData not
supported on the in-VM vsock transport`.

```python
assert old in s, "anchor missing — the edit did NOT apply"
s = s.replace(old, new, 1)
```

`str.replace` reports nothing on no-match, and `sed -i` is the same shape: a
pattern that matches nothing exits 0. Any editor whose failure mode is
"changed nothing, said fine" needs the assertion outside it.

THE GENERAL FORM, which is what makes this worth a section rather than a note:
**a tool's success message is a claim about the tool running, not about the
work landing.** Three instances in one week, three different tools —
`| tail`-masked merges (macuahuitl), the `wsl.exe` exit-code swallow
(yolanda), and this. The check is the same in all three: after the tool says
it worked, read the ARTIFACT for something you know must now be true.
`grep -c PtyOpenData control_dispatch.rs` would have returned 0 and cost five
seconds; the live probe cost a guest rebuild and a VM boot.

Corollary already in this file: the same discipline applied to assertions
themselves — watch a new check FAIL against the defect it targets before
trusting its green.

## A test that constructs the struct it asserts about pins its own fixture

A whole CLASS of vacuous test, distinct from the wrong-expectation kind
(924-bwda): the test builds its own input (a `DeviceRecord` literal, a
hand-rolled config, a synthetic envelope) and then asserts properties of
what it built — so it renders whatever the TEST supplied and never reaches
the production code path it appears to cover. Measured on 793-zumy
(yolanda, 2026-08-29): a reason-string assertion counted as coverage since
806-2r4s stayed GREEN with the production literal reverted to the wrong
value, because the fixture never reaches `enumerate_gpus()`. Found only
because the control ran FIRST — write green after your change and you
report a criterion closed on a test that cannot fail for it.

The fix is structural, not an assertion tweak: move the shipped value into
a pure function so the PRODUCTION value is reachable from a unit test, then
pin that — with the control run in both directions. Keep the old test for
what it does cover, with a doc comment saying plainly it cannot pin
production. When auditing, ask of any test: whose value is being asserted —
the producer's, or the fixture's?

Second measured instance, same evening (935-6fzk, macbook): a signing-seam
fixture ran ITS OWN PlistBuddy derivation and asserted the result — proving
the TECHNIQUE works rather than that the BUILD uses it — and stayed green
when the build was mutated to skip the entitlement strip. Caught by the
author running the mutation control before trusting the green; rewritten
to assert the build performs the deletion. Two instances in one evening,
two authors, both found only by control-first: assume the class is common.

## Which fixtures must survive the old code, and which must fail it

A contract change produces TWO kinds of fixture, and confusing them leaves
the change untested (yoga, 940 follow-through, 2026-08-30): a PROPERTY
fixture asserts behaviour the change must preserve — it must pass against
BOTH the old and new implementation (the compaction cases pass under
either stamp writer; a token is inert to a writer that does not read one).
A CONTRACT fixture asserts the new mechanism itself — it must go RED
against the old implementation, verified by actually running it there.
Check each new fixture against both sides and know which answer you expect
from each.

Two traps from the same change: (1) A NEW GUARD CAN MASK THE PROPERTY
UNDER TEST — after the stamp gained its token check, a negative control
(broken tree must refuse) refused AT THE TOKEN CHECK and never reached the
path under test; it would have passed while proving nothing. Issue the
guard's prerequisite BEFORE breaking the tree, so the refusal you observe
is the one you are testing. (2) A WELL-POSED QUESTION CAN SHIP A HOLE —
the routed question offered "honor or retire the compaction allowance",
but no such allowance existed (it was a hashability fix; deletions change
the digest like edits). Implementing the plausible option (a) would have
required inventing a compaction-vs-modified classifier — a forgery
surface — to satisfy a test. When a fix seems to demand a new classifier,
first verify the premise names a mechanism that actually exists.

## When a checker accuses correct code, fix the checker — with a mutation control

Two guard false positives in one change (830-xsk2, macbook, 2026-08-29),
same root: a guard parsing a PATTERN LANGUAGE EMBEDDED IN A HOST LANGUAGE
(Rust declarations by regex; shell by regex) met a nesting level it does not
model. `check-source-slice-bounds.sh` called a working slice dead because its
declaration regex admitted `pub`/`async` but not `unsafe fn`;
`check-no-spawn-in-if-not.sh` then read the `|` INSIDE that quoted regex as a
shell pipeline.

The tempting responses damage correct code or bury the gap: weaken the test
the first guard protects, or drop a `# sigpipe-ok` marker — a comment
asserting "I checked, it is fine" on a line the checker never understood.
The right move both times: **fix the guard's model, then run the mutation
control that proves the widened guard can still go red** (a genuinely absent
slice bound must still exit 1). Widening a checker without proving it can
still fail just relocates the vacuousness into the guard. Where alternation
in a quoted regex trips a shell-parsing guard, prefer rewriting the pattern
(a repeated word-class) over exempting the line.

## `check-litmus-pin-claims.sh` refuses bare litmus names (721-77yu)

That guard greps every `*.sh` for `litmus:<name>` and refuses any name no test
declares — correctly, because *a script naming a litmus test that does not exist
reads as verification and supplies none*. It fires on fixtures with synthetic
stand-in tests, and on comments that drop a test's `-shape` suffix.

Assemble the token at run time so the literal never appears in source:

```bash
_LT="litmus"; _LT="${_LT}:"      # then use "${_LT}alpha-shape"
```

## A per-function assertion cannot see the sibling that forgot

Green gate, dead feature (925-eofi, 2026-08-29, macbook): a wire fix was
patched into one of TWO functions that chunk input onto the wire; three tests
passed because every test scanned the function just edited; the live run
hung with no warning line — and that SILENCE was the diagnosis, since the
patched path prints a named warning. When an invariant must hold at every
member of a family (every input entry point, every dispatch arm, every
transport), write ONE test that ENUMERATES the family and require each member
to satisfy it — and watch it fail red against the unpatched member before
making it green. **An assertion never seen red is not known to be able to
catch anything.** The companion design rule, measured in the same incident: a
route matrix that REFUSES what it does not know turned the next omission into
a named error instead of a silent no-op — fail-loud registration means an
unregistered variant cannot quietly do nothing.

## Scope an authority search to the AUTHORITY, not the document

A guard that asks "does this approved string appear in the ledger?" approves
anything anyone has ever QUOTED there — measured on 929-47u8 (2026-08-29): the
counterexample string quoted in two prose events made the guard say YES to the
exact unauthorized reword it existed to catch. Fail-open, the inverse of the
comment-anchor family. Scope the search to the structure that confers
authority (`- type: operator_note` bodies, per the spec's own words), then
verify the reword still fails while remaining mentioned in prose.

## Constructed absence must SHADOW the real binary

Order 921-vtf4 / commit `d013a6fc8`, found by lenovinha and macuahuitl. A
fixture built a PATH "with deliberately no `nix`" by omitting it — but kept
`/usr/bin` on PATH for the POSIX baseline, so on a distro-nix host the real
`/usr/bin/nix` leaked into the fake world and honestly detected the throwaway
store. **"No X" is a state you build, not one you assume**:

```bash
cat > "$FAKEBIN/nix" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
chmod +x "$FAKEBIN/nix"
```

A fixture whose premise holds only on the author's host is a fixture that
reports on the host, not on the code.

## Judge what your test could have CAUSED, not what the directory did

A fixture asserting "this wrote nothing" by counting files in a shared
directory makes every concurrent writer its own failure. Order 923-28js:
`before=$(ls plan/index.d/ | wc -l)` around the code under test, and a
`git stash push -u` / `pop` during a concurrent build moved it 62 -> 65 —
reported as "a refusal still wrote a fragment: append-event's archive guard
regressed". Nothing had regressed.

A count is also the weakest observation available: it cannot say WHICH file
appeared, so the message must guess a cause, and it guessed wrong. On a fleet
running driver cycles beside agent cycles on one checkout (873-zcim), **a red
whose own text denies its reason is worse than no check** — the honest reading
sends someone to investigate working code.

Take a SET difference and filter it to what your fixture could have written,
using an identity it stamps on its own output:

```bash
before_set="$(ls "$DIR" | LC_ALL=C sort)"
# ... exercise ...
after_set="$(ls "$DIR" | LC_ALL=C sort)"
new="$(comm -13 <(printf '%s\n' "$before_set") <(printf '%s\n' "$after_set"))"
# red only for files carrying YOUR marker; name the path, never a count delta
```

Pick the identity carefully. `FIXTURE_AGENT` looked like the obvious marker and
is wrong — it resolves to the host's real agent id, so it matches the operator's
own fragments. The fixture's own summary string is the identity that is
uniquely yours.

## Environment dies at every hand-rolled boundary — test through the wrapper

Order 923-ws3r, the third instance. `scripts/with-tillandsias-builder.sh`
forwards `TILLANDSIAS_*` across the toolbox boundary and says in its own comment
why it must; `scripts/with-wsl2-builder.sh` does the same for WSL (889-8tcb).
A hand-rolled `toolbox run` inside `archive-plan-packets.sh` forwarded neither,
so an absolute `TILLANDSIAS_PLAN_BIN` died there and the Ruby half fell back to a
RELATIVE default — red inside a hermetic tree, and silently running a *different
binary* in ordinary ones.

The transferable half is how nearly-wrong the diagnosis was. Measuring raw
`toolbox run` shows the env vanishing, which makes "the toolbox boundary" look
like the cause. **Test through the project's own wrapper before blaming the
boundary class**: the wrapper forwards fine, and the defect is the second,
hand-rolled dispatch that never learned what the shared one knows. Blaming the
class would have fixed the wrong line — 704-zcgi's shape, once more.

## A fixture that mutates tracked files owes restoration under every exit

Order 677-33be: a killed run left a test sentinel in the tracked `VERSION`, which
then blocked every push on that host. Under 921-vtf4 the same fixture grew an
**index** mutation (`git add`), which owes the same discipline:

- restore under `EXIT INT TERM HUP`, and restore the **index** too — an
  unstaged `cp` leaves the blob staged while the working tree looks clean;
- **repair on the next run** what a SIGKILL could not clean up;
- **REFUSE rather than repair** when the file carries work that is not the
  test's. Restoring from HEAD would destroy an operator's uncommitted edit, which
  is worse than the test not running.

Related reflex to avoid: `git checkout -- <file>` to undo a test mutation
destroys *uncommitted* work in that file. It cost this session its own fixture
fix mid-verification.

## Before "fixing" a red, check the rule still holds

Order 921-vtf4, first-red `32192d5bb`. `litmus:image-build-convergence-shape`
appended a comment to a tracked `Containerfile` and expected a rebuild. Order
776-cm74 — an attended operator decision — had changed the cache key to hash
`git ls-files -s` object ids, so the key stops depending on where a checkout
lives. Under that definition a working-tree-only edit is **not** a source change
and the builder was right to skip.

The test was asserting a rule the project had deliberately replaced. The fix was
to re-cut the test (stage the edit), not to change the builder. **Name the
first-red commit before choosing a side** — `git log -S` on the matched string,
or worktree checkouts at the suspect and its parent.

## Checklist

- [ ] Would this fail if the behaviour INVERTED? If not, assert the mapping.
- [ ] Is the anchor code, or could it match a comment?
- [ ] Is the scope syntactic (`awk` range), not a line count?
- [ ] Does a mutated copy actually turn it red?
- [ ] Did you RUN the YAML-decoded command, not just read the diff?
- [ ] Does any absence in your fixture SHADOW the real tool?
- [ ] Do you name a `litmus:` test that exists — suffix and all?
- [ ] If you mutate tracked files: restored on every exit, repaired next run,
      and refused when the dirt is someone else's?
- [ ] Does your "nothing happened" assertion count a SHARED directory? Judge
      only what your fixture could have caused, and name the file.
- [ ] Crossing a container/distro boundary by hand? Forward the namespace, and
      test through the project's wrapper before blaming the boundary.
- [ ] Does a comment claim parity with a sibling? Grep the sibling, not the
      comment.

## The failure mode of a verification tool is not silence, it is fluency

(yolanda's sentence, 2026-08-30, after the seventh instance in two days.)
Two sub-families, and guards for the first cannot see the second:

FLUENT OUTPUTS — a result where there was no result: sha256("") comparing
two nonexistent files as twins; failed curls counted as 6ms "syntheses";
a fixture pinning its own input. The guard is the falsifiability question
at the top of this file.

FLUENT INPUTS — every row a genuine measurement, every guard satisfied,
and the COLUMN HEADING is fiction: a client-side budget var that never
reached the server; an inherited model env running 0.5b under a "7B"
label. A guard that asks "did a measurement happen" cannot catch these,
because one did. The missing check is "was the TREATMENT actually applied
to the thing under test", and it lives in the process under test, not in
its output: read the treatment back out of the running server (its own
/api/ps, its own env, its own config endpoint) and REFUSE THE ARM on
mismatch. Both twin harnesses now do this per cell.

## A process query whose pattern matches the querier

Two measured instances in one day. (1) macuahuitl, mid-incident: a
cleanup `pkill -f` whose pattern appeared in the wrapper shell's own
command line killed the cleanup itself (exit 144 mid-remediation). (2)
yoga: waiter loops polling `pgrep -f "build.sh --check"` MATCHED THE
WAITERS — their own command lines contain the string — and reported
"gate running" for 86 minutes on a machine at load 0.08, waiting on
their own reflection, while the real gate they had accidentally killed
earlier stayed dead. A liveness check that can see itself answers from
its own existence, not from the thing it watches. Remedies: match the
executable, not the command line (`pgrep -x`, or an absolute-path
`pgrep -f ^/path/to/binary`); or check the OBJECT the process would
hold (the lockfile, the stamp mtime, the pid file) rather than the
process table at all.

## Never gate while a measurement batch is live

Measured on the yoga/yolanda 7B tuning day (2026-08-30): a gate flipped red
on IDENTICAL content because heavy inference was running beside it — and the
inverse hazard is worse, because on a fleet where the MEASUREMENT host is
also the GATE host, a green gate says nothing about what else the machine
was doing when it ran. The twins' rule, adopted fleet-wide: unload models
and finish (or pause) the measurement batch before gating, and do not treat
greens on load-sensitive checks as load-bearing until a clean re-gate.

Same day, same hosts, five failures of one shape worth naming as a family:
a check RAN, produced CONFIDENT output, and the output meant nothing — two
nonexistent files comparing as twins via sha256(""); a refusal on stderr
while the empty hash went to stdout at exit 0; a fixture pinning its own
input; failed curls defaulted into a mode and counted as six 6ms
"syntheses"; the loaded-host gate above. The common test: before trusting
any check's output, ask what the output would look like if the thing it
measures were ABSENT — and whether that is distinguishable from what you
are holding.

THE COMMON REPAIR, proven three separate times in one night: make the
artifact CARRY HOW IT KNOWS — treatment_verified as prose naming the
server log lines, the gate stamp requiring a token only the gate can
issue, the capability probe emitting its method beside its verdict (with
`unknown` as a first-class verdict for an unreachable substrate, and a
shim that answers `command -v` but not `--version` treated as evidence
of NOTHING). Record the evidence, not the conclusion.

## Existence on the host is not correctness of the container path

A verifier that checks "every path in the spec exists" is structurally
blind on a host with a self-referential symlink. Measured on 935-jhh5
(lenovinha, Silverblue, 2026-08-29): `/run/host` is a symlink to `/`, so
TWO broken CDI specs — one mounting the GPU node at
`/run/host/dev/nvidia0`, one at `/run/host/run/host/usr/bin/nvidia-smi` —
both passed their own every-path-exists verification (0 missing) while the
container got wrong in-container paths and the inference entrypoint's
`[ -e /dev/nvidia0 ]` found nothing. Both wrong answers came from reaching
for the "clever" immutable-host lever (`--driver-root=/run/host`) when the
boring `--driver-root=/` was correct. The fix has two halves: verify the
path AS THE CONSUMER WILL SEE IT (in-container, not on-host), and refuse
known self-referential prefixes outright rather than resolving them.

Measured on 731-eupn (2026-08-29): the macOS applier's comment said it
"mirrors the Windows wiring in notify_icon::apply_cloud_projects" — while
the Windows applier was the one lane still MISSING the outcome
discriminator (`{ projects, .. }` ate the field, `cloud_projects_loaded =
true` unconditional, its own comment claiming "a confirmed answer (even an
empty one)" with nothing confirming it). A reader auditing macOS against
that sentence concludes Windows is fine. The sentence is evidence of the
author's intent at writing time, not of the sibling's code now. Audit the
named counterpart directly — one grep for the discriminator in the
supposedly-mirroring crate (zero references to CloudRefreshOutcome) settled
in one command what the comment had misdirected for days.

The same probe has a false-negative mode, found by the host that used it
(yolanda, same packet, hours later): a grep for a TYPE NAME is a test of
vocabulary, not behaviour. After the fix landed, `CloudRefreshOutcome`
STILL appeared zero times in the crate — the consumer destructures the
field and converts at the boundary (`outcome` → `confirmed: bool`), so the
callee's name never has to appear at the call site. Absence of the name
proves nothing in either direction. When a runnable test exists, run it;
it was always the stronger probe.

## Exit codes do not survive `wsl.exe -- bash -c '<quoted script>'`

Measured on yolanda 2026-08-29 (740-3k4s WSL verification): three
consecutive EC runs reported exit 0 for a case that exits 1 — which reads
exactly like a probe that reports failure and exits success. It was the
HARNESS: `wsl.exe -d <distro> -- bash -c '<single-quoted script>'` returns
0 regardless of the script's exit. The control that caught it is the one to
copy: `bash -c 'exit 1'` and `bash -c 'exit 7'` through the same invocation
ALSO returned 0. Piping the script to `wsl.exe ... -- bash` on stdin makes
propagation exact. Any Windows-lane defect report resting on an exit code
from the quoted form is unproven until that control has run.

## A pattern that survives in comments makes a plain grep lie in both directions

Found by yolanda retargeting the vsock-ordering litmus after a fold moved the
systemd ordering definition from `wsl_lifecycle.rs` to `readiness.rs`
(937-68n4 fallout, 2026-08-30). `After=` and `Wants=` STILL appear in the old
file — in comments and in the test assertions written during the fold — so
`grep -q 'After=' wsl_lifecycle.rs` stays GREEN while the definition it
claims to pin lives in a file it never reads. A grep that cannot tell a
definition from a mention of one goes green on the corpse of the code it
guards.

The repair that worked: keep the LITERAL-EXTRACTION step (the one that
correctly failed — it pulls the actual unit text and asserts on the emitted
value) and move it to the new file; do not loosen the grep to pass. Two
intermediate attempts produced meaningless greens on the way and are the
other half of the lesson: YAML the strict validator rejects while the litmus
runner reported 8/8 PASS (no yq on the host, so the runner parsed by grep),
then block scalars that satisfied the validator and broke the runner.
Mutation-control in BOTH directions — break the property and watch it fail,
restore it and watch it pass, under the runner that will actually execute it
— before calling a retarget done.

## An incomplete merge makes trunk's files look like your new ones

Cost yolanda a gate cycle on the 942-e23x run (2026-08-30) and will hit
every platform branch eventually. `check-issue-citation-convention.sh` — and
any check that diffs against `origin/linux-next` — computes "what did YOU
add" from that diff. With a merge left INCOMPLETE, trunk-side files your
branch has not yet integrated appear in the diff as if you authored them:
the check flagged a line-number citation in lenovinha's
network-architecture-audit file, green on trunk, red on the branch, on a
file yolanda never touched. Completing the merge cleared it.

Nothing to fix in the check — the diff is telling the truth about the tree.
The diagnosis to reach for: when a diff-against-trunk check flags a file you
never edited, check `git status` for an unfinished merge BEFORE reading the
finding as yours.

## Two arms that fail the same way produce a ratio that looks like a result

From yolanda's axis-B measurement (941-trcf, 2026-08-30). Three invalid
A/B measurements preceded the valid one, and every one of them OVERSTATED
the win: both arms refusing on a missing binary read as 48.8x, both failing
on missing cargo read as 15.6x, arms with different exit codes read as 24x.
The true, controlled number was 2.96x. A ratio of two failure walls is not
a measurement of the treatment — it is a measurement of how fast each arm
happens to fail.

The control that caught all three: before dividing, require BOTH arms to
have rc=0 AND identical verdict lines — the same work demonstrably done on
both sides, differing only in the variable under test. This is the A/B
sibling of record-the-evidence-not-the-conclusion: the evidence is the two
verdict lines, and the ratio is only as real as their agreement.
