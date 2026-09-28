# Lua shell consolidation: measured families and a bounded first slice

Order: **1475-j9kv**. Packet: `lua-source-agreement-consolidation-shadow-pilot`.
Research only, Codex on macuahuitl, 2026-09-28. Source snapshot:
`2b14460571e3d1d5b2f1f4d883c225dafb6057d0` (`origin/linux-next`).
The packet below this research is implementation work for **Terra or Sol**;
this research does not implement it or claim it on their behalf.

## Finding

Consolidate the repeated test/guard machinery into a few Lua evaluators plus
explicit case data. Merely translating one shell file into one Lua file removes
shell failure modes but preserves the file count and duplicated scaffolding.
The largest pool is tests and guards; the safest first family is checks that
read a small, explicitly named set of source files and compare declarations.

There is **no measured basis for promising removal of most shell scripts in one
low-risk sweep**. Tests plus deciders account for 623/860 scripts (72.4%), but
only 234 of those are at most 120 physical lines. Shortness is a screening
criterion, not proof of simplicity: a 24-line fixture builds a policy binary;
a 59-line fixture starts a Podman image. Start with three inspected guards and
their fixture, then measure which families actually fit the shared evaluator.

This extends, rather than duplicates, the designs under 1384-aixy and
1443-6r3q and the completed 1459-mqvd Bash breakage census. Those already own
the interpreter choice, command policies, runner, shell ratchet, risky decider
pilots, and landing-tool conversion. This report contributes a current file
census, a consolidation strategy, and an independently executable shadow pilot.

## Reproducible population

The accompanying `lua-shell-consolidation-inventory-2026-09-28.tsv` records
every tracked `scripts/**/*.sh`: path, family, physical lines, SHA-256, and a
`lines <= 120` flag. It is a dated measurement, not a live ratchet floor.
Families are disjoint, classified by basename: `test-*`, then
`check-*|verify-*|guard-*`, then other. Untracked and generated files are excluded.

| Population at the source snapshot | Files | Physical lines | At most 120 lines |
|---|---:|---:|---:|
| All tracked `.sh`, repository-wide | 961 | 188,535 | not measured here |
| Under `scripts/`, recursively | 860 | 162,170 | 329 |
| Test fixtures in `scripts/` | 465 | 77,970 | 154 |
| Deciders in `scripts/` | 158 | 29,062 | 80 |
| Other scripts under `scripts/` | 237 | 55,138 | 95 |
| Under `images/`, recursively | 84 | 20,566 | not measured here |

There are 131 `.step` descriptors, 15 tracked Lua files repository-wide, and
six under `scripts/` (archiver, determinism fixture, three CentiColon scripts,
one pre-push hook). `.step` data, extensionless executable wrappers, PowerShell,
and YAML `command:` strings are **outside** the `.sh` denominator. Moving shell
into one of those locations must not be credited as removing shell execution.

Reproduce the inventory at the source snapshot with this one-off read-only
Node command; Node is an audit tool here, not a proposed runtime dependency:

```javascript
const fs = require('fs'), cp = require('child_process'), crypto = require('crypto');
const paths = cp.execFileSync('git', ['ls-files', '-z', 'scripts'], {encoding:'utf8'})
  .split('\0').filter(p => p.endsWith('.sh')).sort();
console.log('path\tfamily\tlines\tsha256\tshort_le120');
for (const p of paths) {
  const b = fs.readFileSync(p), s = b.toString('utf8'), base = p.split('/').pop();
  const lines = s.split('\n').length - Number(s.endsWith('\n'));
  const family = /^test-/.test(base) ? 'test'
    : /^(check-|verify-|guard-)/.test(base) ? 'decider' : 'other';
  console.log([p, family, lines, crypto.createHash('sha256').update(b).digest('hex'),
    Number(lines <= 120)].join('\t'));
}
```

## Runtime that exists, versus design that remains

Source anchors are symbols, so line movement does not invalidate them:

| Available now | Source and limits |
|---|---|
| Embedded Lua 5.4 | `crates/tillandsias-plan/Cargo.toml`: mlua `vendored,lua54,send,serialize`; `Cargo.lock`: mlua 0.10.5, lua-src 547.0.0. No installed `lua` executable required; building the vendored C library requires a C toolchain. |
| Two predicate environments | `lua_predicate.rs::build_environment_logged`: Cacheable has no process or clock; Observing has both. This is distinct from `lua_runtime.rs::LuaRuntime::new`, the expert pipeline's older, partially restricted trusted-code VM. Do not use that older VM as the new script host. |
| Explicit reads and assertions | `fs.read` is repository-rooted; `expect.contains`, `expect.matches` (Rust regex, assertion only, no capture API), `expect.eq`. Lua string patterns and Rust regex are different languages; do not mechanically translate grep BRE/ERE syntax. |
| Data helpers | `lua_std.rs::register`: `json.parse/encode/query/array`, `yaml.parse`, `hash.sha256`, lexical `path.join/normalize/basename/dirname`; Observing adds `time.now_ms/iso_utc`. No `yaml.encode` or `time.monotonic_ms` here. `json.query` is the project's subset, not arbitrary jq. |
| Deterministic encoding helpers | `lua_std.rs::determinism/canonical`: sorted iteration/encoding, `table.keys/is_empty`, withheld `next` and `os.setlocale`. Preserve empty-array markers, nulls and numeric behavior when porting structured data. |
| Observing filesystem operations | `register_fs_write_verbs`: rooted `fs.mkdir/write/list/exists`, symlink containment checks and fixture-write guard. `fs.list` lists regular immediate children, excludes symlinks/directories, and returns existence separately. It is explicitly unstable, observing-only and unsuitable as a cached hard-test population. |
| Bounded argv execution | `lua_predicate.rs::proc_run`, `tillandsias_exec::Command`: argv, cwd, explicit environment additions, stdin bytes, timeout, group, capture bound; stdout/stderr, typed completion, run identity, truncation. `policy_gate` evaluates command policy before spawning. `sh.run` is an older compatibility surface with different error/output handling; new process consumers should use `proc.run`. |
| CLI | `main.rs::run_lua_cli`: `lua --class cacheable|observing`, default observing; sandbox escape is explicit `--unsandboxed`, unnecessary for this proposal. Lua chunk return values are printed; a returned `false` is not a process failure. Errors exit nonzero, but this is not the planned typed verdict runner. |

Read-only probes of the installed instrument (`build-id
0.1.0+5ca56d1790ed4656`, not represented as a build of the snapshot) agreed with
the source inspection: Cacheable reports `fs.read=function`, `fs.list=nil`,
`proc=nil`, `time=nil`; Observing reports `proc.run=function`,
`proc.spawn=nil`, `fs.list=function`; both report `verdict=nil`, `text=nil`.
`capabilities` has `lua`, `predicate`, `run`, but no `script`.

Still unimplemented in this snapshot: `script run`, `verdict.*`, `text.*`,
declared-script `env.*`, `proc.spawn` callbacks, and `STEP_LUA` dispatch.
`build.sh`'s gate-step loop requires `STEP_SCRIPT` and invokes Bash.
The 2026-09-26 sketches use recursive `fs.list` even though the later operator
ruling in `register_fs_write_verbs` explicitly forbids that model for hard
tests. Use explicit source paths for this pilot. A future population-wide
scan needs a separately justified Observing inventory, never a disguised pure
predicate.

Cacheability is also not proof of cache correctness. Open **1470-dbuw** records
source-replacement invalidation and read/digest races; **1471-bvjy** owns exact
structured replay. Run the pilot uncached through a fresh Cacheable environment.
Do not claim a cache speedup or monotonic uncertainty guarantee from this port.

## Families ranked by leverage and risk

1. **Pure source/data agreement checks and fixtures.** Inspect the 80 short
   deciders and 154 short test fixtures first. These are candidate bounds,
   not 234 approved ports. Three directly inspected examples below replace
   repeated root discovery, grep/sed/head/tr pipelines, accumulator variables
   and fixture boilerplate with one evaluator and explicit cases. They require
   no process API, network, live container, new parser or filesystem writes.
2. **Fixture scenarios expressed as data.** This is the route to removing a
   large part of the 465 test scripts, where their behavior fits common
   read/transform/assert or execute/assert operations. Preserve each scenario
   and negative control; one shared runner must still report every case ID.
   Counting a suite as one check would over-credit coverage. Process fixtures
   need the typed runner and isolated scratch lifecycle before migration.
3. **Thin dispatch and retired scripts.** Only 22 files have at most ten
   nonblank, noncomment lines, and several are intentional bootstrap or
   adversarial process fixtures. `test-forge-findings-persisted.sh` and
   `test-mo-full-attest.sh` merely dispatch a fixture mode; `small_test.sh`,
   `local_test.sh`, `large_test.sh` dispatch Cargo; four files print retirement
   notices (`bind-provenance-local-paths`, `refresh-cheatsheet-sources`,
   `regenerate-source-index`, `deferred-specs`). Audit consumers and delete or
   route directly where appropriate. They do not need a new Lua file each.
4. **Repository scans and structured-ledger tools.** High repeated cost but
   more semantic risk: `check-unique-bin-names.sh` parses Cargo TOML with awk;
   `check-vault-cli-gate-coverage.sh` extracts Bash case arms;
   `cycle-metrics.sh` reads telemetry; ledger tools must preserve the folded
   CRDT view, not replace `tillandsias-plan` queries with raw YAML reads.
   No TOML parser is exposed to Lua today. Prefer an existing Rust semantic
   query where present; do not build another parser in Lua to inflate removals.
5. **Lifecycle, credentials, installers and live infrastructure.** Keep outside
   this pilot: the 84 image scripts, toolbox/WSL dispatch, lock/signal/PTY code,
   credential exchange, installers and git transport. Lua can orchestrate these
   later, but OS operations still belong to Rust and policy-owned host APIs.
   The existing landing-tool port 1443-u66u owns that risky surface.

The short-file trap is observable: `test-forge-policy-binary-discoverability.sh`
(24 lines) builds a binary into a custom target; `test-forge-standard-gitconfig-path.sh`
(59) needs a built image; `test-headless-env-lock-is-single.sh` (70) runs ten
stress rounds. They are not pure predicates just because they are short.

## Bounded implementation program

**Phase 1 — ready now, the only newly filed implementation packet.** One
shared pure evaluator, explicit case manifest and Rust integration fixture for:

| Existing script | Lines | Semantics that must survive |
|---|---:|---|
| `check-tray-process-running-naming.sh` | 68 | Reject the two old declarations; require the new field; historical prose is allowed; missing source is failure. |
| `check-dev-embed-model-agreement.sh` | 74 | Extract two model defaults and compare; missing extraction cannot equal missing extraction and pass; preserve its three selftest cases. |
| `check-inference-container-name-agreement.sh` | 74 | Creator name must belong to the consumer candidate list; a prose mention is not membership; missing declarations are blocked. |
| `test-inference-container-name-agreement.sh` | 117 | Preserve six existing arms, including mutated disagreement, prose-only match, missing assignment, live-tree arm and actual gate reachability. |

That is **four shell files / 333 lines** eligible for a later atomic deletion,
not four removed by the shadow pilot. The ready packet produces the shared
evaluator and executable parity evidence; it leaves production guards active.
Three file sets, one table of cases, zero external child processes in the pure
evaluator. No general-purpose regex DSL, dynamic directory walk or new runtime
module loader. The Rust harness may inject fixture input and load the Lua
chunk through the existing API, keeping file discovery/writes in the harness.

**Phase 2 — cutover after the existing runner lands.** Attach a follow-up slice
to **1384-bqhy**'s completed runner contract, preserving guard status/diagnostic
contracts and per-case evidence. Update all executable callers and remove the
four `.sh` files in the same change; no wrapper may remain counted as deleted.
Update the one `.step` and the direct `build.sh` calls together. Existing
**1384-bxhk** owns the population ratchet; reuse its register rather than
creating a competing floor. **1384-ddua** keeps its three incident-focused
pilots (seam writers, preflight, Bash dialect); this packet does not claim them.

**Phase 3 — fixed batches of ten reviewed cases.** Re-inventory the 234 short
test/decider candidates. Assign explicit eligible/excluded reasons and
dependencies. File a packet per family only when at least three share an
evaluator and their callers are known. Record `E`, the reviewed eligible
population; a claim to remove its majority requires deletions `> E/2` with no
lost scenarios. A majority of all current `scripts/**/*.sh` would require at
least 431 actual deletions; this research does not establish that opportunity.

**Phase 4 — later, already owned elsewhere.** Typed process fixtures and litmus
steps (902-5bf9), build orchestration (1384-j3cv), landing tools (1443-u66u),
then image entrypoints after provisioning the binary. Each phase earns its own
cross-platform evidence; completion of Phase 1 must not close these rows.

## Validation, measurement and rollback

- Execute old guards on scratch copies and new evaluator on the same inputs.
  Compare verdict class, payload and expected exit meaning; include missing
  files, absent declarations, mismatches, comments containing obsolete names,
  empty inputs, CRLF and paths containing spaces. Pin observed disagreements
  as findings; do not silently preserve a known false pass for parity's sake.
- Inject each deliberate defect independently. The suite must report a failing
  named case; an empty manifest, duplicate case ID, unknown operation, malformed
  input or absent Lua module must never report a clean pass.
- The pure environment must lack `proc`, `sh`, `time`, writable/listing `fs`
  operations. Run fresh, uncached environments; directory membership and
  environment variables are not hidden inputs. Both test reads and case data
  must be explicit. Missing evidence contributes no earned obligation.
- Measure at least 30 warm runs after an uncounted warmup, pairing old and new
  in alternating order on the same host/tree. Report median and p95 wall time,
  process count, checked cases and bytes read. Include cold binary startup
  separately. Propose p95 no worse than 110% of the old suite as the cutover
  criterion; do not label Lua faster before measuring it. The pilot needs zero
  child processes for evaluation, although its comparison harness runs Bash.
- Run targeted Rust tests (assert a nonzero selected test count), the bound
  litmus tests when callers change, and `./build.sh --check` before any push.
  Linux first; require macOS and native Windows events before fleet-wide
  cutover. Test native `tillandsias-plan.exe` rather than assuming WSL proves
  Windows; record an unavailable lane honestly.
- Track shell files deleted, shell LOC deleted, surviving stubs, child process
  count, exact case count and failures separately. Adding Lua is not removal;
  a faster run that skips a case is not an improvement. Keep the obligation
  denominator and case IDs fixed during comparison so uncertainty cannot fall
  just because obligations were dropped.
- Phase 1 rollback is simply reverting its isolated evaluator/fixture change;
  old guards still decide. Phase 2 must be one reversible commit with all
  caller updates, deletions and ratchet changes. On parity failure or missing
  runner, stop cutover. After cutover, revert that whole commit and reconcile
  the ratchet with an explicit regression event; do not retain silent runtime
  fallback or use `--unsandboxed` to get a green result.

## Bootstrap and portability boundaries

Keep the binary bootstrap shell and binary resolver until the plan executable
can be guaranteed on a fresh checkout/image. The binary cannot bootstrap its
own toolchain. The isolated Linux toolbox, macOS host tooling and Windows/WSL
builders remain the compiler boundaries. Vendored Lua removes a host interpreter
dependency; it does not remove Cargo/C or make process/environment semantics
identical. Source-resolved scripts require shipping the Lua/data files with the
checkout and failing clearly on a missing or incompatible runtime.

Cacheable `fs.read` roots to the repository; use fixture roots, never temporary
absolute paths outside that boundary or writes to the live ledger. Windows
paths and symlinks must go through existing path and filesystem APIs. Byte and
newline controls remain necessary. Do not reimplement locking, signals, process
groups, git state, YAML folding or credential mutation in Lua. POSIX hook stubs
and image startup before the plan binary exists have a legitimate residual.

## Coordination and evidence boundary

Executed baseline in the isolated `codex1448` container, from this worktree:
`ok:tray-process-naming:3 checked`,
`ok:dev-embed-model-agreement:nomic-embed-text`,
`selftest:dev-embed-model-agreement:3 cases PASS`,
`ok:inference-container-name-agreement:tillandsias-dev-inference`, and
`PASS: inference-container name agreement 6/6 (967-6ax6)`.
An independent readback checked all 860 inventory hashes and line counts:
860 verified, zero mismatches. `tillandsias-plan check --strict-fragments`
accepted 1,295 packets; `check-packet-tier-declared` and fragment timestamp
checks passed. Cross-branch claim check found no competing claim across three
sibling branches. No timing comparison or new Lua evaluator was executed.

Branch discipline was fetched and verified as effective level 2; work ref
`work/1475-j9kv` carries only this report, inventory and packet. No runtime or
script implementation was edited. No implementation claim was made. The
plan-only fragment is relayable to trunk independently of the research file.
The packet contains enough context to select it, but its worker should start
after these research artifacts are reachable on the integration branch.

Initial sibling heads: main `52e3bc32ec063c7a7090d0c8dca35bb8ade3c844`,
linux-next `2b14460571e3d1d5b2f1f4d883c225dafb6057d0`,
windows-next `b38f7105262afdd2805e947e50d126ea58a4cbfa`,
osx-next `49731c152273395cf95fd9f63249844cac707a57`.
MCP fallback reason: **unavailable** (no project-plan/project-info tools exposed).
Direction: local experts and the deterministic query engine
(`plan/loop_status.md`, operator-owned Direction); explicit operator request
adds this maintenance-reduction research. Active release is v0.5; Phase 1
does not depend on the v0.6 runner program or change its release assignment.

Publication gate results belong in the packet event/handoff, not inferred from
the runtime API probes. The first isolated `./build.sh --check` exited 101
because its `/tmp` target exceeded the user quota. The second run moved target
and scratch to `/home` and reached 2,646 workspace tests with one new red:
`spec_index::tests::the_repo_relative_rung_anchors_to_the_checkout_not_to_home`.
In `spec_index.rs::tests::the_repo_relative_rung_anchors_to_the_checkout_not_to_home`,
the test asserts its resolved fixture path is outside
HOME, although its fixture is created under TMPDIR. Choosing TMPDIR under HOME
therefore violates this fixture's environmental assumption. The corrected run keeps
the dedicated target on `/home` but moves scratch to `/var/tmp`; no runtime,
fixture, known-red baseline, host/container reset or shared builder configuration
was changed. The exact named test passes in that environment (1 passed,
396 filtered out). This is a validation constraint, not a Lua defect.

The subsequent full gate passed the 2,646-test workspace suite (zero new reds),
then refused at the shared-metrics guard while
`test-tool-materialize-litmus-surfaces-arm.sh` ran: the guard observed one new
record in `/tmp/tillandsias-timing.jsonl`. The fixture itself reported 5/5 with
one locale arm explicitly skipped. The counter does not identify the writer;
the file was absent on follow-up inspection, so this is not attributed to a
specific producer. Toolbox inspection showed host PID sharing and a host-root
mount. Publication validation was restarted in a fresh disposable builder from
the existing local builder image with private `/tmp`, a dedicated timing-log
path and the separate Cargo target. The shared-log guard remains enabled.
That timing-log override interfered with the default-discovery negative arms
of `test-metrics-log-path-agreement.sh` (15 passed, 3 failed). The final
validation configuration therefore keeps the private container PID namespace
and `/tmp`, but leaves timing-log discovery at its normal default. No guard,
runtime code, fixture or known-red baseline was edited for these retries.
