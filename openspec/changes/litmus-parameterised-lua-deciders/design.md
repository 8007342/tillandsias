# Design: litmus-parameterised-lua-deciders

## Context

A litmus step is one `command:` string run as `bash -c` by
`scripts/run-litmus-test.sh`, judged by `expected_behavior` containment on
its stdout (or the structured `assert_*` keys). 950 of those strings pipe a
producer into grep/awk/head/test and decide in-line. The Lua runtime
(`tillandsias-plan script run`, script_run.rs) already gives a decider
argv-only `proc.run`, repo-rooted `fs`, a Rust regex `text` table, and a
verdict grammar whose exit codes build.sh and the litmus runner read:
`ok:` 0, `refused:` 1, `blocked:` 2, `could-not-run:` 3, `skip:` 0, and a
script that returns without a verdict is `refused:no-verdict`. The runtime
nils `require`, `dofile` and `loadfile`: a decider is one file.

## Locked decisions

### D1. One script, the family is the first argument

`scripts/lua/litmus-decide.lua -- <family> [--name <n>] <options>`. The
shared library is a section of the file (`LIB`), the families a table of
functions (`FAMILIES[name]`). This needs no runtime change, so a forge whose
binary lags still runs it, and the shell ratchet counts one Lua file rather
than ten. A later `lib` loader in script_run.rs could split the file; it is
not a dependency of any slice and is not proposed here.

### D2. Every family keeps the same five rules

1. An empty population is `could-not-run:<name>:empty-population` (exit 3):
   zero tests ran, zero files under `--path`, a producer that printed
   nothing. Never ok.
2. A tool that cannot spawn is `could-not-run:<name>:tool-missing:<argv0>`,
   never a refusal of the tree.
3. Every non-ok verdict prints `why:` and `remedy:` on stderr and NAMES the
   thing: the test, the file:line, the count against its floor. A red with
   empty output is unconstructible: `verdict.*` prints, and falling off the
   end is `refused:no-verdict`.
4. Retries are bounded (`--retries N`, default 1) and TRANSIENT-ONLY: the
   producer's text must match a lock/busy pattern. A failed assertion is
   never retried; a flaky test retried to green is a false green.
5. The verdict line carries its facts (`n=`, `failed=`, `cache=`,
   `attempts=`, `matches=`, `files=`) so a reader never infers them.

### D3. Caching is keyed on tree state, not on time alone

`cargo-test` keys its cache on the cargo argv, HEAD, and the sha256 of
`git diff HEAD` plus the contents of untracked files under `crates/`,
`Cargo.toml` and `Cargo.lock`, with a TTL (default 1800 s,
`LITMUS_DECIDE_CACHE_TTL_S`). Every step that judges the same crate in one
gate shares one run: step 20's crate takes about 1m50 cold and 16 ms on a
hit. `LITMUS_DECIDE_NO_CACHE=1` or `--no-cache` forces the producer, and the
ok line says `cache=hit:age=<s>|miss|off`. Families whose producer is a
local file read (file-grep) do not cache: the read is the cost.

### D4. The cargo-test family judges by NAME

`--require-ok <test>` must find `test [mod::]<test> ... ok`; absence is
`missing-test`, distinct from `failed=<k>` (a renamed pin is not a green
pin). `--min-ok <re> <n>` is a floor on named-prefix passes, never a bare
`N passed`. A FAILED run lists every `test … FAILED` and every `panicked at`
line (capped at 40) and the remedy is the `cargo test … -- --nocapture` for
the first one. A compile error is `refused:…:compile-error` with the first
error lines; a producer that died before any test (a build-directory lock)
is `could-not-run:…:producer-exit=<code>`, because nothing was decided.

### D5. Burn-down is a carried obligation, advisory

`methodology/convergence.yaml` gains `litmus-piped-commands` beside
`shell-to-lua` and `manifest-dir-runtime`. Its counter is
`scripts/lua/census-litmus-pipes.lua` (`piped=<n>` plus a per-family count,
quote-aware like the ratchet's litmus arm), printed on every `--check`. It
starts advisory under the operator's 2026-10-19 ruling: warnings only. The
item is one converted `command:` line plus its floor line lowered. The
ratchet arm "editing an existing piped command converts it" (1800-f56m) is a
warning at this stage: a diff hunk that touches a piped `command:` line and
leaves a pipe in it is named, never refused.

### D6. Conversion keeps or tightens the expectation

A converted step's `expected_behavior` is the decider's `ok:<name>` line.
A step whose old expectation accepted something the decider refuses (a bare
count, an empty run) is tightened, and the slice records which steps turned
red on conversion as findings: a red found by conversion is the backlog
paying for itself, not a reason to loosen the decider.

## Family option sketches (one line each; a slice fixes the details)

- `cargo-test`: `--package --filter --cargo-arg --min-ok <re> <n> --require-ok <t> --retries --timeout-ms --no-cache` (built)
- `file-grep`: `--path (file|dir, repeatable) --suffix --pattern --fixed --mode present|absent|count --min --max` (built)
- `script-output`: `--argv … -- ` the script's own argv; `--expect-exit`, `--expect-line <re>`, `--count-lines <re> <min> [<max>]`, `--forbid-line <re>`; the script's stderr relayed verbatim
- `structured-field`: `--file | --from-argv …`, `--path .a.b[0]` (json.query), `--equals | --matches | --nonempty | --length-min`
- `podman-probe`: `--images --filter <re> | --inspect <name> --format-path <path> | --ps`, `--expect …`, retries on `database is locked`, `could-not-run` when podman is absent or the machine is down
- `cargo-other`: `build|check|clippy|run` with `--expect-exit`, `--expect-line`, cached like cargo-test
- `process`: `--argv … --expect-line <re> --expect-exit`, `--retries` with `--retry-delay-ms`, for curl/systemctl/ss probes
- `plan-query`: `answer|status|query|check` on the resolved plan binary, `--confidence`, `--min-citations`, `--field`
- `git-query`: `--ancestor A B`, `--ref-exists`, `--log-grep <re> --range`, `--file-at <ref>:<path> --pattern`
- `text-transform`: `--path --between <start-re> <end-re> --pattern --mode` (the `sed -n '/a/,/b/p' | grep` idiom)

## Risks

- A family option set that cannot express a step's decision invites a
  looser conversion. D6 and the per-slice findings list are the control.
- The cache key reads `git diff HEAD` on every call (about 50 ms on this
  tree); on a very dirty worktree it is larger. `--no-cache` is the escape.
- The census is a keyword classifier; minority families are upper bounds.
  The burn-down reads `piped=`, which is exact.

## Operator rulings (2026-10-19)

1. **Editing a piped command without converting it warns now and refuses later.** It is a warning for now. Once the census shows the piped count falling over one window (W ≈ 1 week), it becomes a refusal. Slice 1800-f56m carries both stages.
2. **One file.** Every decider family lives in `scripts/lua/litmus-decide.lua` for now, so it also works on lagging forge binaries. A library loader in script_run.rs may come later, but nothing waits on it.
3. The rest of the migration is worked out as it goes, family by family.
