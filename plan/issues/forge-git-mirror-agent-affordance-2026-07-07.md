# Forge Git Mirror Agent Affordance (Order 237)

**Date:** 2026-07-08
**Agent:** forge-codex-20260708T0000Z
**Status:** Resolved

## Slice 1: fail closed unless origin really resolves to the mirror

The forge credential guard could still return `ok:forge-git-mirror` while
`origin` resolved to plain GitHub HTTPS. That proved anonymous public read
access, not a usable in-forge push channel.

This slice tightens the guard and the injected git config:

- `scripts/check-credential-channel.sh` now requires `git ls-remote --get-url
  origin` to resolve to `git://tillandsias-git/*` or `git://git-service/*`
  before it accepts forge mode as `ok:forge-git-mirror`.
- The guard then probes the resolved mirror URL directly.
- `write_forge_gitconfig()` now emits a project-specific mirror base,
  `git://tillandsias-git/<project>`, instead of the incomplete
  `git://tillandsias-git/` base.
- `litmus:credential-channel-check-shape` now pins both failure modes: an
  unreachable mirror and a plain GitHub origin in forge mode.

## Evidence

- `cargo test --package tillandsias-headless write_forge_gitconfig` with a
  temporary `HOME`: 2 tests passed.
- Direct guard checks:
  - plain GitHub `origin` in `TILLANDSIAS_HOST_KIND=forge` returns
    `missing:no-credential-channel`.
  - `origin` rewritten to `git://tillandsias-git/tillandsias` returns
    `ok:forge-git-mirror`.
- `cargo run --quiet -p tillandsias-policy -- validate-yaml plan/index.yaml
  openspec/litmus-tests/litmus-credential-channel-check-shape.yaml`: ok.
- `./build.sh --check` could not run in this forge because it requires host
  Podman setup even though the forge is already inside a Podman container, and
  because `file` is missing on `PATH`; filed
  `plan/issues/forge-build-check-tooling-gap-2026-07-08.md`.

The local litmus runner currently lists no suites in this forge environment and
executes zero tests for both file-path and name selectors, so the changed
critical-path commands were run directly.

## Residual

This slice does not add a new authentication protocol to the mirror container.
It makes the existing credential-free mirror route explicit and falsifiable.
If the project needs time-limited mirror auth tokens beyond git-daemon enclave
scope, keep order 238 as the follow-up research packet.

## Push Path Evidence

Pushing this checkpoint to GitHub `origin/linux-next` failed after three
fetch/rebase/push attempts:

```text
fatal: could not read Username for 'https://github.com': No such device or address
```

This forge checkout's `origin` resolves to plain
`https://github.com/8007342/tillandsias.git`, not the enclave mirror, and no
usable GitHub credential channel is present in the forge. Smallest next action:
launch future forge checkouts with the injected project-specific mirror
gitconfig active, or provide the git mirror container with a scoped upstream
GitHub credential so mirror pushes reach `origin/linux-next`.

After recording that blocker, the intended enclave route was tested directly:

```bash
git push git://tillandsias-git/tillandsias HEAD:refs/heads/linux-next
```

The mirror accepted commit `5343c856` and its post-receive hook reported:

```text
[git-mirror] Push to origin (https://github.com/8007342/tillandsias.git): success
```

So the direct HTTPS `origin` path remains unavailable inside this forge, but
the credential-free mirror route works when used explicitly. Remaining work:
make future forge checkouts activate the injected project-specific mirror config
by default so agents can use the normal blind `git push origin linux-next`
affordance.
