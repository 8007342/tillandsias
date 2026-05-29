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
| `clippy` (rustup component) | proposed | 06:03Z | Standard Rust linter; absent despite rustc/cargo installed. | Rustup component install — same envelope as rustc. No new egress. |
| `cargo-edit` | proposed | 06:03Z | Enables `cargo add/rm/upgrade` for ergonomic dep management. | Single binary; cargo install. No new egress. |
| `cargo-llvm-cov` | proposed | 06:03Z | Code-coverage tooling expected in CI/test workflows. | Drops llvm tools too — image-size impact; gate at size budget. |
| `cargo-tarpaulin` | proposed | 06:03Z | Alternative coverage tool — pick one between this and `cargo-llvm-cov`. | Single binary; cargo install. |
| `cargo-deny` | proposed | 06:03Z | License + advisory checking, standard in production pipelines. | Needs network at FIRST RUN to fetch advisory-db; review proxy ACL. |
| `cargo-semver-checks` | proposed | 06:03Z | Automated semver verification for library releases. | Single binary; cargo install. |
| `cargo-expand` | proposed | 06:03Z | Macro-expansion debugging essential for Rust development. | Single binary; cargo install. |
| `cargo-outdated` | proposed | 06:03Z | Dependency-freshness checks. | Network needed for upstream version query; gate at proxy ACL. |
| `cargo-tree` | proposed | 06:03Z | Dependency-graph visualization (now in cargo core — VERIFY this is still needed). | n/a — likely already covered by `cargo tree`. Likely BLOCKED. |
| `cargo-criterion` | proposed | 06:03Z | Benchmarking harness front-end for criterion. | Single binary; cargo install. |
| `cargo-wasi` | proposed | 06:03Z | WASI target convenience wrapper. | Single binary; depends on `wasmtime` being available. |

### Python

| Candidate | Status | Source runs | Rationale | Privacy/isolation notes |
|---|---|---|---|---|
| `black` | proposed | 04:05Z, 06:03Z | Formatter; ruff is installed but black is the standard formatter. | pip install — same envelope as existing python. |
| `pylint` | proposed | 06:03Z | Linter complement to ruff/mypy. | pip install — same envelope. |
| `flake8` | proposed | 06:03Z | Linter (overlaps with pylint — pick one). | pip install — same envelope. |
| `bandit` | proposed | 06:03Z | Security-oriented Python linter. | pip install — same envelope. |

### Web (JS/TS)

| Candidate | Status | Source runs | Rationale | Privacy/isolation notes |
|---|---|---|---|---|
| `prettier` | proposed | 04:05Z, 05:03Z, 06:03Z (×3) | Universal formatter covering JS/TS/CSS/JSON/Markdown. No formatter pre-installed. | npm install — same envelope as existing node/npm. |
| `eslint` | proposed | 05:03Z, 06:03Z (×2) | Standard JS/TS linter. `typescript-language-server` is installed but no linter. | npm install — same envelope. |

### Dart / Flutter

| Candidate | Status | Source runs | Rationale | Privacy/isolation notes |
|---|---|---|---|---|
| `flutter` | proposed | 04:05Z, 05:03Z | Dart SDK 3.12.1 installed + `flutter.md` instruction exists, but flutter binary absent. | Flutter SDK install — large image-size impact (~1 GB); gate at size budget. Flutter doctor needs network at first run. |

### Go

| Candidate | Status | Source runs | Rationale | Privacy/isolation notes |
|---|---|---|---|---|
| `delve` | proposed | 04:05Z, 06:03Z | Go debugger; toolchain + gopls present but no debugger. | go install — same envelope as existing go. |

### WebAssembly

| Candidate | Status | Source runs | Rationale | Privacy/isolation notes |
|---|---|---|---|---|
| `wasmtime` | proposed | 04:05Z, 05:03Z, 06:03Z (×3) | WASM runtime; `wasm-pack` is present but no runtime to execute the output. | Single static binary; install from upstream release. No new egress. |
| `wasmer` | proposed | 06:03Z | Alternative WASM runtime — pick one between this and `wasmtime`. | Single static binary; install from upstream release. |

### Shell

| Candidate | Status | Source runs | Rationale | Privacy/isolation notes |
|---|---|---|---|---|
| `shellcheck` | proposed | 04:05Z | Project uses extensive shell scripting; no static analysis for shell scripts. | Single static binary; apt/dnf install. No new egress. |
| `shfmt` | proposed | 04:05Z | Shell formatter; absent alongside shellcheck. | Single static binary; go install or upstream release. |

### Profiling / Dynamic Analysis

| Candidate | Status | Source runs | Rationale | Privacy/isolation notes |
|---|---|---|---|---|
| `perf` (linux-tools) | proposed | 06:03Z | Linux performance counters. gdb/lldb/strace/valgrind are present. | Needs CAP_PERFMON or root; **may BLOCK at the security envelope**. Investigate before approving. |
| `ltrace` | proposed | 06:03Z | Library-call tracer; complements existing strace. | Single binary; same ptrace privs as strace. Same envelope. |
| `heaptrack` | proposed | 06:03Z | Heap-allocation profiler. | Single binary; same envelope as existing valgrind. |

### Reproducible builds / Package managers

| Candidate | Status | Source runs | Rationale | Privacy/isolation notes |
|---|---|---|---|---|
| `nix` | proposed | 04:05Z, 05:03Z | `nix-first.md` instruction exists but binary is absent — instruction-installer gap. | Nix daemon needs root by default; rootless mode (`nix --no-daemon`) exists but limits cache sharing. **Investigate envelope before approving.** |

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
