## Context

The `vm-provisioning-lifecycle` spec was drafted assuming the same shape as the Linux release pipeline: take a known-good Fedora cloud image, drop the prebuilt `tillandsias-linux-x86_64` binary into it, ship. That model has three problems on the host-shell wave:
1. Apple Silicon under VFR is arm64-only; an x86_64 binary needs Rosetta-in-Linux setup that the spec doesn't address.
2. Publishing per-host-arch Linux binaries doubles the release surface and the trust boundary.
3. The provisioning artifacts (rootfs + binary) are opaque relative to the source tree — debugging "what's actually inside the VM" means inspecting the running container, not reading a recipe.

The repo already has a Containerfile-per-service convention (`images/forge`, `images/proxy`, `images/git`, `images/inference`, etc.) and a `scripts/build-image.sh` wrapper. Extending that convention to "VM rootfs" rather than "container image" is a small step: the same OCI base, the same package set, the same `RUN` steps, plus a few VM-specific concerns (systemd-bootable, sshd-disabled-in-favor-of-vsock-listener, kernel command line).

## Goals / Non-Goals

**Goals:**
- Single declarative recipe (`images/vm/Recipefile` + `manifest.toml` + `bootstrap/*.sh`) describes the entire in-VM environment.
- Host-side materializer reads the recipe + the host arch and produces a bootable rootfs cached locally.
- Reproducibility: identical recipe + identical host arch → identical rootfs SHA (modulo timestamps in metadata).
- Layer-level caching: changing only `bootstrap/30-enclave.sh` re-runs only that step.
- Zero Linux **binaries** shipped from our release pipeline.
- Works for both WSL2 (x86_64) and VFR (aarch64). One recipe, two materializations.
- Dual distribution (D8): a CI-materialized, SHA-pinned **rootfs** as the default fast install path, with on-host materialization as the audit/dev path. The rootfs is a reproducible *output* of the recipe, so the recipe stays the trust root.

**Non-Goals:**
- Replacing OCI / Containerfile syntax wholesale — we extend it with three `RECIPE` directives, not a new DSL.
- Shipping opaque prebuilt per-arch **binaries** (`tillandsias-linux-*`) — the trust root is always the checked-in recipe. (NOTE: distributing a *recipe-materialized, SHA-pinned rootfs* built in CI is explicitly IN scope as the default fast path — see D8 — because it is a reproducible recipe output, not a hand-built binary.)
- Running the recipe inside the in-VM headless (it could in principle, for "rebuild the VM from inside the VM" — out of scope).
- Multi-arch cross-materialization (e.g. building an aarch64 rootfs on an x86_64 host). v1 host arch == VM arch.

## Decisions

### D1: Reuse Containerfile syntax + add three `RECIPE` directives

The recipe is parsed first as a standard Containerfile (via `tillandsias-vm-layer::recipe::parse`, which thinly wraps an existing OCI builder library — likely `buildah` invoked as a subprocess for v1, replaceable later). On top of `FROM`, `RUN`, `COPY`, `ARG`, `ENV` we add:
- `RECIPE vsock-listen <port>` — installs a systemd unit that runs `tillandsias-headless --listen-vsock <port>` on boot.
- `RECIPE entry <command>` — declares the primary in-VM entrypoint (informational; systemd is the actual init).
- `RECIPE arch <comma-list>` — declares supported architectures; the materializer cross-references `manifest.toml` to pick the right base digest.

**Why over alternatives:**
- Pure Containerfile with magic `ENV` vars — clever but invisible to readers; the `RECIPE` keyword signals "this matters for VM materialization."
- A YAML/TOML-only recipe with no scripting — loses the well-understood `RUN` step semantics that match the existing `images/*/Containerfile` convention.
- New DSL (Nix flake-style) — wholesale rewrite; not justified by current need.

### D2: `manifest.toml` pins base-image digests and arch matrix

```toml
recipe_version = 1
recipe_sha     = "auto"            # computed at materialization time

[[base]]
arch    = "x86_64"
ref     = "registry.fedoraproject.org/fedora:44"
digest  = "sha256:<pinned>"
manifest_size_bytes = 524288

[[base]]
arch    = "aarch64"
ref     = "registry.fedoraproject.org/fedora:44"
digest  = "sha256:<pinned>"
manifest_size_bytes = 524288

[output]
expected_rootfs_sha = { x86_64 = "<after-first-success>", aarch64 = "<after-first-success>" }
```

The `expected_rootfs_sha` table is populated by the `recipe-smoke` CI job and checked-in. Drift between CI-observed and user-observed rootfs hash triggers a warning ("your materialization diverged from CI; opening an issue may be appropriate").

**Why:** an unpinned `FROM` makes "reproducible" a lie. Pinning digests is the Containerfile-world equivalent of `package-lock.json`.

### D3: Layer-level caching keyed on (parent_layer_sha + directive_text + script_content_sha)

Each `RUN` / `COPY` / `RECIPE` step produces a layer; its cache key is a hash of (previous layer's content SHA, the directive's text, and — for `COPY` — the SHA of the copied content). Identical key → cache hit; the materializer reuses the existing layer tar instead of re-running the step.

The cache lives at the platform-native app-support path (`~/Library/Application Support/tillandsias/recipe-cache/`, `%LOCALAPPDATA%\tillandsias\recipe-cache\`, `~/.local/share/tillandsias/recipe-cache/`).

**Why:** matches BuildKit / podman's well-understood layer-cache model. No new mental model for contributors.

### D4: Materialization runs inside a throwaway container, not on the host

To avoid polluting the host's package manager state, the materializer:
1. Pulls the pinned base image into a throwaway `buildah` working container.
2. Executes each `RUN` step inside it.
3. After the last step, exports the rootfs as a `.tar` archive.
4. Converts to the VM-native disk format (`.img` for VFR raw, WSL distro-import format for WSL2).
5. Discards the buildah working container.

**Why:** keeps the materializer's side effects bounded; the user's host gets a binary blob, not a half-installed package set. Also means we can run the materializer inside any container runtime (docker, podman, buildah) without host privileges beyond what those tools already need.

### D5: VFR-specific output is a raw image; WSL2-specific output is an importable tar

Both flow from the same intermediate `.tar` of the rootfs. The VFR converter wraps it in a partition table + EFI System Partition + ext4 (or btrfs) rootfs. The WSL2 converter passes the tar directly to `wsl --import`. Per-platform conversion lives in `tillandsias-vm-layer::materialize::{vfr,wsl}`.

### D6: CI-materialized rootfs as first-class dual path, default for non-Linux hosts

Amended 2026-05-25 (Path B owner decision; macOS host authoring per co-owner
mandate). Both non-Linux hosts (macOS, Windows) hit a chicken-and-egg with
the local-only model in D4: local materialization needs `buildah` inside a
Linux environment, which itself needs a Linux VM — *the very thing we're
trying to provision*. macOS gets `buildah` only inside `podman machine`'s
Linux VM (another VFR guest); Windows gets it inside WSL.

The dual-path resolution: every release publishes **CI-materialized,
SHA-pinned, recipe-derived rootfs artifacts** alongside the recipe. The host
fetches the artifact via `tillandsias-vm-layer::fetch` (verified +
resumable), bypassing local materialization entirely. This is NOT a return
to shipping opaque binaries: the recipe is the source of truth, CI is just
a deterministic materializer. The output is reproducible by anyone who
re-runs the recipe locally and compares SHAs.

**Path matrix:**

| Host | Default path | Opt-in dev path |
|---|---|---|
| Linux | local materialization (`buildah` native) | n/a — Linux is the materializer |
| macOS | CI-fetch (`.img` for VFR + `.tar` audit copy) | `--materialize-local` via `podman machine` |
| Windows | CI-fetch (`.tar` for `wsl --import`) | `--materialize-local` via buildah-in-WSL |

**CI placement (per owner decision 2026-05-25): Linux CI builds both
formats.** `materialize::macos::tar_to_vfr_img` is deterministic
(parted/sgdisk + mkfs.ext4 + copy-in) and runs fine on the Linux runner;
no macOS runner minutes are consumed for the rootfs artifact. macOS CI
remains reserved for `Tillandsias.app` bundle builds.

**Format-matrix in `manifest.toml`** (extends D2):

```toml
[output]
expected_rootfs_sha = {
    "x86_64.tar"   = "<sha>",   # Linux dev, WSL2 import
    "aarch64.tar"  = "<sha>",   # CI audit, Linux ARM dev
    "aarch64.img"  = "<sha>",   # macOS Apple Silicon → VFR
    # x86_64.img omitted: no x86_64 VFR consumer in v0.0.1
}
```

The local materialization path (D4) still produces only `.tar`; the
`.img` is a Linux-CI-only emission for the macOS consumer's default path.

**Why over alternatives:**
- "Force local materialization everywhere" — collapses on the chicken-
  and-egg above; punishes macOS + Windows users with a 5+ minute first-run
  bootstrap of a separate Linux VM to build a Linux VM.
- "Ship pre-built binaries, no recipe" — owner explicitly rejected.
- "OCI registry distribution" — heavier infra; can revisit later as a
  CDN-friendly cache layer in front of the CI-built artifact.

**Trust model:** the recipe + manifest is the canonical source. CI
artifacts are caches; `--materialize-local` is the audit. Three-way SHA
agreement (CI build + local rebuild + manifest pin) is the
falsifiability check.

@trace spec:vm-recipe-provisioning, spec:ci-release

### D7: Recipe version stamp lives in `Hello.capabilities`

(was D6 pre-2026-05-25 amendment)

`Hello { capabilities: [..., "vm.recipe@<recipe_sha>"] }` lets the host shell detect "in-VM headless built from a stale recipe" — useful for prompting the user to re-materialize after a `git pull`.

### D8: `tillandsias-headless` builds from source inside the recipe

(was D7 pre-2026-05-25 amendment)

`bootstrap/20-tillandsias.sh` runs `cargo install --path crates/tillandsias-headless --target $TARGETARCH-unknown-linux-musl`. The recipe-build container has the full Rust toolchain; the resulting binary is the only piece that ships in the rootfs. This is what enables "no shipped Linux binaries" — the binary is materialized, not downloaded.

For first-run UX, the build step is by far the slowest (~2 minutes on a modern host). Caching D3 makes subsequent re-materializations skip it if `crates/tillandsias-headless/` source is unchanged.

### D8: Distribution — CI-materialized rootfs is the default install path; on-host materialization is the audit/dev path

*(Added 2026-05-25 by the windows-next host per owner directive + the linux-host amendment request in `plan/issues/linux-recipe-convergence-response-2026-05-24.md`. Cross-ref: `plan/issues/tray-convergence-coordination.md`.)*

Materialization (D4+D7) is the **trust root**, but it is not the only way a user's host can *obtain* the rootfs. Two paths produce a byte-identical (modulo metadata) result; both are first-class:

1. **Fetch (default).** CI runs the recipe (`recipe-smoke`) for each supported arch, producing a rootfs whose SHA-256 is recorded in `manifest.toml`'s `[output] expected_rootfs_sha.<arch>` and published to a **content-addressed distribution surface** (an OCI registry artifact, or a content-addressed URL recorded alongside the SHA in `manifest.toml`). On first run the host downloads that rootfs and verifies it against the pinned SHA via `tillandsias-vm-layer::fetch::download_verified` (resumable, SHA-checked — the function `tillandsias-windows-tray` already shipped in Phase 2). This is **NOT** "shipping a Linux binary": the artifact is a reproducible *output* of the checked-in recipe, content-addressed and recipe-version-stamped, exactly as auditable as the recipe that produced it.

2. **Materialize-local (opt-in, audit/dev).** A `--materialize-local` flag (or env) bypasses the fetch and runs the full on-host materialization (D4). This is the path a recipe contributor uses to validate a change before pushing, and the path any user can use to independently reproduce and compare against the pinned SHA. It is always supported, never removed.

**Per-OS default:**

| Host | Default | Why |
|---|---|---|
| Windows (WSL2) | **Fetch** | On-host materialization needs buildah/podman + Fedora base + Rust toolchain *inside WSL* purely to build the rootfs — a heavy chicken-and-egg first run. Fetch+verify is far lighter. |
| macOS (VFR) | **Fetch** (offered) | On-host materialization runs inside the `podman machine` Linux VM (~2 min cargo build per R1). Fetch is the fast path; the macOS host may confirm/adjust this default in its own response file. |
| Linux | n/a at runtime; **materialize in CI + for dev** | The Linux tray runs `tillandsias-headless` natively with NO VM, so Linux needs no rootfs at runtime. Linux CI is where the canonical per-arch rootfs + `expected_rootfs_sha` are produced; Linux contributors materialize locally to validate recipe changes. |

**Why this is safe relative to the "no shipped binaries" principle:** the rejected model shipped opaque, hand-built per-arch `tillandsias-linux-*` binaries with no in-tree description. A CI-materialized rootfs is the deterministic result of running an in-tree recipe against pinned base digests; its SHA is checked in; anyone can rebuild it with `--materialize-local` and compare. The trust boundary is the recipe + `manifest.toml`, not a release blob.

**Why first-class, not R1-future:** without it, every Windows user pays the buildah-in-WSL bootstrap on first run, which is the single heaviest UX cost in this design. Promoting fetch to the default makes the common path fast while preserving full reproducibility.

## Risks / Trade-offs

- **[R1] First-run wall-clock is dominated by cargo build (~2 min).** → Mitigation: cache hit on re-materialization; UX condensed-status surface already covers "this takes a few minutes" per the spec. **Now first-class as D8:** the default install path fetches a CI-materialized, SHA-pinned rootfs (a recipe output, not a binary), so most users never pay the build cost; on-host materialization stays available via `--materialize-local` as the audit/dev path.
- **[R2] `buildah` is a host dependency.** → Mitigation: it's already a transitive dep of `podman`, which the macOS and Windows trays expect to be available on the host for the same reason. If absent, the materializer surfaces a friendly install hint.
- **[R3] Recipe drift between CI and user can be subtle (different glibc, different microdnf cache).** → Mitigation: D2's `expected_rootfs_sha` field is the canary; the materializer warns on mismatch but does not fail (the recipe is the contract; minor SHA drift is acceptable as long as the recipe ran to completion).
- **[R4] Cross-platform `buildah` availability: it runs natively on Linux but on macOS requires `podman machine` which is itself a VM.** → Mitigation: on macOS, the materializer detects `podman machine` and reuses it — same VM that holds the materialized rootfs cache later.
- **[R5] BREAKING: removing `tillandsias-linux-x86_64` from releases stops anyone currently depending on it.** → Mitigation: nobody is depending on it yet (host-shell wave is pre-release). Document in changelog.
- **[R6] Recipe version stamp in `Hello.capabilities` couples wire compatibility to recipe SHA.** → Acknowledged. The host shell SHOULD only refuse to attach when the in-VM recipe SHA is structurally incompatible (different control wire envelope set); minor recipe drift (e.g. updated `gh` version) is informational, not blocking.
- **[R7] Custom `RECIPE` directives are non-standard Containerfile syntax → other tools (BuildKit linters, IDE plugins) emit warnings.** → Mitigation: prefix-comment fallback — `# tillandsias:recipe vsock-listen 42420` as a parser-compatible alias if the `RECIPE` keyword causes friction. Initial implementation uses the keyword.

## Migration Plan

1. Land the recipe + manifest + bootstrap scripts + spec delta on `linux-next`. The recipe materializer lives as `pub(crate)` inside `tillandsias-vm-layer`; not exposed publicly until tested.
2. Smoke-test in CI: `recipe-smoke` job materializes on `ubuntu-latest` and `macos-latest`, asserts VM boots and `tillandsias-headless --version` returns.
3. Update `tillandsias-macos-tray` and `tillandsias-windows-tray` to call the materializer at first launch (replaces the legacy "download binary from release" code path that was specced but never implemented).
4. Drop the GitHub-release `tillandsias-linux-x86_64` upload job from `.github/workflows/release.yml`.
5. Archive this change.

Rollback: revert the spec delta + release-workflow edit; the recipe + materializer code can stay in-tree (unused) without breaking anything.

## Open Questions

- **Should the recipe support a `RECIPE include <relative-path>` directive** to split large recipes across files? *Default:* not in v1; `bootstrap/*.sh` already provides the composition seam.
- **Is `images/vm/` the right home or should it be `recipes/vm/`** (the latter signals "this is not a Containerfile-only directory")? *Default:* `images/vm/` to match existing convention; happy to renamed if owner prefers.
- **Should `manifest.toml` carry the kernel command line** the VFR/WSL boot uses? *Default:* yes, as `[output] kernel_cmdline = "..."` — moves kernel cmdline from code into recipe.
- **Should the materializer record a `recipe-trace.jsonl`** of which layers were cache hits vs misses, for debugging? *Default:* yes, written next to the rootfs cache entry.
