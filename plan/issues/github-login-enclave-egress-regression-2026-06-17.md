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
- status: ready
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
