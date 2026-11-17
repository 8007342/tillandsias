# Proposal — lua-door-environment-inheritance

<!-- @trace order:2029-39bt, spec:command-runtime -->

Design row: `2029-39bt` (kind design, "DESIGN FIRST"). Code is cited by
SYMBOL, never by line. Companion: `design.md` (the model, the audit, the
sources) and `tasks.md` (implementation rows, each starting from a red
fixture). This change is SPEC ONLY: it changes no runtime (coordinator
constraint 3, 2026-11-07).

## Why

Every child a Lua door starts — `proc.run`, `proc.spawn`, `proc.chain`,
`sh.run`, `expert.shell`, and the agent door `tillandsias-plan run` — is
built by `lua_predicate::base_env_command` (and its twin
`run_verb::base_env`): `env_clear()`, then `PROC_RUN_BASE_ENV_PASSTHROUGH`
(PATH, HOME, TMPDIR, the Windows basics, `CARGO_TARGET_DIR` per 1593-1ny6,
`XDG_RUNTIME_DIR` and `DBUS_SESSION_BUS_ADDRESS` per 1838-nwyn), then every
`TILLANDSIAS_*` variable, then `PROC_RUN_BASE_ENV_FIXED` (`LC_ALL=C`,
`LANG=C`, `TZ=UTC`, `GIT_TERMINAL_PROMPT=0`), then the call's own `env`
table. Order 1551-nyzb made it so, after `sh.run{'printenv',
'AUDIT_PROBE_SECRET'}` returned `hunter2` from the runner's environment
(`plan/issues/lua-runtime-audit-2026-10-04.md`, §2 F1).

That fail-closed default is right, and this change keeps it. What it lacks
is a DESIGNED way for a script whose job is "run the caller's own tool" to
let that tool see the caller's configuration:

- Measured 2026-11-07 on PR #996 (order 2006-me5t): `scripts/verify-image-
  usable.sh` was ported to Lua, byte-identical on four side-by-side arms, and
  evicted at the land gate on `scripts/test-build-image-installed-version-
  alias.sh` (gate step 747-knbp). That fixture's fake `podman` reads
  `FAKE_PODMAN_STORE`; the Lua child got `unbound variable`. The port was
  reverted (`915410103`) and the shell-to-lua obligation waived
  `blocked-by:2029-39bt`.
- The same door drops podman's real inputs — `CONTAINER_HOST` (which
  `scripts/common.sh` `_podman_remote_url` reads to drive podman-remote),
  `CONTAINER_CONNECTION`, `CONTAINERS_CONF`, `CONTAINERS_STORAGE_CONF`,
  `REGISTRY_AUTH_FILE` — so a Lua port of any podman-running script answers
  for a different podman than its caller uses.
- The only ways in today are the per-call `env` table and `-- @env NAME`
  plus `env.get` plus a hand-written forward (which
  `scripts/lua/check-forge-service-health.lua` does for eleven proxy and CA
  names). That works for a finite list the script author knows; it cannot
  work for a fixture-private name the script has never heard of, and it
  routes every value through Lua strings on its way to the child.

Two things the audit for this change found that the incident did not:

1. The `TILLANDSIAS_*` passthrough is itself a blanket prefix rule over a
   namespace of 920 distinct names
   (`/usr/bin/grep -rhoE 'TILLANDSIAS_[A-Z0-9_]+' crates scripts | sort -u |
   wc -l`), and it carries at least two real secrets:
   `TILLANDSIAS_COORD_CLIENT_SECRET` (a Cloudflare Access service-token
   secret, read in `coordinator_client.rs`) and `TILLANDSIAS_KEY_PASS` (the
   CA key passphrase, `ca_key_store::PASS_ENV`). Both reach every child of
   every door today whenever they are set on the runner.
2. `env.get` already lets a script read a credential it declares:
   `scripts/lua/litmus-helper-nix-cache-size.lua` declares `-- @env GH_TOKEN
   GITHUB_TOKEN` and forwards the value to a child per call.

Operator direction (2026-11-07): a proper inherit / block / override model,
chosen by policy rather than by accident. Coordinator constraints
(macuahuitl, 2026-11-07), binding on the design: (1) keep the fail-closed
default; inheritance is an explicit per-script allowlist, never a blanket
pass-through, and no profile may amount to one; (2) credentials never
inherit, not even when declared — a credential-shaped name is hard-blocked
and whatever needs one gets it another way; (3) spec only.

## What Changes

- **One environment builder, five layers, deterministic.** Every door —
  the Lua doors and the `run` verb — builds the child's environment through
  one builder (`ChildEnv`, replacing `base_env_command` and
  `run_verb::base_env`), applying in order: hard block → base passthrough →
  project namespace (`TILLANDSIAS_*` minus the hard block) → per-script
  declared inherit → fixed overrides → per-call explicit `env`. The hard
  block filters EVERY inherited layer; the per-call layer wins over the
  others for a name it sets, and cannot set a hard-blocked name either.
- **Two block classes, named in one table.** Class A (`never`): loader and
  shell-init injection names (`LD_*`, `DYLD_*`, `BASH_ENV`, `ENV`, `PS4`,
  `IFS`, `GIT_SSH_COMMAND`, `GIT_ASKPASS`, …) and every credential-shaped
  name (`*TOKEN*`, `*SECRET*`, `*PASSWORD*`, `*_KEY`, `AWS_*`,
  `SSH_AUTH_SOCK`, `GH_TOKEN`, …, with a closed list of locator suffixes
  such as `_FILE` that mark a name as a path, not a value). Class B
  (`inherit-blocked`): names that redirect or de-determinise a tool
  (`GIT_DIR`, `GIT_WORK_TREE`, `GIT_CONFIG_*`, `RUSTFLAGS`, `RUSTC_WRAPPER`,
  `NIX_CONFIG`, `WSLENV`, …) — never inherited from the caller, but a script
  may set them per call with a literal, because fixtures legitimately build
  fake repositories that way (`scripts/lua/test-forge-empty-project-
  starts.lua` sets `GIT_CONFIG_GLOBAL=/dev/null` per call today).
- **Declaration is per script, in the header, and names come from a
  central table.** `-- @env-profile podman` names a profile defined ONCE in
  Rust (`ENV_INHERIT_PROFILES`: podman, net-egress, cargo, toolbox, vault,
  nix, gh, session, macos-toolchain), each name carrying its reason and
  order citation. `-- @env-inherit NAME …` adds exact names for one-offs.
  No prefixes or globs in v1: every profile in the audit is a documented,
  finite set (podman(1) lists its environment exhaustively), so a prefix
  buys nothing and would have to justify why it cannot carry a credential.
- **Declared-inherit is pass-to-child only.** The script does not see the
  value; `-- @env NAME` remains the read grant (`env.get`). A script that
  needs both declares both. `env.get` of a credential-shaped name is refused
  like any other hard-blocked use.
- **A block is a refusal that names the variable, never its value.** A
  header that declares a class-A name, an unknown profile, a fixed name, or
  an unknown `@` directive is refused before any script code runs
  (`refused:env-inherit:<reason>:<NAME>`); a per-call `env` entry on a
  class-A name raises a Lua error naming it. Nothing is dropped silently.
- **The project namespace stays a prefix layer, narrowed and justified.**
  `TILLANDSIAS_*` is the control plane nested runners depend on
  (`TILLANDSIAS_POLICY_REGIME`, `TILLANDSIAS_FIXTURE_SCOPE`,
  `TILLANDSIAS_HOST_KIND`, `TILLANDSIAS_PLAN_BIN`, `TILLANDSIAS_TIMING_LOG`,
  `TILLANDSIAS_GATE_DIFF_BASE`, …): a nested plan binary that lost the
  regime variable would judge under `interactive` and change policy
  outcomes silently. The hard block now applies to this layer, which removes
  the two secrets; a namespace-hygiene guard keeps the invariant "a
  `TILLANDSIAS_` name that is not a credential is not spelled like one, and
  one that is, is". Two names need renaming: `TILLANDSIAS_WRAPPER_TOKEN`
  (a process-tree marker, not a credential — the reaper must find it on
  children) and `TILLANDSIAS_NOTARY_KEY` (a `.p8` path).
- **Observability.** The `script-run` timing record gains
  `env_profiles`, `env_inherited` (names present), `env_absent` (declared,
  unset on the caller). A `tillandsias-plan script env <script>` dry-run
  prints the effective layered policy per name with its source layer.
- **Fixtures that fake a caller tool** communicate with the fake through a
  file beside the fake binary, or through a `TILLANDSIAS_FIXTURE_*` name
  (the project namespace, so no new door); never through a bespoke
  `FAKE_*` name. The 747-knbp fixture's `FAKE_PODMAN_STORE` becomes
  `TILLANDSIAS_FIXTURE_PODMAN_STORE` (two lines), or a store file next to
  the fake.
- **Acceptance.** `scripts/verify-image-usable.sh` is re-ported with
  `-- @env-profile podman`, side by side on the four 2006-me5t arms plus the
  747-knbp fixture and a `CONTAINER_HOST` arm; the `blocked-by:2029-39bt`
  waiver is retired. Option (b) of the row's exit criterion — excluding
  caller-tool scripts from the shell-to-lua backlog — is rejected (design.md
  §Alternatives).

## Impact

- `openspec/specs/command-runtime/spec.md`: req `231502c2` (one directory,
  one environment, one deadline rule) and req `48b22c5d` (the run verb) are
  MODIFIED to describe the layered environment; five requirements ADDED
  (`specs/command-runtime/spec.md` in this change).
- `crates/tillandsias-plan`: `lua_predicate.rs` (`base_env_command`,
  `PROC_RUN_BASE_ENV_PASSTHROUGH`, `PROC_RUN_BASE_ENV_FIXED`, `validate_proc`),
  `run_verb.rs` (`base_env`), `script_run.rs` (`parse_header`, `Header`,
  `register` for `env.get`, `emit_timing`), a new `child_env.rs` holding the
  tables. Tests: `tests/lua_proc.rs` (`the_child_environment_is_the_base_set`
  and new siblings), `tests/lua_observing_boundary.rs`, `run_verb` tests.
- `scripts/lua/`: one header line per script that runs a caller tool;
  `litmus-helper-nix-cache-size.lua` migrates off `@env GH_TOKEN`.
- `scripts/`: `with-tillandsias-builder.sh`, `lib-dispatch-reap.sh`,
  `check-no-competing-gate.sh` and their fixtures (the `WRAPPER_TOKEN`
  rename); `build-macos-dmg.sh`, `build-macos-tray.sh`,
  `test-macos-signing-seam.sh` (`NOTARY_KEY` rename);
  `test-build-image-installed-version-alias.sh` (fixture variable).
- `methodology/`: a fixture-double rule (how a fake tool receives its
  configuration) and the namespace-hygiene rule.
- Carried obligations: the `blocked-by:2029-39bt` waiver reason stays valid
  until the acceptance task lands; the counter excludes nothing.
- Plan rows: listed in `tasks.md` §Follow-up rows; none filed by this
  change.
- Cited orders: 2029-39bt, 1551-nyzb, 1593-1ny6, 1838-nwyn, 747-knbp,
  2006-me5t, 2026-ggu8, 1384-ddua, 1442-22d2, 1760-nn6u.
