# Lua runtime architecture: replacing per-host runtime dependencies (design)

- Date: 2026-09-26. Author: macuahuitl (coordinator, Claude session). Base: origin/linux-next `cda7f75c4`.
- Operator direction (2026-09-25): jq is the next runtime dependency breaking by host. Replace it in the Rust/Lua layers; consider Go only if Lua cannot. Research and design the next steps in the Lua runtime, file packets.
- Packets filed from this design: 1375-rn9b, 1375-btuf, 1375-6pnd, 1375-tsfu, 1375-2x4e, 1375-8g5t, 1375-amye. Events on 902-5bf9, 914-ahsy, 1367-q9yc, 1297-2htc, 1353-ryhq.
- Code is cited by symbol. Counts are `git grep -c` over `scripts build.sh launch.sh` unless stated; "litmus" is a whole-file grep over `openspec/litmus-tests/*.yaml` (454 files), not restricted to `command:` fields.

## 1. Inventory: external tools the committed automation forks on

| Rank | Tool / idiom | Sites / files | Litmus files | Hosts where it breaks | Recorded incidents | Existing shim |
|---|---|---|---|---|---|---|
| 1 | `jq` (277 real invocations in 68 files; 696 token mentions) | 277 / 68 | 35 | macOS and Git Bash: absent unless installed; every host: dynamically linked (libjq, libonig) so `fast_tool` cannot copy it out of the toolbox on a toolbox-less host; jq.exe writes CRLF | 1186-w3ph (`/proc/self/fd/0` on MSYS), run-litmus-test.sh CR strip (yolanda 2026-09-04), 914-ahsy relay held on `"$JQ"` quoting, 746-htj9 moved the runner from yq to jq | `resolve_tool jq` (tool-dispatch.sh), `fast_tool jq` (tool-materialize.sh), `tillandsias-plan yaml-json \| jq` (`_yaml_jq`) |
| 2 | `timeout` | 356 / 106 | 28 | stock macOS lacks it | check-host-tools.sh names it a REQUIRED tool (the inverse of portability) | probe only |
| 3 | `yq` | 163 / 30 | 10 | Silverblue host, builder toolbox, Windows (1297-2htc cannot provision it) | 746-htj9 (2026-08-15 double outage), 1297-2htc, 1330-bb87 | `yaml-get`, `yaml-json`, `yaml-type` verbs; toolbox shim in the litmus runner (799-tb7q) |
| 4 | `sha256sum` vs `shasum` | 143 / 46 vs 62 / 27 | 7 + 3 | macOS has only `shasum` | 699-usxc fragments (PATH-narrowed regimes) | none — inline `command -v` forks |
| 5 | `setsid` | 68 / 10 | 2 | macOS, Windows | 1352-vmbc (done), 1353-ryhq: 108-110 preflight guards refused at once | none |
| 6 | `flock` | 59 / 9 | 7 | macOS (absent), Git Bash (flaky) | concurrent-lane contention notes (2026-07/08) | none |
| 7 | `date +%s%3N` / `%N`; `date -d` vs `date -j` | 30 / 18; 20 / 15 vs 17 / 11 | 2 | BSD date: one-second resolution, no `-d` | 1279-a7b6 (a real sub-second measurement reads as zero) | none |
| 8 | `sed -i` (GNU form), `stat -c` vs `stat -f`, `readlink -f`, `grep -P` | 36 / 19; 19 / 15 vs 15 / 11; 14 / 6; 6 / 4 | 0-4 | BSD userland | 1130-i6xj, 1174-jd8n, 1268-m2ir | check-portability-idioms.sh (advisory, counted) |
| — | `ruby` 142 / 32, `python3` 80 / 41, `perl` 13 / 9 | | 13 / 18 / 1 | ruby absent in the forge; python forbidden for committed automation | 746-htj9, 1301-ie39 | policy guard only |
| — | `mapfile` 27 / 16, `<(` 161 / 95, `xargs -r` 6 / 4, `awk gensub/asort` 0 | | | bash 3.2 on macOS, BSD xargs | 1374-4u6i (bash-dialect fixture red and unbound) | check-bash-dialect.sh |

Ranking is call sites × hosts broken × incidents. jq is first on all three axes; timeout/setsid/flock are the largest process-control group; yq is already half-solved by the `yaml-*` verbs; sha256/date are the cheapest to close.

Two shims exist and both are dispatch-shaped: `resolve_tool` (host arm probed with `--version`, else `toolbox run --container tillandsias-builder <tool>`) and `fast_tool` (materialise the toolbox's binary once into `target/tool-cache`). Both presuppose a toolbox, which macOS and Git Bash do not have. That is why "dispatch conversion" (914-ahsy) cannot be the end state for jq: on the hosts that lack jq there is nothing to dispatch to.

## 2. What the Lua runtime is today

- mlua 0.10.5, features `vendored, lua54, send, serialize`. Lua 5.4 compiled from bundled C source; no system Lua. The plan binary builds natively on all three platforms (yolanda's `target/release/tillandsias-plan.exe` answers `build-id`, 1267-uafx; macOS builds on osx-next), so the runtime is already on every host that runs a gate. `resolve_plan_binary` (plan-binary-probe.sh) finds it.
- Three Lua environments that share no code:
  1. `LuaRuntime::new` (lua_runtime.rs) — expert-serve pipeline; nils `os.execute`, `os.exit`, `os.getenv`, `io.open/popen/close/output/input`, `debug`, `loadfile`, `dofile`, `require`; exposes `expert.log_info`, `expert.now_ms`; loads `crates/tillandsias-plan/lua/{collect,decompose,tier,init}.lua` from disk. Documented as "a partial stdlib restriction, not a sandbox".
  2. `build_environment(PredicateClass)` (lua_predicate.rs) — `Cacheable` is an allow-list (1367-upz6: string/table/math-minus-random/utf8, `expert.log_info`, `expert.verbs`); `Observing` adds `expert.now_ms` and `expert.shell{argv}` on `tillandsias_exec::Command`. `PredicateRegistry::eval` memoises Cacheable only. On trunk the memo key is `(name, arg)`; yoga's 1367-q9yc (origin/work/1367-q9yc, relayed as `7a660180d` on the coordinator's local linux-next, not on origin at writing time) makes it content-addressed on the bytes `fs.read` returned (`file_digest`, `still_valid`) and adds `fs.read` (repo-rooted) and `expect.contains/matches/eq`.
  3. `run_lua_cli` (`tillandsias-plan lua <script|-e>`) — a raw `mlua::Lua::new()`: full stdlib, `os.execute` and `io.popen` live. This is the unsandboxed door and 1375-btuf closes it.
- Nothing exposes json, yaml, hash, time-formatting or path handling to any Lua script, although the `serialize` feature already bridges `serde_json::Value` to Lua tables (`lua.to_value` in `call_collect`) and the crate links `serde_json` (`float_roundtrip`), `serde_yaml`, `sha2`, `chrono`.
- The litmus seam: `rust_queries:` (crates/tillandsias-litmus-rust, dispatched by `run_rust_queries_for_litmus`) has 1 adopter in 454 files since 2026-05-22. No `lua:` step key exists. 902-5bf9 (ready) plans the `steps:` form and made adoption a measured exit criterion for that reason.

## 3. Architecture: one implementation, three front doors

```
            shell script            litmus steps: (902-5bf9)         Lua predicate / expert .lua
                 |                          |                                  |
   tillandsias-plan <verb>          Observing Lua env                 Cacheable | Observing env
                 |                          |                                  |
                 +---------- lua_std::register(&Lua, class) -----------------+
                                            |
        host_verbs.rs (hash, time) | json_query.rs (eval) | run_verb.rs (tillandsias_exec)
                                            |
                        serde_json / serde_yaml / sha2 / chrono / tillandsias_exec
```

Layers, bottom up:

1. Rust primitives, each a plain function with no CLI knowledge: `json_query::eval(&Value, &Filter, &Opts)`, `host_verbs::sha256_hex`, `host_verbs::now_ms`, `host_verbs::iso_utc`, `run_verb::run(RunSpec)`.
2. CLI verbs on the plan binary (the shell door): `json get`, `yaml get`, `hash sha256`, `time now`, `run`. Verdict grammar follows the house style (`blocked:<reason>` on stdout, exit codes that keep the caller's vocabulary: 124 for a timeout).
3. `lua_std::register` (the Lua door): pure tables `json`, `yaml`, `hash`, `path` in both classes; `time`, `fs.read`, `sh.run` in Observing only. The single registrar is called by all three environment builders, so the `lua` CLI, the predicate bridge and expert-serve see the same names.
4. The litmus `steps:` form (902-5bf9) runs in the Observing environment and needs no API of its own.

Invariants: Cacheable never observes the clock, the environment or the disk except through content-addressed `fs.read` (1367-upz6, 1367-q9yc). A Cacheable predicate that calls `json.query` over `fs.read(path)` is therefore a pure function of the file's bytes, and the memo stays valid. No verb ever passes a shell string; argv only (1252-fg9e).

## 4. The jq replacement: `tillandsias-plan json get`

Survey (277 invocations): A path extraction 174, B iterate+select 68, C construction 12, D advanced 21, E validator-only 7. Bucket D uses `join` ×7, string interpolation ×3, `group_by` ×2, `@tsv` ×2, `strftime/now` ×2, `test`, `sub`, `sort_by`, `paths`, `..` once each; none of `reduce`, `def`, `input(s)`, `walk`, `env.`, `@csv`, `limit`. The fleet-critical surface is small: hardware-fingerprint.sh 14 sites (A/E), land-queue.sh 2, the three status-loss/long-running `@tsv` folds, and the runner's `_yaml_jq`. agent-identity.sh, push-plan-fragments-to-trunk.sh and the pre-push gate carry none.

Supported subset (the whole grammar; the ratchet guard and the parity fixture pin it):

- Paths: `.`, `.a`, `.a.b`, `."quoted key"`, `.a[0]`, `.a[-1]`, `.[]`, `.a[]`, optional forms `.a?`, `.a[]?`.
- Pipes of the above with `select(<path> == <literal>)`, `select(<path> != <literal>)`, `select(<path>)`, `select(<path> | not)`.
- Alternatives `// empty`, `// <literal>`.
- Builtins on the current value: `keys`, `length`, `has("k")`, `type`, `not`, `tostring`; array construction `[.a, .b]` and `join("<sep>")` only if 1375-2x4e finds the `@tsv` folds want it (recorded in the ratchet header either way).
- Flags: `-r`, `-c` (default is compact anyway), `-e`, `--arg k v`, input file or `-`.
- Output: one result per line, LF on every platform, jq's compact encoding, key order preserved (requires serde_json `preserve_order` on the workspace; float formatting is already `float_roundtrip`). `-e` exit codes mirror jq (1 on null/false, 4 on empty).

jaq (MIT; jaq-core, jaq-std, jaq-json, roughly ten transitive crates; not in Cargo.lock) was weighed and deferred: it would give the full language for 12% of sites, most of them litmus assertions that are moving to Lua anyway, at the price of a second grammar nobody can enumerate and output-format edge cases (number rendering, `@sh`) that a parity fixture would have to chase. Criterion to revisit: after 1375-2x4e, more than 15 non-litmus sites still need bucket D. Licence and dependency weight were not measured offline; the spike that revisits it must read Cargo.lock's delta.

## 5. Lua versus Go: the decision and its criteria

Decision: Lua on the plan binary for everything expressible as data transformation or assertion; Rust verbs on the same binary for anything that touches the OS; Go is not adopted.

Criteria applied to the top dependencies:

| Dependency | Lua can? | Where it lands | Why not Go |
|---|---|---|---|
| jq | yes — `json.query`, Lua tables for C/D | 1375-rn9b (verb), 1375-btuf (Lua) | the binary is already on every host; Go adds a toolchain, a build lane and a signing asset per platform to ship a second binary |
| yq | yes — `yaml.parse` + the same query engine | 1375-rn9b `yaml get`, 1375-6pnd | same |
| sha256sum / shasum, date %N | yes via `hash.sha256`, `time.*` (Rust-backed) | 1375-8g5t | same |
| timeout / setsid / flock | NO — Lua 5.4 has no fork, exec, session, signal or file-lock primitive, and Cacheable must never gain one | Rust `run` verb on `tillandsias_exec` (1375-amye, after 1252-fg9e) | Rust reaches the same syscalls Go would; there is no gap Go fills |
| sed -i, stat, readlink -f | mostly — text edits and lexical paths are Lua; `stat` and path resolution are small Rust verbs when a caller asks | on touch; not filed (check for the capability before designing its replacement) | same |

"Portable" means native on Fedora/Silverblue, macOS (bash 3.2, BSD userland) and Git Bash plus WSL2. The plan binary is already native on all three; every replacement above rides on it. The one genuine "Lua cannot" is process control, and it is answered by Rust, not by a new language.

Cost comparison for one verb: Rust+Lua is a module, a dispatch arm, a capabilities token and a fixture (the shape of every existing verb); Go is a toolchain on eleven hosts, a release asset per platform, a new `resolve_*` probe, and a second "stale binary" class (1267-uafx already costs one).

## 6. Adoption: how availability becomes a number

The rust_queries lesson is that an available seam with no forcing function stays at one adopter. Three mechanisms, all in 1375-tsfu and the sibling rows:

1. A counter on every `--check`: `ok:jq-callsites:<n>:floor:<f>` from `check-jq-callsite-ratchet.sh`, count pinned to a reproducible `git grep` pattern published in the script header (1374-4u6i and 1174-jd8n are why the count is pinned and why an empty population is a refusal).
2. A ratchet: per-file floors in `scripts/portability/jq-callsite-floor.txt`; a NEW bare jq site whose filter parses under `json get --parse-only` is refused with the replacement spelling printed; a site outside the subset warns. Standing debt is never reddened (1130-i6xj's rule).
3. The floor only moves down, and 1375-2x4e's closure is a floor delta (≥20), so migration is scored by the same instrument that guards it. Release notes can carry `jq call sites: 277 -> N`.

The same three mechanisms generalise to 902-5bf9's step form (`ok:litmus-step-forms:command=<n>:lua=<m>`) and, when a second caller exists, to sha256sum/shasum.

## 7. Rollout sequence

1. 1367-q9yc lands (yoga; relay in progress) — content-addressed memo, `fs.read`, `expect.*`.
2. 1375-rn9b `json get` / `yaml get` + parity fixture (Linux: lenovinha). Independent of 1.
3. 1375-tsfu ratchet guard (any host; after 2, needs `--parse-only`).
4. 1375-6pnd runner reads (any host; verify on yolanda and macbookair, where the defect bites).
5. 1375-btuf `lua_std` + sandboxed `lua` CLI (Linux; after 1 and 2).
6. 1375-2x4e fleet-critical callers (Linux; after 2 and 3; coordinate with 914-ahsy's relay).
7. 1375-8g5t hash/time verbs (Linux; independent; macOS verifies the `shasum` arm).
8. 1252-fg9e executor, then 1375-amye `run` verb, then 1353-ryhq on that verb (Linux, macOS verifies).
9. 902-5bf9 `steps:` form on the Observing environment (after 5), with its adoption counter.

Hosts: interchangeable Linux work goes to lenovinha then yoga; macOS verification to macbookair; Windows verification to yolanda; never macuahuitl.

## 8. Risks

- `preserve_order` on serde_json changes `Map` to IndexMap for every crate in the workspace; parity needs it, but the commit must say so and `./build.sh --check` must be green on all three platforms before the verb is relied on (green on one regime is not green).
- Two grammars: if bucket D callers are migrated by adding builtins to `json get` one at a time, the subset stops being enumerable. The ratchet header is the register of record; a builtin not listed there is not supported.
- 914-ahsy's relay edits the same loop callers 1375-2x4e names. On a duplicate fix, hold; the loser waits for the winner on origin.
- 1325-ygq5 refuses an orphan test script: every fixture above is named by a build.sh --check line in the same commit.
- The Cacheable allow-list is the security boundary for cached verdicts; `lua_std` adds to it, never widens it by deny (1367-upz6). `json.query` over `fs.read` is pure only because the memo is content-addressed — do not land 1375-btuf's Cacheable tables before 1367-q9yc.
- The Windows `run --detach` semantics (process group, not session) differ from Unix; the fixture asserts survival of the caller's exit rather than a session id there.
- Not measured: jaq's licence/dependency delta offline; the pre-fix FAIL of 1375-6pnd's fixture on this host (jq and yq are both present here), which is why that row makes the pre-fix run its first recorded event.
