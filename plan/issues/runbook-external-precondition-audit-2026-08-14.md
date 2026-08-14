# Audit: every skill step that gates on an external command (order 601-462g)

- Order: 601-462g
- Class: `exploration/` (audit), with three fixes landed in the same commit
- Audited: 2026-08-14, linux_mutable, against `skills/*/SKILL.md` at `3e811287`

## The question

601-f6ci was one instance of a class: **a step that consults an external system
and reports success when that system has nothing to say.** For every skill step
that gates on an external command's exit status, what does the command return
when the thing it asks about is ABSENT rather than broken?

## Enumeration

`gh` = the risky family. Its list subcommands exit 0 on an empty result set, and
`--jq '.[0].x'` renders that emptiness as the literal string `null` — so both a
bare emptiness test and a bare exit-status test pass.

| Site | Command | On ABSENT | Verdict |
|---|---|---|---|
| merge-to-main §1 | `git rev-parse --abbrev-ref HEAD  # MUST be linux-next` | exits 0 on the wrong branch | **FIXED** — now `test "$(...)" = linux-next` |
| merge-to-main §1 | `git status --short  # MUST be clean` | exits 0 on a dirty tree | **FIXED** — now `test -z "$(git status --porcelain)"` |
| merge-to-main §1 | `test "$(git rev-list --count origin/linux-next..HEAD)" -eq 0` | asserts a positive fact | sound |
| merge-to-main §2 | `gh pr list … --jq '.[0].number'` | prints `null`, exits 0 → `PR #null`, then merges a PR that does not exist | **FIXED** — `scripts/resolve-open-pr.sh`, fixture 5/5 |
| merge-to-main §2 | re-query after `gh pr create` | same shape: a silently failed creation yields `PR #null` | **FIXED** — same resolver |
| merge-to-main §3 | `gh pr checks --watch` | prints "no checks reported", exits 0 | documented 2026-08-03; the runbook gates LOCALLY instead |
| merge-to-main §4 | `prev_tag=$(git tag --list … \| tail -1)` | empty, and empty is handled (`seq=1`) | sound — absence is a meaningful answer here |
| merge-to-main §6 | `gh run list --workflow=release.yml --limit 1` | prints nothing, exits 0 | advisory display only; §7 does the asserting |
| merge-to-main §7 | `run_id=$(gh run list … --jq '.[0].databaseId')` | prints `null`, exits 0 → `gh run watch null` | **FIXED 2026-08-13** — `scripts/resolve-release-run.sh`, fixture 6/6 |
| merge-to-main §7 | `gh release view "$tag"` | exits non-zero when the release is absent | sound |
| build-install-e2e §2 | `test -z "$(podman ps -aq)"` etc. | emptiness IS the asserted fact | sound — a negative assertion, not a consult |
| build-install-e2e | `(& wsl --list --quiet) -contains 'tillandsias'` | asserts membership | sound |
| smoke-curl-e2e | `podman ps -a --format …` piped to `tee` | evidence capture, no gate | advisory by construction |
| coordinate-multihost §3 | `git rev-list --count origin/linux-next..origin/<sibling>` | errors non-zero if the ref is absent | sound |
| meta-orchestration | `gh auth status` (credential guard) | non-zero when unauthenticated | sound — and the guard explicitly warns that reads succeeding is not evidence of write capability |
| meta-orchestration | `git ls-remote origin refs/heads/<b>` in the attestation | empty output cannot match the claimed SHA | sound — the comparison is the assertion |
| advance-work-from-plan §final | "verify `git status --short --branch` is clean" | prose instruction, no exit code | **residual** — see below |

## What the enumeration shows

Three of the four defects were in ONE file, and that file already documented the
class twice in its own prose. Knowing the shape did not prevent a third instance
three steps earlier in the same runbook. That is the argument for resolvers over
cautions: `resolve-open-pr.sh` and `resolve-release-run.sh` are deliberately
twins so the pair reads as one pattern rather than two fixes.

The `podman` and `wsl` sites are all sound for a structural reason worth naming:
they assert a POSITIVE fact (membership, a specific count, emptiness that IS the
requirement). The `gh` sites were unsound because they extracted a value and
then trusted it. **Extracting a value is where this class lives.**

## Residual

`skills/advance-work-from-plan/SKILL.md:368` states its final worktree check as
prose ("verify `git status --short --branch` is clean and not ahead"). It is a
real gate expressed as an instruction to an agent, not as an executable
assertion. Left as-is deliberately: rewriting it needs a decision about whether
that skill's finalization should share meta-orchestration's boundary guard
rather than growing its own check, and that is a design choice, not a fix.

---

## Round 2 (order 727-kmks): the remaining runbooks

### The measured scope was inflated ~2x, and the biggest "offender" was noise

727-kmks recorded 87 candidate sites from a grep for
`command -v|which |gh <sub>|podman|wsl`. Re-measured three ways:

| Scope | merge-to-main | meta-orchestration | build-install-e2e | smoke-curl-e2e | total |
|---|---:|---:|---:|---:|---:|
| loose grep (as filed) | 26 | 22 | 16 | 17 | 87 |
| command position only | 18 | 3 | 14 | 12 | 49 |
| **inside ```bash blocks** | **8** | **0** | **6** | **3** | **21** |

`which ` matched the English word. meta-orchestration — the runbook every host
executes every cycle, and the file the count made look second-worst — has **zero**
external-command gates in executable position; all 22 hits were prose. The three
remaining "command position" hits there are backticked mentions inside sentences.

This matters beyond bookkeeping: a 6h estimate built on 87 sites, most of which
are English, is what makes an audit keep getting deferred for being large. The
real surface is 21 executable sites in three files.

### Findings

| Site | Shape | Verdict |
|---|---|---|
| build-install-e2e §1 | `command -v tillandsias \| tee …` then `tillandsias --version \| tee …` | **FIXED** — a pipeline exits with TEE's status, so a missing binary wrote two empty evidence files and passed. The build step three lines above already captured `${PIPESTATUS[0]}`; the two probes that prove the install landed did not. |
| smoke-curl-e2e §2 | `podman system reset --force \| tee …`, then "All three should be empty" | **FIXED** — reset failure exited 0 (no `PIPESTATUS` capture) and the store check was an instruction, not an assertion. Its sibling runbook asserted both, and this is the path that tests PUBLISHED releases. |
| build-install-e2e §2 | `RESET_RC=${PIPESTATUS[0]}`; `test -z "$CONTAINERS"` … | sound — this is the shape the smoke-curl path now matches |
| build-install-e2e §2 (Windows) | `& wsl --unregister` tolerated, then `-contains 'tillandsias'` asserted | sound — absence is explicitly the tolerated case, presence is the failure |
| smoke-curl-e2e §4b | `podman ps --format … \| tee` | advisory by construction (evidence capture, no gate) |

### The pattern across both rounds

Round 1's defects extracted a VALUE and trusted it (`gh … --jq '.[0].x'` →
`null`). Round 2's extract an EXIT STATUS and lose it (`… | tee` → tee's status).
Both are the same failure at different layers: the step consulted something and
then treated the consultation as the answer. `| tee` is the more dangerous of the
two in this repo, because logging every step to an evidence file is exactly the
house style — the habit that makes the runbook auditable is the habit that
silently discards its exit codes.

### Round 2, second pass: `| tee` swallows exit codes, and that is the house style

Classifying every in-code `| tee` pipeline by whether the next three lines
recover `${PIPESTATUS[0]}` found three more live defects beyond the two above:

| Site | Was | Now |
|---|---|---|
| build-install-e2e §1·macOS | `codesign --verify --deep --strict … \| tee` | asserted — a signature failure was being written to the evidence file and then discarded |
| smoke-curl §1 | curl-install pipeline `\| tee 01-install.log` | asserted — a curl-install that failed outright exited 0 |
| smoke-curl §1 | `tillandsias --version \| tee … # must equal $SMOKE_TAG` | `grep -qF` against the tag — the clean-room test of a PUBLISHED release never once confirmed it was running the release it claimed to test; a stale binary already on PATH would answer and pass |

The remaining unguarded `| tee` lines are evidence capture with no gate
(`git rev-parse HEAD`, `du -sh`, container listings): their exit status is not a
fact anyone acts on. That distinction — gate versus evidence — is the whole
classification, and it is why a blanket "every pipeline must capture PIPESTATUS"
rule would be wrong here.

### Why no executable guard for this class (yet)

A checker for "a `| tee` pipeline whose left side is a gate" needs to know which
commands are gates, and every version of that list is a guess. Two of the three
defects above are gates only because of what the runbook does NEXT with them.
Encoding that would produce a checker whose false positives train people to
ignore it — the failure mode 731-d89b's narrowing was written to avoid. Recorded
as a known gap rather than papered over with a noisy rule.
