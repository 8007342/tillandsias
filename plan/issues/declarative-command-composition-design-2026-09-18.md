# Declarative command composition for tests — design record, 2026-09-18

**Status**: approved by the operator 2026-09-18. Filed as orders 1252-fg9e
(Rust executor), 1252-hsrz (Lua predicate bridge), 1252-znbn (structured
assert), 1252-r72q (tree-sitter-bash lint), with 1252-qyii (SELinux, audit to
enforcement) filed alongside as its own long tail.

**The operator's framing, which is the point of the whole design**: *"We're not
trying to fix a problem, we're trying to fix the architecture so the problem
doesn't exist."*

**The settled split**: Rust owns the verbs — spawn, fds, timeouts, reaping.
Lua composes them. This is NOT a compromise between two proposals; each layer
gets what it is actually good at, and it preserves 920-pxg6's division intact.

The forge constraint is what makes the dynamic layer a REQUIREMENT rather than
a convenience: an agent inside the forge cannot recompile the host binary, so
if predicates are Rust, a forge agent cannot validate a spec it just wrote, and
the runtime-verifiable-obligation vision is unreachable from where most of the
work happens.

Three constraints held firm, each with a reason that cost something to learn:

1. **argv, never shell strings.** `run{"git","status"}`, never
   `run("git status")`. Deletes quoting, word-splitting, globbing and injection
   as a CLASS — and is exactly what bash cannot offer.
2. **`sh` withheld from the cacheable predicate class**, so purity is enforced
   by symbol absence rather than documented. A cached impure predicate is a
   green gate that ran nothing.
3. **No claim of SELinux containment** until SELinux is enforced and tested.
   Asserting it today would recreate the phantom that the 920-pxg6 audit
   deleted from lua_runtime.rs.

What follows is the measurement the design rests on, recorded so nobody
re-derives it — including the parts where the first measurement was WRONG.

---


Host macuahuitl, 2026-09-17. Every number below was measured on this
checkout at `db759e84d`; none is estimated.

## 1. The defect surface is composition, and it is large

`find -L scripts -name '*.sh'` → **669** scripts. Whole-file co-occurrence
of each hazard shape (an UPPER BOUND — co-occurrence in a file is not proof
that the specific pipeline runs under that option):

| shape | files | what it costs |
|---|---|---|
| `pipefail` + `\| grep -q` | **195** | verdict inverts: SIGPIPE kills the producer, `rc=141` reads as "no match" |
| `\| tail -1` | **65** | discards the guard's reasoning and remedy |
| `if ! <pipeline>` | **27** | 795-imz3: pipefail+SIGPIPE can invert the guard |
| `pgrep\|pkill -f` inline | **7** | self-match; the sweeper's own argv carries the literal (exit 144) |

**The inversion is deterministic, not intermittent.** Over a 200,000-line
input whose first line matches, `sed … | grep -q` under `pipefail` returned
`rc=141` and reported NO-MATCH on **5 of 5** trials while the string was
present 200,000 times. Capture-then-match returned the correct verdict 5/5.
Reproducer: `poc/01-demonstrate-inversion.sh`.

This matters for how the fix is framed: at small inputs the producer finishes
before `grep -q` exits and the bug is invisible, so a guard can be green for
months and flip the day its corpus grows. That is the shape that bit
`check-seam-writers-canonical.sh` this session.

## 2. The prose-vs-enforceability gap is REAL but ~30x smaller than it looks

2,541 litmus steps carry a `command:`. First cut said 89.6% were
unenforced prose. **That was wrong** and the correction matters:

| adjudicated by | steps | enforceable? |
|---|---|---|
| verdict-prefixed literal (`ok:`, `PASS:`, `refused:` …) | 1,622 | yes — `grep -Fqi` literal |
| other short literal (≤60 chars) | 580 | yes |
| `success_pattern` regex | 85 | yes |
| exit code only (no pattern declared) | 180 | weak but honest — strict-exit since order 267 |
| **contains the word "succeeds"** | **64** | **NO — collapses to exit code, rest of sentence discarded** |
| long English sentence (>60 chars) | **10** | **NO — 4 of them assert timing ("~10 minutes") nothing can check** |

So the gap is **~74 steps**, not 2,276. The corpus self-selected toward
verdict tokens because the fallback is strict (`grep -Fqi`, then `return 1`).

**But the mechanism underneath is the real finding.** `behavior_matches_output`
in `scripts/run-litmus-test.sh` is a **natural-language interpreter written in
bash `case` arms**: `*"multiple"*` and `*"several"*` mean "grep the first
integer out of the output and require ≥2"; `*"succeeds"*` means "ignore the
output, honour the exit code"; `*"cargo"*` means "grep the output for cargo".
Rewording an English sentence silently changes the adjudication rule. Order
868-p8xi is already a scar from this: an expectation written as `(a|b)` is
matched VERBATIM and can never pass.

That is the thing worth killing, and it is a far smaller and sharper target
than "rewrite piping".

## 3. The hard constraint: 920-pxg6 forbids exactly the proposed design

`crates/tillandsias-plan/src/lua_runtime.rs` nils out `os.execute`,
`io.popen`, `io.open`, `require`, `dofile`, and `debug`. Its header states
the division of labour the 920-pxg6 audit established:

> Lua owns TIER CLASSIFICATION, VARIANT TRIMMING, and COLLECTION DEDUP —
> deterministic data-in/data-out scripts. Rust owns everything with
> consequences.

A `run()` bridge in Lua is "everything with consequences" moving into Lua,
against a deliberate and recently-audited line. The same header warns: *"Do
not re-promise a stronger sandbox here without implementing one — that
phantom claim is what the 920-pxg6 audit removed."*

**The design survives by inverting which side executes.** Lua (or YAML)
DECLARES the flow; Rust OWNS spawn, capture, routing and adjudication. That
is the podman precedent done properly — `crates/tillandsias-podman` is Rust,
and callers describe intent. It keeps 920-pxg6 intact and is the stronger
architecture anyway.

## 4. What the layer fixes, and what it does not

Of the ten defects that cost time this session:

**Fixed by construction** (6): SIGPIPE verdict inversion (no OS pipe between
stages); `set -e` assignment exit (status is a value); options not
propagating into a child `bash -c` (the layer owns the invocation);
`if ! <pipeline>` (no control flow from pipelines); `tail -1` discarding
stderr (stdout/stderr captured separately); `pgrep -f` self-match (pattern
assembled inside the callee, never in the caller's argv).

**Untouched** (4): the litmus YAML indentation defect that actually reddened
the release gate; command-position-vs-argument-position when patching YAML;
the `head -8` over a 12-item list; the regex that clipped `920-cluster`.
Those are data-format and enumeration defects. **The layer would not have
saved the release gate this session** — worth saying plainly, because the
proposal's motivating incident is in the untouched column.

Demonstrated on this host, `poc/02-properties.sh`, all five green:
P1 verdict cannot invert · P2 stdout/stderr separate · P3 status is a value ·
P4 swept pattern never in caller argv · P5 every refusal carries an affordance.

## 5. "Atomicity" is the wrong word and it will mislead

A shell command cannot be made atomic by wrapping it; `rm -rf` has committed
before any wrapper sees a status. What IS deliverable:

- **complete observation** — you get a whole Result or an error, never a
  half-read stream (this is what the layer actually provides);
- **declared idempotence** — a step marked pure may be re-run;
- **compensation** — an explicit undo hook, which is not rollback.

In a tree that gates releases on these scripts, a future reader who believes
"atomic" means "a failed step left nothing behind" will skip a cleanup that
matters. Name it `observe`/`complete`, and reserve "atomic" for things that
are.

## 6. Deterministic validation: tree-sitter-bash, NOT shellcheck

Measured: **shellcheck is absent on this host AND inside the
`tillandsias-builder` toolbox.** A shellcheck-based gate is a
green-on-one-regime hazard the moment it is wired — it would pass where it is
installed and skip silently everywhere else.

`crates/tillandsias-litmus-rust` already depends on `tree-sitter 0.25` and
`tree-sitter-rust 0.24`, and already runs declarative `rust_queries:` out of
litmus YAML (`processor: syn | tree_sitter`, with `required:`, `usage:`,
`score:`). **427 litmus files carry `rust_queries`; exactly 1 does. Zero
carry any bash equivalent.**

So this is not a new paradigm for the tree — it is an existing one that
covers Rust and does not cover bash. Adding `tree-sitter-bash` as a vendored
crate dependency travels with the build, needs nothing on the host, and
extends a pattern that already has a landing shape.

The four hazards in §1 are all detectable on a bash AST: a `pipeline` node
whose last command is `grep -q` inside a file that sets `pipefail`; a
`command` node `pgrep`/`pkill` with `-f` and a string literal argument; an
`if` whose condition is a negated pipeline; a pipeline ending in `tail -1`.

## 7. Recommended sequencing

1. **Rust `Cmd`/`Result`** — argv not shell strings; stdout/stderr separate;
   status a value. Small, no new language surface.
2. **Kill the keyword interpreter.** Replace `behavior_matches_output`'s
   `case` arms with a structured `assert:` block. Migrate the **74** soft
   steps first — they are the ones with no teeth today.
3. **`tree-sitter-bash` lint, advisory first.** Per the hermetic-fixture
   lesson: stage it advisory, watch one in-situ run, then gate.
4. **Lua declares, never executes** — and only once 1 and 2 are load-bearing.
5. **Migrate on touch**, exactly as the operator ruled for redb. A 669-script
   sweep is how a second substrate appears that the gate does not run.

The honest expected value: this removes a class that cost ~6 defects in one
session and is latent in up to 195 files. It does not address the data-format
class, which is what actually broke the release tonight.

## 8. A live instance, found while this document was being written

The 2026-09-18 release gate came back rc=1 with litmus `PASS: 368, FAIL: 0`
and exactly one red: `tillandsias-plan`'s
`groundtruth::tests::the_spec_engine_stamps_the_index_frame_not_the_readers_head`,
panicking inside `resolve_podman_bin()` in `crates/tillandsias-podman/src/lib.rs` —

> `TILLANDSIAS_PODMAN_REFUSE_REAL=1: refusing to resolve the REAL podman —
> TILLANDSIAS_PODMAN_BIN is unset at resolution time.`

**It is a transfer failure, and the fix is 36 lines away.**

- `scripts/local-ci.sh`, the `cargo test --workspace --lib --no-fail-fast` invocation:
  tripwire ARMED (via `run_rust_test_on_host`), **no seat**, parallel.
- `scripts/local-ci.sh`, the `-p tillandsias-headless --bin tillandsias` invocation — `env TILLANDSIAS_PODMAN_BIN=/bin/false cargo
  test -p tillandsias-headless … --test-threads=1`: **seated and serial.**

The comment above line 1235 records the measurement that earned the seat
(1022-y7kc cause 12): *"13 tests never seat a fake podman themselves and only
ever passed on a seat leaked by a parallel neighbour."* That lesson was
learned, measured, and written down at one call site. Its sibling — the one
that runs the other 331 tests — never got it.

**A correction to tonight's own filing.** I filed this as intermittent
(1242-4x53) on the strength of it passing standalone. It does not. With the
tripwire armed it fails standalone, deterministically, in 0.01 s; seated with
`/bin/false` it passes in 0.01 s. What I had actually observed was it passing
without `TILLANDSIAS_PODMAN_REFUSE_REAL=1` — the variable I had not
controlled. The distinction is not academic: an intermittent gets retried, a
deterministic failure gets fixed, and filing it wrong would have sent the next
host into a retry loop.

**Why this belongs in this document.** `TILLANDSIAS_PODMAN_BIN` is a
process-global seam that every call site must handle correctly and
independently. Nothing reports "this correct idea is absent 36 lines away."
That is the same failure mode as the 195 `| grep -q` sites: the knowledge
exists, it is written down, it is measured — and it does not travel. An
idiomatic layer does not make engineers better at transferring lessons; it
removes the need to, by owning the seam in one place. That is the strongest
argument for the proposal, and it arrived by itself while the case for it was
being written.
