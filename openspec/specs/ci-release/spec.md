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

The shell corpus is also the first backlog of methodology
`carried_obligations` (methodology/convergence.yaml), named `shell-to-lua`,
at the GENTLE stage since 2026-10-10. A change whose own diff against its base
adds, edits or deletes a file under `scripts/check-*.sh`, `test-*.sh`,
`verify-*.sh`, `guard-*.sh`, `audit-*.sh`, `census-*.sh`, `preflight-*.sh`,
`scripts/lua/` or `scripts/gate-steps.d/` is DUE, and MUST carry one of: one
port (a file from the backlog's counted population ported to `scripts/lua/`
with the same verdict grammar, or retired, its `.sh` deleted and both floors
lowered through `--dump-floors`, so the backlog counter at the head is below
the counter at the base), or one commit trailer
`Carried-Waiver: shell-to-lua <reason>`. Waivers are counted, not judged. A
change that touches none of those paths owes nothing. The carried item SHOULD
be the smallest in reach and MUST be at most 150 lines; when it is larger than
the change's own diff, the change waives with `too-big:<item>:<lines>` instead
of growing. Paid is measured on the backlog counter
(`counter=shell-to-lua:<n>` on the carried-obligation guard's ok: line, over
the `population` globs in convergence.yaml, with an exec wrapper counted once
with its callee), never on the floor's length. A floor line naming a deleted
file is refused as `violation:shell-ratchet:stale-floor:<path>` (1577-57u3; on
2026-10-10 sixteen such lines stood across both floors). The move to ENFORCED (only a port, or a
waiver citing `blocked-by:<order>`, passes) is an operator bar raise, proposed
when the counter does not descend across ten consecutive due integrations,
as `check-carried-obligations.lua --burndown` reports (`trigger=fired`). Provenance:
operator 2026-10-09, "new gates in lua only, and each new lua requires to
retroactively update 1+ of old ones"; operator 2026-10-10, withdrawing that
wording but not its intent, "I just want to automatically do backlog to LUA
migration as agents do progress" and "migrate +1 with your PR". What enforces
this: `scripts/lua/check-carried-obligations.lua` (1577-g96z) prints what a
change owes in `./build.sh --preflight` and warns on a work-ref push; at
landing, `scripts/relay-preflight.sh` refuses a due, silent change and
`scripts/land-queue.sh` evicts it before its gate, and every land commit
records a `Carried: <backlog> <state> [<item-or-reason>]` trailer per backlog
(1577-568c). The honest counter is 1577-57u3.

The bootstrap and installer shell in
`scripts/portability/bootstrap-shell-allowlist.txt` is outside this
requirement by design (it runs before any binary exists).

#### Scenario: A due, silent change is evicted at landing and a waived one is recorded
- **WHEN** the land queue merges a work ref that edits `scripts/check-<name>.sh`, ports nothing and carries no `Carried-Waiver:` trailer
- **THEN** it prints `evict:land-queue:<n>:carried-silent:shell-to-lua` and the waiver line to add, comments it on the PR, and runs no gate for it
- **AND** the same change carrying `Carried-Waiver: shell-to-lua <reason>` in its last paragraph lands with the trailer `Carried: shell-to-lua waived <reason>` on the land commit

#### Scenario: A new shell decider is refused by name
- **WHEN** a commit adds `scripts/check-<name>.sh` not present in `shell-decider-floor.txt`
- **THEN** `./build.sh --check` prints `violation:shell-ratchet:new-decider:scripts/check-<name>.sh` and exits non-zero
- **AND** the refusal names `scripts/lua/check-<name>.lua` on `tillandsias-plan script run` as the remedy

#### Scenario: A floor line naming a deleted file is refused
- **WHEN** a commit deletes `scripts/check-<name>.sh` and leaves its line in `shell-decider-floor.txt` or `pipe-site-floor.txt`
- **THEN** `check-shell-ratchet.lua` prints `violation:shell-ratchet:stale-floor:scripts/check-<name>.sh`, names `--dump-floors` as the remedy, and exits non-zero
- **AND** the same commit with the file's floor lines dropped passes

#### Scenario: A ported decider lowers its floors in the same commit
- **WHEN** a commit replaces `scripts/check-<name>.sh` with `scripts/lua/check-<name>.lua` and deletes the `.sh`
- **THEN** that commit also removes the file's lines from both floor files via `--dump-floors`
- **AND** a later commit that re-adds either line is refused as `violation:shell-ratchet:floor-raised`, judged over the floor file's own history

#### Scenario: A change that touches a gate script carries one port or one waiver
- **WHEN** a change's diff against its base touches `scripts/check-<x>.sh`, `scripts/lua/check-<y>.lua` or a `scripts/gate-steps.d/` step
- **THEN** either the backlog counter at the change's head is below its count at the base, with the ported `.sh` deleted and both floors lowered by `--dump-floors`, or a commit in the change carries the trailer `Carried-Waiver: shell-to-lua <reason>`
- **AND** the carried-obligation guard prints `carried:shell-to-lua:paid:<path>` or `carried:shell-to-lua:waived:<reason>`, and a due change with neither prints `carried:shell-to-lua:due:<path> (<n> lines)` with the waiver line to paste

#### Scenario: A change outside the gate scripts owes nothing
- **WHEN** a change's diff touches no path under `scripts/check-*.sh`, `test-*.sh`, `verify-*.sh`, `guard-*.sh`, `audit-*.sh`, `census-*.sh`, `preflight-*.sh`, `scripts/lua/` or `scripts/gate-steps.d/`
- **THEN** the carried-obligation guard prints `carried:shell-to-lua:not-due`
- **AND** no port or waiver is asked of it

#### Scenario: A stalled backlog is proposed for enforcement, not enforced by the loop
- **WHEN** the backlog counter does not descend across ten consecutive due integrations on linux-next
- **THEN** the coordinator puts one plain ask to the operator carrying the window's paid, waived and silent counts
- **AND** the stage stays gentle until the operator's approval is recorded in methodology `approved_bar_raises`

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
