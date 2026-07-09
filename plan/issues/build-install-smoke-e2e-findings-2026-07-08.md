# build-install-and-smoke-test-e2e (Linux) — findings — 2026-07-08

- discovered_by: `/build-install-and-smoke-test-e2e` (linux_mutable)
- host: Linux mutable
- run_ids: `20260708T193145Z`, `20260708T200628Z`
- evidence:
  - `target/build-install-smoke-e2e/20260708T193145Z/01-build-install.log`
  - `target/build-install-smoke-e2e/20260708T200628Z/01-build-install.log`

## Result: STOPPED at gate 1 (build + CI + install)

`./build.sh --ci-full --install` exited non-zero through `scripts/local-ci.sh`
before the `--install` step. Per the e2e runbook, the destructive Podman reset
gate was **not** reached and was **not** run.

Final failed checks from `01-build-install.log:2166`:

- `version-monotonicity`
- `no-python-scripts`
- `litmus-pre-build`

## Duplicate Finding — order 211 still blocks fresh-checkout `--ci-full`

This run reproduced the existing `ci-full-guest-binary-prereq-gap` packet
(order 211). Evidence:

- `01-build-install.log:1344` — `litmus:guest-binary-embed-integrity`
- `01-build-install.log:1348` — missing
  `target-guest/tillandsias-headless-x86_64-unknown-linux-musl`

No new packet was created for this duplicate; order 211 remains ready.

### Work Packet: smoke-finding/local-build-version-regression

- id: `smoke-finding/local-build-version-regression`
- owner_host: linux
- capability_tags: [release, versioning, build-script, testing]
- status: done
- discovered_by: `/build-install-and-smoke-test-e2e` on `linux-next@38ea4156`
- evidence:
  - `target/build-install-smoke-e2e/20260708T193145Z/01-build-install.log:43` —
    `VERSION` is `0.3.260707.1` while the latest release is `v0.3.260707.2`.
- repro:
  - `scripts/verify-version-monotonic.sh`
- next_action: >
    Decide whether local-build e2e should bump `VERSION` before running the
    release-monotonicity pre-build gate, or whether `linux-next` should be
    advanced to at least `0.3.260707.2` immediately after a newer release lands.
- resolution: >
    Fixed in the order-211 implementation by running the CI-full install input
    preparation before the pre-build gate; the follow-up e2e run reports
    `Version 0.3.260708.2 is monotonically >= latest release v0.3.260707.2`
    at `target/build-install-smoke-e2e/20260708T200628Z/01-build-install.log:230`.
- events:
  - type: discovered
    ts: "2026-07-08T19:34:50Z"
    agent_id: "linux-macuahuitl-codex-20260708T1919Z"
    host: linux

### Work Packet: smoke-finding/silverblue-builder-python-runtime

- id: `smoke-finding/silverblue-builder-python-runtime`
- owner_host: linux
- capability_tags: [build-script, policy, silverblue, toolbox]
- status: done
- discovered_by: `/build-install-and-smoke-test-e2e` on `linux-next@38ea4156`
- evidence:
  - `target/build-install-smoke-e2e/20260708T193145Z/01-build-install.log:1228` —
    `scripts/with-tillandsias-builder.sh:92` installs `python3 python3-pyyaml`.
  - `/tmp/no-python-check.log:1` — policy checker reports the same line.
- repro:
  - `scripts/check-no-python-scripts.sh`
- next_action: >
    Remove Python runtime packages from the Silverblue builder bootstrap or file
    an explicit Tlatoāni approval/exception. If YAML support is needed, use the
    existing Ruby or Rust policy tooling instead of Python.
- resolution: >
    Fixed by order 239; `python3 python3-pyyaml` were removed from
    `scripts/with-tillandsias-builder.sh`. The follow-up e2e run reports
    `ok: no Python runtime references in scripts/harness files` at
    `target/build-install-smoke-e2e/20260708T200628Z/01-build-install.log:1383`.
- events:
  - type: discovered
    ts: "2026-07-08T19:34:50Z"
    agent_id: "linux-macuahuitl-codex-20260708T1919Z"
    host: linux

### Work Packet: smoke-finding/credential-channel-mirror-litmus-host-fixture

- id: `smoke-finding/credential-channel-mirror-litmus-host-fixture`
- owner_host: linux
- capability_tags: [litmus, credentials, forge, ci]
- status: done
- discovered_by: `/build-install-and-smoke-test-e2e` on `linux-next@38ea4156`
- evidence:
  - `target/build-install-smoke-e2e/20260708T193145Z/01-build-install.log:1735` —
    `litmus:credential-channel-check-shape` mirror-resolved origin step failed.
  - `target/build-install-smoke-e2e/20260708T193145Z/01-build-install.log:1737` —
    output was `missing:no-credential-channel`.
- repro:
  - `scripts/run-litmus-test.sh meta-orchestration --phase pre-build --size quick`
- next_action: >
    Make the forge-mirror pass fixture deterministic outside a live forge
    network, for example by using a local temporary bare repository/git daemon
    or by explicitly classifying the live `tillandsias-git` DNS dependency as a
    forge-only e2e check instead of a host pre-build litmus.
- resolution: >
    Fixed by making the test seam validate that Git URL rewriting resolves to a
    forge mirror URL before skipping only the live mirror probe. The follow-up
    pre-build litmus phase passed at
    `target/build-install-smoke-e2e/20260708T200628Z/01-build-install.log:2280`.
- events:
  - type: discovered
    ts: "2026-07-08T19:34:50Z"
    agent_id: "linux-macuahuitl-codex-20260708T1919Z"
    host: linux

## Follow-up Result: gate 1 reached post-build status smoke

Run `20260708T200628Z` started from `linux-next@f1d3dcc7` with local worker
changes in progress. During the run, in-forge meta-orchestration commits
advanced `origin/linux-next` to `7d534d8b`; the local worker changes were then
reapplied on top of that pushed state.

`./build.sh --ci-full --install` no longer stopped before install:

- `01-build-install.log:230` — version monotonicity passed at `0.3.260708.2`.
- `01-build-install.log:1383` — no-Python policy passed.
- `01-build-install.log:1498-1499` — `litmus:guest-binary-embed-integrity`
  passed via `scripts/build-guest-binaries.sh --verify`.
- `01-build-install.log:2280` — pre-build litmus passed.
- `01-build-install.log:2321` — portable launcher installed at
  `/home/tlatoani/.local/bin/tillandsias`.

The run then failed in post-build status smoke:

- `01-build-install.log:2350` — `event:container_launch stage=opencode
  state=failed` during `litmus:forge-diagnostics-e2e`.
- `01-build-install.log:2381` — `FAIL: loop_status.md not modified in new
  commit(s)` during `litmus:opencode-prompt-e2e-shape`.
- `01-build-install.log:2390-2391` — `litmus:tray-parity-matrix-complete`
  failed.
- `01-build-install.log:2406` — `Post-build status smoke failed`.

Per the e2e runbook, the destructive Podman reset gate was not reached and was
not run.

### Work Packet: smoke-finding/forge-diagnostics-opencode-attached-exit

- id: `smoke-finding/forge-diagnostics-opencode-attached-exit`
- owner_host: linux
- capability_tags: [litmus, forge, diagnostics, opencode, e2e]
- status: ready
- discovered_by: `/build-install-and-smoke-test-e2e` on `linux-next@f1d3dcc7`
  with in-forge commits later advancing `origin/linux-next` to `7d534d8b`
- evidence:
  - `target/build-install-smoke-e2e/20260708T200628Z/01-build-install.log:2350`
    — opencode container launch failed during diagnostics annex capture.
- repro:
  - `scripts/run-litmus-test.sh default-image --phase post-build --size e2e --compact`
- next_action: >
    Run the diagnostics litmus directly with full output, inspect the opencode
    attached command exit, and decide whether the product launch failed or the
    diagnostics annex is over-reporting a transient/expected exit.
- events:
  - type: discovered
    ts: "2026-07-08T20:24:45Z"
    agent_id: "linux-macuahuitl-codex-20260708T1958Z"
    host: linux_mutable

### Work Packet: smoke-finding/opencode-prompt-e2e-loop-status-contract

- id: `smoke-finding/opencode-prompt-e2e-loop-status-contract`
- owner_host: linux
- capability_tags: [litmus, meta-orchestration, forge, plan, opencode]
- status: ready
- discovered_by: `/build-install-and-smoke-test-e2e` on `linux-next@f1d3dcc7`
  with in-forge commits later advancing `origin/linux-next` to `7d534d8b`
- evidence:
  - `target/build-install-smoke-e2e/20260708T200628Z/01-build-install.log:2379`
    — loop-status delta assertion started.
  - `target/build-install-smoke-e2e/20260708T200628Z/01-build-install.log:2381`
    — `FAIL: loop_status.md not modified in new commit(s)`.
- repro:
  - `scripts/run-litmus-test.sh meta-orchestration --phase post-build --size e2e --compact`
- next_action: >
    Align the litmus with the current meta-orchestration exit contract, or
    require the in-forge meta-orchestration path to always update
    `plan/loop_status.md` before it pushes.
- events:
  - type: discovered
    ts: "2026-07-08T20:24:45Z"
    agent_id: "linux-macuahuitl-codex-20260708T1958Z"
    host: linux_mutable

### Work Packet: smoke-finding/tray-parity-matrix-complete-post-build

- id: `smoke-finding/tray-parity-matrix-complete-post-build`
- owner_host: any
- capability_tags: [litmus, tray, parity, post-build]
- status: ready
- discovered_by: `/build-install-and-smoke-test-e2e` on `linux-next@f1d3dcc7`
  with in-forge commits later advancing `origin/linux-next` to `7d534d8b`
- evidence:
  - `target/build-install-smoke-e2e/20260708T200628Z/01-build-install.log:2390`
    — executing `litmus:tray-parity-matrix-complete`.
  - `target/build-install-smoke-e2e/20260708T200628Z/01-build-install.log:2391`
    — tray parity matrix litmus failed.
- repro:
  - `scripts/run-litmus-test.sh tray-app --phase post-build --size quick`
- next_action: >
    Run the tray parity litmus with verbose output and decide whether the parity
    matrix evidence is stale or a tray implementation/status entry is missing.
- events:
  - type: discovered
    ts: "2026-07-08T20:24:45Z"
    agent_id: "linux-macuahuitl-codex-20260708T1958Z"
    host: linux_mutable

## Finding — order 241 — Fix applied: NODE_EXTRA_CA_CERTS + CA_CHAIN mount

- discovered_by: `/advance-work-from-plan` (linux/yoga, big-pickle)
- fixed_by: same run (2026-07-08T22:35:00Z)
- commit: `crates/tillandsias-headless/src/main.rs` (3 sites)

### Root cause

The diagnostics annex captures forge diagnostics by running
`opencode run --dangerously-skip-permissions "$(<prompt>)"` inside a forge
container that connects through the MITM SSL-bumping proxy. The proxy
issues a certificate signed by the Tillandsias intermediate CA for all
bumped connections (including `models.dev`).

Node.js (used by opencode's undici HTTP client) does NOT trust this
proxy-issued certificate because:

1. `NODE_EXTRA_CA_CERTS` was never set to the Tillandsias intermediate CA
   path (`/etc/tillandsias/ca.crt`), even though the CA cert itself WAS
   bind-mounted at that path.
2. The forge entrypoint (`lib-common.sh`) checks for
   `/run/tillandsias/ca-chain.crt` to build a combined CA bundle for
   `SSL_CERT_FILE`/`REQUESTS_CA_BUNDLE`, but NO container arg ever mounted
   a file to that path. This dead code path meant non-Node tools also had
   no trust of the proxy CA.

### Fix

In all three forge-container argument builders:

| Builder | NODE_EXTRA_CA_CERTS | /run/tillandsias/ca-chain.crt mount |
|---|---|---|
| `build_stack_common_args` | ✅ added | ✅ added |
| `build_opencode_forge_args` | ✅ added | ✅ added |
| `build_forge_agent_run_args` | ✅ added | ✅ added |

The env var tells Node.js to trust the Tillandsias intermediate CA for TLS
validation. The second bind-mount of `intermediate.crt` to
`/run/tillandsias/ca-chain.crt` satisfies the entrypoint's `$CA_CHAIN`
check, which then exports `SSL_CERT_FILE`/`REQUESTS_CA_BUNDLE` for
non-Node tools.

### Verification

- `rustfmt --check --edition 2024` passes.
- Full `cargo check` blocked by missing `gcc`/`cc` linker.
- Litmus verification pending rebuild on a host with full toolchain.
