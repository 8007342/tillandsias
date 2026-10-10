<!-- @trace spec:ci-release -->

## Status

active

## Requirements

### Release workflow publishes the Linux musl binary

The release workflow MUST publish the `tillandsias-linux-x86_64` musl-static
binary as the canonical Linux release artifact. It MUST NOT depend on Tauri,
AppImage packaging, Node.js, or host WebKit packaging.
The hosted runner MUST build the musl-static release artifacts through the
repository Nix targets and MUST use the configured FlakeHub cache.

#### Scenario: Linux binary artifact
- **WHEN** the release workflow completes
- **THEN** the GitHub Release includes `tillandsias-linux-x86_64`
- **AND** the workflow validates that the binary is statically linked
- **AND** the workflow signs the artifact with a `.cosign.bundle`
- **AND** the workflow builds `.#tillandsias-x86_64-musl`

### Hosted workflows stay release-only

GitHub-hosted workflows MUST be reserved for remote-only release work:
platform builds, artifact sanity checks, Cosign keyless signing through GitHub
OIDC, GitHub Release upload, and rolling tags. Verification, litmus execution,
dashboard generation, cache probing, merge work, and integration checks belong
to the local release gate.

#### Scenario: Local litmus and dashboard gate
- **WHEN** an operator prepares a release
- **THEN** they run `scripts/release-preflight-local.sh`
- **AND** the local preflight runs `scripts/local-ci.sh`
- **AND** hosted workflows do not run litmus, convergence dashboard, cache warm,
  or test execution (a lean fmt+check push/PR gate, ci.yml, is permitted)

#### Scenario: Manual hosted release
- **WHEN** `.github/workflows/release.yml` is dispatched manually
- **THEN** it builds, validates, signs, publishes, and updates rolling tags only

### Requirement: A new gate decider or gate fixture runs on the Lua runner
<!-- req-id: ec267f02 -->

A decider or fixture added to the local gate (`./build.sh --check`, the
preflight door, `scripts/gate-steps.d/*.step`) MUST be a Lua script under
`scripts/lua/` run through `tillandsias-plan script run`, ending in one
`verdict.*` call (1384-bqhy). It MUST NOT be a new `scripts/check-*.sh`,
`test-*.sh`, `verify-*.sh` or `guard-*.sh`, and it MUST NOT reach a host
tool the plan binary already provides (`jq`, `yq`, `rg`, `sed`/`awk` for
text, `sha256sum`/`shasum`): the `json`, `yaml`, `text`, `hash`, `path` and
`fs` tables (1375-btuf, 1384-ddua) are the portable form. A process a
decider or fixture needs MUST be an argv through `proc.run` / `proc.spawn`
(command-runtime), never a shell string.

The shell corpus that predates this requirement is pinned, per file, in
`scripts/portability/shell-decider-floor.txt` and
`scripts/portability/pipe-site-floor.txt`; `scripts/lua/check-shell-ratchet.lua`
(1384-bxhk) refuses a new shell decider and a raised floor, and a port that
deletes a `.sh` MUST lower the floors in the same commit through
`check-shell-ratchet.lua --dump-floors`, never by hand. The `--check` log
prints the counts on every run (`ok:shell-ratchet:sh=<n>:floor:<f> ...
gate-steps:sh=<a>:lua=<b>`) so a reader can see the corpus only descend.
Each change that adds a Lua decider or fixture MUST also port at least one
existing shell decider or fixture to Lua in that same change, deleting the
`.sh` and lowering the floors (operator ruling 2026-10-09: "each new lua
requires to retroactively update 1+ of old ones"). New gates therefore pay
down the shell corpus instead of only stopping its growth.
The bootstrap and installer shell in
`scripts/portability/bootstrap-shell-allowlist.txt` is outside this
requirement by design (it runs before any binary exists).

#### Scenario: A new shell decider is refused by name
- **WHEN** a commit adds `scripts/check-<name>.sh` not present in `shell-decider-floor.txt`
- **THEN** `./build.sh --check` prints `violation:shell-ratchet:new-decider:scripts/check-<name>.sh` and exits non-zero
- **AND** the refusal names `scripts/lua/check-<name>.lua` on `tillandsias-plan script run` as the remedy

#### Scenario: A ported decider lowers its floors in the same commit
- **WHEN** a commit replaces `scripts/check-<name>.sh` with `scripts/lua/check-<name>.lua` and deletes the `.sh`
- **THEN** that commit also removes the file's lines from both floor files via `--dump-floors`
- **AND** a later commit that re-adds either line is refused as `violation:shell-ratchet:floor-raised`, judged over the floor file's own history

#### Scenario: A new Lua decider carries a port of an old shell one
- **WHEN** a change adds `scripts/lua/check-<new>.lua` to the gate
- **THEN** the same change deletes at least one `scripts/check-*.sh`, `test-*.sh`, `verify-*.sh` or `guard-*.sh` and replaces it with a Lua equivalent
- **AND** `shell-decider-floor.txt` is at least one line shorter than on the change's base

#### Scenario: A new shell fixture is counted until native process conformance lands
- **WHEN** a commit adds `scripts/test-<name>.sh` not present in `shell-decider-floor.txt`
- **THEN** `--check` prints one `warn:shell-ratchet:new-shell-fixture:` line naming the Lua fixture pattern and exits 0
- **AND** the warn names the open native macOS / Windows managed-process rows as the reason the arm is advisory, not an unlanded `proc.spawn`

## Litmus Chain

Smallest actionable boundary:
- `grep -F 'tillandsias-linux-x86_64' .github/workflows/release.yml`
- `grep -F 'statically linked' .github/workflows/release.yml`
- `grep -F 'nix build -L .#tillandsias-x86_64-musl' .github/workflows/release.yml`
- `test -x scripts/release-preflight-local.sh`
- `! test -e .github/workflows/litmus-tests.yml`
- `! grep -F 'cargo test' .github/workflows/ci.yml`

Sibling tests:
- `./scripts/release-preflight-local.sh --fast`
- `./scripts/local-ci.sh --fast`

Scoped follow-up:
```bash
./build.sh --ci-full --install --filter ci-release --strict ci-release
./build.sh --ci-full --install --strict-all
```

## Litmus Tests

### test_release_workflow_musl_binary_policy (binding: litmus:ci-release-musl-binary-policy)
**Setup**: Inspect `.github/workflows/release.yml`
**Signal**: Release workflow builds, validates, signs, and publishes the Linux
musl binary
**Pass**: Release workflow publishes `tillandsias-linux-x86_64` and litmus
execution stays local
**Fail**: Release workflow drifts back to Node/Tauri/AppImage or cloud runtime
execution

### test_shell_ratchet_refuses_new_shell_decider (binding: litmus:shell-ratchet)
**Setup**: `scripts/test-shell-ratchet.sh` builds a scratch repo with seeded floors
**Signal**: `tillandsias-plan script run scripts/lua/check-shell-ratchet.lua`
over a tree that adds a `check-*.sh`, a raised floor, and a quoted pipe
**Pass**: the new decider and the raised floor are refused by name; the
quoted pipe and an honest lowering are accepted; the count line prints
`sh=`, `pipes=`, `litmus-form:` and `gate-steps:` every run
**Fail**: a new `.sh` decider lands green, or a floor rises without refusal

## Sources of Truth

- `cheatsheets/utils/gh-cli.md` — Gh Cli reference and patterns
- `cheatsheets/build/cargo.md` — Cargo reference and patterns
- `cheatsheets/build/validation-ci.md` — Local release gate policy
- `cheatsheets/runtime/linux-user-session-podman.md` — Local/runtime Podman boundary

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:ci-release" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
