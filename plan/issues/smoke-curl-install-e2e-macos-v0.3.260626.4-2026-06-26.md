# macOS curl-install e2e — released v0.3.260626.4 — 2026-06-26

**discovered_by:** `/smoke-curl-install-and-test-e2e` on macOS
**Host:** Darwin arm64, end-user flow from a clean Tillandsias app substrate
**Release under test:** `v0.3.260626.4` (published 2026-06-26T19:57:18Z)
**Agent:** `macos-smoke-20260626T2000Z`

## Gates

| Gate | Result |
|---|---|
| `curl .../install-macos.sh \| bash` downloads and extracts app | PASS |
| Installer SHA256 | PASS (`5900c86401740c96f6cc8b13031f3a1162d4a5632162d60bdac62e7a39590347`) |
| Installer post-install verify | KNOWN FAIL: `DIAG_PIN...: unbound variable` (pre-existing) |
| Installed binary git hash | PASS: `git dde9d4fd`, built `2026-06-26T19:57:57Z` |
| Destructive macOS substrate reset | PASS: removed `~/Library/Application Support/tillandsias` and `~/Library/Caches/tillandsias` |
| `--provision` fresh (528 MB Fedora Cloud image) | PASS (after resume from stall — see download-stall packet) |
| `--diagnose --json` provisioned=true | PASS: `rootfs_bytes=5368709120`, `provisioned=true` |
| `--exec-guest` control wire (1st boot) | **PASS** — `control-wire-ok` received |
| `--github-login` ordering (control wire before prompts) | **PASS** — VM started, wire ready, then prompted |
| `--github-login` Vault bootstrap | PASS — `[tillandsias-vault] bootstrap complete` |
| `--github-login` git identity save | PASS — `Git identity saved: /root/.cache/tillandsias/secrets/git/.gitconfig` |
| `--github-login` container gh auth | PASS — token piped inside container |
| `--github-login` Vault token write | PASS — `secret/github/token` present after VM restart |
| `--github-login` host `gh` credential setup | **FAIL** — `No such file or directory (os error 2)` |
| `--github-login` exit code | FAIL — exit_code:1 due to host gh spawn |
| `--opencode` forge launch (macOS CLI) | **NOT IMPLEMENTED** — no `--opencode` flag on macOS tray |
| Download stall auto-recovery | FAIL — stalled 34 min; requires manual kill+restart |

## Headline

Control-wire ordering fix and Vault enclave routing both land correctly in
v0.3.260626.4. The GitHub login flow runs through credential entry and
successfully stores the token in the in-guest Vault. The only failure is a
final convenience step that tries to run `Command::new("gh")` inside the
Fedora guest (which has no `gh` binary). Making that step non-fatal unblocks
the full login flow since the Vault write — the critical operation — already
succeeded.

macOS forge launch has no CLI path; it is GUI-only in the current tray. Step 4
of the smoke (forge + /meta-orchestration) is therefore SKIPPED on macOS pending
an `--opencode` or equivalent CLI flag.

---

## Work Packets

### Work Packet: smoke-finding/headless-host-gh-spawn-non-fatal

- id: `smoke-finding/headless-host-gh-spawn-non-fatal`
- owner_host: any
- capability_tags: [rust, headless, github-login, reliability]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.3.260626.4`
- evidence:
  - `target/smoke-e2e/04-github-login.log` — `Error: Failed to spawn host gh auth login: No such file or directory (os error 2)`
  - `crates/tillandsias-headless/src/main.rs:4132-4145` — `Command::new("gh")` spawned on the "host" (Fedora guest) where `gh` is not installed
- repro:
  - `/Applications/Tillandsias.app/Contents/MacOS/tillandsias-tray --github-login` on macOS (or any Linux system without `gh` in PATH)
- next_action: >
    In `crates/tillandsias-headless/src/main.rs`, at the block starting line ~4132
    (`let mut host_login = Command::new("gh")`), match on the spawn error kind:
    if `ErrorKind::NotFound`, log a warning ("gh not on host PATH; skipping host
    credential helper setup — Vault write succeeded") and continue Ok(()).
    Only propagate the error for unexpected I/O failures. Add a test that the
    function succeeds when the gh step would fail with NotFound.
- events:
  - type: discovered
    ts: "2026-06-26T20:47:00Z"
    agent_id: "macos-smoke-20260626T2000Z"
    host: macos

### Work Packet: smoke-finding/macos-tray-no-opencode-cli

- id: `smoke-finding/macos-tray-no-opencode-cli`
- owner_host: macos
- capability_tags: [rust, macos, forge, opencode, ux]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.3.260626.4`
- evidence:
  - `"/Applications/Tillandsias.app/Contents/MacOS/tillandsias-tray" --help` — only flags: `--provision`, `--exec-guest`, `--github-login`, `--diagnose [--json]`, `-V`, `-h`
  - Smoke step 4 requires `tillandsias . --opencode --prompt "..."` — absent on macOS
- repro:
  - `"/Applications/Tillandsias.app/Contents/MacOS/tillandsias-tray" . --opencode --prompt "Use the /meta-orchestration skill"` — no such flag
- next_action: >
    Add `--opencode [<path>] [--prompt <text>]` to the macOS tray CLI. On macOS
    the forge runs inside the guest VM; the flag should: (1) start the VM if not
    running, (2) wait for control wire, (3) run the forge launch sequence in the
    guest (equivalent to Linux `tillandsias . --opencode`), (4) attach a PTY so
    the forge agent is interactive. The existing `--exec-guest` PTY path in
    `diagnose.rs`/`vsock_exec` provides the building blocks. An initial slice
    can hard-code the prompt via `TILLANDSIAS_OPENCODE_PROMPT` env and just
    launch `exec /usr/local/bin/tillandsias-headless --opencode .` in the guest.
- events:
  - type: discovered
    ts: "2026-06-26T21:00:00Z"
    agent_id: "macos-smoke-20260626T2000Z"
    host: macos

### Work Packet: smoke-finding/vault-keyring-warning-noise-in-guest

- id: `smoke-finding/vault-keyring-warning-noise-in-guest`
- owner_host: any
- capability_tags: [rust, headless, vault, ux]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.3.260626.4`
- evidence:
  - `target/smoke-e2e/04-github-login.log` — `[tillandsias-vault] WARNING: failed to write vault-root-token-v1 to OS keyring (Platform secure storage failure: no secret service provider or dbus session found); writing to fallback file`
  - Fedora Cloud guest has no dbus session or SecretService; fallback file is the correct and expected behavior
- repro:
  - Any `--github-login` or Vault bootstrap on the macOS VZ Fedora guest
- next_action: >
    Find the keyring write error site in the Vault bootstrap code and downgrade
    the log level from WARNING to INFO (or DEBUG) when the error reason is
    "no secret service provider or dbus session". Optionally append "(expected
    in headless/VM guest environments)" to the message. The fallback file path
    is correct; the WARNING level is misleading.
- events:
  - type: discovered
    ts: "2026-06-26T21:00:00Z"
    agent_id: "macos-smoke-20260626T2000Z"
    host: macos

### Work Packet: arch/macos-github-login-must-be-fully-containerized

- id: `arch/macos-github-login-must-be-fully-containerized`
- owner_host: any
- capability_tags: [rust, macos, headless, podman, github-login, architecture]
- status: ready
- discovered_by: operator review of `/smoke-curl-install-and-test-e2e` on release `v0.3.260626.4`
- evidence:
  - `crates/tillandsias-headless/src/main.rs:4132-4160` — after the in-container vault write, `run_github_login` spawns `Command::new("gh")` and `Command::new("gh") auth setup-git` **directly on the bare Fedora guest** (not inside a Podman container). This violates the invariant that only `tillandsias-headless` and `podman` (plus their direct helpers) execute on the bare guest; all business logic must run inside Podman containers.
  - Architecture requirement (operator): macOS GitHub Login must flow:
    `macOS tray → vsock (macos::virt) → bare VM guest (tillandsias-headless) → Podman → container (git service image)`
    No business logic — no `gh`, no credential helpers, no vault-cli — should run outside a container in the guest.
- repro:
  - Review `run_github_login` in `crates/tillandsias-headless/src/main.rs`: the function correctly routes git auth and vault writes into the `tillandsias-gh-login-<pid>` container, but then leaks out to run `Command::new("gh") auth login --with-token` and `Command::new("gh") auth setup-git` directly on the guest.
- next_action: >
    **Research first**: map every `Command::new(...)` call in `run_github_login`
    and identify which ones escape the container boundary (run on bare guest).
    Classify each as: (a) already inside a `podman exec` call (correct),
    (b) on bare guest but only needed for user convenience (remove or move),
    (c) structurally required on bare guest (document why and add an explicit
    `// invariant: runs on bare guest because ...` comment).

    **Then implement**: remove or containerize every class-(b) escape.
    The "configure git credential helper on host" block (lines ~4118-4166)
    extracts the token from the container and re-feeds it to a bare-guest
    `gh auth login --with-token`. Since the token is already in Vault and all
    git operations use the Podman-managed git container, the bare-guest
    credential helper is not needed for Tillandsias to function. Either remove
    it entirely or, if a host-side helper is desired for operator convenience,
    gate it behind an opt-in flag and make it explicitly not part of the
    core auth contract.

    Guiding principle: the macOS tray is a thin vsock→container pass-through.
    `tillandsias-headless` is the only Tillandsias process on the bare guest;
    all auth, git, vault, and forge operations go through `podman run`/`exec`.
- events:
  - type: discovered
    ts: "2026-06-26T21:10:00Z"
    agent_id: "macos-smoke-20260626T2000Z"
    host: macos
    note: >
      Operator review clarified the intended architecture: macOS tray is a
      vsock pass-through; business logic lives in Podman containers inside
      the VM. The current `run_github_login` violates this by running `gh`
      and `gh auth setup-git` on the bare Fedora guest after the vault write.
