# Impl: migrate curl/tar Containerfile installers to idempotent FIRST_RUN — 2026-07-04

- class: enhancement (forge image)
- filed: 2026-07-04
- owner: linux
- status: pending (blocked on persistence prereq)
- depends_on: forge-persistent-tool-cache-mount-2026-07-04.md, forge-image-creation-vs-firstrun-split-research-2026-07-04.md
- trace: spec:default-image, spec:forge-cache-dual

## Migration path (CORRECTED per operator 2026-07-04)

**KEEP the prebuilt binaries. Do NOT switch to source compilation.** The problem
is NOT that these tools are curl-fetched prebuilt binaries — that's correct and
fast. The problem is the *finicky, hardcoded command chains* baked into container
CREATION:

- `curl -o x.tar && sha256 && mkdir && tar -xzf && cp && chown && chmod && rm …`
  exploded across the Containerfile, and
- every URL pinning a **hardcoded version + SHA256** (`ARG CARGO_NEXTEST_VERSION`,
  `…_SHA256`, …) that rots and must be hand-bumped.

So the migration is: **"manual curl-install of prebuilt AT CREATION" →
"manual curl-install of prebuilt AT FIRST_RUN, resolving the LATEST version
dynamically."** Same prebuilt artifacts, same fetch approach — just moved to a
first-run step into the persistent cache, de-hardcoded, and expressed once as a
clean reusable helper instead of an exploded chain per tool.

### Scope

Delete the "exploded" `install_archive`/curl/tar/zip blocks (+ wasmtime + dart +
marksman) from `images/default/Containerfile.base` and ollama from
`images/inference/Containerfile`, and replace them with an idempotent FIRST_RUN
step in the forge/inference entrypoint (lib-common `ensure_first_run_tools` or
similar) driven by ONE reusable prebuilt-installer helper:

```
install_prebuilt <name> <url-template-or-latest-resolver> [<archive-member>]
  # 1. present in the persistent cache?  -> skip (idempotent)
  # 2. resolve LATEST version (GitHub releases /latest, or the tool's stable
  #    channel) — NO hardcoded version/SHA in the image
  # 2b. resolve the asset for THIS host's arch via $(uname -m) (x86_64 | aarch64)
  #    — NO hardcoded x86_64 URL (see macos-forge-base-build-arch-and-fragility)
  # 3. curl the prebuilt asset -> extract -> place the binary on the cache PATH
  # 4. all the mkdir/tar/chmod/rm finickiness lives ONCE here, not per tool
```

> **Arch-awareness (added 2026-07-05, macOS evidence).** The current
> `Containerfile.base` install_archive URLs are hardcoded `x86_64-unknown-linux-gnu`
> and the base image builds with no `--platform`, so on the **aarch64** macOS/Apple-
> Silicon guest they bake non-executable x86_64 binaries. Moving the same x86_64 URLs
> to first-run just relocates that bug — the helper MUST resolve the asset for the
> running arch. See `plan/issues/macos-forge-base-build-arch-and-fragility-2026-07-05.md`.

Tools (all stay PREBUILT — just fetched first-run, latest):

- cargo tools (nextest/chef/watch/audit/edit/llvm-cov/semver-checks/expand/
  criterion/wasi/outdated) + wasm-pack/trunk/typos-cli/watchexec → prebuilt release
  tarballs (as today, via the same cargo-quickinstall / project release assets) into
  `$CARGO_HOME/bin`, resolved to latest. (`cargo binstall` is one acceptable
  *mechanism* for "fetch prebuilt" — but NEVER `cargo install` from source.)
- actionlint / vale → prebuilt GitHub release asset onto the cache PATH.
- wasmtime → prebuilt release tarball into cache.
- dart, marksman → prebuilt SDK/binary into cache.
- ollama → prebuilt release tarball on first inference-container run into the
  inference models/tool cache (NOT the official `curl | sh` if it re-bakes chains —
  reuse `install_prebuilt`).

Dynamic-latest caveat: pin a **floor** (minimum acceptable version) and verify the
downloaded asset's checksum *computed at fetch time* (not a hardcoded image SHA), so
"latest" stays reproducible-enough and tamper-evident without hand-bumping constants.

## Idempotency contract (Tillandsias likes idempotency)

Each first-run step MUST:
1. `command -v <tool>` (or version-file check) → skip if already present in the
   persistent cache (second launch is a fast no-op).
2. Install into the persistent cache path only (never the ephemeral overlay).
3. Be safe under a partially-provisioned image (no reliance on a fully-launched
   enclave; the historical reason installers were "exploded" into the Containerfile
   — solve it with proper install-if-missing + the proxy egress at first-run, not by
   baking chains at build).
4. Fail soft: a first-run install failure logs + continues (the forge is usable
   without every optional tool), and retries next launch.

## Sequencing

Do it in SMALL slices, one tool-group per commit, each behind an idempotency
litmus, so a bad migration is isolated. FIRST slice: land the reusable
`install_prebuilt` helper + migrate ONE tool-group (cargo tools) to prove the
pattern; then wasmtime/dart/marksman, then actionlint/vale, then ollama (separate
container). Remove the corresponding Containerfile lines + their pinned
`ARG …_SHA256` / `ARG …_VERSION` in the same slice (de-hardcoding is part of the win).

## Exit criteria
- Named Containerfile curl/tar/zip/chmod/mkdir/chown/rm chains removed + their
  `ARG …_VERSION`/`…_SHA256` constants gone; image build no longer fetches those
  tarballs; image shrinks + builds faster.
- Tools are still PREBUILT (no source compilation; no `cargo install` from source),
  fetched at first-run and resolved to LATEST (no hardcoded versions).
- Each migrated tool is installed on first forge/inference launch into the
  persistent cache and is present on PATH; second launch is a no-op (litmus).
- A fresh forge (persistent cache empty) provisions all tools on first attach and
  reuses them thereafter.
- `./build.sh --check` + `--test` pass; forge e2e smoke: first attach installs,
  second attach reuses.

## SLICE 2 DONE 2026-07-05 (actionlint/vale/wasmtime)

actionlint/vale/wasmtime now install at arch-aware FIRST_RUN via lib-common
`ensure_forge_prebuilt_tools` (their arch tokens differ from the cargo triple:
actionlint linux_amd64|arm64, vale Linux_64-bit|arm64, wasmtime x86_64|aarch64-linux).
Removed from Containerfile.base along with the now-unused `install_archive` helper +
their ARG _VERSION/_SHA256; only **dart** remains build-time (a full SDK to
/opt/dart-sdk — its own later sub-slice). Verified on x86_64 (actionlint 1.7.12 +
wasmtime 45.0.0 install + run; wasmtime's nested tar.xz extracts correctly); aarch64
assets pre-verified 200. default-image litmus suite 100% (STEP 7 now 2 sha256sum
sites; arch-shape litmus gains a slice-2 step). Remaining: dart sub-slice + version
de-hardcoding via the releases/latest web redirect.

## DART SUB-SLICE DONE 2026-07-05 (dart SDK — forge base now microdnf-only)

The Dart SDK now installs at arch-aware FIRST_RUN via lib-common `ensure_dart_sdk`
(x86_64 -> x64, aarch64 -> arm64) into the order-179 persistent cache at
`$PROJECT_CACHE/dart/dart-sdk`, called (backgrounded) from `ensure_forge_prebuilt_tools`.
Idempotent (skip if `$PROJECT_CACHE/dart/dart-sdk/bin/dart` is executable), fail-soft
(a failed fetch logs + retries next launch), timeout-guarded (`curl --max-time 300`).
Unlike the cargo dev-tools (single binaries via `install_prebuilt`), Dart ships as a
full SDK that unpacks a top-level `dart-sdk/` dir, so it gets its own helper.

Removed from `Containerfile.base`: the `ARG DART_VERSION` + `ARG DART_SHA256`, the
curl/unzip `RUN` block, and the `ENV PATH=/opt/dart-sdk/bin`. lib-common's PATH now
points at `$PROJECT_CACHE/dart/dart-sdk/bin`.

**This COMPLETES forge-base CREATION becoming microdnf-only** — `Containerfile.base`
has NO curl/tar/unzip archive-extraction tool chain left (creation is microdnf + npm +
a couple single-binary curls like marksman only). Verified on x86_64: `ensure_dart_sdk`
fetches + unzips the SDK and `dart-sdk/bin/dart --version` reports Dart 3.12.1; both the
x64 + arm64 release zips were pre-verified HTTP 200. default-image litmus suite 100%
(Req Direct assets now expects 1 sha256sum site — only ollama; arch-shape litmus gains
an `ensure_dart_sdk` step). Remaining for order 180: marksman single-binary + ollama
(inference) -> FIRST_RUN, and version de-hardcoding via releases/latest.
