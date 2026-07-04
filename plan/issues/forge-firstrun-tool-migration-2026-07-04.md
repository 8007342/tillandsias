# Impl: migrate curl/tar Containerfile installers to idempotent FIRST_RUN — 2026-07-04

- class: enhancement (forge image)
- filed: 2026-07-04
- owner: linux
- status: pending (blocked on persistence prereq)
- depends_on: forge-persistent-tool-cache-mount-2026-07-04.md, forge-image-creation-vs-firstrun-split-research-2026-07-04.md
- trace: spec:default-image, spec:forge-cache-dual

## Scope

Delete the "exploded" curl/tar installers from `images/default/Containerfile.base`
(the `install_archive` block + wasmtime + dart + marksman) and
`images/inference/Containerfile` (ollama), and replace each with an idempotent
FIRST_RUN install-if-missing step in the forge/inference entrypoint (lib-common
`ensure_first_run_tools` or similar) that installs into the persistent cache using
each tool's REGULAR user-space installer:

- cargo tools (nextest/chef/watch/audit/edit/llvm-cov/semver-checks/expand/
  criterion/wasi/outdated) + wasm-pack/trunk/typos-cli/watchexec →
  `cargo install <tool>` (or `cargo binstall`) into `$CARGO_HOME`.
- actionlint/vale → official installer into a cache bin dir on PATH.
- wasmtime → official `wasmtime` installer into cache.
- dart, marksman → first-run fetch into cache (or keep at build if truly needed
  for image validation — decide in research).
- ollama → official `ollama` install on first inference-container run into the
  inference cache.

## Idempotency contract (Tillandsias likes idempotency)

Each first-run step MUST:
1. `command -v <tool>` (or version-file check) → skip if already present in the
   persistent cache (second launch is a fast no-op).
2. Install into the persistent cache path only (never the ephemeral overlay).
3. Be safe under a partially-provisioned image (no reliance on a fully-launched
   enclave; the historical reason installers were "exploded" — solve it with
   proper install-if-missing + the proxy egress, not by baking at build).
4. Fail soft: a first-run install failure logs + continues (the forge is usable
   without every optional tool), and retries next launch.

## Sequencing

Do it in SMALL slices, one tool-group per commit, each behind an idempotency
litmus, so a bad migration is isolated. Suggested order: cargo tools first
(highest count, cleanest `cargo install`), then wasmtime/dart/marksman, then
actionlint/vale, then ollama (separate container). Remove the corresponding
Containerfile lines + their pinned `ARG …_SHA256` / `ARG …_VERSION` in the same
slice.

## Exit criteria
- Named Containerfile curl/tar block(s) removed; image build no longer fetches
  those tarballs; image shrinks + builds faster.
- Each migrated tool is installed on first forge/inference launch into the
  persistent cache and is present on PATH; second launch is a no-op (litmus).
- A fresh forge (persistent cache empty) provisions all tools on first attach and
  reuses them thereafter.
- `./build.sh --check` + `--test` pass; forge e2e smoke: first attach installs,
  second attach reuses.
