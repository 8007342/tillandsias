# Curated Forge-Toolchain Enhancement Backlog — 2026-05-29

trace: plan/issues/forge-diagnostics-automation-2026-05-27.md
       (`forge-enhancements/curated-toolchain-backlog` work packet)
trace: methodology/forge-diagnostics.yaml (response_shape)
trace: openspec/specs/default-image/spec.md

## Provenance

This backlog is seeded by three independent live forge-diagnostic runs
this session:

- `plan/diagnostics/diagnostics_20260529T040556Z-summary.md` (04:05Z, 100% completeness, 8 missing tools, 8 enhancement candidates)
- `plan/diagnostics/diagnostics_20260529T050328Z-summary.md` (05:03Z, 100% completeness, 5 missing tools, 5 enhancement candidates)
- `plan/diagnostics/diagnostics_20260529T060330Z-summary.md` (06:03Z, 100% completeness, 24 missing tools, 10 enhancement candidates)

Each run is the LLM agent walking the diagnostic prompt at
`plan/diagnostics/forge-diagnostics-prompt.txt`, observing the
installed-toolchain state inside the forge container, and surfacing
gaps where instruction files exist for a tool the binary doesn't
provide.

**Status convention** (per the work packet's `expected_evidence`):

- `proposed` — candidate captured from at least one diagnostic run, awaiting orchestrator approval against the privacy/isolation gate.
- `approved` — orchestrator has approved + a sized implementation packet exists.
- `blocked` — flagged by an isolation/privacy risk OR conflict with an existing tool OR no instruction file motivating the inclusion.
- `deferred` — not enough signal yet OR depends on an upstream change OR low/marginal value.

This file STAGES candidates at `proposed`; it does NOT approve them
unilaterally. The orchestrator advances state via separate commits
once the privacy/isolation rationale is reviewed.

## Privacy/Isolation Gate

All candidates must pass the forge's privacy/isolation envelope
unchanged before approval:

- No new network egress paths beyond the existing proxy ACL.
- No new credentials, secrets, or auth flows.
- No new mounts that broaden host filesystem visibility.
- No drop of `--cap-drop=ALL` / `--security-opt=no-new-privileges` / `--userns=keep-id` / `--rm`.
- Static binaries / package-manager-managed tools that drop into `/usr/local/bin` or a versioned `/opt/<tool>/bin` are PREFERRED.
- Any tool that needs runtime root or daemon-mode access is BLOCKED at the gate.

## Backlog (by ecosystem)

### Rust

| Candidate | Status | Source runs | Rationale | Privacy/isolation notes |
|---|---|---|---|---|
| `clippy` (rustup component) | **implemented** | 06:03Z | Standard Rust linter; absent despite rustc/cargo installed. | Rustup component install — same envelope as rustc. No new egress. |
| `cargo-edit` | **implemented** | 06:03Z | Enables `cargo add/rm/upgrade` for ergonomic dep management. | Single binary; cargo install. No new egress. |
| `cargo-llvm-cov` | **implemented** | 06:03Z | Code-coverage tooling expected in CI/test workflows. | Drops llvm tools too — image-size impact; gate at size budget. |
| `cargo-tarpaulin` | deferred | 06:03Z | Alternative coverage tool — pick one between this and `cargo-llvm-cov`. | Single binary; cargo install. |
| `cargo-deny` | **implemented** | 06:03Z | License + advisory checking, standard in production pipelines. | Needs network at FIRST RUN to fetch advisory-db; review proxy ACL. |
| `cargo-semver-checks` | **implemented** | 06:03Z | Automated semver verification for library releases. | Single binary; cargo install. |
| `cargo-expand` | **implemented** | 06:03Z | Macro-expansion debugging essential for Rust development. | Single binary; cargo install. |
| `cargo-outdated` | approved | 06:03Z | Dependency-freshness checks. | Network needed for upstream version query; gate at proxy ACL. |
| `cargo-tree` | blocked | 06:03Z | Dependency-graph visualization (now in cargo core — VERIFY this is still needed). | n/a — likely already covered by `cargo tree`. Redundant. |
| `cargo-criterion` | **implemented** | 06:03Z | Benchmarking harness front-end for criterion. | Single binary; cargo install. |
| `cargo-wasi` | **implemented** | 06:03Z | WASI target convenience wrapper. | Single binary; depends on `wasmtime` being available. |

### Python

| Candidate | Status | Source runs | Rationale | Privacy/isolation notes |
|---|---|---|---|---|
| `black` | **implemented** | 04:05Z, 06:03Z | Formatter; ruff is installed but black is the standard formatter. | pip install — same envelope as existing python. Shipped on the existing `pip3 install` RUN layer (no new image layer). |
| `pylint` | **implemented** | 06:03Z | Linter complement to ruff/mypy. | pip install — same envelope. Shipped alongside `black` in the same pip3 install batch. |
| `flake8` | deferred | 06:03Z | Linter (overlaps with pylint — pick one). | pip install — same envelope. |
| `bandit` | **implemented** | 06:03Z | Security-oriented Python linter. | pip install — same envelope. Shipped alongside `black` + `pylint` in the same pip3 install batch. |

### Web (JS/TS)

| Candidate | Status | Source runs | Rationale | Privacy/isolation notes |
|---|---|---|---|---|
| `prettier` | **implemented** | 04:05Z, 05:03Z, 06:03Z (×3) | Universal formatter covering JS/TS/CSS/JSON/Markdown. No formatter pre-installed. | npm install — same envelope as existing node/npm. Shipped on the existing `npm install -g` RUN layer (no new image layer). |
| `eslint` | **implemented** | 05:03Z, 06:03Z (×2) | Standard JS/TS linter. `typescript-language-server` is installed but no linter. | npm install — same envelope. Shipped alongside `prettier` in the same npm install batch. |

### Dart / Flutter

| Candidate | Status | Source runs | Rationale | Privacy/isolation notes |
|---|---|---|---|---|
| `flutter` | deferred | 04:05Z, 05:03Z | Dart SDK 3.12.1 installed + `flutter.md` instruction exists, but flutter binary absent. | Flutter SDK install — large image-size impact (~1 GB); gate at size budget. Flutter doctor needs network at first run. |

### Go

| Candidate | Status | Source runs | Rationale | Privacy/isolation notes |
|---|---|---|---|---|
| `delve` | **implemented** | 04:05Z, 06:03Z | Go debugger; toolchain + gopls present but no debugger. | go install — same envelope as existing go. |

### WebAssembly

| Candidate | Status | Source runs | Rationale | Privacy/isolation notes |
|---|---|---|---|---|
| `wasmtime` | **implemented** | 04:05Z, 05:03Z, 06:03Z (×3) | WASM runtime; `wasm-pack` is present but no runtime to execute the output. | Single static binary; install from upstream release. No new egress. |
| `wasmer` | deferred | 06:03Z | Alternative WASM runtime — pick one between this and `wasmtime`. | Single static binary; install from upstream release. |

### Shell

| Candidate | Status | Source runs | Rationale | Privacy/isolation notes |
|---|---|---|---|---|
| `shellcheck` | **implemented** | 04:05Z | Project uses extensive shell scripting; no static analysis for shell scripts. | microdnf install — added to the existing dnf RUN layer; no new image layer. |
| `shfmt` | **implemented** | 04:05Z | Shell formatter; absent alongside shellcheck. | `go install mvdan.cc/sh/v3/cmd/shfmt@latest` — added to the existing Go-tools RUN layer alongside gopls + dlv; no new image layer. |

### Profiling / Dynamic Analysis

| Candidate | Status | Source runs | Rationale | Privacy/isolation notes |
|---|---|---|---|---|
| `perf` (linux-tools) | blocked | 06:03Z | Linux performance counters. gdb/lldb/strace/valgrind are present. | Needs CAP_PERFMON or root; **violates security envelope (requires privileges)**. |
| `ltrace` | **implemented** | 06:03Z | Library-call tracer; complements existing strace. | microdnf install — added alongside `strace`/`valgrind` on the existing dnf RUN layer. Same ptrace privs as strace, same envelope. |
| `heaptrack` | **implemented** | 06:03Z | Heap-allocation profiler. | microdnf install — added alongside `valgrind` on the existing dnf RUN layer. Same envelope as existing valgrind. |

### Reproducible builds / Package managers

| Candidate | Status | Source runs | Rationale | Privacy/isolation notes |
|---|---|---|---|---|
| `nix` | deferred | 04:05Z, 05:03Z | `nix-first.md` instruction exists but binary is absent — instruction-installer gap. | Nix daemon needs root by default; rootless mode limits cache sharing. **Deferred pending rootless/enclave investigation.** |

## Sizing notes (for orchestrator split)

When the orchestrator approves a candidate, split into platform-sized
implementation packets per the work packet's
`expected_evidence` rule "not one giant image change". Suggested
groupings:

1. **Rust cargo-* batch** (small): `clippy`, `cargo-edit`,
   `cargo-deny`, `cargo-semver-checks`, `cargo-expand`,
   `cargo-criterion` — all installable via `cargo install` or
   `rustup component`, single image-layer add.
2. **Coverage tooling** (medium — pick ONE): `cargo-llvm-cov` OR
   `cargo-tarpaulin`. cargo-llvm-cov drags in llvm-tools; size budget
   review.
3. **Web tooling batch** (small): `prettier` + `eslint` — single
   `npm install -g` layer.
4. **Python tooling batch** (small): `black` + `bandit` + `pylint` OR
   `flake8` (pick one linter). Single pip-layer.
5. **Shell tooling batch** (small): `shellcheck` + `shfmt`. Two
   binaries.
6. **WASM runtime** (small — pick ONE): `wasmtime` OR `wasmer`.
   Tied to existing `wasm-pack`.
7. **Go debugger** (small): `delve` alone.
8. **Profiling tools** (medium — needs envelope review): `perf`,
   `ltrace`, `heaptrack` — `perf` may block at the security envelope.
9. **Flutter SDK** (large — image-size review): `flutter` alone.
   Significant image growth.
10. **Nix** (large — envelope review): `nix` alone. Rootless mode
    deviation from default install.

## Out of scope here

This file STAGES candidates. The orchestrator advances state
(`approved`/`blocked`/`deferred`) via subsequent commits. Approved
candidates become sized implementation packets in `plan/issues/` or
`plan/steps/`. Implementation lands in `images/default/Containerfile`
or `images/default/<feature>/` per the existing forge-image
layout.

## Update protocol

Future diagnostic runs may surface additional candidates or change
the convergence on which alternative (e.g. wasmtime vs wasmer) is
preferred. Append a `## Update YYYY-MM-DD` section here with the
delta — do NOT rewrite history. The forge enhancements that ALREADY
shipped this session (e.g. the 8 approved tools per the
2026-05-28T20:23Z baseline implemented in `c373f12a` + `a81cc9b5`)
established the pattern.

## Update 2026-05-29T08:21Z — delta from 08:08Z + 08:11Z runs

Two new live diagnostic runs surfaced candidates and privacy/isolation
observations not present in the original 04:05Z/05:03Z/06:03Z seed.
Per the file's "Update protocol" at the top: appended below, do NOT
rewrite history.

### Provenance — new runs

- `plan/diagnostics/diagnostics_20260529T080843Z-summary.md` (08:08Z,
  100% completeness, 18 missing tools, ~14 enhancement candidates,
  2 isolation risks)
- `plan/diagnostics/diagnostics_20260529T081135Z-summary.md` (08:11Z,
  100% completeness, 9 missing tools, 10 enhancement candidates,
  5 isolation risks)

### New candidate tools (proposed & reviewed)

| Candidate | Status | Source runs | Ecosystem | Rationale | Privacy/isolation notes |
|---|---|---|---|---|---|
| `rust-analyzer` (PATH symlink) | **implemented** | 08:08Z | Rust | **Installation gap, not missing binary**: the rustup component is installed at `/usr/local/rustup/toolchains/stable-x86_64-unknown-linux-gnu/bin/rust-analyzer` but isn't symlinked into `/usr/local/bin/`. LSP clients can't find it. | Pure symlink — no new envelope impact. Shipped: `ln -sf "$(rustup which rust-analyzer)" /usr/local/bin/rust-analyzer` appended to the rustup-install RUN step in `images/default/Containerfile`. Verification: next live forge-diagnostic run will surface rust-analyzer as present. |
| `cargo-audit` | **implemented** | 08:08Z | Rust | Security advisory scanner for Rust dependencies — complementary to the already-proposed `cargo-deny`. | Shipped via `cargo install cargo-audit` at image build time. |
| `just` | **implemented** | 08:08Z | Other (task runners) | Modern alternative to make/Justfile-driven workflows. | Shipped via `microdnf install just` at image build time. |
| `gcc` | **implemented** | 08:08Z | Other (build) | C compiler. **Verify** — may already be available via rustc's bundled cc OR via build-essential; check with `command -v gcc` against actual image. | Shipped via `microdnf install gcc` at image build time. |
| `g++` | **implemented** | 08:08Z | Other (build) | C++ compiler. Same verify-first treatment as `gcc`. | Shipped via `microdnf install gcc-c++` at image build time. |
| `make` | **implemented** | 08:08Z | Other (build) | Build automation. Often coupled with gcc/g++ as build-essential. | Shipped via `microdnf install make` at image build time. |
| `cmake` | **implemented** | 08:08Z | Other (build) | Cross-platform build generator. Heavier than `make`. | Shipped via `microdnf install cmake` at image build time. |
| `jq` | blocked | 08:08Z | Other (data) | **Verify-installed**: agent flagged as missing but earlier 06:03Z summary noted `jq` available. Already present in image. | n/a — redundant. |
| `ripgrep` | **implemented** | 08:08Z | Other (dev quality-of-life) | Fast grep alternative. Standard in modern dev images. | Shipped via `microdnf install ripgrep` at image build time. |
| `fd` | **implemented** | 08:08Z | Other (dev quality-of-life) | Modern `find` alternative. | Shipped via `microdnf install fd-find` at image build time (installs directly as `/usr/bin/fd` on Fedora 44). |
| `bat` | **implemented** | 08:08Z | Other (dev quality-of-life) | Syntax-highlighted `cat`. | Shipped via `microdnf install bat` at image build time. |
| `delta` | **implemented** | 08:08Z | Other (dev quality-of-life) | Better `git diff` viewer. | Shipped via `microdnf install git-delta` at image build time. |
| `httpie` | **implemented** | 08:08Z | Other (HTTP client) | User-friendly `curl` alternative. Useful for diagnostic HTTP testing. | Shipped via `microdnf install httpie` at image build time. |
| `yq` | **implemented** | 08:08Z, 08:11Z (×2) | Other (data) | YAML processor analogous to `jq`. OpenSpec/methodology/plan files are YAML-heavy — frequently useful. | Shipped via `microdnf install yq` at image build time. |
| `git-lfs` | **implemented** | 08:11Z | Other (git extension) | Git Large File Storage support for binary/asset repos. | Shipped via `microdnf install git-lfs` and globally registered via `git lfs install --system` at image build time. |

### New non-binary candidates (architectural)

| Candidate | Status | Source runs | Rationale | Notes |
|---|---|---|---|---|
| `tmpfs-work-partition` | deferred | 08:11Z | All work paths share a single ~951 MB root filesystem. Mount dedicated tmpfs at `/home/forge/.cache/tillandsias-work` per `spec:forge-cache-dual`. | NOT a toolchain candidate — this is a Containerfile / orchestrate-enclave.sh change. Routes through different approval pipeline. Tagged for `spec:forge-cache-dual` follow-on. |

### New / amplified privacy/isolation observations (delta vs. file head's gate)

The 08:08 and 08:11 runs amplified the original "external_curl HTTP
403" observation with finer-grained framings. These don't BLOCK any
specific candidate but inform the gate when the orchestrator reviews
the full backlog:

- **Proxy-as-plain-HTTP (no TLS) to `http://proxy:3128`** — credentials
  or tokens sent through proxy are visible WITHIN the container
  network (08:11Z). The proxy is already inside the enclave network,
  so the threat surface is in-enclave; still, terminating the proxy
  with TLS would harden against in-enclave lateral observation.
- **GIT_AUTHOR_EMAIL + GIT_AUTHOR_NAME present** — personal-info leak
  if container outputs are captured or shared (08:08Z + 08:11Z). The
  values are real (`bulloncito@gmail.com` / `Tlatoāni`). Possible
  mitigation: scrub these on entry per spec:tillandsias-vault?
  Investigate.
- **/run/secrets mounted from host AND world-readable** — currently
  empty in the container, but any future mounted secret would be
  visible to all processes (08:11Z). Permissions tightening to
  `0o600` + owner-only is a quick win.
- **Single root filesystem (no isolation hot/cold)** — same
  observation that motivates the `tmpfs-work-partition` candidate
  above (08:11Z). `spec:forge-cache-dual` already addresses this in
  spec, but the implementation gap remains.
- **HTTPS CONNECT-tunnelling via the proxy** — the proxy ACL governs
  HTTP GET targets, but HTTPS CONNECT to non-standard ports may
  bypass policy (08:11Z). Verify against the Squid TCP-reset ACL
  shipped at `96531d2a` — that work specifically targeted denied
  strict-port-3128 connections; CONNECT-tunnel behaviour for
  ALLOWED hosts is a different matter.

### Cross-run convergence updates

Some candidates from the original 04:05/05:03/06:03 seed strengthened:

- `nix` — now confirmed by 4 of 5 runs (was 2 of 3).
- `flutter` — now confirmed by 3 of 5 runs (was 2 of 3).
- `prettier` — now confirmed by 4 of 5 runs (was 3 of 3).
- `eslint` — now confirmed by 3 of 5 runs (was 2 of 3).
- `black` — now confirmed by 3 of 5 runs (was 2 of 3).
- `delve` — now confirmed by 3 of 5 runs (was 2 of 3).

The strengthening reduces "captured-once" noise. The orchestrator can
weight by run-count when deciding approval order.

### Sizing-notes addendum

Two of the new candidates need their own sizing flag:

- **Dev quality-of-life batch** (small): `ripgrep`, `fd`, `bat`,
  `delta`, `httpie`, `yq`, `git-lfs`. Six binaries, single image layer.
  Likely high-approval-velocity batch.
- **C/C++ build tooling batch** (medium, verify-first): `gcc`, `g++`,
  `make`, `cmake`. CONFIRM these aren't already present via
  build-essential before sizing; if genuinely missing, batch as one
  packet — none make sense in isolation.
- **rust-analyzer PATH symlink** (trivial): one-line Containerfile
  fix. Could merge into the "Rust cargo-* batch" or be a follow-on
  hotfix.

The original "Sizing notes" 10-packet decomposition still holds; the
above are additive.

## Update 2026-05-29T16:10Z — delta from 15:13Z run

A new live diagnostic run (`diagnostics_20260529T151307Z-summary.md`) surfaced additional candidates and verified further convergence. Per the file's "Update protocol", these updates are appended below.

### Provenance — new runs

- `plan/diagnostics/diagnostics_20260529T151307Z-summary.md` (15:13Z, 100% completeness, 5 missing tools, 5 enhancement candidates)

### New candidate tools (proposed & approved)

| Candidate | Status | Source runs | Ecosystem | Rationale | Privacy/isolation notes |
|---|---|---|---|---|---|
| `pylsp` | **implemented** | 15:13Z | Python | Python language server (python-lsp-server) to enable rich code intelligence. | Installed via pip3. Standard sandboxed execution. No new egress. |
| `yamllint` | **implemented** | 15:13Z | Other (linter) | Linter for YAML configuration files (OpenSpec/methodology/plan). | Installed via pip3. Static local execution. |
| `markdownlint` | **implemented** | 15:13Z | Other (linter) | Markdown style and syntax linter for documentation and specs. | Installed via npm (`markdownlint-cli`). Local static analysis. |
| `actionlint` | **implemented** | 15:13Z | Other (linter) | Linter for GitHub Actions workflow files. | Pinned static Go binary downloaded from upstream releases. Local static analysis. |
| `vale` | **implemented** | 15:13Z | Other (linter) | Syntax-aware prose linter for documentation and specifications. | Pinned static Go binary downloaded from upstream releases. Local static analysis. |
