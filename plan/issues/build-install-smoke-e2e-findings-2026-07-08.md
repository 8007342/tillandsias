# build-install-and-smoke-test-e2e (Linux) — findings — 2026-07-08

- discovered_by: `/build-install-and-smoke-test-e2e` (linux_mutable)
- host: Linux mutable, `linux-next@38ea4156`
- run_id: `20260708T193145Z`
- evidence: `target/build-install-smoke-e2e/20260708T193145Z/01-build-install.log`

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
- status: ready
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
- events:
  - type: discovered
    ts: "2026-07-08T19:34:50Z"
    agent_id: "linux-macuahuitl-codex-20260708T1919Z"
    host: linux

### Work Packet: smoke-finding/silverblue-builder-python-runtime

- id: `smoke-finding/silverblue-builder-python-runtime`
- owner_host: linux
- capability_tags: [build-script, policy, silverblue, toolbox]
- status: ready
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
- events:
  - type: discovered
    ts: "2026-07-08T19:34:50Z"
    agent_id: "linux-macuahuitl-codex-20260708T1919Z"
    host: linux

### Work Packet: smoke-finding/credential-channel-mirror-litmus-host-fixture

- id: `smoke-finding/credential-channel-mirror-litmus-host-fixture`
- owner_host: linux
- capability_tags: [litmus, credentials, forge, ci]
- status: ready
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
- events:
  - type: discovered
    ts: "2026-07-08T19:34:50Z"
    agent_id: "linux-macuahuitl-codex-20260708T1919Z"
    host: linux
