# Tasks — lua-door-environment-inheritance

<!-- @trace order:2029-39bt, spec:command-runtime -->

Each task starts from a RED fixture named here, written against today's code
before the change. Fixtures live in `crates/tillandsias-plan/tests/lua_proc.rs`
(child programs are modes of `tests/support/fixture_child.rs` or shell FILES
written by the test — never shell strings, never an interpreter the project
bans) unless a Lua fixture under `scripts/lua/test-*.lua` is named. Every new
fixture needs a second regime (yolanda-windows or a macOS host) before the
row is READY (STEP_SECOND_REGIME). Orders in brackets are the follow-up rows
in §Follow-up rows; none is filed by this change.

## 1. The builder and the block (runtime, order of landing)

- [ ] 1.1 **One builder.** `crates/tillandsias-plan/src/child_env.rs`:
      `ChildEnv::for_call`, `ENV_BASE_PASSTHROUGH` (moved from
      `PROC_RUN_BASE_ENV_PASSTHROUGH`, same names, same comments),
      `ENV_FIXED` (from `PROC_RUN_BASE_ENV_FIXED`). `lua_predicate::
      base_env_command` and `run_verb::base_env` become one-line callers.
      RED: `tests/lua_source_agreements.rs::child_environment_has_one_builder`
      — asserts no `starts_with("TILLANDSIAS_")` over `std::env::vars` exists
      in the plan crate outside `child_env.rs` (today: two). Plus the spec
      scenario "Two doors, one answer" as a lua_proc test comparing sorted
      `env` from `proc.run` and from the `run` verb under one injected
      variable. [R1]
- [ ] 1.2 **The hard block.** `ENV_BLOCK_NEVER` (A1 list, design §4.2),
      `credential_shape(name)` (A2 rule with the locator suffixes),
      `ENV_BLOCK_INHERIT` (class B, §4.3), `value_shape(value)` extending
      `command_policy::redact`'s token shapes (A3). Table-driven unit test
      holding every name in design §5.3 and every `TILLANDSIAS_` name from the
      §4.10 census with its expected class. RED:
      `lua_proc.rs::a_credential_shaped_project_variable_does_not_reach_a_child`
      — sets `TILLANDSIAS_PROBE_TOKEN=hunter2` and
      `TILLANDSIAS_PROBE_TOKEN_FILE=/tmp/t` on the runner, child prints both,
      expects `unset|/tmp/t`; today prints `hunter2|/tmp/t`. Also
      `lua_proc.rs::a_per_call_literal_cannot_set_a_loader_variable`
      (`env={LD_PRELOAD=…}` raises; today spawns). [R1]
- [ ] 1.3 **Header directives.** `script_run::Header` gains `env_profiles`,
      `env_inherit`; `parse_header` accepts `@env-profile`, `@env-inherit`,
      refuses unknown `@` directives, globs, hard-blocked, inherit-blocked
      and fixed names with the tokens in the spec; a base name is a `note:`.
      Refusals happen in `cli_run` before `run_to_verdict`. RED, as runner
      tests in `lua_proc.rs` (each a header + a child printing one name):
      `a_declared_caller_variable_reaches_the_child` (today: `unset`),
      `an_undeclared_caller_variable_stays_absent` (today passes; it is the
      control and must stay green through every arm),
      `a_hard_blocked_name_is_refused_when_declared`,
      `a_misspelt_env_directive_is_refused_not_ignored` (today: ignored),
      `a_glob_is_refused`, `an_unknown_profile_is_refused_by_name`,
      `per_call_env_beats_inherit`, `a_fixed_override_beats_the_caller`
      (today green; stays green). [R1]
- [ ] 1.4 **Profiles.** `ENV_INHERIT_PROFILES` with the nine profiles and
      the names in design §5.3, each `(var, why, order)`. Unit test: every
      profile name matches no shape, is not base, not fixed, not class B; no
      name contains `*`. A source-agreement test that every profile name
      appears in `design.md` §5.3 of this change (or its archived copy).
      [R1]
- [ ] 1.5 **Passed, not readable.** `env.get` keeps `header.env` as its only
      grant; `env.get` of a class-A name raises naming the variable and
      `credential-shape`. RED: `lua_proc.rs::a_declared_inherit_name_is_passed_not_readable`
      and `env_get_refuses_a_credential_shaped_name` (today: returns the
      value). Migrate `scripts/lua/litmus-helper-nix-cache-size.lua` off
      `-- @env GH_TOKEN GITHUB_TOKEN` to design §4.6 (a) or (b); its litmus
      arms stay byte-identical. [R1, R2]
- [ ] 1.6 **Observability.** `emit_timing` gains `env_profiles`,
      `env_inherited`, `env_absent`; `run --json` gains the same;
      `tillandsias-plan script env <script>` dry-run verb. RED:
      `lua_proc.rs::the_timing_record_names_inherited_variables_and_holds_no_value`
      (asserts the three arrays and `grep -c <value>` = 0 over the log) and
      `script_env_dry_run_attributes_every_name_to_one_layer`. [R3]
- [ ] 1.7 **Windows case folding.** On Windows the block, shape and profile
      matches are case-insensitive. RED on yolanda:
      `lua_proc.rs::windows_folds_case_for_the_hard_block` (`gh_token` set on
      the runner, declared as `GH_TOKEN`, refused). Linux asserts the
      case-sensitive side. [R1]
- [ ] 1.8 **Warn census, then flip.** `TILLANDSIAS_ENV_BLOCK_WARN=1` logs
      would-be refusals of step (2) to the timing record without applying
      them; one `./build.sh --check` per platform branch under it; the list
      of names is recorded on the row; the warn mode is deleted in the same
      landing that flips the block on. [R1]

## 2. Namespace hygiene (lands BEFORE 1.2 flips)

- [ ] 2.1 **Rename `TILLANDSIAS_WRAPPER_TOKEN` → `TILLANDSIAS_WRAPPER_MARK`**
      in `scripts/with-tillandsias-builder.sh`, `scripts/lib-dispatch-reap.sh`,
      `scripts/check-no-competing-gate.sh`, `scripts/test-dispatch-reap.sh`,
      `scripts/test-no-competing-gate.sh`,
      `scripts/test-competing-gate-no-dispatch-cause.sh`. RED: the existing
      `test-dispatch-reap.sh` run with a child started through a Lua door
      under the 1.2 block — the reaper misses the subtree (add that arm
      first). [R4]
- [ ] 2.2 **Rename `TILLANDSIAS_NOTARY_KEY` → `TILLANDSIAS_NOTARY_KEY_FILE`**
      in `scripts/build-macos-dmg.sh`, `scripts/build-macos-tray.sh`,
      `scripts/test-macos-signing-seam.sh`. RED: `test-macos-signing-seam.sh`
      arm with the new name (macOS host). [R4]
- [ ] 2.3 **`TILLANDSIAS_CREDENTIAL_NAMES`** in `child_env.rs`:
      `TILLANDSIAS_COORD_CLIENT_SECRET`, `TILLANDSIAS_KEY_PASS`,
      `TILLANDSIAS_CONSENT_TOKEN`. [R4]
- [ ] 2.4 **Guard `scripts/lua/check-env-namespace-hygiene.lua`** (+ its
      `test-env-namespace-hygiene.lua` with a mutation arm that plants
      `TILLANDSIAS_NEW_API_TOKEN` in a scratch tree) and a build.sh step with
      a second regime. RED: the test's planted-name arm against a guard that
      does not exist yet. Pays one shell-to-lua item if the change touches
      the area. [R4]

## 3. Acceptance — the port that was evicted

- [x] 3.1 **Port `scripts/verify-image-usable.sh` again** from `fdca0b2bc`,
      adding `-- @env-profile podman` (and `-- @env TILLANDSIAS_PODMAN
      TILLANDSIAS_PODMAN_ARGS` as before). `build-image.sh::_verify_image_usable`
      and `with-nix-builder.sh` as in that commit; update the Rust pin in
      `crates/tillandsias-headless/src/main.rs::init_and_build_image_builds_are_keep_id_warm`
      to the new call string; drop the two floor lines
      (`shell-decider-floor.txt`, `pipe-site-floor.txt`). Side-by-side arms,
      `.sh` vs `.lua`, byte-identical on stdout, stderr and rc:
      (a) intact image; (b) missing image, `inspect-rc=125`; (c) no podman on
      PATH → `skip:image-usable:no-podman-on-this-host`; (d)
      `TILLANDSIAS_PODMAN_ARGS=--root … --runroot …` hermetic store
      (`scripts/test-image-usability-check.sh`, 7/7); (e) **the 747-knbp
      fixture** `scripts/test-build-image-installed-version-alias.sh` with
      its fake podman reading `TILLANDSIAS_FIXTURE_PODMAN_STORE` (two-line
      change) — all four of its arms green with a RUNNABLE plan binary on the
      fake tree (the pre-fix local run passed only because there was none);
      (f) `CONTAINER_HOST=unix:///nonexistent.sock` → both arms fail with
      podman's remote-connection error and the same rc; (g) `FAKE_PODMAN_STORE`
      left set and undeclared → the child does not see it (the control). The
      usage arm stays the one documented difference
      (`refused:image-usable:usage`, exit 2). Retire the
      `blocked-by:2029-39bt` waiver reason. [R5]
- [ ] 3.2 **Fixture-double rule.** `scripts/test-build-image-installed-version-alias.sh`
      is the first; the other 16 floor fixtures that read `FAKE_*` /
      `*_CALLS` / `*_ARGV_LOG` names are listed on the row and move to a
      file beside the fake or `TILLANDSIAS_FIXTURE_*` as each is ported, not
      before. [R6]

## 4. Methodology and the backlog

- [ ] 4.1 **Methodology text**: in `methodology/` (the file that owns Lua
      runtime rules; `methodology_ask "lua door environment"` to find it), the
      six-step model, the two block classes, "a fake tool is a caller tool"
      (design §4.11), the namespace-hygiene rule (§4.10), and the pointer to
      `child_env.rs` as the one answer. Distil, do not duplicate the design.
      [R6]
- [ ] 4.2 **Carried obligations**: `scripts/lua/check-carried-obligations.lua`
      adds `profile-hint:<profile>` to an offer whose `.sh` reads a profile
      name, and marks `blocked-by:2029-39bt` retired once 3.1 lands (its
      existing retired-reason mechanism). RED: its fixture with an offered
      `.sh` that reads `CONTAINER_HOST` (today: no hint). [R6]
- [ ] 4.3 **Spec sync**: fold this change's delta into
      `openspec/specs/command-runtime/spec.md` (reqs `231502c2`, `48b22c5d`
      modified; `ae550c5d`, `c3d80b67`, `1dd43038`,
      `bba4ae64`, `42690226` added) when 1.x lands; `@trace
      spec:command-runtime` on `child_env.rs`. [R1]

## Follow-up rows (suggested; to be filed by the coordinator)

| Ref | Suggested title | Exit criterion (runnable) | Size / tier |
|---|---|---|---|
| R1 | One child-environment builder with a hard block and per-script declared inherit (design 2029-39bt §4) | `cargo test -p tillandsias-plan --test lua_proc a_credential_shaped_project_variable_does_not_reach_a_child a_declared_caller_variable_reaches_the_child a_hard_blocked_name_is_refused_when_declared a_misspelt_env_directive_is_refused_not_ignored per_call_env_beats_inherit` green on the fixed tree; the first and second RED against a binary built from `c6fc0fe68`; `tests/lua_source_agreements.rs::child_environment_has_one_builder` green; a yolanda run of `windows_folds_case_for_the_hard_block` | L / opus |
| R2 | litmus-helper-nix-cache-size.lua stops reading GH_TOKEN through env.get | `env_get_refuses_a_credential_shaped_name` green; the helper's litmus arms byte-identical before and after on a host with and without `GH_TOKEN` set | S / sonnet |
| R3 | The script-run record and a `script env` dry run name inherited variables, never values | `the_timing_record_names_inherited_variables_and_holds_no_value` and `script_env_dry_run_attributes_every_name_to_one_layer` green; `tillandsias-plan script env scripts/lua/verify-image-usable.lua` prints no `FAKE_PODMAN_STORE` line with it set | M / sonnet |
| R4 | TILLANDSIAS_ names that are not credentials are not spelled like one (two renames, the credential-name list, the hygiene guard) | `tillandsias-plan script run scripts/lua/test-env-namespace-hygiene.lua` 3/3 incl. the planted-name mutation arm; `bash scripts/test-dispatch-reap.sh` green with a Lua-door child arm; `/usr/bin/grep -rn 'TILLANDSIAS_WRAPPER_TOKEN\|TILLANDSIAS_NOTARY_KEY\b' scripts crates` prints nothing | M / sonnet |
| R5 | verify-image-usable.sh is ported to Lua with the podman profile and survives the 747-knbp fixture (re-does 2006-me5t) | seven side-by-side arms (3.1 a–g) byte-identical on stdout, stderr and rc on two platforms; `bash scripts/test-build-image-installed-version-alias.sh` green with a runnable plan binary on the fake tree; the `Carried-Waiver … blocked-by:2029-39bt` reason absent from the landing's trailers; floors shrink by two lines | M / opus |
| R6 | Methodology, fixture-double rule and the obligations hint for the environment model | `methodology_ask "lua door environment"` answers with the six steps; `check-carried-obligations.lua` fixture shows `profile-hint:podman` for an offered `.sh` reading `CONTAINER_HOST`; the 16 fixture doubles are listed on the row | S / sonnet |
| R8 | RESEARCH then DECISION: kernel enforcement of the class-A loader block on Linux (design §4.14): an SELinux domain transition without `noatsecure` for Lua door children, vs running them in `container_t` | on yoga (Silverblue, SELinux enforcing): a probe child started through each candidate prints `AT_SECURE` from `/proc/self/auxv` (or `getauxval`) and runs with `LD_PRELOAD` of a marker `.so`. The candidate passes when AT_SECURE=1 and the marker never loads; control: the same child without the candidate loads it. The install path is recorded without sudo or layering, or as an explicit operator decision. The added latency per call is measured | M / opus |
| R9 | A hard-block refusal is a recorded, classified violation (spec `7120e541`) | `cargo test -p tillandsias-plan --test lua_proc a_per_call_loader_literal_is_recorded_suspicious a_declared_credential_is_recorded_innocent an_inherited_caller_name_is_not_refused` green; a record never contains the value (a planted unique value is absent from the log file, checked with `/usr/bin/grep -c` = 0); `violation:env-block:suspicious:` reaches the gate summary | M / opus |
| R7 | DECISION: fixed-layer additions `TERM=dumb`, `GIT_CONFIG_NOSYSTEM=1` (design §9 Q4) | a measurement of how many floor fixtures' output changes under each, recorded with the command, then a yes/no per name | S / sonnet |

Dependencies: R4 before R1's flip (1.8); R1 before R2, R3, R5, R9; R8 before R9's kernel-enforcement arm; R5 before
R6's retirement arm. R7 is independent.
