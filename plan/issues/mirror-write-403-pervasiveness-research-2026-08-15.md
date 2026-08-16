# Is the mirror write-channel 403 pervasive? Yes — by construction. (759-*)

- Date: 2026-08-15
- Trigger: operator question after two incidents (2026-08-15 Windows/codex on
  v0.4.260815.1; 2026-08-14 OpenCode on another host, older curl-installed
  release), asking whether the class spans platforms/harnesses and whether the
  secured-write + anonymous-pull hybrid caused it.
- Method: four parallel researchers (write-path map, migration timeline,
  harness matrix, live scope verification on this host). Full transcripts in
  the session workflow journal; key citations inline below.
- Packets filed: 759-vceg (seed-time push-authorization validation, p1),
  759-vsaj (fleet propagation + reseed), 759-ffh7 (host-keyring authorization
  probe). Complements 756-2jnj (unreleased guard) and order 424 evidence.

## Verdict, on the operator's three axes

- **Harness-independent: YES.** All four lanes (opencode, codex, claude,
  antigravity) converge on one gitconfig facade (`write_forge_gitconfig`,
  main.rs:8178 — credential.helper cleared, url.insteadOf → mirror) and one
  choke point: the mirror pre-receive relay with the single Vault-held
  `secret/github/token`. Forge lanes carry ZERO git credentials
  (lib-common.sh:85-90). The "codex/brew token exception" no longer exists —
  order 359's injection was reversed outright 2026-08-01
  (main.rs:11863-11905, "do not reintroduce"), with source-pin tests.
- **Platform-independent: YES.** Same seeding flow, same relay, on
  linux/macOS/Windows; no platform-specific credential delta found.
- **Release-independent: YES.** Every installable release from v0.3.260715.2
  onward (stable v0.4.260810.1, stale `latest` v0.3.260724.1, daily
  v0.4.260815.1, and the force-promoted v0.4.260809.2 on the 2026-08-14
  incident host) ships the identical write path with a reachability-only
  guard. The 756-2jnj fail-closed guard is in NO release yet. Pre-relay
  releases (≤ v0.3.260714.1) had the same credential defect WORSE: the
  post-receive hook always exited 0, so it produced silent mirror/upstream
  divergence instead of a loud late rejection.

## Root cause (sharper than the migration hypothesis)

The migration did not create the defect; it changed when and how loudly it
surfaces. The defect is at the SOURCE:

1. **There is no GitHub device flow.** GitHub auth is token-paste only
   (GH_LOGIN_TOKEN_SCRIPT main.rs:7350-7359; stdin variant :7367-7374). The
   `AuthModel::OAuthDevice` tag on the GitHub branch is a mislabel
   (provider_device_auth_spec returns None, main.rs:7545-7552).
2. **Zero authorization validation at seed time.** The flow checks:
   non-empty, `gh auth login --with-token` (authentication), `gh auth status`
   (authentication), Vault round-trip (byte equality). Nothing checks
   X-OAuth-Scopes, fine-grained repository permissions, or push capability
   against the target repo. The guidance even steers operators to a
   fine-grained PAT (main.rs:7450-7466) — exactly the token class that
   authenticates as the owner yet is denied push when Contents:write or the
   repo selection is missing, matching the 403 verbatim.
3. **Anonymous everything until the first push.** Pulls/clones/mirror reads
   are anonymous (`--export-all`, git:// daemon; entrypoint.sh:381-398); the
   pre-756-2jnj guard proved reachability only. So an under-scoped or absent
   credential passes login, passes the guard, and works for hours — until the
   first relay push, where the verified-ack correctly refuses.
4. **Prior art:** the exact guard-ok-then-relay-reject signature occurred
   2026-07-18 (plan/issues/blocker-github-upstream-credential-2026-07-18.md,
   blocker-git-mirror-relay-token-expiry-2026-07-18.md). The blind spot is a
   month old; the incidents finally made it legible.

## The 2026-08-14 OpenCode incident, honestly

No 403 trace exists in plan/ for 08-13/14. The best-matching record is
741-3y48: an OpenCode BigPickle forge on the linux_immutable host (installed
tray v0.4.260809.2 — the operator's force-promoted stable, plausibly the
"older curl-installed release") whose three fragments died with the container,
unpushed. That is the same blind-spot class seen from the silent side —
consistent with, but not proof of, the under-scoped-credential mechanism. If
that forge had attempted a relay push with an under-scoped Vault token,
v0.4.260809.2 would produce exactly the incident-1 signature.

## Live state of THIS host (linux_mutable)

- Host keyring: classic token, scopes `gist, read:org, repo, workflow`,
  permissions.push=true — the operator-facing credential is fine.
- Vault: DOWN 46h; no GitHub token exists anywhere on disk outside Vault
  (by design). The mirror volume's git-push.log shows this host's mirror has
  NEVER performed a live authenticated upstream push ("No upstream
  configured; accepting as a durable local-only mirror update", 2026-08-06)
  — this host is itself in the latent state, simply never exercised.
- The 403 lines in git-push.log dated 2026-08-15T17:0x are litmus fixture
  replays from the 756-2jnj suite, NOT live denials. Do not count them.

## Fix ladder

1. **756-2jnj** (implemented, unreleased): mirror probes upstream
   authorization non-mutatingly, publishes verdict; guard fails closed
   before worker drain. Detection.
2. **759-vceg** (p1): seed-time validation — `--github-login` refuses a token
   that cannot push to the target repo, with exact remediation guidance.
   Prevention at the source, all platforms, all future seeds.
3. **759-vsaj**: fleet propagation — next daily release carries 1+2; sibling
   queues instruct each host to restart its mirror on the new image, read the
   probe verdict, and re-login with a properly-scoped token if denied.
4. **759-ffh7** (p3): host (non-forge) guard branches — `ok:gh-keyring`
   should also verify repo push permission cheaply; `gh auth status` proves
   authentication, not authorization (same class, direct-push flavor).
