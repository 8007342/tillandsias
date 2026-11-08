# Design — lua-door-environment-inheritance

<!-- @trace order:2029-39bt, spec:command-runtime -->

Row `2029-39bt`. Code is cited by SYMBOL. Every measurement below quotes the
command that produced it; every source claim names a file. The two registers
are kept apart on purpose.

## 1. Context — what exists

- `lua_predicate::base_env_command(argv)`: `env_clear()`, then
  `PROC_RUN_BASE_ENV_PASSTHROUGH`, then every variable whose name
  `starts_with("TILLANDSIAS_")`, then `PROC_RUN_BASE_ENV_FIXED`. Called by
  `prepare_shell` (`sh.run` / `expert.shell`, both installers, 1551-nyzb)
  and by `validate_proc` → `PreparedProc` (shared by `proc.run`,
  `proc.spawn`, `proc.chain` in `lua_process.rs`). The call's `env` table is
  applied after the fixed set, so a per-call literal wins today.
- `run_verb::base_env(additions)`: a SECOND implementation of the same three
  layers for `tillandsias-plan run --env K=V`. Same order, separately
  maintained. Two deciders of one decision.
- `script_run::parse_header`: leading `--` comment lines; knows `@class`,
  `@env` (names `env.get` may read — it reads them from the RUNNER's
  environment, `std::env::var`, not from the base set), `@read-env` (1384-ddua
  read roots). An unknown `@` directive is IGNORED — a misspelt header does
  nothing and says nothing.
- `script_run::register`: `env.get(name)` refuses an undeclared name with
  `env.get: '<n>' is not declared; add it to the header: -- @env <n>`.
- `script_run::emit_timing`: one JSON line into `TILLANDSIAS_TIMING_LOG`
  (`kind: script-run`, `name`, `verdict`, `exit`, `elapsed_ms`,
  `read_roots`, `ts_ms`). This is where inherited names belong.
- `command_policy::Request.env` carries the per-call additions so the fixture
  rules can read `GIT_DIR` / `GIT_COMMON_DIR` (1760-nn6u); `policy_gate` reads
  `TILLANDSIAS_POLICY_REGIME` from the runner's own environment; the regime
  is `interactive` unless that variable says otherwise. `FixtureScope::from_env`
  reads `TILLANDSIAS_FIXTURE_SCOPE` / `TILLANDSIAS_FIXTURE_GIT_DIRS`;
  `ConsentCtx::from_env` reads `TILLANDSIAS_SKILL` /
  `TILLANDSIAS_DESTRUCTIVE_RESET_OK`. All of these are `TILLANDSIAS_*` and
  reach nested runners ONLY because of the prefix passthrough.
- `command_policy::redact` already knows token VALUE shapes
  (`-----BEGIN` PEM bodies, `AKIA`/`ASIA` + 16 upper-alnum) and emits
  `<redacted:token>`.
- Existing fixtures: `tests/lua_proc.rs::the_child_environment_is_the_base_set`
  (sets `UNRELATED_1384` on the runner, asserts `C|UTC|unset`),
  `::the_legacy_shell_door_runs_where_it_was_authorised_from_the_base_environment`
  (1551-nyzb), `::scoped_spawn_preserves_fixed_environment_stdin_and_cacheable_process_absence`,
  `tests/lua_observing_boundary.rs::script_rooted_writes_keep_fixture_scope_and_declared_env_controls`.

### 1.1 The incident, by symbol

`scripts/test-build-image-installed-version-alias.sh` (gate step 747-knbp)
writes a fake `podman` whose first line of logic is `STORE="$FAKE_PODMAN_STORE"`
under `set -u`, then runs each arm as `env -i HOME=… PATH=… FAKE_PODMAN_STORE=…
bash build-image.sh forge`. The reverted port (`fdca0b2bc`) made
`build-image.sh::_verify_image_usable` run `scripts/lua/verify-image-usable.lua`
on the resolved plan binary; its `proc.run{argv={podman,…,"image","inspect",tag}}`
child started from the base set, `FAKE_PODMAN_STORE` was gone, and bash
answered `unbound variable`. A local run passed because the fixture's fake
tree had no runnable plan binary, so `_verify_image_usable` took its shell
fallback and the Lua path never ran (row 2029-39bt, context).

## 2. Threat model for a repo-checking runtime

Three things an environment can do to a decider, each with an incident or a
primary source behind it:

1. **Secret exfiltration into output or logs.** A child prints its
   environment (`printenv`, `env`, a crash dump, `set -x`), or a verdict line
   embeds a value. Measured here: 1551-nyzb F1. GitHub Actions' own guidance
   says value-redaction is best-effort ("Because there are multiple ways a
   secret value can be transformed, automatic redaction is not guaranteed")
   and that secrets must be referenced explicitly to reach a step at all
   (§8, sources 7–8). Name-level blocking is therefore the primary control;
   value-shape blocking is defence in depth.
2. **Code injection through loader and shell-init variables.** `LD_PRELOAD`,
   `LD_LIBRARY_PATH`, `DYLD_*` load code into any dynamically linked child;
   `BASH_ENV` / `ENV` source a file before a script runs; `PS4` runs
   expansions under `set -x`; `IFS` and `CDPATH` change word splitting and
   `cd`; `GIT_SSH_COMMAND`, `GIT_ASKPASS`, `SSH_ASKPASS`, `GIT_PROXY_COMMAND`,
   `GIT_EXEC_PATH` name a program git will run; `NIX_CONFIG` can set
   `post-build-hook`. sudo's default removal table lists exactly this family
   (§8, source 3: `IFS`, `CDPATH`, `LD_*`, `_RLD*`, `ENV`, `BASH_ENV`, `PS4`,
   `SHELLOPTS`, `BASHOPTS`, `GLOBIGNORE`, `PERL5OPT`, `PYTHON*`, `RUBYOPT`,
   `NODE_OPTIONS`, `GIT_SSH_COMMAND`, `GIT_CONFIG_*`, `GCONV_PATH`,
   `*=()*`, and `DYLD_*` on Apple), and notes the dynamic linker strips
   `LD_*`/`DYLD_*` from set-uid programs before sudo even starts.
3. **Nondeterministic verdicts.** Locale changes `sort` order and message
   text; `TZ` changes dates in output; `GIT_DIR` / `GIT_WORK_TREE` redirect
   which repository is judged (1442-22d2: a fixture wrote into the real
   checkout's git dir); `RUSTFLAGS` / `RUSTC_WRAPPER` / `CC` change what a
   build produces; `CARGO_TARGET_DIR` absent made a nested runner report
   `blocked:litmus-no-plan-binary` (1593-1ny6). Bazel's
   `--incompatible_strict_action_env` exists for this: a static `PATH`, no
   `LD_LIBRARY_PATH`, "can prevent cross-user caching if a shared cache is
   used" (§8, source 5). Nix clears the builder environment entirely and sets
   `PATH=/path-not-set`, `HOME=/homeless-shelter` (§8, source 4).

A fourth, specific to this project: **a nested runner losing its control
plane.** `TILLANDSIAS_POLICY_REGIME`, `TILLANDSIAS_FIXTURE_SCOPE`,
`TILLANDSIAS_HOST_KIND` decide what a nested `tillandsias-plan` may do. Drop
them and the nested policy decision changes silently (a fixture-regime run
would be judged `interactive` and ask for consent, or a forge would be judged
bare metal). The project namespace is therefore not optional passthrough; it
is the runtime's equivalent of systemd's "variables defined by the service
manager itself" (§8, source 1) and cargo's `CARGO_*` set for build scripts
(§8, source 6).

## 3. Survey — what mature systems do (digest; sources in §8)

| System | Default | Inherit (named) | Block | Override | Lesson taken |
|---|---|---|---|---|---|
| systemd (system manager) | Clean: a "small curated list" (`PATH` fixed, `LANG`, `USER`, `INVOCATION_ID`, …); services "generally do not inherit" the manager's env | `PassEnvironment=NAME…` from the manager's env; unset names silently ignored | `UnsetEnvironment=` applied LAST, removes even `Environment=`/PAM-set names; takes names or `NAME=VALUE` | `Environment=`, `EnvironmentFile=`; "the later source wins"; "not suitable for passing secrets" | A clean default with a NAMED pass list and a final unset step; precedence is a published order |
| sudo | `env_reset` on: new minimal env (`HOME MAIL SHELL LOGNAME USER SUDO_*`, plus what `env_keep`/`env_check` admit) | `env_keep`; `env_check` keeps a name only if its value has no `%` or `/` | `env_delete` (only when `env_reset` is off); default bad table is loader/shell-init/interpreter path vars; `*=()*` bash functions | — | Two block flavours: a NAME list and a VALUE-shape check; wildcards `*` allowed in all three lists; default lists are the canonical injection catalogue |
| Nix builder | Cleared; `PATH=/path-not-set`, `HOME=/homeless-shelter`, `NIX_STORE`, `NIX_BUILD_TOP`, `TMPDIR`… | `impureEnvVars` — fixed-output derivations ONLY, passed from the calling user's env | everything else | derivation attributes become variables | Inheritance is an exception scoped to the one derivation class that already has network; the default is total |
| Bazel | `--incompatible_strict_action_env` (default true): static `PATH`, no `LD_LIBRARY_PATH` | `--action_env=NAME` from the invocation env | `--action_env==NAME` unsets | `--action_env=NAME=VALUE` | Hermeticity is a cache-correctness property; inherit by name, and the flag text warns about shared-cache poisoning |
| Deno | No env access; `--allow-env=API_KEY` scopes to a name; `--deny-*` overrides `--allow-*` | `Deno.Command{env}` with `clearEnv=false` default | `clearEnv: true` ("Doesn't guarantee that only env variables are present, as the OS may set" some) | `env` option | Read permission is per NAME and separate from child env; a subprocess "runs as a separate program with its own permissions" |
| GitHub Actions | Secrets never implicit: `${{ secrets.X }}` must be written into `env:`/`with:`; not passed to fork-PR workflows (except `GITHUB_TOKEN`) | — | `::add-mask::` for non-secret sensitive values | `env` at workflow/job/step scope | Explicit reference is the control; redaction is "not guaranteed"; untrusted input goes through an intermediate variable, never inline |
| cargo | Build scripts get a documented `CARGO_*`/`OUT_DIR`/`TARGET`… set; `RUSTFLAGS` removed since 1.55 | `[env]` does NOT override an existing variable unless `force = true` | — | `[env] force`, `relative` | A project namespace is a curated, documented set; declared inputs (`rerun-if-env-changed`) make environment dependence visible |
| podman | Container env from image + `containers.conf` | `-e NAME` reads the host value "only if it is set on the host"; `-e PREFIX*` passes host names with the prefix | `--unsetenv`, `--unsetenv-all` | `-e NAME=VALUE`; precedence image < `--http-proxy` < `--env-host` < `--env-file` < `--env` | `--env-host` is "not available with the remote Podman client"; secrets have their own channel (`--secret`, a file under `/run/secrets` by default) |

What they agree on: a clean default; inheritance by NAME, declared where the
child is defined; a block step that beats every grant; secrets through a
separate channel (file or explicit reference), never through inheritance;
published precedence. What differs is whether prefixes are allowed (sudo and
podman: yes; systemd and Bazel: names only). This design allows none in v1
(§4.5).

## 4. The model

### 4.1 One builder, six steps, deterministic

`child_env::ChildEnv::for_call(script: Option<&Header>, call: &[(String,
String)], door: Door) -> Result<Vec<(OsString, OsString)>, EnvRefusal>` is
the ONLY function that turns a runner environment into a child environment.
`lua_predicate::base_env_command`, `run_verb::base_env` and any future door
call it. The steps, in the order applied:

| # | Layer | Source | Filtered by hard block? | Beats |
|---|---|---|---|---|
| 0 | **Hard block** (`ENV_BLOCK_NEVER`, `ENV_BLOCK_INHERIT`) | one table in `child_env.rs` | — | everything: it is a filter on every later inherited layer and a refusal for a per-call class-A name |
| 1 | **Base passthrough** (`ENV_BASE_PASSTHROUGH`, today's `PROC_RUN_BASE_ENV_PASSTHROUGH`, unchanged) | runner env | yes | — |
| 2 | **Project namespace** (`TILLANDSIAS_*`) | runner env | yes (this is the change) | layer 1 on a same name (none overlap today) |
| 3 | **Declared inherit** (`@env-profile`, `@env-inherit`) | runner env, only the names the SCRIPT declared | yes, and refused at header time | layers 1–2 (same value anyway: all inherit) |
| 4 | **Fixed overrides** (`ENV_FIXED`, today's `PROC_RUN_BASE_ENV_FIXED`) | literals | n/a | layers 1–3: the caller's `LC_ALL` never wins; a header declaring a fixed name is refused |
| 5 | **Per-call explicit** (`proc.run{env=…}`, `run --env K=V`) | literals in the script or on the command line | class A refused (raise); class B allowed | layers 1–4: a literal in the source is a deliberate, reviewable choice — `test-forge-empty-project-starts.lua` sets `GIT_CONFIG_GLOBAL=/dev/null` per call today and keeps working |

"Deterministic" means: given the same runner environment, the same script
header and the same call, the child environment is the same byte sequence,
and every name in it can be attributed to exactly one layer. `tillandsias-
plan script env <script.lua>` prints that attribution (§4.8).

The run verb has no script header; its layer 3 comes from `--env-profile
NAME` and `--env-inherit NAME` flags, same table, same hard block (§4.9).

### 4.2 The hard block — class A, never

A class-A name never reaches a child by any layer, and `env.get` refuses it.
Declaring it in a header is a refusal before script code runs; setting it per
call raises a Lua error (a programmer error, like an unknown `proc.run`
field). The refusal names the VARIABLE and its class, never a value:

```
refused:env-inherit:never:LD_PRELOAD:loader
refused:env-inherit:never:GH_TOKEN:credential-shape
```

**A1 — loader and shell-init injection** (sudo's default removal table,
§8 source 3, plus git's program-naming variables): `LD_*`, `DYLD_*`,
`_RLD*`, `LDR_*`, `LIBPATH`, `SHLIB_PATH`, `GCONV_PATH`, `NLSPATH`,
`LOCALDOMAIN`, `RES_OPTIONS`, `HOSTALIASES`, `BASH_ENV`, `ENV`, `SHELLOPTS`,
`BASHOPTS`, `GLOBIGNORE`, `PS4`, `IFS`, `CDPATH`, `FPATH`, `ZDOTDIR`,
`NULLCMD`, `READNULLCMD`, `TMPPREFIX`, `PERL5OPT`, `PERLLIB`, `PERL5LIB`,
`PERL5DB`, `PERLIO_DEBUG`, `PYTHON*` (also banned by project rule),
`RUBYLIB`, `RUBYOPT`, `NODE_OPTIONS`, `NODE_PATH`, `JAVA_TOOL_OPTIONS`,
`_JAVA_OPTIONS`, `CLASSPATH`, `TERMINFO`, `TERMINFO_DIRS`, `TERMPATH`,
`TERMCAP`, `GIT_SSH_COMMAND`, `GIT_SSH`, `GIT_ASKPASS`, `GIT_PROXY_COMMAND`,
`GIT_EXEC_PATH`, `GIT_EXTERNAL_DIFF`, `GIT_PAGER`, `SSH_ASKPASS`,
`SUDO_ASKPASS`, `NIX_CONFIG`, `NIX_USER_CONF_FILES`. Any value beginning
with `() ` (a bash function export) is refused under any name (`*=()*`).
Not in A1 on purpose: `CARGO_HOME` is a locator a cargo child needs (profile
`cargo`); cargo's injection surface is `RUSTC_WRAPPER` /
`RUSTC_WORKSPACE_WRAPPER`, which are class B (§4.3) because a fixture may
legitimately point a per-call literal at a fake compiler.

**A2 — credential shape.** A name is credential-shaped when, after
upper-casing, EITHER its terminal segment is one of `_TOKEN`, `_SECRET`,
`_PASSWORD`, `_PASSWD`, `_PASSPHRASE`, `_PASS`, `_KEY`, `_AUTH`,
`_CREDENTIALS`, `_CREDENTIAL`, `_COOKIE`, `_SESSION`; OR it contains one of
`TOKEN`, `SECRET`, `PASSWORD`, `PASSWD`, `PASSPHRASE`, `API_KEY`,
`ACCESS_KEY`, `PRIVATE_KEY`, `SECRET_KEY`, `SIGNING_KEY`, `CLIENT_SECRET`,
`CREDENTIAL`; OR it begins with `AWS_`, `AZURE_`, `GOOGLE_APPLICATION_`,
`CLOUDFLARE_API_`, `CF_API_`; OR it is one of the exact names `GH_TOKEN`,
`GITHUB_TOKEN`, `GH_ENTERPRISE_TOKEN`, `NPM_TOKEN`, `CARGO_REGISTRY_TOKEN`,
`VAULT_TOKEN`, `HF_TOKEN`, `HUGGING_FACE_HUB_TOKEN`, `OPENAI_API_KEY`,
`ANTHROPIC_API_KEY`, `SSH_AUTH_SOCK`, `GPG_AGENT_INFO`, `KRB5CCNAME`,
`DOCKER_AUTH_CONFIG` — UNLESS its terminal segment is a **locator or label
suffix** from the closed list `_FILE`, `_PATH`, `_DIR`, `_ID`, `_NAME`,
`_FP`, `_LOG`, `_URL`, `_ADDR`, `_SRC`, `_COUNT`, `_ENV_FILE`, `_SINK_FILE`.
A locator names WHERE a secret is, which is exactly the channel this design
wants secrets to travel by (podman `--secret` mounts a file; the project's
own `TILLANDSIAS_VAULT_TOKEN_FILE`, `VAULT_TOKEN_FILE`,
`TILLANDSIAS_AGY_TOKEN_ENV_FILE` follow it). The shape test is one pure
function, `child_env::credential_shape(name) -> Option<Shape>`, with a
table-driven unit test holding every name in §5.3 and every name in the
`TILLANDSIAS_*` census that matched `(TOKEN|KEY|SECRET|PASS)`.

Why a shape rule and not a list: the runner cannot know every credential
name an operator will export (sudo's lists cover injection, not secrets,
because sudo's author could not enumerate them either). A shape catches the
ones nobody listed; the locator suffixes keep the project's existing
file-locator convention working. The cost — a false positive on a name that
is not a secret — is paid by renaming the variable, which is cheap, visible
and permanent, and §5.3 shows there are exactly two such names in the tree
today.

**A3 — value shape, defence in depth.** An inherited value (layers 1–3)
that matches `command_policy::redact`'s token shapes (PEM header, AWS key
id; the implementation adds `ghp_`, `github_pat_`, `glpat-`, `sk-`,
`xox[abp]-` prefixes to the same function) is refused with the NAME and
`value-shape`, never the value. A proxy URL (profile `net-egress`) whose
authority part contains `@` (userinfo) is refused the same way. Per-call
literals (layer 5) are exempt: they are in the source and reviewed there.

### 4.3 Class B — inherit-blocked, per-call allowed

Never inherited from the caller by layers 1–3 (declaring one is refused as
`refused:env-inherit:inherit-blocked:<NAME>:<reason>`), but a script may set
one PER CALL with a literal. These redirect or de-determinise a tool, and
fixtures set them on purpose to build a fake world:

- `GIT_DIR`, `GIT_WORK_TREE`, `GIT_COMMON_DIR`, `GIT_INDEX_FILE`,
  `GIT_OBJECT_DIRECTORY`, `GIT_ALTERNATE_OBJECT_DIRECTORIES`,
  `GIT_CEILING_DIRECTORIES`, `GIT_NAMESPACE`, `GIT_CONFIG_GLOBAL`,
  `GIT_CONFIG_SYSTEM`, `GIT_CONFIG_NOSYSTEM`, `GIT_CONFIG_COUNT`,
  `GIT_CONFIG_KEY_*`, `GIT_CONFIG_VALUE_*`, `GIT_CONFIG_PARAMETERS`,
  `GIT_OPTIONAL_LOCKS`, `GIT_AUTHOR_*`, `GIT_COMMITTER_*` (redirection;
  1442-22d2; the fixture rules read `GIT_DIR`/`GIT_COMMON_DIR` from the
  per-call env, 1760-nn6u);
- `RUSTFLAGS`, `CARGO_BUILD_RUSTFLAGS`, `CARGO_ENCODED_RUSTFLAGS`,
  `RUSTC`, `RUSTDOC`, `RUSTC_WRAPPER`, `RUSTC_WORKSPACE_WRAPPER`, `RUSTUP_TOOLCHAIN`,
  `CC`, `CXX`, `AR`, `LD`, `CFLAGS`, `CXXFLAGS`, `LDFLAGS`, `MAKEFLAGS`,
  `SOURCE_DATE_EPOCH` (what a build produces);
- `NIX_PATH`, `NIX_CONF_DIR`, `NIX_REMOTE_SYSTEMS`, `NIX_BUILD_HOOK` (what
  nix evaluates and where it builds);
- `WSLENV` (how Windows variables cross into WSL; the cross-locus
  constructor in `wsl.rs` passes nothing implicitly, 795-jjw3);
- `TERM`, `COLORTERM`, `NO_COLOR`, `CLICOLOR_FORCE`, `PAGER`, `EDITOR`,
  `VISUAL`, `LESS`, `MANPAGER` (output shape; a decider's child must not
  colour or page by the caller's taste).

### 4.4 Base passthrough and fixed overrides — unchanged

Layer 1 is today's `PROC_RUN_BASE_ENV_PASSTHROUGH`, name for name, with its
order citations (1593-1ny6 for `CARGO_TARGET_DIR`, 1838-nwyn for
`XDG_RUNTIME_DIR` / `DBUS_SESSION_BUS_ADDRESS`). Layer 4 is today's
`PROC_RUN_BASE_ENV_FIXED` (`LC_ALL=C`, `LANG=C`, `TZ=UTC`,
`GIT_TERMINAL_PROMPT=0`). Two candidates for layer 4 are NOT added by this
design and are listed as a decision (§9, Q4): `TERM=dumb` and
`GIT_CONFIG_NOSYSTEM=1`.

### 4.5 Declared inherit — the header

Two directives, parsed by `script_run::parse_header` alongside `@class`,
`@env`, `@read-env`:

```lua
-- @env-profile podman
-- @env-inherit CONTAINER_SSHKEY TOOLBOX_PATH
```

- `@env-profile NAME…` names one or more profiles from
  `child_env::ENV_INHERIT_PROFILES`, a `&[(name, &[(var, why, order)])]`
  table in Rust. Each entry carries the reason the name is safe to inherit
  and the order that introduced it. The table is the ONE answer to "what
  does the podman profile pass" (the same reason `PROC_RUN_BASE_ENV_PASSTHROUGH`
  is one constant).
- `@env-inherit NAME…` adds exact names for a one-off. Each must be a valid
  variable name (ASCII letters, digits, underscore; not starting with a
  digit), not hard-blocked, not fixed, not already base.
- **No prefixes or globs in v1.** Every need in the audit (§5) is a finite,
  documented set: podman(1) enumerates its environment; cargo's reference
  does; the proxy convention is six names and a handful of CA locators. A
  prefix would have to justify why no name under it can be a credential
  (coordinator constraint 1), and the only prefix anyone has asked for,
  `CONTAINERS_*`, has four documented members. The grammar RESERVES a
  trailing `*` (a header containing one is refused with
  `refused:env-inherit:glob-not-supported:<PATTERN>`), so adding prefixes
  later is a spec change, not a parser surprise. If one is ever added, it
  lives in a profile (central, reviewed, with a `why`), never in a script,
  and the hard block still filters every name it admits.
- **Why profiles AND names, not one of them.** Names alone put the podman
  list into every podman-running script (twelve on the floor name
  `TILLANDSIAS_PODMAN`; 84 run podman) and let them drift. Profiles alone
  make every one-off a Rust change. A profile is the default spelling; a
  bare name is for the variable only one script needs, and a name that
  appears in three scripts is a review signal to promote it.
- **Why the header and not the call.** The header is read before any script
  code runs, so a refusal is a refusal of the SCRIPT, with no partial
  effects; it is grep-able across the tree (`/usr/bin/grep -rn -- '^-- @env-
  profile' scripts/lua`), which is how the fleet audits `@env` and
  `@read-env` today; and it is per script, which is the unit constraint 1
  names.
- **Unknown directives are refused.** `parse_header` today ignores an
  unknown `@` line; under this design a `--` header line starting with `@`
  that is not one of `@trace`, `@class`, `@env`, `@read-env`,
  `@env-profile`, `@env-inherit`, `@research`, `@cheatsheet` is
  `refused:script-header:unknown-directive:<word>`. Without this, a typo
  (`@env-inherits`) silently yields today's behaviour, and a script run on
  an older binary would too — the acceptance fixture therefore also asserts
  the child SEES the variable, not merely that the runner accepted the
  header.

### 4.6 Readable, or passed only?

**Passed only.** A name in `@env-profile` / `@env-inherit` reaches children
and is invisible to `env.get`. `-- @env NAME` stays the read grant. A script
that needs both writes both lines. Reasons:

- Least privilege, two questions: "what can this script read" and "what can
  its children see" are different audit questions and get different grep
  answers.
- A value the script never holds cannot be concatenated into a verdict line,
  a log line or a `fs.write`.
- The forward-by-hand pattern (`check-forge-service-health.lua`'s `FORWARD`
  table) keeps working for scripts that genuinely need to read AND pass; it
  is simply no longer the only way.
- `env.get` of a class-A name is refused (`env.get: 'GH_TOKEN' is
  credential-shaped and cannot be read; see design 2029-39bt §4.6`). The one
  script that does it today, `scripts/lua/litmus-helper-nix-cache-size.lua`,
  migrates to one of: (a) let the `gh` child authenticate itself from its own
  store under `HOME` (base) or `GH_CONFIG_DIR` (profile `gh`); (b) obtain the
  token from a child (`proc.run{argv={"gh","auth","token"}}`) and pass it per
  call — the value then comes from a program the script ran, which is "a
  source the script reads"; (c) a `GH_TOKEN_FILE` locator declared `@env`,
  read with `fs.read` under `@read-env`, passed per call. (c) is the
  project's existing pattern (`TILLANDSIAS_VAULT_TOKEN_FILE`).

### 4.7 Conflicts and precedence, spelled out

| Situation | Result |
|---|---|
| Header declares a class-A name | refused before script code runs, names the variable and class |
| Header declares a class-B name | refused (`inherit-blocked`), remedy says "set it per call with a literal" |
| Header declares a fixed name (`TZ`) | refused (`fixed`) |
| Header declares a base name (`PATH`) | accepted, no-op, one `note:` line (it is already inherited) |
| Header declares an unknown profile | refused, lists the known profile names |
| Header declares a name that is unset on the caller | accepted; the child does not get it; recorded in `env_absent` (systemd: "silently ignored"; here: silently absent from the child, loudly present in the record) |
| Same name in base and declared | one entry, the runner's value |
| Per-call `env` sets a fixed name | per-call wins (today's behaviour; visible in source) |
| Per-call `env` sets a declared name | per-call wins |
| Per-call `env` sets a class-A name | Lua error naming the variable (today: silently passed — `test-forge-empty-project-starts.lua` sets none, so nothing shipped breaks) |
| Per-call `env` sets a class-B name | allowed |
| Inherited value fails the value-shape check | refused, names the variable, `value-shape` |
| `TILLANDSIAS_*` name is credential-shaped | not inherited (hard block applies to layer 2); the hygiene guard (§4.10) makes this a tree-level refusal so it is fixed at the source |

### 4.8 Observability — names, never values

- `script_run::emit_timing`'s record gains `env_profiles: [..]`,
  `env_inherited: [NAME, ..]` (declared and present on the caller),
  `env_absent: [NAME, ..]` (declared and unset). No values, no base or
  namespace names (those are the same on every run of a host and would be
  noise). A fixture asserts the record carries the names and that
  `/usr/bin/grep -c <value>` over the log is 0.
- `tillandsias-plan script env <script.lua>` — a read-only verb that prints,
  for the script's effective policy, one line per name: `NAME layer=<base|
  namespace|profile:<p>|inherit|fixed> present=<yes|no>`, and the refusal it
  would give, if any, without running the script. This is the tool the
  747-knbp incident lacked: the question "would this child see
  `FAKE_PODMAN_STORE`" had no cheap answer.
- The `run` verb's `--json` result gains the same three arrays.

### 4.9 Windows, WSL and macOS

- **Windows names are case-insensitive** (`Path` and `PATH` are one
  variable). The hard block, the shape test and profile matching compare
  case-insensitively on Windows and case-sensitively elsewhere; the base
  list already spells both `SystemRoot` and `SYSTEMROOT` for this reason.
  The second regime for every new fixture here is yolanda-windows
  (STEP_SECOND_REGIME, memory rule).
- **WSL**: `WSLENV` is class B. The cross-locus constructor passes argv as
  JSON (`--argv-json -`, spec req `48b22c5d`) and no environment; a script
  that needs a Windows variable inside WSL sets `WSLENV` per call with a
  literal.
- **macOS**: `DYLD_*` is class A (sudo's `__APPLE__` table). Profile
  `macos-toolchain` holds `DEVELOPER_DIR` and `SDKROOT` (locators the build
  scripts read). `TMPDIR` is per-user on macOS and is already base.
- **Podman remote**: podman(1) says `CONTAINER_HOST` "Automatically enables
  --remote option" and `--env-host` is not available to the remote client.
  The profile `podman` passes `CONTAINER_HOST` / `CONTAINER_CONNECTION` /
  `CONTAINER_SSHKEY` so a Lua child drives the same service its caller does
  (the macOS and Windows hosts reach podman through `TILLANDSIAS_PODMAN_REMOTE_URL`
  or `CONTAINER_HOST` in `scripts/common.sh`).

### 4.10 The `TILLANDSIAS_*` layer, re-examined under constraint 1

The question: is a prefix passthrough of 920 names a "blanket pass-through"?

Measured: `/usr/bin/grep -rhoE 'TILLANDSIAS_[A-Z_]*(TOKEN|KEY|SECRET|PASS)[A-Z_]*'
scripts crates | sort -u` on the worktree at `c6fc0fe68` gives fourteen
names. Read one by one (file cited):

| Name | What it is | Under the shape rule |
|---|---|---|
| `TILLANDSIAS_COORD_CLIENT_SECRET` | Access service-token secret, `crates/tillandsias-plan/src/coordinator_client.rs` | **blocked** (correct: a secret; the binary reads it from ITS OWN env, children never needed it) |
| `TILLANDSIAS_KEY_PASS` | CA key passphrase, `crates/tillandsias-headless/src/ca_key_store.rs` `PASS_ENV` | **blocked** (correct) |
| `TILLANDSIAS_CONSENT_TOKEN` | consent token; appears only as `env_remove` in `tests/lua_proc.rs` | blocked (correct; a one-shot authorisation must not propagate) |
| `TILLANDSIAS_WRAPPER_TOKEN` | process-tree MARKER, `scripts/with-tillandsias-builder.sh` exports it so `lib-dispatch-reap.sh::tillandsias_reap_marked` can find the subtree | blocked — **false positive**; the reaper needs it on children. Rename to `TILLANDSIAS_WRAPPER_MARK` (6 files, tasks.md 2.3) |
| `TILLANDSIAS_NOTARY_KEY` | path to a `.p8`, `scripts/build-macos-dmg.sh` | blocked — false positive; rename `TILLANDSIAS_NOTARY_KEY_FILE` (3 files) |
| `TILLANDSIAS_NOTARY_KEY_ID`, `TILLANDSIAS_PUSH_KEY_ID`, `TILLANDSIAS_PUSH_KEY_FP`, `TILLANDSIAS_NIX_CACHE_KEY_NAME` | identifiers | allowed (`_ID`, `_FP`, `_NAME` suffixes) |
| `TILLANDSIAS_VAULT_TOKEN_FILE`, `TILLANDSIAS_AGY_TOKEN_ENV_FILE`, `TILLANDSIAS_TOKENS_LOG`, `TILLANDSIAS_RUNTIME_SECRET_SRC` | locators | allowed (`_FILE`, `_ENV_FILE`, `_LOG`, `_SRC`) |
| `TILLANDSIAS_FALSE_PASS_OUT` | a fixture's output path ("false pass" is a verdict word) | allowed (`_PASS` is not terminal) |

Decision: **keep the prefix layer, apply the hard block to it, add a
hygiene guard, rename two names.** Justification against constraint 1:

1. The namespace is OWNED and ENUMERABLE. Unlike the caller's environment,
   every `TILLANDSIAS_` name is written by this tree, so the tree can be
   held to a naming rule, and a guard can refuse a new name that breaks it.
   That is what makes "a prefix that cannot carry a credential" a checkable
   claim here and not elsewhere.
2. The layer is the control plane. The regime, fixture scope, host kind,
   plan binary, timing log and gate diff base MUST reach nested runners.
   Replacing the prefix with an explicit list means one missed name is a
   silent policy change in a nested runner — the failure mode "a guard fed
   its own subject" warns about, in the safety-relevant direction.
3. The two real secrets are now blocked by shape, and the hygiene guard
   (`scripts/lua/check-env-namespace-hygiene.lua`, tasks.md 2.4) refuses
   any OTHER credential-shaped `TILLANDSIAS_` name in the tree unless it is
   listed in `child_env::TILLANDSIAS_CREDENTIAL_NAMES` (today:
   `COORD_CLIENT_SECRET`, `KEY_PASS`, `CONSENT_TOKEN`). A new secret must be
   spelled so the block catches it; a new non-secret must not be.

The coordinator asked for this layer to be looked at again; §9 Q1 puts the
stricter alternative (an explicit control-plane list) on the table with its
cost, so the decision is theirs with the trade named.

### 4.11 Fixtures that fake a caller's tool

A fake `podman`, `git`, `gh`, `cargo`, `toolbox` or `tillandsias` on a
fixture's `PATH` is a caller tool too, and the 747-knbp incident is what
happens when it reads a bespoke name. Measured on the floor
(`scripts/portability/shell-decider-floor.txt`, 592 files present): 9
fixtures write a fake tool into a `bin/` on `PATH`; 17 read an ad-hoc `FAKE_*`
/ `*_CALLS` / `*_ARGV_LOG` name (`/usr/bin/grep -lE '\$\{?(FAKE_[A-Z_]+|
[A-Z_]+_(CALLS|ARGV_LOG|CALLS_FILE))'` over the floor list). Rule, to be
written into `methodology/` (tasks.md 4.1):

- A fake tool receives its configuration from a FILE beside itself
  (`"${0%/*}/store"`; bash sets `$0` to the resolved path for a PATH
  lookup), or through a `TILLANDSIAS_FIXTURE_*` name (layer 2, so no new
  door, and the name says what it is). Never through a bespoke `FAKE_*`
  name, and never through a profile (a `fixtures` profile would be the
  blanket constraint 1 forbids).
- The `TILLANDSIAS_FIXTURE_*` route works BECAUSE layer 2 is a prefix. If
  §9 Q1 ever narrows layer 2 to an explicit list, `TILLANDSIAS_FIXTURE_*`
  must be on it as a sub-prefix or every double moves to the file form.

For 747-knbp specifically: `FAKE_PODMAN_STORE` → `TILLANDSIAS_FIXTURE_PODMAN_STORE`
in the fake's `STORE=` line and the arm's `env -i` line. Two lines.

### 4.12 Migration

1. No header → exactly today's behaviour, minus class-A names in layer 2.
   The only shipped names that change are the two renames (§4.10); land
   them FIRST (tasks.md 2.3), then the builder.
2. Measure before flipping: run one `./build.sh --check` on a host with the
   builder in a `TILLANDSIAS_ENV_BLOCK_WARN=1` mode that logs would-be
   refusals to the timing record without applying them; the list of names
   is the migration's first datum. The warn mode is removed with the flip
   (memory rule: remove workarounds, do not stack guards).
3. Scripts that forward by hand today keep working unchanged; they MAY
   switch to a profile line and drop the forward table when touched.
4. The acceptance port (tasks.md 3.1) is the first script to use
   `@env-profile`, and its side-by-side arms are the first regime.

### 4.13 The shell-to-lua backlog and the carried waiver

- `blocked-by:2029-39bt` remains a valid `Carried-Waiver` reason until
  tasks.md 3.1 lands; after that, a waiver naming it is stale and the
  obligations guard should say so (tasks.md 4.2 adds the reason to the
  "retired reasons" list it already keeps for others).
- Option (b) of the row — exclude caller-tool scripts from the counter — is
  rejected: 84 of 592 floor scripts run podman, 286 run git, 122 run cargo,
  40 run toolbox, 23 run gh (`cut -f2 env-audit.tsv | sort | uniq -c` over
  the audit, §5.1). Excluding "scripts that run a tool" excludes most of the
  backlog; the counter would stop measuring anything.
- The obligations guard's offer line gains a hint when the offered `.sh`
  reads a profile name (`profile-hint:podman`), so the porter knows which
  header line to write (tasks.md 4.2, optional).

## 5. Audit of the tree

Method: `scripts/portability/shell-decider-floor.txt` (593 lines, 592 files
present) was read file by file; for each, every `${NAME` / `$NAME` with an
upper-case name was collected and every external tool word was collected.
Shell locals (`WORK`, `PLAN`, `OUT`, …) dominate the raw census and were
filtered by a list of known external names. Output:
`/tmp/claude-1000/-var-home-tlatoani-claudia-tillandsias/d256f899-c79b-4758-b8d5-dd94c7a9c63b/scratchpad/env-audit.tsv`
(scratch; not committed). The commands are in §5.1–5.2.

### 5.1 Tools the backlog runs (scripts per tool)

`cut -f2 env-audit.tsv | tr ' ' '\n' | /usr/bin/grep -v '^$' | sort | uniq -c
| sort -rn`: git 286, cargo 122, podman 84, toolbox 40, gh 23, curl 20, nix
9, rustup 7, wsl.exe 6, ssh 5. Six floor scripts source
`scripts/common.sh` (which reads `CONTAINER_HOST` for podman-remote);
twelve name `TILLANDSIAS_PODMAN`.

### 5.2 External environment names the backlog reads (scripts per name)

Filtered census (same file, column 3, against the external-name list in the
command history): `CARGO_TARGET_DIR` 12 (base), `GIT_CONFIG_GLOBAL` 8
(fixtures isolating git config — per-call literal, class B), `XDG_CACHE_HOME`
5, `XDG_RUNTIME_DIR` 4 (base), `FAKE_BIN` 4 (fixture double), `CARGO_HOME`
4, `XDG_CONFIG_HOME` 3, `CODEX_HOME` 3, `VAULT_TOKEN_FILE` 2, `TOOLBOX_PATH`
2, `LOCALAPPDATA` 2 (base), `VAULT_*` locators (ADDR, CACERT, ROLE_ID_FILE,
SECRET_ID_FILE, TOKEN_SINK_FILE, HELPER, …) 1 each, `GITHUB_TOKEN` 1,
`GH_TOKEN` 1, `GIT_DIR` 1, `GIT_AUTHOR_NAME` / `GIT_COMMITTER_NAME` 1,
`RUSTUP_HOME` 1, `NIX_REMOTE` 1, `SYSTEMROOT` 1, and a tail of
fixture-private names (`FAKE_PODMAN_STORE`, `FAKE_PODMAN_PS`, `FAKE_TOKEN`,
`FAKE_HOME`, `FAKE_ROOT`, `PODMAN_CALLS`, `GIT_ARGV_LOG`, `OPENCODE_*`,
`CODEX_*`, `CLAUDE_*`), 1 each.

Lua scripts already declaring non-`TILLANDSIAS_` names (`/usr/bin/grep -rh
-- '^-- @env ' scripts/lua/ | … | sort | uniq -c`): `PATH` 85, `HOME` 21,
`XDG_RUNTIME_DIR` 13, `CARGO_TARGET_DIR` 5, Windows basics 3–4, the six
proxy names 3 each, `DBUS_SESSION_BUS_ADDRESS` 3, `SSL_CERT_FILE` /
`CURL_CA_BUNDLE` 2, `VAULT_ADDR` / `VAULT_CACERT` / `VAULT_TOKEN_FILE` 1,
`GH_TOKEN` / `GITHUB_TOKEN` 1 (§4.6), `USER` 1, `OS` 1.

### 5.3 Classification

| Need | Names | Class | Where it goes |
|---|---|---|---|
| Find the same podman the caller uses | `CONTAINER_HOST`, `CONTAINER_CONNECTION`, `CONTAINER_SSHKEY`, `CONTAINERS_CONF`, `CONTAINERS_CONF_OVERRIDE`, `CONTAINERS_REGISTRIES_CONF`, `CONTAINERS_STORAGE_CONF`, `PODMAN_CONNECTIONS_CONF`, `STORAGE_DRIVER`, `STORAGE_OPTS`, `REGISTRY_AUTH_FILE`, `DOCKER_HOST`, `XDG_CONFIG_HOME`, `XDG_DATA_HOME` | inherit (locators and socket URLs; podman(1) ENVIRONMENT) | profile `podman` |
| Reach the network the way the host does | `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY`, `ALL_PROXY` and lower-case twins, `SSL_CERT_FILE`, `SSL_CERT_DIR`, `CURL_CA_BUNDLE`, `GIT_SSL_CAINFO`, `NIX_SSL_CERT_FILE`, `CARGO_HTTP_CAINFO`, `NODE_EXTRA_CA_CERTS` | inherit with value check (no userinfo in a proxy URL) | profile `net-egress` |
| Build with the caller's toolchain location | `CARGO_HOME`, `RUSTUP_HOME`, `CARGO_BUILD_JOBS`, `CARGO_NET_OFFLINE`, `CARGO_INCREMENTAL` (`CARGO_TARGET_DIR` is base) | inherit | profile `cargo` |
| Start the builder toolbox | `TOOLBOX_PATH`, `USER`, `LOGNAME` (`XDG_RUNTIME_DIR`, `DBUS_SESSION_BUS_ADDRESS` are base, 1838-nwyn) | inherit | profiles `toolbox`, `session` |
| Talk to Vault | `VAULT_ADDR`, `VAULT_CACERT`, `VAULT_CAPATH`, `VAULT_NAMESPACE`, `VAULT_TOKEN_FILE`, `VAULT_ROLE_ID_FILE`, `VAULT_SECRET_ID_FILE`, `VAULT_TOKEN_SINK_FILE` | inherit (locators) | profile `vault` |
| Use the caller's nix store | `NIX_REMOTE`, `NIX_STORE_DIR`, `NIX_STATE_DIR`, `NIX_LOG_DIR` | inherit | profile `nix` |
| Drive gh | `GH_HOST`, `GH_REPO`, `GH_CONFIG_DIR` | inherit | profile `gh` |
| Cache locations | `XDG_CACHE_HOME`, `XDG_STATE_HOME` | inherit | profile `session` |
| macOS toolchain | `DEVELOPER_DIR`, `SDKROOT` | inherit | profile `macos-toolchain` |
| Locale, zone, prompts | `LC_ALL`, `LANG`, `TZ`, `GIT_TERMINAL_PROMPT` | override | fixed (unchanged) |
| Which repo / what a build produces / output shape | `GIT_DIR`, `GIT_WORK_TREE`, `GIT_CONFIG_*`, `GIT_AUTHOR_*`, `RUSTFLAGS`, `RUSTC_WRAPPER`, `CC`, `NIX_PATH`, `NIX_CONF_DIR`, `WSLENV`, `TERM`, `PAGER`, … | class B: per-call literal only | §4.3 |
| Loader / shell-init / program-naming | `LD_*`, `DYLD_*`, `BASH_ENV`, `ENV`, `PS4`, `IFS`, `GIT_SSH_COMMAND`, `GIT_ASKPASS`, `NIX_CONFIG`, `PYTHON*`, … | class A: never | §4.2 A1 |
| Credentials | `GH_TOKEN`, `GITHUB_TOKEN`, `SSH_AUTH_SOCK`, `AWS_*`, `VAULT_TOKEN`, `CARGO_REGISTRY_TOKEN`, `*_TOKEN`, `*_SECRET`, `*PASSWORD*`, `*_KEY`, `TILLANDSIAS_COORD_CLIENT_SECRET`, `TILLANDSIAS_KEY_PASS`, `FAKE_TOKEN` | class A: never; reach a child only per call from a file or a program the script ran | §4.2 A2, §4.6 |
| Fixture doubles | `FAKE_PODMAN_STORE`, `FAKE_BIN`, `*_CALLS`, `*_ARGV_LOG`, … | file beside the fake, or `TILLANDSIAS_FIXTURE_*` | §4.11 |
| Agent homes | `CODEX_HOME`, `OPENCODE_*`, `CLAUDE_*` | not inherited; the three floor fixtures that read them set them per call when ported | — |

### 5.4 Which backlog scripts need which profile (summary)

- `podman`: `verify-image-usable.sh` (acceptance), `build-image.sh` (its
  Lua children), the twelve `TILLANDSIAS_PODMAN` deciders, the six
  `common.sh`-sourcing scripts, and any fixture whose fake podman moves to
  `TILLANDSIAS_FIXTURE_*`. 84 floor scripts run podman; most through
  `TILLANDSIAS_PODMAN` or `common.sh`, so the profile covers them as they
  port.
- `net-egress` (+ `vault`): the three health/tier checks already forwarding
  by hand (`check-forge-service-health.lua`, `check-local-expert-health.lua`,
  `check-imagegen-tier-sources-ungated.lua`), the 20 curl-running floor
  scripts, the nix-cache helpers.
- `cargo`: the 122 cargo-running scripts that do more than
  `--target-dir` (`CARGO_HOME` 4, `RUSTUP_HOME` 1 measured; most need
  nothing beyond base).
- `toolbox` + `session`: the 40 toolbox-running scripts (base already
  carries the two 1838-nwyn names; `TOOLBOX_PATH` 2).
- `gh`: the 23 gh-running scripts — none needs a token inherited; `gh`
  authenticates from `HOME`.
- `nix`: the 9 nix-running scripts (`NIX_REMOTE` 1).
- None: the 286 git-running scripts (git needs nothing inherited; fixtures
  set `GIT_CONFIG_GLOBAL` per call).

## 6. Alternatives considered and rejected

1. **Row option (b): exclude caller-tool scripts from the backlog.** §4.13:
   it excludes most of the backlog and turns the counter into noise. It also
   leaves the 920-name blanket and the two secrets in place.
2. **Blanket inheritance under `TILLANDSIAS_POLICY_REGIME=fixture`.** A
   fixture is exactly where fake tools and odd variables live, so it is the
   regime most likely to carry something surprising; and the regime is set
   by the caller, so this is a caller-chosen widening — constraint 1.
3. **A caller-side list (`TILLANDSIAS_ENV_INHERIT=NAME,NAME`).** Moves the
   allowlist from the reviewed script to the unreviewed caller; a fixture
   could widen anything for any script. Also the shape of the 1551-nyzb
   regression: the environment deciding the environment.
4. **Inherit everything minus a denylist** (sudo with `env_reset` off, Deno
   `clearEnv=false`). The denylist can never be complete for secrets
   (nobody can enumerate operator-exported names), and it is the pre-1551
   state.
5. **Value masking instead of name blocking** (GitHub Actions redaction).
   GitHub's own page says it is "not guaranteed"; a transformed or
   structured value escapes. Kept only as defence in depth (A3).
6. **Prefixes in scripts (`-- @env-inherit CONTAINERS_*`).** Every real need
   is finite and documented; a prefix needs a per-prefix credential argument
   that belongs in one reviewed place, not in each script. Grammar reserved,
   not implemented (§4.5).
7. **Declared-inherit readable by `env.get`.** Rejected for least privilege
   (§4.6); `@env` exists for reading.
8. **A `fixtures` profile for `FAKE_*`.** A profile over a free prefix of
   fixture-invented names is a blanket. §4.11 gives doubles two sanctioned
   channels instead.
9. **Narrowing `TILLANDSIAS_*` to an explicit list now.** Safety-relevant
   control-plane names would have to be enumerated and kept complete; one
   miss is a silent regime change in a nested runner. Offered as §9 Q1 with
   that cost, not chosen by default.
10. **Putting the model in `.tillandsias/command-policies.yaml` (the
    tighten-only seed).** The seed can tighten; the hard block must not be
    loosenable by a seed, and profiles are code the fleet ships, not
    per-project configuration. A seed MAY later add names to the hard
    block (tighten) — noted as a follow-up, not designed here.

## 7. Risks

- **A false-positive shape blocks a real need.** Mitigation: the locator
  suffix list; the refusal names the variable so the fix is a rename or a
  per-call literal; §4.10 shows two such names in 920 today.
- **Windows case folding** hides a shape (`gh_token`). Mitigation: fold on
  Windows; a yolanda fixture (tasks.md 1.7).
- **The warn-mode step is skipped** and a host loses a name it relied on.
  Mitigation: tasks.md orders the renames and the warn census before the
  flip; the refusal grammar names the variable, so the failure is loud and
  attributable, unlike `unbound variable`.
- **Profiles grow into blankets.** Mitigation: a source-agreement test that
  every profile name has a `why` and an order and matches no shape; no
  prefixes; a review signal when a bare `@env-inherit` name appears in three
  scripts.
- **Two builders drift again.** Mitigation: tasks.md 1.1 deletes
  `run_verb::base_env` and `base_env_command`'s body; a source-agreement test
  asserts no other `starts_with("TILLANDSIAS_")` over `std::env::vars` exists
  in the plan crate.

## 8. Sources

Primary documentation, read 2026-11-07 through a web-fetch agent; each
digest was checked against verbatim page text where the agent reported
having it, and marked where it did not.

1. systemd.exec(5) — "Environment Variables in Spawned Processes";
   `Environment=`, `EnvironmentFile=`, `PassEnvironment=`, `UnsetEnvironment=`.
   https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html
   — "The general philosophy is to expose a small curated list of
   environment variables"; system services "generally do not inherit
   environment variables set for the service manager itself (but this may
   be altered via PassEnvironment=)"; `UnsetEnvironment=` is applied "as the
   final step"; "If the same environment variable is set by multiple of
   these sources, the later source … wins"; environment variables are "not
   suitable for passing secrets".
2. systemd-system.conf(5) — `DefaultEnvironment=`, `ManagerEnvironment=`.
   https://www.freedesktop.org/software/systemd/man/latest/systemd-system.conf.html
3. sudoers(5), "Command environment" — https://man7.org/linux/man-pages/man5/sudoers.5.html
   — `env_reset` "enabled" by default, "a new, minimal environment";
   `env_check`: "'safe' means that the variable's value does not contain
   any '%' or '/' characters"; wildcards: "may include one or more '*'
   characters"; `()`-valued variables removed "as they may be interpreted
   as functions by the bash shell"; the dynamic linker strips `_RLD*`,
   `DYLD_*`, `LD_*`, `LDR_*`, `LIBPATH`, `SHLIB_PATH` from set-uid programs.
   Default tables from the source:
   https://raw.githubusercontent.com/sudo-project/sudo/main/plugins/sudoers/env.c
   (`initial_badenv_table`, `initial_checkenv_table`, `initial_keepenv_table`;
   the full removal list is reproduced in §4.2 A1).
4. Nix manual — builder environment: https://nix.dev/manual/nix/latest/store/building.html
   ("The environment is cleared and set to the derivation attributes";
   `PATH=/path-not-set`; `HOME=/homeless-shelter`); `impureEnvVars`:
   https://nix.dev/manual/nix/latest/language/advanced-attributes.html
   ("only allowed in fixed-output derivations"; "passed from the environment
   of the calling user to the builder"); `impure-env` setting (experimental
   `configurable-impure-env`): https://nix.dev/manual/nix/latest/command-ref/conf-file.html
5. Bazel command-line reference — `--action_env`, `--host_action_env`,
   `--test_env`, `--incompatible_strict_action_env` (default true: "a static
   value for PATH and does not inherit LD_LIBRARY_PATH … can prevent
   cross-user caching if a shared cache is used").
   https://bazel.build/reference/command-line-reference
6. Cargo reference — environment variables Cargo sets for build scripts
   (`RUSTFLAGS` "is removed from the environment" since 1.55):
   https://doc.rust-lang.org/cargo/reference/environment-variables.html ;
   `[env]` ("will not override values that already exist in the environment"
   unless `force`): https://doc.rust-lang.org/cargo/reference/config.html#env ;
   `cargo::rerun-if-env-changed`: https://doc.rust-lang.org/cargo/reference/build-scripts.html
7. GitHub Actions, secure use reference —
   https://docs.github.com/en/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions
   ("automatic redaction is not guaranteed"; "redaction largely relies on
   finding an exact match"; intermediate environment variable for untrusted
   input; secrets as command-line arguments visible via `ps`).
8. GitHub Actions, using secrets —
   https://docs.github.com/en/actions/security-for-github-actions/security-guides/using-secrets-in-github-actions
   ("With the exception of GITHUB_TOKEN, secrets are not passed to the
   runner when a workflow is triggered from a forked repository";
   `::add-mask::`; "Avoid passing secrets between processes from the
   command line").
9. Deno security — https://docs.deno.com/runtime/fundamentals/security/
   (`--allow-env=API_KEY` "to a single variable"; `--deny-*` overrides
   `--allow-*`; a subprocess "runs as a separate program with its own
   permissions"); `Deno.CommandOptions.clearEnv`:
   https://docs.deno.com/api/deno/~/Deno.CommandOptions ("Doesn't guarantee
   that only env variables are present, as the OS may set environmental
   variables").
10. podman-run(1) — `--env` ("checks the host environment for a value and
    set the variable only if it is set on the host"; `PREFIX*` form),
    `--env-host` ("not available with the remote Podman client"),
    `--env-merge`, `--unsetenv`, `--secret` (`type=mount|env`, default
    mount under `/run/secrets`): https://docs.podman.io/en/latest/markdown/podman-run.1.html
11. podman(1) — ENVIRONMENT VARIABLES (`CONTAINER_HOST` "Automatically
    enables --remote option", `CONTAINER_CONNECTION`, `CONTAINER_SSHKEY`,
    `CONTAINERS_CONF`, `CONTAINERS_REGISTRIES_CONF`, `CONTAINERS_STORAGE_CONF`,
    `PODMAN_CONNECTIONS_CONF`, `STORAGE_DRIVER`, `STORAGE_OPTS`, `TMPDIR`,
    `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_RUNTIME_DIR`), "Remote Access":
    https://docs.podman.io/en/latest/markdown/podman.1.html

In-tree sources: `plan/index.d/20261107t230000z-2029-39bt-lua-door-cannot-
run-in-caller-env-yoga.yaml`; `plan/index.d/20261004t201859z-1551-nyzb-lua-
runtime-audit-findings-yoga.yaml`; `plan/issues/lua-runtime-audit-2026-10-04.md`
§2 F1; `openspec/specs/command-runtime/spec.md` reqs `231502c2`, `48b22c5d`;
`openspec/changes/lua-command-runtime-and-policies/design.md` §Decisions;
commits `fdca0b2bc` (the port) and `915410103` (the revert).

The project's `research/` store is for human-factors research
(`skills/find-research/SKILL.md`: "about people rather than tools"); this
is tool documentation, so it is recorded here rather than as a research
record.

## 9. Open questions — decisions for the operator or coordinator, ranked

1. **Layer 2: keep `TILLANDSIAS_*` as a hard-block-filtered prefix (this
   design), or replace it with an explicit control-plane list?** The list
   buys constraint-1 purity; it costs enumerating every name a nested runner
   needs (regime, fixture scope and git dirs, host kind, plan bin, runner
   bin, timing log, gate diff base, skill, reset-ok, carried-* …) and the
   risk that one miss silently changes a nested policy decision. Default:
   keep the prefix with the guard.
2. **Should `env.get` also refuse credential-shaped names** (this design),
   or only the inherit path? Refusing both closes the "read it, then print
   it" route at the cost of migrating one script. Default: refuse both.
3. **Per-call literals on class-A names: raise (this design) or allow with a
   `note:`?** A fixture might want `LD_PRELOAD=` to test a sanitiser.
   Default: raise; such a fixture runs its subject through a wrapper file.
4. **Add `TERM=dumb` and `GIT_CONFIG_NOSYSTEM=1` to the fixed layer?** Both
   remove nondeterminism; `TERM=dumb` changes colour output of children
   today. Default: not in this change; file as a follow-up measurement.
5. **The locator-suffix list** (`_FILE _PATH _DIR _ID _NAME _FP _LOG _URL
   _ADDR _SRC _COUNT _ENV_FILE _SINK_FILE`): closed as written, or drop
   `_SRC`/`_COUNT` and rename the two names that need them? Default: as
   written.
