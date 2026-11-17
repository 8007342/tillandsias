<!-- @trace order:2029-39bt, spec:command-runtime -->
# command-runtime — delta for lua-door-environment-inheritance

Design: `openspec/changes/lua-door-environment-inheritance/design.md`.
Orders: 2029-39bt (this change), 1551-nyzb (the fail-closed default this
keeps), 1593-1ny6 and 1838-nwyn (base passthrough entries), 747-knbp and
2006-me5t (the incident and the port).

## MODIFIED Requirements

### Requirement: The run verb is the agent's door and reads argv as JSON when asked
<!-- req-id: 48b22c5d -->

`tillandsias-plan run [--cwd P] [--env K=V]… [--env-profile NAME]…
[--env-inherit NAME]… [--timeout-ms N] [--capture-bytes N] [--stdin-file F]
[--json] -- <argv…>` SHALL run one child through `tillandsias_exec::Command`
after the policy engine answers allow. With `--argv-json -` the verb SHALL
read the argv as a JSON array from stdin so that no argument is present on
the process command line; this is the required form on Git Bash (MSYS
argument conversion) and for any cross-locus dispatch (`wsl.exe`). The child
SHALL start from the layered environment of requirement `ae550c5d`
(below), built by the same `ChildEnv` builder as the Lua doors, with
`--env-profile` and `--env-inherit` as its declared-inherit layer and
`--env` as its per-call layer. The `--json` result SHALL carry
`env_profiles`, `env_inherited` and `env_absent` as names only.

#### Scenario: The caller's secrets are not inherited

- **WHEN** the caller's environment carries `GH_TOKEN=x`
- **AND** the caller runs `tillandsias-plan run -- env`
- **THEN** `GH_TOKEN` is absent from the child's stdout

#### Scenario: The caller's secrets are not inherited even when named

- **WHEN** the caller's environment carries `GH_TOKEN=x`
- **AND** the caller runs `tillandsias-plan run --env-inherit GH_TOKEN -- env`
- **THEN** the verb exits non-zero before spawning, printing
  `refused:env-inherit:never:GH_TOKEN:credential-shape`
- **AND** the value `x` appears nowhere in the verb's output

#### Scenario: A profile on the run verb passes the same names as in a script

- **WHEN** the caller's environment carries `CONTAINER_HOST=unix:///tmp/p.sock`
  and `UNRELATED_2029=y`
- **AND** the caller runs `tillandsias-plan run --env-profile podman -- env`
- **THEN** the child's stdout carries `CONTAINER_HOST=unix:///tmp/p.sock`
  and no `UNRELATED_2029`

#### Scenario: argv-json survives MSYS

- **WHEN** Git Bash on a Windows host feeds `["printf","%s","C:\\x\\."]` to
  `tillandsias-plan run --argv-json -`
- **THEN** the child's third argument is unconverted

### Requirement: Every Lua door judges and runs in one directory, from one environment, under one deadline rule
<!-- req-id: 231502c2 -->

`proc.run`, `proc.spawn`, `proc.chain` and the positional `sh.run` /
`expert.shell` SHALL each resolve the child's working directory ONCE per call
— the call's `cwd` where the door has one, else the repository root, else the
process cwd — and SHALL use that same value both as the cwd of the policy
request and as the cwd the child runs in. Each SHALL start the child from the
layered environment of requirement `ae550c5d`: the base passthrough, the
project namespace minus hard-blocked names, the script's declared inherit
set, the fixed overrides, and the call's own additions — and nothing else.
Each SHALL apply the default deadline when the call names none;
`timeout_ms = 0` SHALL mean no deadline on every door (order 1551-nyzb).

#### Scenario: The positional door acts where it was judged

- **WHEN** the runner is started in a directory other than the repository
  root and a script calls `sh.run{'pwd'}` and `proc.run{argv={'pwd'}}`
- **THEN** both print the same directory
- **AND** `sh.run{'rm','-r','victim'}` removes nothing in the directory the
  runner was started in

#### Scenario: The caller's environment does not reach a child through any door

- **WHEN** the runner's environment carries a variable outside the base set
  and the script's header declares nothing about it
- **THEN** it is absent from the child of `sh.run`, of `proc.run`, of
  `proc.spawn` and of `proc.chain`

## ADDED Requirements

### Requirement: A child's environment is built by one builder in six deterministic steps
<!-- req-id: ae550c5d -->

Every door onto the runtime SHALL obtain the child's environment from ONE
builder (`child_env::ChildEnv`), which SHALL apply, in this order: (0) the
hard block, a filter on every inherited name; (1) the base passthrough
(`PATH`, `HOME`, `TMPDIR`, the Windows basics, `CARGO_TARGET_DIR`,
`XDG_RUNTIME_DIR`, `DBUS_SESSION_BUS_ADDRESS`; orders 1593-1ny6,
1838-nwyn); (2) the project namespace, every runner variable whose name
begins `TILLANDSIAS_` and is not hard-blocked; (3) the declared inherit set
(requirement `1dd43038`); (4) the fixed overrides (`LC_ALL=C`, `LANG=C`,
`TZ=UTC`, `GIT_TERMINAL_PROMPT=0`); (5) the call's explicit additions. A
later step SHALL win for a name it sets. Given the same runner environment,
header and call, the builder SHALL produce the same environment, and every
name in it SHALL be attributable to exactly one step. No door SHALL hold a
second implementation of any step.

#### Scenario: A fixed override beats the caller

- **WHEN** the runner's environment carries `LC_ALL=fr_FR.UTF-8` and
  `TZ=Europe/Berlin`
- **AND** a script runs, through `proc.run`, a shell FILE (never a shell
  string) that prints `$LC_ALL|$TZ`
- **THEN** the child prints `C|UTC`

#### Scenario: Per-call env beats inherit

- **WHEN** the runner's environment carries `CONTAINER_HOST=unix:///a.sock`
- **AND** a script with `-- @env-profile podman` runs the child with
  `env = {CONTAINER_HOST = "unix:///b.sock"}`
- **THEN** the child sees `CONTAINER_HOST=unix:///b.sock`

#### Scenario: Two doors, one answer

- **WHEN** the same runner environment, header and additions are given to
  `proc.run` and to `tillandsias-plan run`
- **THEN** the two children print identical sorted `env` output

### Requirement: Hard-blocked names never reach a child, declared or not
<!-- req-id: c3d80b67 -->

The builder SHALL hold one table of hard-blocked names in two classes.
Class A (`never`) SHALL contain the loader, shell-initialisation and
program-naming variables (`LD_*`, `DYLD_*`, `_RLD*`, `BASH_ENV`, `ENV`,
`PS4`, `IFS`, `CDPATH`, `SHELLOPTS`, `BASHOPTS`, `GIT_SSH_COMMAND`,
`GIT_ASKPASS`, `GIT_EXEC_PATH`, `NIX_CONFIG`, `PYTHON*`, `PERL5OPT`,
`NODE_OPTIONS`, …, the full list in design §4.2 A1) and every
credential-shaped name (design §4.2 A2: terminal `_TOKEN`, `_SECRET`,
`_PASSWORD`, `_PASS`, `_KEY`, `_AUTH`, …; containing `TOKEN`, `SECRET`,
`PASSWORD`, `API_KEY`, `PRIVATE_KEY`, `CLIENT_SECRET`, …; prefixed `AWS_`,
`AZURE_`, …; or one of the exact names `GH_TOKEN`, `GITHUB_TOKEN`,
`SSH_AUTH_SOCK`, `VAULT_TOKEN`, `CARGO_REGISTRY_TOKEN`, …), where a name
whose terminal segment is a locator or label suffix from the closed list
(`_FILE`, `_PATH`, `_DIR`, `_ID`, `_NAME`, `_FP`, `_LOG`, `_URL`, `_ADDR`,
`_SRC`, `_COUNT`, `_ENV_FILE`, `_SINK_FILE`) is NOT credential-shaped. A
class-A name SHALL NOT be inherited by any step, SHALL be refused when a
header declares it, SHALL raise when a call sets it, and SHALL NOT be
readable through `env.get`. Class B (`inherit-blocked`: `GIT_DIR`,
`GIT_WORK_TREE`, `GIT_CONFIG_*`, `RUSTFLAGS`, `RUSTC_WRAPPER`, `WSLENV`,
`TERM`, `PAGER`, …, design §4.3) SHALL NOT be inherited by any step and
SHALL be refused when a header declares it, but MAY be set by a call with a
literal. The hard block SHALL apply to the project namespace step, so a
credential-shaped `TILLANDSIAS_*` name does not reach a child. An inherited
value matching a known token shape (PEM header, AWS key id, `ghp_`,
`github_pat_`, …) or a proxy URL carrying userinfo SHALL be refused by name.
Every refusal SHALL name the variable and the class and SHALL NOT print the
value. On Windows, matching SHALL be case-insensitive.

#### Scenario: A hard-blocked variable is refused even when declared

- **WHEN** a script's header says `-- @env-inherit LD_PRELOAD`
- **THEN** the runner prints `refused:env-inherit:never:LD_PRELOAD:loader`
  and exits non-zero before any script code runs

#### Scenario: A credential-shaped name is refused even when declared

- **WHEN** the runner's environment carries `MY_SERVICE_TOKEN=abc` and a
  script's header says `-- @env-inherit MY_SERVICE_TOKEN`
- **THEN** the runner prints
  `refused:env-inherit:never:MY_SERVICE_TOKEN:credential-shape`
- **AND** `abc` appears nowhere on stdout or stderr

#### Scenario: A credential-shaped project variable no longer reaches a child

- **WHEN** the runner's environment carries `TILLANDSIAS_PROBE_TOKEN=hunter2`
  and `TILLANDSIAS_PROBE_TOKEN_FILE=/tmp/t`
- **AND** a script with no environment header runs a child that prints both
- **THEN** the child prints `unset|/tmp/t`
- **AND** on the tree of this change's filing the same child prints
  `hunter2|/tmp/t` (the pre-fix result)

#### Scenario: A locator suffix is not a credential

- **WHEN** a script's header says `-- @env-inherit VAULT_TOKEN_FILE` and the
  runner's environment carries `VAULT_TOKEN_FILE=/run/secrets/vault`
- **THEN** the child sees `VAULT_TOKEN_FILE=/run/secrets/vault`

#### Scenario: A per-call literal cannot set a class-A name

- **WHEN** a script calls `proc.run{argv={...}, env={LD_PRELOAD="/x.so"}}`
- **THEN** the call raises a Lua error naming `LD_PRELOAD` and `never`
- **AND** no child is spawned

#### Scenario: A per-call literal may set a class-B name

- **WHEN** a script calls `proc.run{argv={"git","init"}, env={GIT_CONFIG_GLOBAL="/dev/null"}}`
- **THEN** the child sees `GIT_CONFIG_GLOBAL=/dev/null`
- **AND** a header line `-- @env-inherit GIT_CONFIG_GLOBAL` on the same
  script is refused `inherit-blocked`

#### Scenario: env.get refuses a credential-shaped name

- **WHEN** a script's header says `-- @env GH_TOKEN` and the script calls
  `env.get("GH_TOKEN")`
- **THEN** the call raises an error naming `GH_TOKEN` and `credential-shape`

### Requirement: A script declares what its children inherit, in its header, from a central table
<!-- req-id: 1dd43038 -->

`script_run::parse_header` SHALL accept `-- @env-profile NAME…` and
`-- @env-inherit NAME…`. A profile SHALL be an entry of
`child_env::ENV_INHERIT_PROFILES`, a Rust table in which every name carries
its reason and the order that introduced it; the initial profiles SHALL be
`podman`, `net-egress`, `cargo`, `toolbox`, `session`, `vault`, `nix`, `gh`,
`macos-toolchain` with the names in design §5.3. An `@env-inherit` name
SHALL be an exact variable name; a pattern containing `*` SHALL be refused
`glob-not-supported`. A declared name SHALL be refused when it is
hard-blocked, inherit-blocked or fixed; a declared base name SHALL be
accepted as a no-op with a `note:` line. A declared name that is unset on the
runner SHALL be absent from the child and listed in `env_absent`. A declared
name SHALL be passed to children and SHALL NOT be readable through
`env.get`; `-- @env NAME` remains the read grant. A header line beginning
`@` that is not a known directive (`@trace`, `@class`, `@env`, `@read-env`,
`@env-profile`, `@env-inherit`, `@research`, `@cheatsheet`) SHALL be refused
`refused:script-header:unknown-directive:<word>` before any script code runs.

#### Scenario: A declared caller variable is present in the child

- **WHEN** the runner's environment carries `CONTAINER_HOST=unix:///tmp/p.sock`
- **AND** a script with `-- @env-profile podman` runs a child that prints it
- **THEN** the child prints `unix:///tmp/p.sock`

#### Scenario: An undeclared caller variable is absent in the child

- **WHEN** the runner's environment carries `CONTAINER_HOST=unix:///tmp/p.sock`
  and `FAKE_PODMAN_STORE=/tmp/s`
- **AND** a script with `-- @env-profile podman` runs a child that prints
  `${FAKE_PODMAN_STORE:-unset}`
- **THEN** the child prints `unset`

#### Scenario: A declared name is passed, not readable

- **WHEN** a script's header says `-- @env-inherit TOOLBOX_PATH` and nothing
  else about it, and the script calls `env.get("TOOLBOX_PATH")`
- **THEN** the call raises `env.get: 'TOOLBOX_PATH' is not declared; add it
  to the header: -- @env TOOLBOX_PATH`
- **AND** a child of the same script sees `TOOLBOX_PATH`

#### Scenario: An unknown profile is refused by name

- **WHEN** a script's header says `-- @env-profile podmann`
- **THEN** the runner prints `refused:env-inherit:unknown-profile:podmann`
  and the known profile names on stderr

#### Scenario: A misspelt directive does not silently become today's behaviour

- **WHEN** a script's header says `-- @env-inherits CONTAINER_HOST`
- **THEN** the runner prints
  `refused:script-header:unknown-directive:env-inherits` and exits non-zero

#### Scenario: A glob is refused

- **WHEN** a script's header says `-- @env-inherit CONTAINERS_*`
- **THEN** the runner prints
  `refused:env-inherit:glob-not-supported:CONTAINERS_*`

### Requirement: The project namespace passes through minus its credential shapes, and the tree keeps its names honest
<!-- req-id: bba4ae64 -->

Step (2) SHALL pass every `TILLANDSIAS_*` runner variable that is not
hard-blocked. The plan crate SHALL hold `child_env::TILLANDSIAS_CREDENTIAL_NAMES`,
the closed list of project names that ARE credentials (initially
`TILLANDSIAS_COORD_CLIENT_SECRET`, `TILLANDSIAS_KEY_PASS`,
`TILLANDSIAS_CONSENT_TOKEN`). A guard (`scripts/lua/check-env-namespace-
hygiene.lua`) SHALL refuse a tree in which a credential-shaped `TILLANDSIAS_`
name appears in `crates/` or `scripts/` and is not in that list, naming the
variable and its file, so that a non-credential is never spelled like one
(it would be blocked from nested runners) and a credential is never spelled
otherwise (it would reach them).

#### Scenario: The control plane still reaches a nested runner

- **WHEN** the runner's environment carries
  `TILLANDSIAS_POLICY_REGIME=fixture` and `TILLANDSIAS_FIXTURE_SCOPE=/tmp/w`
- **AND** a script runs a nested `tillandsias-plan` that prints its regime
- **THEN** the nested runner reports `fixture`

#### Scenario: A new credential-shaped project name is refused by the guard

- **WHEN** a script under `scripts/` reads `${TILLANDSIAS_NEW_API_TOKEN}`
  and the name is not in `TILLANDSIAS_CREDENTIAL_NAMES`
- **THEN** `check-env-namespace-hygiene.lua` prints
  `violation:env-namespace:credential-shape:TILLANDSIAS_NEW_API_TOKEN:<file>`
  and exits non-zero

### Requirement: Inherited names are recorded, values never
<!-- req-id: 42690226 -->

The `script-run` timing record (`TILLANDSIAS_TIMING_LOG`) and the `run`
verb's `--json` result SHALL carry `env_profiles` (names), `env_inherited`
(declared names present on the runner) and `env_absent` (declared names
unset on the runner). Neither SHALL carry a value, nor the base or namespace
names. `tillandsias-plan script env <script.lua>` SHALL print, without
running the script, one line per effective name — `NAME layer=<base|
namespace|profile:<p>|inherit|fixed> present=<yes|no>` — and the refusal the
header would earn, if any.

#### Scenario: The record names what was inherited and holds no value

- **WHEN** the runner's environment carries `CONTAINER_HOST=unix:///tmp/p.sock`
  and `CONTAINERS_CONF` is unset, and a script with `-- @env-profile podman`
  runs under `TILLANDSIAS_TIMING_LOG=<file>`
- **THEN** the record's `env_profiles` is `["podman"]`, `env_inherited`
  contains `CONTAINER_HOST`, `env_absent` contains `CONTAINERS_CONF`
- **AND** `/usr/bin/grep -c 'p.sock' <file>` prints `0`

#### Scenario: The dry run answers the 747-knbp question

- **WHEN** an operator runs `tillandsias-plan script env scripts/lua/verify-image-usable.lua`
  with `FAKE_PODMAN_STORE` set
- **THEN** the output has no line for `FAKE_PODMAN_STORE`, has a line
  `CONTAINER_HOST layer=profile:podman present=<yes|no>`, and the verb exits 0

### Requirement: A hard-block refusal is a recorded violation, classified, and enforced below the runtime where the platform can
<!-- req-id: 7120e541 -->

Operator ruling 2026-11-07 (design §4.14): a per-call literal or declaration
naming a class-A variable SHALL refuse the call, AND SHALL append one
violation record to the runtime's violation log, AND, on a platform with a
kernel mechanism for it, SHALL also be enforced below the runtime so that a
bypass of the runtime's own check cannot deliver the variable to a loader.

The violation record SHALL carry: the UTC time, the host, the script path and
its content hash, the door (`proc.run`, `proc.spawn`, `proc.chain`, `sh.run`,
`run`), the call site (script line), the variable NAME, its class and
sub-class (`loader`, `shell-init`, `program-naming`, `credential-shape`),
the source of the attempt (`header-declare`, `per-call-literal`,
`inherited-from-caller`), the policy regime, and a `value_shape` descriptor
(empty / path-to-existing-file / path-to-shared-object / url / opaque, plus
its length). It SHALL NEVER carry the value or any reversible digest of it.

Each record SHALL be classified by a deterministic rule into exactly one of
`innocent` (the attempt is explained by an existing need the model has not
yet granted: a header declaration, an inherited-from-caller name the script
never mentioned, or an empty value under the fixture regime), `suspicious`
(a per-call literal of a `loader` or `shell-init` name with a non-empty value,
a value shaped as a path to a shared object, a credential-shaped name whose
value also appears in the child's argv, or a repeat of the same refused
attempt by the same script after a refusal in the same run), or
`unclassified`. The classification and the rule that produced it SHALL be in
the record.

An `innocent` record SHALL name the remedy it implies (a profile entry, an
override, or an isolation such as a wrapper file); a `suspicious` record SHALL
be surfaced as a `violation:env-block:suspicious:<script>:<NAME>` line on the
run's own output and in the next gate's summary, never folded into a count.

#### Scenario: a per-call loader literal is refused, recorded and classified suspicious
- **WHEN** a script calls `proc.run{argv={"true"}, env={LD_PRELOAD="/tmp/x.so"}}`
  and `/tmp/x.so` exists
- **THEN** the call raises `refused:env-inherit:never:LD_PRELOAD:loader`,
  the child is not spawned, one violation record is appended with
  `source=per-call-literal`, `value_shape=path-to-shared-object`,
  `class=suspicious`, and the value `/tmp/x.so` appears nowhere in the record

#### Scenario: a declared credential name is refused and classified innocent
- **WHEN** a script header declares `-- @env-inherit GH_TOKEN`
- **THEN** the script is refused before it runs with
  `refused:env-inherit:never:GH_TOKEN:credential-shape`, one record is
  appended with `source=header-declare`, `class=innocent`, and a remedy
  naming the sanctioned credential route (design §4.6)

#### Scenario: a caller variable that was simply present is not an attack
- **WHEN** the runner's own environment holds `LD_LIBRARY_PATH` and a script
  that never mentions it calls `proc.run`
- **THEN** the child does not receive it, the call is NOT refused (the block
  is a filter on inherited layers), and at most one `innocent`
  `source=inherited-from-caller` record per run names it

#### Scenario: on Linux with SELinux enforcing, a loader variable cannot take effect even past the runtime
- **WHEN** a Lua door child is spawned on a Linux host whose SELinux mode is
  `Enforcing` and the kernel-side mechanism selected by follow-up R8 is
  installed
- **THEN** the child runs in secure-execution mode (`AT_SECURE=1`), so the
  dynamic loader ignores `LD_PRELOAD` / `LD_LIBRARY_PATH` even if one were
  present, and the run records `kernel-enforcement=selinux`; on a host
  without it the run records `kernel-enforcement=none:<reason>` and the
  runtime check alone applies, never silently
