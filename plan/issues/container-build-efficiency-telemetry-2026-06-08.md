# Container build efficiency, identity, and telemetry research — 2026-06-08

trace: methodology/distributed-work.yaml, methodology/agent-observability.yaml,
       openspec/specs/default-image/spec.md,
       openspec/specs/init-incremental-builds/spec.md,
       openspec/specs/forge-staleness/spec.md,
       openspec/specs/user-runtime-lifecycle/spec.md

- **Status**: research complete; implementation shaped as steps 44-48.
- **Host / branch**: Linux / `linux-next`.
- **Scope**: plan files only. No Containerfile, Rust, shell, or spec implementation
  was changed during this research pass.
- **Supersedes**: the implementation scope of step 40
  `forge-recipe-download-only-assembly`, which mixed package sourcing, image
  identity, cache behavior, runtime init, and verification in one claim.
- **Operator contract**:
  - Prefer Fedora `microdnf install` wherever Fedora 44 has a suitable package.
  - Eliminate `curl | bash` installer execution.
  - Instrument image creation and build scripts with durable structured events.
  - Reuse unchanged images, layers, and downloads.
  - Rebuild only when the image source digest changes, while keeping
    `:<digest>`, `:v<VERSION>`, and `:latest` aliases coherent.

## Executive findings

1. `scripts/build-image.sh` already computes a content digest and canonical
   `tillandsias-<image>:<digest>` tag, but that contract is not shared with
   `tillandsias --init`. The Rust init path independently builds
   `tillandsias-<image>:v<VERSION>` and tracks success in
   `init-build-state.json`. This split permits duplicate builds and divergent
   alias/state behavior.
2. The shell path disables Podman's normal layer reuse with `--no-cache`
   (`scripts/build-image.sh:435-456`) and deletes the package cache before every
   build (`scripts/build-image.sh:340-346`). Even a legitimate rebuild therefore
   re-downloads package metadata, RPMs, npm packages, pip wheels, and release
   assets.
3. The shell digest is computed before forge cheatsheets and source metadata are
   refreshed into `images/default/` (`scripts/build-image.sh:250-251` versus
   `426-432`). The digest can therefore describe the previous staged context
   rather than the exact context sent to Podman.
4. The shell digest is not checkout-portable: `sha256sum` emits each absolute
   filename and the second hash includes those names. Identical source bytes in
   `/home/a/repo` and `/home/b/repo` therefore produce different identities.
5. The Git-only enumeration omits ignored generated inputs that Podman still
   consumes. The router's staged `images/router/tillandsias-router-sidecar`
   binary is gitignored but copied by its Containerfile, so a changed sidecar can
   leave the router source digest unchanged.
6. Digest validation depends on an external `.last-build-<image>.sha256` file.
   If that file is missing but the digest-tagged OCI image exists, the script
   rebuilds instead of trusting the image's identity. Conversely, aliases are
   considered as fallback source tags without validating an OCI source-digest
   label.
7. A cache-version mismatch forces all init images to rebuild
   (`crates/tillandsias-headless/src/main.rs:2563-2579`), even though the active
   source-hash contract says a version bump alone must not force a rebuild.
8. `crates/tillandsias-core/src/image_builder.rs` is still a sketch:
   `image_exists()` always returns false and execution is commented out.
   `crates/tillandsias-core/src/bin/build-image.rs` is also a placeholder.
   The top-level `build-{git,proxy,inference,web}.sh` wrappers run this placeholder
   through Toolbox and then fall back to the shell script.
9. Structured image-build event types already exist in
   `tillandsias-logging::ImageBuildEvent`, but the active shell and `--init`
   build paths do not emit them. Existing logs report only fragments such as
   duration or human-readable BUILD/SKIP lines.
10. `build-all-images.sh --parallel` launches concurrent Podman builds, while
   repository history records prior Podman storage corruption that required
   serialized image builds. No current lock or bounded scheduler protects the
   parallel mode.
11. `build-all-images.sh` covers only git, proxy, forge, inference, and web. It
    omits router, chromium-core, chromium-framework, and vault, so its "all
    images" success message does not prove the runtime image matrix is ready.

## Containerfile source audit

### Fedora package-manager replacements verified on Fedora 44

The following were verified with the Fedora 44 `dnf5` repositories on
2026-06-08. Implementation agents must re-run `dnf5 repoquery` immediately
before editing because package availability is time-sensitive.

| Current source | Fedora 44 package path | Planning decision |
| --- | --- | --- |
| `rustup.rs | sh` | `rustup` | Install the RPM, then invoke the packaged `rustup-init` command explicitly if rustup-managed targets are still required. Never pipe network bytes to a shell. |
| rust components | `rust`, `cargo`, `clippy`, `rustfmt`, `rust-analyzer` | Prefer RPMs when the image does not require rustup-only target management. Do not install Fedora `rust` and `rustup` side by side without an explicit compatibility decision. |
| `cargo-deny` via cargo-binstall | `cargo-deny` | Move to `microdnf install`. |
| Delve release tarball | `delve` | Move to `microdnf install`. |
| shfmt release binary | `shfmt` | Move to `microdnf install`; verify the Fedora 44 repo still resolves the package despite its current fc41 build release. |
| Ollama `latest/download` tarball | `ollama` | Candidate for `microdnf install`, but validate image-size and CPU-only behavior first: the Fedora package currently pulls ROCm/hipblas dependencies and reports about 941 MiB installed size. Keep the direct pinned CPU-only binary if the RPM violates the inference image's lean CPU-only contract. |
| Python pip tools | `ruff`, `poetry`, `pipx`, `uv`, `black`, `pylint`, `yamllint`, `python3-mypy`, `python3-pytest` | Move the available subset to `microdnf install`; retain pip only for tools with no suitable RPM and pin versions/hashes. |
| Node package managers | `pnpm`, `yarnpkg` | Move to `microdnf install` after confirming command names and required versions. |

Useful primary references:

- Fedora Developer Portal, Rust installation:
  `https://developer.fedoraproject.org/tech/languages/rust/rust-installation.html`
- Fedora package index:
  `https://packages.fedoraproject.org/`
- Local verification commands:
  `dnf5 repoquery <name>` and `dnf5 repoquery --info <name>`.

### Tools without a verified Fedora 44 binary package

No exact Fedora 44 package was found in the 2026-06-08 repository query for:

- `cargo-nextest`, `cargo-audit`, `cargo-watch`, `cargo-chef`,
  `cargo-binstall`, `cargo-llvm-cov`, `cargo-semver-checks`,
  `cargo-criterion`, `cargo-wasi`, `cargo-outdated`, `wasm-pack`,
  `typos-cli`, `watchexec-cli`, `actionlint`, `vale`, `wasmtime`,
  Dart SDK, `pyright`, `bandit`, Python LSP server, Prettier, ESLint,
  TypeScript language server, markdownlint, and Playwright.

These are not automatic removals. For each tool the implementation packet must
choose one of:

1. A pinned direct release asset with a checked SHA-256 checksum and no shell
   execution.
2. A pinned npm/pip package where that ecosystem is the tool's authoritative
   distribution channel, using cache mounts and an explicit version.
3. Removal from the lean image when no download-only, reproducible source is
   justified by active specs.

`@latest`, `/releases/latest/`, and dynamically fetched "latest version" values
must not participate in the source digest contract. They can change without a
Containerfile edit and therefore make `Containerfile hash unchanged => image
unchanged` false.

### Current unsafe or floating sources

- `images/default/Containerfile:87`: `https://sh.rustup.rs | sh`.
- `images/default/Containerfile:92`: cargo-binstall installer script piped to
  `bash`.
- `images/default/Containerfile:38`: four npm packages use `@latest`.
- `images/default/Containerfile:111-115`: Dart resolves `latest/VERSION`.
- `images/inference/Containerfile:33`: Ollama uses `releases/latest/download`.
- Multiple direct release tarballs lack explicit checksum verification.

### Package-source decision, verified 2026-06-08

Fedora 44 `dnf5 repoquery` and a Fedora Minimal `microdnf --assumeno`
transaction verified these migrations:

| Executable group | Before | After |
| --- | --- | --- |
| Rust compiler/components | rustup pipe-to-shell | Fedora `rust`, `cargo`, `clippy`, `rustfmt`, `rust-analyzer` |
| Cargo policy tool | cargo-binstall | Fedora `cargo-deny` |
| Go debugger/shell formatter | unchecked GitHub assets | Fedora `delve`, `shfmt` |
| Python developer tools | unpinned pip | Fedora `ruff`, `poetry`, `pipx`, `uv`, `black`, `pylint`, `yamllint`, `python3-mypy`, `python3-pytest`, `python3-lsp-server` |
| JS package managers | unpinned npm | Fedora `pnpm`, `yarnpkg` |
| Agent and remaining language tools | floating npm/pip | exact npm/pip versions |
| nextest, cargo-binstall, Wasmtime, actionlint, Vale, Dart | unchecked/floating assets | exact upstream release URL plus embedded SHA-256 |
| Ollama CPU binary | `releases/latest/download` | exact v0.30.6 URL plus upstream SHA-256 |

RPM Fusion free and nonfree Fedora 44 metadata was queried directly for
`cargo-binstall`, `cargo-nextest`, `actionlint`, `vale`, `dart`, `ollama`,
`wasmtime`, `pyright`, `bandit`, and `markdownlint-cli`; none were present.
Adding RPM Fusion would therefore remove no direct asset while adding
repositories, keys, and metadata refreshes. Fedora COPR candidates for Dart
were stale, failed, beta, or lacked Fedora 44 coverage; COPR remains
owner-scoped and unofficial, so none were admitted to the base image.

The Fedora Ollama RPM measured 52.1 MiB compressed and 940.9 MiB installed.
The checksum-verified CPU-only extraction produced a complete Tillandsias
inference image of 187 MB, so the RPM remains unsuitable for the lean
inference contract.

The sibling Alpine Containerfiles already use `apk add --no-cache` correctly.
They are in scope for common identity/telemetry and checksum policy, but not for
conversion to DNF.

## Target identity contract

The implementation wave should establish one source-of-truth image descriptor:

```text
ImageBuildSpec {
  image_name,
  containerfile,
  context_root,
  dependency_digests,
  build_args,
  source_digest,
  canonical_tag,
  version_alias,
  latest_alias
}
```

Digest rules:

- Hash the exact bytes visible to Podman after generated/staged inputs exist.
- Include relative paths, file modes, symlink targets, file contents,
  Containerfile bytes, build args that affect output, and dependency image
  digests such as chromium-core for chromium-framework.
- Never include checkout-absolute paths in the digest.
- Include required generated/ignored context inputs through an explicit manifest
  or dependency digest; do not infer the build input set from Git tracking alone.
- Exclude logs, local state, Git metadata, and outputs generated by the build.
- Make traversal sorted and deterministic.
- The canonical tag is `tillandsias-<image>:sha256-<digest>` or the existing
  full-digest form, chosen once and pinned by tests.
- Add OCI labels:
  - `io.tillandsias.image.source-digest`
  - `io.tillandsias.image.version`
  - `io.tillandsias.image.name`
  - `org.opencontainers.image.version`
  - `org.opencontainers.image.revision` when available
- A build is skipped when the canonical digest tag exists and its label matches,
  regardless of whether an external state file exists.
- `:v<VERSION>` and `:latest` are aliases only. Refreshing aliases never builds.
- `--force` means rebuild the same digest for diagnostics; it does not mint a
  false new identity.
- A version/cache-version change alone never rebuilds an unchanged source
  digest.

## Target cache contract

- Remove unconditional `--no-cache`; Podman 5.8 enables intermediate layers by
  default and exposes `--layers`, `--cache-from`, and `--cache-to`.
- Do not delete package caches before every build.
- Add named `RUN --mount=type=cache` mounts where supported for DNF, npm, pip,
  Cargo/rustup downloads, and other remaining network-heavy installers.
- Keep cache IDs scoped by package manager, architecture, and base-image
  identity so incompatible caches do not collide.
- Preserve Containerfile ordering: stable OS/toolchain layers first, frequently
  changing cheatsheets/config/entrypoints last.
- Record cache policy and hit/miss evidence. Do not claim a cache hit from
  elapsed time alone.
- Serialize Podman storage mutations or use a proven bounded scheduler/lock.
  `build-all-images.sh --parallel` must not reintroduce the previously observed
  storage corruption.

## Target telemetry contract

Emit one JSONL lifecycle stream to a stable user-state location, recommended:

`$XDG_STATE_HOME/tillandsias/image-build-events.jsonl`

Fallback:

`$HOME/.local/state/tillandsias/image-build-events.jsonl`

Required event fields:

```yaml
schema_version: 1
event_type: image.build.decision | image.build.started | image.build.completed | image.build.failed
event_id: stable UUID/ULID
build_id: shared across one attempt
timestamp: RFC3339 UTC
actor: build-image.sh | tillandsias-init | build-all-images | image-builder
image_name: forge
source_digest: sha256...
canonical_tag: tillandsias-forge:sha256-...
version_alias: tillandsias-forge:v...
latest_alias: tillandsias-forge:latest
decision: skip | build | force_rebuild | retag
reason: digest_present | digest_missing | source_changed | image_missing | forced | label_mismatch
cache_policy: layers | remote | disabled
cache_result: hit | partial | miss | unknown
duration_ms: integer
image_id: string
image_size_bytes: integer
bytes_downloaded: integer | null
exit_code: integer
error_class: string | null
error_summary: redacted string | null
containerfile: repo-relative path
context_file_count: integer
podman_version: string
host_platform: linux | macos | windows
```

Privacy and robustness:

- Never log `GITHUB_TOKEN`, secrets, command environments, or full URLs with
  query strings.
- Use append + lock + atomic line writes so concurrent wrappers cannot corrupt
  JSONL.
- Telemetry write failure is visible but non-fatal to the image build.
- Human output is rendered from the same decision/result object; it must not be
  a separate truth source.
- Extend the existing `ImageBuildEvent` rather than creating an unrelated
  schema when practical.

Metrics derived from the stream:

- build attempts and failures by image/reason
- skip/retag/build counts
- build duration histogram
- image size
- cache hit/partial/miss counts
- bytes downloaded when Podman exposes trustworthy data
- duplicate-build count for the same digest

## Work graph

### Step 44 — package-manager-first recipes

- Containerfile-only package/source cleanup.
- Does not own build identity or Rust init behavior.
- Can start immediately.

### Step 45 — canonical digest and alias engine

- One Rust-owned image build specification and digest implementation.
- Makes labels and aliases authoritative across runtime paths.
- Can start in parallel with step 44.

### Step 46 — Podman cache and build serialization

- Removes `--no-cache`, introduces cache policy, and protects Podman storage.
- Depends on the step-45 build specification contract.

### Step 47 — structured build telemetry

- Wires existing logging types into shell/Rust paths and metrics.
- Depends on the step-45 decision/result shape.

### Step 48 — wrapper convergence and end-to-end proof

- Retires placeholder/Toolbox fallback paths and validates the full matrix.
- Depends on steps 44-47.

## Risks and explicit non-goals

- Do not replace Alpine `apk` with DNF.
- Do not install Fedora `rust` and `rustup` together accidentally.
- Do not adopt the Fedora Ollama RPM until CPU-only size/dependency behavior is
  measured against the current selective binary extraction.
- Do not use network availability, mutable `latest` endpoints, or timestamps as
  digest inputs.
- Do not expose secrets in build logs or telemetry.
- Do not publish Tillandsias images to a registry; the operator previously
  rejected that model.
- Do not make telemetry infrastructure a prerequisite for successful builds.

## Research evidence

- Fedora host: Fedora Linux 44, `dnf5`, Podman 5.8.2.
- Podman build capabilities verified locally:
  `--layers`, `--cache-from`, `--cache-to`, `--cache-ttl`, `--label`,
  `--annotation`, `--secret`, `--source-date-epoch`; `--no-cache` explicitly
  disables existing cached images.
- Repository paths audited:
  - all `images/**/Containerfile*`
  - `scripts/build-image.sh`
  - top-level `build-*.sh`
  - `crates/tillandsias-headless/src/main.rs`
  - `crates/tillandsias-core/src/image_builder.rs`
  - `crates/tillandsias-core/src/bin/build-image.rs`
  - `crates/tillandsias-podman/src/client.rs`
  - `crates/tillandsias-logging/src/event_collector.rs`
