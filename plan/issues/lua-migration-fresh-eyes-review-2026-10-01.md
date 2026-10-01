# Lua migration: fresh-eyes review (1525-ajtc)

Reviewed 2026-10-01 against `origin/linux-next` `b24677d85` and the folded
ledger, not the 2026-09-29 handoff's stale refs. This is an independent review
of `openspec/changes/lua-command-runtime-and-policies/`, its draft durable
specs, and the current implementation. The operator's Direction remains local
forge experts; these findings concern the command/policy layer those agents
will use. No implementation is claimed here.

## Findings, ordered by consequence

### 1. A malformed policy seed discards *all* project restrictions while the door still runs (confirmed)

`command_policy::load_seed` returns `None` for any parse, validation or
cannot-loosen error (`crates/tillandsias-plan/src/command_policy.rs`,
`load_seed`). `decide` then falls through to `ok:policy:allow:default` for an
unmatched command (`command_policy::decide`). `run_verb::execute` ignores the
load verdict and spawns on that allow (`crates/tillandsias-plan/src/run_verb.rs`,
`execute`).
Read-only reproduction on this tree:

```
./target/release/tillandsias-plan policy eval --root . --seed /dev/null -- printf safe
# stderr: refused:policy-seed:invalid:not-a-mapping
# stdout: ok:policy:allow:default; exit 0
```

The built-in floor still denies its named families, so this is **not** an
observed floor bypass. It *does* discard an otherwise deny-by-default seed or
every project-specific deny if one unrelated rule becomes invalid. The design
calls the fallback “fail closed” (`design.md`, Decision 4 and Risks / Trade-offs), but that is
true only relative to the floor, not the project's effective policy.
**Next action:** policy owner `1443-isrk`: distinguish an absent seed from a
present-but-refused one at every door; refuse evaluation/spawn or retain the
last validated seed on failure. Pin a scratch project with `default: deny`,
then corrupt one rule and show an unmatched argv cannot become allowed.

### 2. A read-only `policy eval` can consume an operator's one-use token (confirmed by call graph)

`policy eval` calls `evaluate` in `main.rs` (`run_policy`); `evaluate` calls
`resolve_consent` outside `cfg(test)` (`command_policy.rs`, `evaluate`), which
calls `consent_consume` and atomically renames/deletes a matching token
(`command_policy.rs`, `consent_consume` and `resolve_consent`). `policy eval`
never spawns the command. The spec
requires consumption by the *first use* of the approved run
(`openspec/specs/command-policies/spec.md`, “Consent is per run”), and the code comments
assert “a decision that is acted on,” which the eval-only caller is not.
No real consent was minted or spent in this review.
**Next action:** consent owner `1443-9f5w`: make `eval` inspection-only
(`decide` plus an unspent-token availability result) and reserve spend for
the execution door's immediately preceding decision. A fixture with an
isolated consent dir should grant one `workspace-destroy` argv whose target
is an empty scratch directory, query it twice, then show the *first actual
run* alone spends it; never exercise a real reset/push in the fixture.

### 3. Fixture scope is a recognizer, not a boundary around arbitrary children (confirmed)

`fixture_decide` recognizes `gate-stamp.sh write`, `git update-ref|push` on
the real git dir, and `rm` only when it targets that dir
(`command_policy.rs`, `fixture_decide`). Its `rm` arm passes an **empty** roots
list (`fixture_decide`'s `rm` branch); `fs.write`/`fs.mkdir` have their own
rooted guard (`lua_predicate.rs`, `fixture_write_guard` and
`register_fs_write_verbs`). The runner exports the fixture regime and scope
(`scripts/run-litmus-test.sh`, critical-path step dispatch), but a spawned arbitrary executable
can write directly to the filesystem. Read-only policy evaluations with
`TILLANDSIAS_FIXTURE_SCOPE=/tmp/opencode/allowed` both returned
`ok:policy:allow:default` for `rm /tmp/opencode/outside-scope-example` and
`git -C /tmp/opencode/outside-repo commit -m x` (nothing was executed).

The draft spec says *write-shaped argv* outside scope is refused
(`openspec/specs/command-policies/spec.md`, “Filesystem scope under the fixture regime”); current implementation
does not establish that for arbitrary commands. It already honestly notes
that a Bash step is not an argv the engine sees (`command_policy.rs`, fixture
scope module header).
**Next action:** `1443-fpck` (ready at review time): narrow the spec to the
enumerated recognized forms **or** enforce a real filesystem boundary for
untrusted children. In either case add negative controls for a nonrecursive
outside-scope write and a child that invokes a writer without an argv
recognizer; preserve the existing real-git-dir negative control.

### 4. The measured deny-default transition has no active decision path or coverage floor (confirmed gap)

`DefaultPolicy::DenyAfterQuietDays` is parsed (`command_policy.rs`,
`DefaultPolicy` and `parse_seed`) but `decide` treats it as allow. `policy show`
explicitly prints `not active` (`main.rs`, `run_policy`). The draft spec requires
the fourteen-day flip (`openspec/specs/command-policies/spec.md`, “A built-in
floor that a project seed can only tighten”), while `tasks.md` §1 and §2
remain unchecked even though `1443-isrk`, `1443-w9hf`
and the bridge are marked completed in the folded ledger. `bash_policy::status_counts`
reads totals from whatever audit exists, with no daily volume or continuity
test (`bash_policy.rs`, `status_counts`); `classify-bash --status` prints the
condition but does not adjudicate it (`main.rs`, `run_classify_bash`). An inactive bridge could
look “quiet” if the flip were implemented by counting only zero denies.
**Next action:** policy/default-flip owner: make this an explicitly open
criterion rather than treating closed component rows as proof; define the
minimum observed per-day bridge volume/coverage and missing-log behavior,
then test inactive, missing-day, and one-deny-reset cases before enabling a
deny-default transition. This review does **not** recommend a new value for
the operator-approved 14-day duration.

### 5. The agent JSON door hides the number of dropped bytes and is lossy for non-UTF-8 output (confirmed)

`tillandsias_exec::Output` carries `dropped` and raw byte vectors
(`crates/tillandsias-exec/src/lib.rs`, `Output`). Lua `proc.run` returns Lua
strings from those bytes *and* `dropped` (`lua_predicate.rs`, `proc_run`). The
agent door's `outcome_json` returns `truncated` but omits `dropped` and
serializes both fds with `String::from_utf8_lossy`
(`run_verb.rs`, `outcome_json`). A harmless read-only probe,
`tillandsias-plan run --json --capture-bytes 1 -- printf ab`, returned
`"truncated":true,"stdout":"a"` without a `dropped` field. The draft
runtime spec promises `dropped:<bytes>` (`openspec/specs/command-runtime/spec.md`,
“Time and output are bounded”) and “the same result shape” for every door
(“A result is typed and carries its run identity”). This is a gap in the
JSON door, not a claim that the Lua door loses byte identity.
**Next action:** `1443-8pur` / runtime owner: include `dropped` and document
an unambiguous byte encoding (or a separate raw-byte route) for stdout/stderr;
compare two payloads differing only in invalid UTF-8 and a >cap payload
across Lua, CLI JSON, and MCP before declaring cross-door parity. Also align
the spec's status vocabulary with live `no_status` and `policy_consent`.

### 6. Derived branch discipline can regress when a rolling observation disappears (conditional)

The seed's *declared* level cannot drop below `published_level`
(`branch_discipline.rs`, `parse_seed`/`published_level`), but `derive` uses
`COMMIT_WINDOW` (50 commits) and the current count of origin work refs.
`at_enforcement` downgrades an enforced rule to a warning whenever its
qualifier is observed absent (`branch_discipline.rs`, `at_enforcement`). If the stray sweep deletes the
last work ref or the two host identities age out of that 50-commit window,
level-2 ref-grammar enforcement can turn off even with an unchanged level-2
seed. That is a **conditional inference from the code**, not an observed
production regression. The draft design promises forward-only levels
(`openspec/changes/lua-command-runtime-and-policies/design.md`, Decisions 11
and 16).
**Next action:** `1446-664f` owner: pin a durable *maximum observed* level,
distinct from today's diagnostic window, or obtain an operator ruling that
enforcement may deliberately decay. A scratch git repo should prove the
verdict before/after deleting its only work ref and after aging the host
commits beyond 50, with unchanged seed bytes.

## Corrected assumptions and boundaries

- The 2026-09-29 handoff's “host-kind env plus marker” concern was overtaken:
  `read_host_kind_from` now requires the forge image in `/run/.containerenv`,
  treats another container as bare metal, and reports disagreement
  (`command_policy.rs`, `read_host_kind_from`). Do not re-file the old marker-only claim.
- The handoff's blanket “fixture scope missing” is obsolete: `1443-fpck`
  code now guards the Lua fs verbs and known git-dir writers; finding 3 is
  the remaining boundary, not absence of an implementation.
- `script run` and three Lua decider pilots have landed (`1384-bqhy` and
  `1384-ddua` completed); `1384-bxhk` is claimed elsewhere. The unchecked
  OpenSpec tasks (`tasks.md`, “First usable vertical slice” and “Migration
  instruments”) are not a reliable progress report.
  `1375-amye` is awaiting Mac evidence; no work on its run verb or gate loop
  is claimed here. The raw `lua --unsandboxed` option still exists
  (`main.rs`, `run_lua_cli`) by explicit opt-in; the bridge is Claude PreToolUse,
  while other Bash doors remain. That is migration exposure, not evidence of
  a bypass of an enforcement boundary already promised to be universal.
- Forge-safe verification: Rust/Lua unit tests, policy `eval` on scratch
  seeds, source/JSON comparisons, and fixtures wholly rooted in a scratch
  checkout. Host-only verification: real Podman/Vault/mirror pre-receive and
  consent, macOS `getsid`/setsid vs setpgid, native Windows job/external-kill,
  and destructive e2e. No host-only or destructive check was run for this
  review. The read-only evals above did not execute their argv.

## Routing

These are review findings, not additional claims on the named implementation
rows. Ask the coordinator to triage findings 1–3 as distinct tests/fixes before
raising enforcement; schedule 4 with the default-flip owner, 5 with the
cross-door parity owner, and 6 with branch-discipline governance. Each proposed
negative control states what would falsify the concern. No changes to
`build.sh`, land tooling, hooks or `.claude` are requested by this packet.
