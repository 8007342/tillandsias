# msys Lua fixture census — doris-windows, 2026-11-27

Every `scripts/lua/test-*.lua` at origin/linux-next `625ecf3de`, run on doris (Windows 11, Git Bash/msys,
no podman, no WSL Lua) with a release `tillandsias-plan` built from that tree, worktree at
`/c/Users/bullo/census-tree`. Reds were re-run with full output and tagged by first matching cause
(grep rules, so the buckets are a triage, not a per-test verdict).

| verdict | count |
|---|---|
| ok | 448 |
| skip (named) | 34 |
| violation | 97 |
| refused (31 script-error) | 55 |
| could-not-run | 31 |
| FAIL | 3 |
| no verdict (mcp-server-resilience: fail:usage-sigpipe-or-malformed) | 1 |

## Packets, one per cause (largest real defect first)

1. **2428-cens-a: the runner's path scope rejects msys-form paths inside the repo (real runner bug).**
   `fs.exists/fs.walk/fs.read: refused — path '/c/Users/.../census-tree/target/plan-scratch/...' is outside
   the repository root`, and the C:/ twin `is outside the repo and every declared read root`. The scratch
   dir IS under <repo>/target; the root check compares /c/x and C:/x forms unnormalised. One fix in the
   runner's path canonicaliser should clear: agy-install-cached centicolon-grade claim-unknown-host
   configure-ollama-affordances credentials-at-rest gate-podman-mode-configuration pilot-lua-ports
   smoke-agent-prompt-is-minimal spec-index-ensure-affordances; and probably much of the C:/-mentioning
   set: brew-shim-tier2-warning ci-full-refreshes-stale-plan-binary codex-safe-state discipline-install-hooks
   fleet-msg-same-host forge-discovery-cli forge-opencode-is-pinned forge-plan-bin-staging gate-keep-going
   hooks-armed land-queue-trains mcp-plan-resolver-pinning spec-index-durable-tier-demotion
   uninstall-preserves-vm. Re-census after the fix before triaging those individually.
2. **2428-cens-b: `scratch.chmod` and other unix-only primitives refuse on Windows, and the fixture
   crashes.** Fixtures that need a mode bit should name a skip (`skip:<name>:no-unix-modes`):
   cloudflare-token-rotation headless-cloud-one-shot install-macos-setup-is-quiet native-lint-hold
   prune-darwin-stale-objects uninstall-sweeps-both-app-dirs.
3. **2428-cens-c: fixtures spawn sh stubs natively.** `os error 193` (an sh script is not a Win32 app) and
   rc=127 `env: 'bash': No such file`: launch stubs via `fixture.posix_shell()`. codex-mcp-registration
   command-policy-consent ensure-toolbox-properties git-mirror-existing-volume-hardening
   git-mirror-relay-token-expiry litmus-decide run-verb-agent-door credential-channel-names-a-locked-keyring
   cycle-preflight-cargo-resolution e2e-step2-macos forge-bash-policy-hook-fails-closed
   git-mirror-ready-before-retry-push harness-rollback install-linux-setup-is-quiet; and likely
   copilot-vault-auth, forge-copilot-harness, land-queue-eviction and land-queue-landing (gh stub output
   reads as `queue-not-an-array`).
4. **2428-cens-d: podman-dependent fixtures answer could-not-run/refused/violation instead of a named
   skip.** That's expected on a podman-less host, but the verdict should be `skip:<name>:no-podman` everywhere:
   audio-studio-{glitches,separate,tiers,transforms} clear-vault-credentials-partial-is-nonzero
   cloudflare-login dev-inference-start-refusal-names-cause enclave-service-health
   forge-config-trust-cross-platform-parity forge-gitconfig-bidirectional-quarantine forge-image-agents
   forge-lua-tooling forge-policies-cannot-read-github-token forge-runtime-ca-trust
   forge-standard-gitconfig-path git-mirror-dns-identity image-build-scope image-ensure-disk-preflight
   inference keyring-fixtures-use-a-private-bus nix-cache-service-affordance pre-receive-yaml-gate-date
   prebuilt-resolver-refuses-stale proxy-tier-ports-live sidecar-ignores-rustc-wrapper
   spec-index-repo-relative-rung studio-{custom-nodes,decap,front,grapesjs,puck,tina}
   tillandsias-cache-in-image tillandsias-impact-in-image.
5. **2428-cens-e: /tmp scratch.** `scratch.declare: refused — '/tmp/...' is not under $TMPDIR`; use the
   declared scratch dir: flaky-installs-background litmus-bindings rust-lints script-run-roots-at-a-repository.
6. **2428-cens-f: Linux-only kernel surfaces** (/proc, setsid, getfattr) should skip by name:
   deciders-within-door-deadline dispatch-reap forge-oomd-avoid.
7. **2428-cens-g: `no-git` false negative.** git is on PATH; the probe looks for it some other way:
   land-auth-retry land-push-classification.
8. **2428-cens-h: signals.** TERM/KILL/SIGSEGV arms assume POSIX delivery: awk-float-lc-numeric-signal
   harness-supervisor squid-supervisor smoke-agent-watch worktree-add-cleanup preflight-wall-clock-deadline
   status-channel-absent-is-first-class. Decide per arm whether to port the assertion or skip it by name on msys.
9. **2428-cens-i: triage individually.** These are the rest, and each names its own cause. Notable:
   litmus-diff-scope hits os error 206 (should use common/argv_batch); loop-status-append-input writes
   `plan\loop_status.d` with a backslash; derive-host-identity ignores the faked hostname;
   ssh-lane-refuses-when-unwired hands the msys path to a native git clone; build-sccache-regimes and
   uv-venv-survives-forge-replacement get os error 3 (path not found); archiver-check-memo misses across
   worktrees (`miss:ledger-or-instrument-changed`, see the velocity row on the archiver memo).

Raw data stays on doris: census.tsv (path, rc, seconds, last verdict line) and per-test logs. To regenerate,
run each fixture with `timeout 600 tillandsias-plan script run <fixture>` from a trunk worktree.
