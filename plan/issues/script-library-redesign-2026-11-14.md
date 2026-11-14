# Script library redesign: shared Lua modules, hooks, caching, native fallback (proposal)

Date: 2026-11-14. Branch measured: work/1667-6rtp at 69776ab29.
Status: PROPOSAL. It claims no rows and edits no scripts. Packets in section 9 are
candidates for the coordinator to file.

Read path note: `methodology_ask` returned `confidence=unsupported` for "script
dialects and shell-to-lua" (it has no route for that question). I fell back to
reading the files under the **unavailable** reason. The missing route belongs in
packet P0.

## 0. The answer in six lines

1. Lua scripts cannot share code today because the runner removes `require`
   (`crates/tillandsias-plan/src/lua_runtime.rs:234`) and loads each script as
   one chunk (`script_run.rs:792`). Every one of the 119 `scripts/lua/*.lua`
   files is self-contained, and duplication is the predictable result.
2. Fix this by adding `scripts/lua/lib/<area>.lua` modules. They are resolved
   only through a Rust `package.preload`-style searcher with a fixed allow-list,
   so there is no `package.path` and no filesystem search. The searcher is
   class-aware: a cacheable script cannot import a module that observes the
   world.
3. Hooks are `pre`/`post` around a `verdict` and around `proc.run`. They are
   declared in the script header, never discovered implicitly. That is the
   Nix `runHook` model without its "last resort" global setup hooks.
4. Caching already exists for the `Cacheable` class: there is a memo keyed on
   source plus read log (`lua_predicate.rs:1669-1678`). This proposal extends it
   to script-level verdicts with key = sha256(script + transitive lib sources +
   declared inputs' bytes + declared env values + plan binary version). It is
   stored under `target/` and is never available to the `Observing` class.
5. Rust is the fallback, not Go. The plan binary is already the Lua host, so
   anything Lua can't express becomes a Rust `std` table entry or a
   `tillandsias-plan` verb. Go would add a second toolchain with no host.
6. Land it as about 9 packets. Each one is under 150 lines of carried change
   and closes on a litmus or fixture.

## 1. Current state, measured

### 1.1 Population

| corpus | count | how measured |
|---|---|---|
| `scripts/*.sh` | 841 | `ls scripts/*.sh \| wc -l` |
| `scripts/lua/*.lua` | 119 | `ls scripts/lua/*.lua \| wc -l` |
| shell libs `scripts/lib-*.sh` | 11 | `ls scripts/lib-*.sh` |
| shell libs under `images/default/lib-*.sh` sourced by scripts | 2 (`lib-common.sh` x93 refs, `lib-expert-capability.sh` x10) | `grep -o 'lib-[a-z-]*\.sh' scripts/*.sh` |
| Lua library modules | **0** (`scripts/lua/` has no subdirectory) | `ls -a scripts/lua` |

Source-reference counts across `scripts/*.sh`: lib-common 93, lib-ca-path 26,
lib-wsl-exec 10, lib-env-forward 10, lib-build-version 10, lib-dispatch-reap 9,
lib-wsl-capture 8, lib-freeze-paths 8, lib-cargo-sites 7, lib-sigpipe-verdict 5,
lib-embed-endpoint 5, lib-rerun-failed-rust-tests 4, lib-mcp-build-id 4,
lib-dev-env 4, lib-project-engine-capability 2.

### 1.2 How Lua scripts run today

- **One runner.** `tillandsias-plan script run <file.lua>`
  (`crates/tillandsias-plan/src/script_run.rs:1-31`). A script ends in exactly
  one `verdict.ok|skip|advisory|refused|blocked|could_not_run`, with exit codes
  0/0/0/1/2/3. A script that returns without a verdict prints
  `refused:no-verdict:<name>` (`script_run.rs:9-22`).
- **Header.** Leading `--` lines may declare `@class cacheable|observing`,
  `@env NAME...` and `@read-env NAME...` (`script_run.rs:163-190`).
  `env.get` refuses an undeclared name (`script_run.rs:569`, error text near
  `:704`). `os.getenv` is gone.
- **Env clearing.** Every process door (`proc.run`, `proc.spawn`, `proc.chain`,
  `sh.run`) builds its child through `base_env_command`, which calls
  `env_clear()` and re-adds a fixed passthrough list, every `TILLANDSIAS_*`
  variable, and pinned `LANG=C TZ=UTC GIT_TERMINAL_PROMPT=0`
  (`lua_predicate.rs:190-215`; history 1551-nyzb).
- **Capability tables.** `lua_std::register` installs `json`, `yaml`, `hash`,
  `path`, plus `time` for Observing (`lua_std.rs:32-44`). The cacheable global
  allow-list is pinned at `lua_predicate.rs:1005-1040`. `fs.walk` and `env.get`
  are Observing-only (`script_run.rs:569-580`).
- **Sandboxing.** `io.open/popen`, `debug`, `loadfile`, `dofile` and
  **`require`** are removed (`lua_runtime.rs:215-234`, comment: "scripts are
  loaded by Rust, not Lua").
- **Cache.** `PredicateClass::Cacheable` results are memoised over the
  predicate source and the bytes it read. Observing results never are
  (`lua_predicate.rs:43-66, 99-100, 1669-1678, 1767`). The registry
  invalidates on re-registration (`lua_predicate.rs:1820`). The memo is
  in-process only. Nothing persists between runs.
- **Hooks.** Git hooks are already Lua: `crates/tillandsias-plan/hooks/
  {pre-commit,post-commit,post-checkout,post-merge,pre-push}.lua`.

### 1.3 How they share helpers today

They don't. Of 119 files, 18 contain the token `require` and only one call
remains (`require('fs'`, which errors at runtime because `require` is nil).
Every other match is in a comment or string.

## 2. Duplication clusters (counts = files containing the pattern)

Measured with `grep -l` over `scripts/lua/*.lua` (119) and `scripts/*.sh` (841).
These are pattern hits, not proven clones. Each cluster's packet must
re-measure.

| cluster | Lua files | sh files | evidence / note |
|---|---|---|---|
| repo root discovery (`git rev-parse --show-toplevel` / `REPO_ROOT=`) | 53 call `rev-parse`; 16 hand-roll repo root | 51 `--show-toplevel`; 92 `REPO_ROOT=` | `check-fragment-events-land.lua:41`, `check-litmus-dead-inputs.lua:27` (same argv, different timeouts 30000 vs 15000) |
| local `git(...)` wrapper | (subset of the 53) | n/a | `check-declared-closures-added.lua:72`, `check-carried-obligations.lua:98`: two `git` helpers with different argv conventions (with and without leading `"git"`) |
| arg parsing (`ipairs(arg)` / `arg[1]`) | 31 | 114 (`while [[ $# -gt 0` / `case "$1"`) | flags like `--dump-floor`, `--landing`, `--timeout` re-parsed per file |
| verdict printing | 44 `verdict.ok` (runner-owned, good) | 561 `echo "ok:`, 88 `echo "refused:`, 2 `todo:` | shell's verdict grammar is ad hoc. Lua already centralises it |
| die/fail/log helpers | 3 | 101 `die()/fail()`, 29 `log()/info()` | |
| temp dirs | 16 | 558 `mktemp`, 409 `trap ... rm -rf` | the bare-mktemp floor exists because of this (`check-bare-mktemp.lua:1-30`) |
| yaml reads | 9 `yaml.decode/parse` | 25 `yq` | spec forbids `yq` for new deciders (ci-release spec, below) |
| podman | 3 | 148 | almost all of it is still shell, in lifecycle scripts (see §1.1 of the 09-28 research, family 5) |
| string utils (`trim`, `split`) | 3 + 4 local definitions | n/a | |

Prior inventory: `plan/issues/lua-shell-consolidation-inventory-2026-09-28.tsv`
(860 rows) and the family ranking in
`plan/issues/lua-shell-consolidation-research-2026-09-28.md:107-146`. This
proposal covers the library layer that report's families 1-2 need. It does not
replace that ranking.

## 3. What the rules already say

- **ci-release spec, Requirement ec267f02**
  (`openspec/specs/ci-release/spec.md:43-80`): a new gate decider or fixture
  MUST be Lua under `scripts/lua/`, run through `tillandsias-plan script run`,
  end in one `verdict.*`, and MUST NOT reach `jq/yq/rg/sed/awk/sha256sum`. The
  `json/yaml/text/hash/path/fs` tables are the portable form. Processes MUST be
  argv through `proc.run`/`proc.spawn`. The shell corpus is pinned by
  `shell-decider-floor.txt` and `pipe-site-floor.txt`, and
  `check-shell-ratchet.lua` refuses a raised floor.
- **Carried obligation `shell-to-lua`** (`methodology/convergence.yaml:587-722`,
  entry at `:699`): a change touching the counted paths owes one port of at
  most 150 lines, or `Carried-Waiver: shell-to-lua <reason>`, or
  `too-big:<item>:<lines>`.
- **No embedded scripts**: `methodology.yaml:200-222`
  (`check-no-python-scripts.lua`, `check-no-base64-script-injection.lua`).
  Library modules must be real files, never strings inside Rust or shell.
- **Toolbox-first**: `methodology/multi-host-development.yaml:1224-1230`.
  Scripts are idempotent and toolbox-friendly. A Lua lib must not assume host
  tools the plan binary doesn't provide.
- **Bash dialect**: `methodology/verification.yaml:263`
  (`check-bash-dialect.lua`) still governs the shell that remains.
- **Design lineage**: `plan/issues/scripting-runtime-lua-no-pipes-design-2026-09-26.md`
  §4 (execution model), §5 (determinism), §6 (migration, coexistence, ratchet);
  `lua-bash-replacement-and-policies-design-2026-09-27.md`;
  `lua-runtime-audit-2026-10-04.md`.

None of these documents mentions modules, `require` or a shared Lua library, so
this proposal conflicts with no existing ruling. It does need one new spec
requirement (P1) because it re-opens a symbol the runtime deliberately removed.

## 4. Directory layout

```
scripts/lua/
  lib/                      # importable modules ONLY; no verdicts, no top-level effects
    repo.lua                # root(), rel(path), is_worktree()      [observing]
    git.lua                 # git.run(args), rev_parse, merge_base, diff_names, ls_files  [observing]
    args.lua                # declarative flag parser               [pure]
    text.lua                # trim, split, lines, starts_with (wraps std `text`)  [pure]
    floor.lua               # pinned-floor files: read, compare, dump (bare-mktemp, shell-ratchet, centicolon)  [pure]
    scratch.lua             # scoped temp dir under $TMPDIR, swept on verdict  [observing]
    podman.lua              # argv builders + ps/inspect parsers (no daemon calls in pure half)  [split]
    ledger.lua              # thin wrappers over `tillandsias-plan` query verbs, never raw YAML of plan/  [observing]
    fixture.lua             # case table runner: cases -> per-case ids -> one verdict  [observing]
  hooks/                    # optional pre/post hook modules (section 6)
  check-*.lua  test-*.lua   # entry scripts, unchanged location (spec ec267f02 pins scripts/lua/)
scripts/lib-*.sh            # frozen: no new shell lib; each deleted when its last caller ports
```

Why flat `lib/<area>.lua` and not `lib/common` + `lib/utils`: "common" and
"utils" name no area, so they grow into the next `lib-common.sh` (93 callers,
one file). One module per area, named by noun, mirrors git's `t/` split:
`test-lib.sh` is the framework entry point, `test-lib-functions.sh` holds the
shared helpers, and `t/lib-<area>.sh` (for example `lib-subtest.sh`) are
opt-in area libraries [git]. The runner and verdict play the role of
`test-lib.sh`, and `lib/<area>.lua` plays `t/lib-<area>.sh`. Module names
follow LuaRocks dot notation (`lib.git` -> `scripts/lua/lib/git.lua`) [luarocks]
so the layout works with standard tooling (luacheck, LSP) without a rockspec.

## 5. Module API sketch

### 5.1 Loading

```lua
-- @class observing
-- @lib git args floor          -- NEW header key: the closed import set
local git   = require("lib.git")
local args  = require("lib.args")
```

Runner rules (Rust, in `script_run.rs` and `lua_runtime.rs`):

1. `require` is reinstated as a **single custom searcher**, registered the way
   Lua's own `package.preload` / `package.searchers[1]` is consulted first
   [lua-manual]. `package.path`, `package.cpath` and the C searchers stay
   absent, so there is no filesystem search and no `LUA_PATH` env leak.
2. A name resolves only if it appears in the header's `@lib` list AND maps to
   `scripts/lua/lib/<name>.lua` inside the repo root (realpath-checked, same
   rule as `@read-env`, `script_run.rs:577-580`). Anything else raises
   `require: '<x>' not declared; add -- @lib <x>`, which matches the existing
   `env.get` error shape.
3. Each module declares its own `-- @class`. A `cacheable` script requiring an
   `observing` module is refused at load. This is structural, not
   documentary, the same reasoning as `lua_predicate.rs:51-55`.
4. Modules are loaded once per run and returned tables are frozen
   (`setmetatable` with `__newindex` error), so a script cannot monkey-patch a
   library another module relies on.
5. A module must not call `verdict.*`. Only the entry script may end the run.
   The runner enforces this with a load-time flag that `verdict` checks.

The prior art here is `mlua-pkg`, which inserts its resolver at
`package.searchers[1]` with first-match-wins resolvers and an optional
capability sandbox [mlua-pkg]. The fit is good, but it is a third-party crate.
Implement the ~80 lines in-tree instead of taking the dependency; this is a
decision for P1.

### 5.2 Representative signatures

```lua
-- lib.args (pure)
local a = args.parse(arg, {
  flags   = { ["--dump-floor"] = "bool", ["--landing"] = "bool" },
  options = { ["--timeout"] = { type = "duration", default = "5m" } },  -- 'm' not 'h', per runner parse
  positional = { "base_ref?" },
})                              -- unknown flag -> verdict.refused("args", "...") by the caller via a returned err

-- lib.git (observing)
git.run({ "rev-parse", "--verify", "--quiet", ref }) -> { ok, code, stdout, stderr }   -- never a leading "git"
git.toplevel()            -> string   -- one timeout (30000), one argv
git.diff_names(base, head, { filter = "AMD" }) -> { paths... } (byte-ordered)

-- lib.floor (pure; replaces three hand-rolled floor readers)
floor.read(path)          -> { [file] = n }
floor.compare(floor_tbl, counts) -> { new = {...}, stale = {...} }
floor.dump(counts)        -> string   -- for --dump-floor(s)

-- lib.scratch (observing)
local d = scratch.dir("bare-mktemp")   -- "$TMPDIR/bare-mktemp.XXXXXX", registered for sweep at verdict

-- lib.fixture (observing)
fixture.run(name, cases)  -- each case {id, setup, act, expect}; verdict lists every case id, never one bool
```

Verdict printing deliberately has **no** library. The runner's `verdict` table
already owns it, and the 44 Lua files using it are the one cluster with no
duplication. Shell `echo "ok:` sites (561) shrink only as files port.

## 6. Hook points

Prior art: Nix stdenv runs `runHook pre<Phase>` and `runHook post<Phase>`
around each phase, and a hook is the function `<name>` plus the array
`<name>Hooks`. The manual says to keep those calls when overriding a phase,
and treats global setup hooks as a last resort [nix-stdenv][nix-pills]. The
pre-commit framework binds hooks to explicit `stages` (pre-commit, pre-push)
and installs push hooks separately [pre-commit].

Proposed hooks are declared, not discovered:

| hook | where | justification | allowed effects |
|---|---|---|---|
| `pre_run` | before the entry chunk | uniform `@env` and `@lib` validation and scratch setup. Removes per-script preambles (the 16 Lua repo-root hand-rolls) | Observing class only |
| `post_verdict` | after the first `verdict.*`, before exit | sweep `lib.scratch` dirs (the darwin TMPDIR problem, `check-bare-mktemp.lua:7-15`), emit the timing span, and write the cache entry (section 7) | cannot change the verdict token or exit code |
| `pre_proc` / `post_proc` | around each `proc.run` | trace argv + rc for `lua_proc_trace` (`crates/tillandsias-plan/tests/lua_proc_trace.rs`) and record the process as a cache-poisoning observation | read-only on the result |

Rejected:

- **Hooks that rewrite the environment.** That would undo the
  `base_env_command` single answer (`lua_predicate.rs:196-200`).
- **Per-directory implicit hooks** (`scripts/lua/hooks/*.lua` auto-loaded).
  These are the Nix "setup hook" failure mode, where effect at a distance is
  invisible in the script. A script opts in with `-- @hook <name>`.
- **New git hook stages.** The five `crates/tillandsias-plan/hooks/*.lua`
  already cover the stages the project uses.

## 7. Caching design

Models: Bazel's action key is a digest over the command line, environment
variables, and input digests, and `--action_env` values are part of the key
[bazel-cache][engflow]. Ninja stores a hash of the command line per output in
`.ninja_log` and rebuilds when it changes [ninja]. Buck2 keys on the action
digest and can place outputs at content-based paths [buck2]. The lesson all
three share is that the key must cover the tool, the command, the environment
and the inputs, or a hit can be stale.

**Eligibility.** Only scripts with `-- @class cacheable`. The class already
forbids shell and clock (`lua_predicate.rs:43-66`), and it must also forbid
any `observing` lib (§5.1 rule 3). Observing scripts are never cached and
there is no flag to change that (`lua_predicate.rs:1678`). A user-visible
cache that can make an observing gate green without running it is the failure
the predicate split exists to prevent.

**Key** = sha256 over a canonical, length-prefixed encoding of:

1. the entry script bytes
2. the bytes of every module in the transitive `@lib` closure, in sorted name
   order
3. the argv after `--` (normalised by `lib.args` when present)
4. for each `@env` name, the name and value (absent is distinct from empty)
5. the **read log**: the path and sha256 of every `fs.read` the run performed.
   This is the existing memo mechanism (`lua_predicate.rs:1677, 1852-1874`).
   Because reads are discovered rather than declared, the stored entry holds
   the read log, and a lookup re-hashes those paths (Bazel's two-level
   action-cache plus CAS shape, applied in-process)
6. the plan binary identity: `CARGO_PKG_VERSION` + build git sha + lua_std
   table-set version, so a changed `std` function invalidates everything

**Value**: verdict line, exit code, stderr detail, and the read log.

**Location**: `$CARGO_TARGET_DIR`-sibling `target/lua-cache/v1/<k[0:2]>/<k>.json`
in the worktree. It is never shared across hosts in the first version,
because host-wide `/tmp` state has already reddened gates (memory: "No heavy
runs during a gate"). Writes go to a temp name and are then renamed, so
readers never see a partial entry.

**Invalidation**: purely by key, with no TTL. `--no-cache` on `script run`
forces execution. In gate mode the cached and fresh verdicts are compared on a
1-in-N sample, and a mismatch is `refused:cache-divergence`. Evict
oldest-first above a size cap (default 64 MB). `target/` is already what
"drop target/ of landed rows" cleans.

**Transparency**: the verdict line is byte-identical on a hit. A hit adds a
stderr note `cache:hit:<k[0:12]>` and the timing span marks `cached=1`. Stdout
stays the verdict (`test-litmus-verdict-reads-stdout-only.lua`).

## 8. When to fall back to Rust (and why not Go)

Fall back to Rust when one of the following holds. Name the one that applies
in the packet.

1. **Parser absent.** The task needs a format with no `std` table (TOML today,
   per `lua-shell-consolidation-research-2026-09-28.md` family 4). Add
   `toml.decode` to `lua_std.rs` rather than writing a Lua parser.
2. **Semantics already in Rust.** The ledger's folded CRDT view, the closure
   checker and fragment rules belong in a `tillandsias-plan` verb that
   `lib.ledger` calls. Never re-implement them over raw YAML (same source).
3. **Performance.** A measured run over 1 s on the gate host for a pure scan,
   where the loop is per-byte or per-line over more than 10^5 lines.
4. **OS primitives** that the process doors can't express safely: signals,
   pty, vsock, Windows handle semantics (`lib-wsl-exec.sh`,
   `check-wsl-exe-single-constructor.lua`), or long-lived daemons.
5. **Security boundary.** Anything handling secrets or vault tokens stays in
   Rust, where tests can inject a fake keyring (memory "Tests must not reach
   real keyring").

**Go is not recommended.** It would add a second toolchain to the toolbox
(`methodology/multi-host-development.yaml:1224`), cross-compilation for three
platforms, and a second process boundary, and nothing hosts it. Rust already
hosts Lua and ships in every lane. Revisit only if an upstream dependency
exists only in Go and an FFI or subprocess is cheaper than a port.

Bootstrap shell (`scripts/portability/bootstrap-shell-allowlist.txt`, cited
at `methodology/convergence.yaml:688`) stays shell. It runs before the plan
binary exists.

## 9. Migration packets

Each packet is independently landable and at most 150 carried lines unless it
is marked as a Rust change. Order is by dependency first, then by the
duplication it removes.

| # | packet | closure (verifiable) | depends on |
|---|---|---|---|
| P0 | Add a `methodology_ask` route for "script dialect / shell-to-lua / lua library" | the forge-plan MCP answers this question with `confidence!=unsupported`, plus a fixture in the methodology route table test | none |
| P1 | Spec delta (ci-release): Requirement "a Lua decider imports shared code only through `-- @lib` from `scripts/lua/lib/`", plus Rust searcher (§5.1 rules 1-5) | `cargo test -p tillandsias-plan` cases: undeclared lib refused; path escape refused; cacheable script requiring an observing lib refused; module calling verdict refused; frozen table write raises. New litmus `lua-lib-require-contract` | P0 |
| P2 | `lib/text.lua` + `lib/args.lua` (pure); port 3 scripts with local `trim`/`split` | `scripts/lua/test-lib-args.lua` (case table); `check-shell-ratchet.lua` counts unchanged or lower | P1 |
| P3 | `lib/repo.lua` + `lib/git.lua`; port `check-fragment-events-land.lua` and `check-litmus-dead-inputs.lua` (§2 row 1) | both scripts' existing fixtures stay green, and `grep -c '"rev-parse", "--show-toplevel"' scripts/lua/*.lua` falls by 2 | P1 |
| P4 | `lib/floor.lua`; port the floor logic of `check-bare-mktemp.lua`, `check-shell-ratchet.lua`, `check-centicolon-ratchet.lua` | `test-bare-mktemp.lua`, `test-shell-ratchet.lua` green; `--dump-floor(s)` output byte-identical before and after (golden file) | P1 |
| P5 | `lib/scratch.lua` + `post_verdict` sweep hook | new fixture: a script that makes scratch and refuses still leaves no dir under its `$TMPDIR` (run under darwin regime in litmus, per memory "New fixture goes in a litmus step") | P1 |
| P6 | `lib/fixture.lua` case runner; port 2 short `test-*.sh` from the 09-28 inventory family 2 | verdict lists every case id; negative-control case proven to fail; shell floor lowered via `--dump-floors` | P5 |
| P7 (Rust) | Persistent cache for `@class cacheable` (§7) | `cargo test`: key changes on each of the 6 components; hit output byte-identical; `--no-cache` forces run; divergence sample refuses. Litmus `lua-cache-transparent` | P1 |
| P8 | `lib/podman.lua` pure half (argv builders and `ps --format json` parsers), no daemon calls | parser fixture over pinned JSON samples (pre-pulled, stdout-only per memory) | P1 |
| P9 | Freeze `scripts/lib-*.sh`: new ratchet floor so no new `lib-*.sh` and no new source sites | `check-shell-ratchet.lua` extension with a raised-floor negative test | P1 |

Every port packet can also serve as a `shell-to-lua` carried item
(`convergence.yaml:699`).

## 10. Risks

1. **Re-opening `require` weakens the sandbox.** The removal was deliberate
   (`lua_runtime.rs:233`). Mitigations: there is no `package.path`, the
   header must declare each import, paths are realpath-confined, and P1's
   negative tests cover each rule.
2. **Cache staleness.** A missed key component turns into a green that ran
   nothing. Mitigations: only the cacheable class, the binary version in the
   key, sampled divergence checks, and no cross-host sharing in v1.
3. **Library becomes the new `lib-common.sh`.** Mitigations: one module per
   noun, no `common`/`utils` names, and a modules-without-callers check that
   could be added to P9.
4. **Class contagion.** A pure helper that later gains a `proc.run`
   reclassifies to observing and silently de-caches its importers. Rule 3
   makes this a load-time refusal, not a silent change.
5. **Behaviour drift during dedupe.** Different timeouts and argv shapes
   (§2: 30000 vs 15000 ms; `git` with and without a leading `"git"`) are
   merged into one default. Each port packet must keep the existing fixtures
   green and say which value it picked.
6. **Hooks hide control flow.** That is why hooks are opt-in per header and
   cannot alter verdicts or env.
7. **Measurement here is grep-level.** The cluster counts in §2 are pattern
   hits, not semantic clones. Each packet re-measures its own cluster before
   claiming a reduction.
8. **Not verified.** I did not compile anything, I did not check whether mlua's
   version on the tree exposes `package.searchers` in the sandboxed state, and
   I did not test darwin or msys behaviour.

## Sources

- [lua-manual] Lua reference manual, package library (`require`,
  `package.preload`, `package.searchers`): https://www.lua.org/manual/5.4/manual.html#6.3
  (5.3 mirror consulted: https://help.qsys.com/q-sys_9.4/Content/Control_Scripting/Lua_5.3_Reference_Manual/Standard_Libraries/2_-_Modules.htm);
  lua-l on preferring `package.preload` over overriding `require`:
  https://groups.google.com/g/lua-l/c/BckKacbarZw
- Programming in Lua, "Modules and Packages": https://www.lua.org/pil/15.html
- [luarocks] Rockspec format (`modules` table, dot notation):
  https://github.com/keplerproject/luarocks/wiki/Rockspec-format ;
  https://git.lua4.win/luarocks/plain/docs/rockspec_format.md?h=main
- [mlua-pkg] https://docs.rs/crate/mlua-pkg/0.5.0
- [git] t/README: https://code.googlesource.com/git/+/5e839c8f6d5edfaf0d2250f3c9628a238e24c6be/t/README ;
  t/test-lib.sh: https://code.googlesource.com/git/+/v2.3.2/t/test-lib.sh
- [nix-stdenv] https://github.com/NixOS/nixpkgs/blob/master/doc/stdenv/stdenv.chapter.md ;
  [nix-pills] https://nixos.org/guides/nix-pills/20-basic-dependencies-and-hooks.html ;
  https://ekala-project.github.io/nix-book/ch06-03-phases.html
- [bazel-cache] https://bazel.build/remote/caching ; [engflow]
  https://blog.engflow.com/2024/05/13/the-many-caches-of-bazel/
- [ninja] https://fuchsia.dev/fuchsia-src/development/build/ninja_how ;
  https://groups.google.com/g/ninja-build/c/lF1hw9BnBl8
- [buck2] https://buck2.build/docs/rule_authors/content_based_paths/
- [pre-commit] https://pre-commit.com/
