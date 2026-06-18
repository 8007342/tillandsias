# GitHub Login Enclave Egress Regression - 2026-06-17

Discovered by operator curl-install smoke on immutable Linux with published
release `v0.3.260616.2`.

## Summary

Fresh install and `tillandsias --debug --init` succeeded, including Vault
bootstrap. A subsequent `tillandsias --debug --github-login` accepted git
identity input, started Vault, recovered the root token, provisioned Vault
policies/AppRoles, launched the transient `tillandsias-gh-login-*` helper
container, then failed inside `gh auth login` with:

```text
error connecting to api.github.com
check your internet connection or https://githubstatus.com
```

The helper launch line shows the container attached only to
`--network tillandsias-enclave`:

```text
"/usr/bin/podman" "run" "--detach" "--rm" "--name" "tillandsias-gh-login-33130" "--network" "tillandsias-enclave" ...
```

Given the `v0.3.260616.2` enclave-network checkpoint made
`tillandsias-enclave` internal, the likely regression is that the GitHub login
helper now runs on a no-egress network while `gh auth login` still needs
outbound HTTPS to `api.github.com`.

## Work Packet: github-login/enclave-egress-regression

- id: `github-login/enclave-egress-regression`
- owner_host: linux
- capability_tags: [rust, podman, networking, vault, github-login, release]
- status: in_progress
- reopened: >
    2026-06-18 — the code fix (d3f4e2f3) merged to `linux-next` and the packet
    was marked `done`, but NO published release contains it. The latest release
    `v0.3.260618.1` predates d3f4e2f3, so the operator still hits the bug on
    every installable release. `done` means "merged", not "shipped"; this packet
    is not closed until a published release carries the fix. See the
    `release_gate` acceptance and the events below.
- discovered_by: operator curl-install smoke on immutable Linux
- release: `v0.3.260616.2`
- related_packets:
  - `enclave/network-level-egress-deny`
  - `smoke-finding/rootless-bridge-network-missing`
  - `github-login-vault-native-flow`
- severity: high - blocks storing GitHub credentials after a successful init on
  the published Linux release.
- evidence:
  - `tillandsias --debug --github-login` reported runtime lane
    `desktop-user-session`.
  - Git identity was saved to
    `/var/home/tlatoani/.cache/tillandsias/secrets/git/.gitconfig`.
  - Vault was already running and unsealed, then policies/AppRoles were
    provisioned successfully.
  - The helper container was launched with only
    `--network tillandsias-enclave`.
  - `gh auth login --hostname github.com --git-protocol https --with-token`
    failed with `error connecting to api.github.com`.
- repro:
  - On immutable Linux, install published `v0.3.260616.2` via curl installer.
  - Run `tillandsias --debug --init` and confirm exit 0.
  - Run `tillandsias --debug --github-login`.
  - Enter the default git identity values and paste a valid GitHub token.
- suspected_root_cause: >
    The GitHub login helper needs outbound HTTPS to GitHub but is attached only
    to the internal enclave network. After `enclave/network-level-egress-deny`,
    direct egress from `tillandsias-enclave` is intentionally denied, so
    `api.github.com` is unreachable unless the helper uses the approved egress
    path.
- next_action: >
    Audit the `--github-login` helper container network/profile. Route GitHub
    API egress through the same approved mechanism used for allowlisted forge
    egress, or attach the helper to a clean-rootless-safe managed egress network
    with an explicit justification. Do not weaken direct forge-container egress
    denial. Add a litmus or smoke gate proving: fresh init succeeds, direct
    enclave egress remains denied, `tillandsias --github-login` can reach
    `api.github.com`, and the token is persisted into Vault.
- acceptance_evidence:
  - `tillandsias --debug --init` exits 0 on a clean rootless Podman store.
  - `tillandsias --debug --github-login` completes after a valid token and does
    not report `error connecting to api.github.com`.
  - Vault contains the GitHub credential expected by the forge/git-mirror login
    path.
  - Direct external curl from an ordinary enclave-only container still fails.
  - The existing forge/proxy egress smoke remains green.
- release_gate: >
    The packet closes ONLY when the fix is in a PUBLISHED GitHub release (a
    release object, not just a tag) AND an operator re-run of
    `tillandsias --github-login` on that release saves the token into Vault
    without the api.github.com connection error. Code-merged-to-linux-next is
    necessary but not sufficient — the 2026-06-18 reopen happened precisely
    because a merged-but-unreleased fix left every installable release broken.
- events:
  - type: discovered
    ts: "2026-06-18T00:36:11Z"
    agent_id: "linux-tlatoani-codex-20260618T003611Z"
    host: linux
    release: "v0.3.260616.2"
    note: >
      Operator reported successful curl install and successful `--debug --init`
      on immutable Linux, followed by `--debug --github-login` failure in the
      transient gh helper container. The helper was launched only on
      `tillandsias-enclave`, and `gh auth login` could not connect to
      `api.github.com`.
  - type: claim
    ts: "2026-06-18T02:28:05Z"
    agent_id: "linux-bigpickle-20260618T0228Z"
    host: linux
    lease_id: "lease-linux-github-login-egress-fix-20260618T0228"
    expires_at: "2026-06-18T06:28:05Z"
  - type: completed
    ts: "2026-06-18T02:35:00Z"
    agent_id: "linux-bigpickle-20260618T0228Z"
    host: linux
    lease_id: "lease-linux-github-login-egress-fix-20260618T0228"
    evidence_refs:
      - "main.rs:3876 ENCLAVE_NET → ENCLAVE_EGRESS_NETS (dual-home gh-login helper)"
      - "new test: github_login_helper_dual_homes_onto_managed_egress_network"
    note: >
      Root cause: the GitHub login helper was launched with only
      --network tillandsias-enclave (internal, no egress), so gh auth login
      could not reach api.github.com. Fix: changed to ENCLAVE_EGRESS_NETS
      (tillandsias-enclave,tillandsias-egress) dual-homing the helper
      container onto the managed egress network, consistent with the proxy
      and git-service pattern. Added source-level regression test pinning
      ENCLAVE_EGRESS_NETS in run_github_login. cargo test --workspace and
      cargo fmt --all -- --check pass.
  - type: reopened
    ts: "2026-06-18T17:22:00Z"
    agent_id: "linux-tlatoani-claude-opus-20260618T170827Z"
    host: linux
    note: >
      Operator re-hit `error connecting to api.github.com` on `--github-login`
      from a published release. Investigation: the fix (d3f4e2f3) is NOT an
      ancestor of any published release — `git merge-base --is-ancestor
      d3f4e2f3 v0.3.260618.1` is false, and v0.3.260618.1 is the latest
      published release. The packet was marked `done` on merge-to-linux-next,
      but no release ever shipped it, so every installable binary is still
      broken. Reopened with an explicit release_gate. Root cause empirically
      re-confirmed on the mutable Linux builder: git-image container on
      `tillandsias-enclave` alone → curl api.github.com HTTP=000; on
      `tillandsias-enclave,tillandsias-egress` → HTTP=200.
  - type: hardened
    ts: "2026-06-18T17:22:00Z"
    agent_id: "linux-tlatoani-claude-opus-20260618T170827Z"
    host: linux
    evidence_refs:
      - "run_github_login now calls ensure_enclave_network(debug)? before launching the helper (login works without a prior full --init)."
      - "non-vault branch of run_github_login also dual-homes onto ENCLAVE_EGRESS_NETS."
      - "augmented test github_login_helper_dual_homes_onto_managed_egress_network to pin the ensure_enclave_network call."
      - "cloud_projects::fetch_github_username gated behind listen-vsock — it was dead code under --features tray and broke `cargo clippy --features tray -- -D warnings`, blocking a clean release build."
    note: >
      Built on top of upstream d3f4e2f3. Local validation on the mutable Linux
      builder (rustup stable): `cargo fmt --check --all` OK; `cargo clippy
      --workspace --features tray -- -D warnings` clean; `cargo test --workspace
      --lib`, `cargo test -p tillandsias-headless --bin tillandsias`, and the
      `--features tray` bin tests all green (153 tray bin tests pass). Next:
      merge to main + push a release so the fix reaches an installable binary.
