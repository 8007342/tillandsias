# Research: forge mirror credential injection for transparent agent push — order 238

- filed_as: plan/index.yaml `forge-git-mirror-credential-injection` (order 238,
  scope inherited from order 237's residual exit criteria 3/4)
- researched_by: `windows-bullo-fable5-20260715T1942Z` (windows lane, hybrid
  work through `scripts/with-wsl2-builder.sh` — git mechanism probes ran live
  in the `tillandsias-build` WSL2 distro)
- date: 2026-07-15
- evidence: `images/git/{entrypoint.sh,relay-refs.sh,vault-cli.sh,
  pre-receive-hook.sh}` at f54db8ae; live fixture run of
  `scripts/test-git-mirror-relay-verified-ack.sh` (3 cases PASS, 3s wall,
  wrapped); order 237 closure events; order 368 reconcile research.

## TL;DR — the recommended option is ALREADY BUILT; this doc names it and closes the analysis

The mirror's upstream push is authenticated today by a **vault-mediated,
push-time, process-scoped token fetch** — a hardened variant of Option B that
supersedes the original A/B/C framing. Recommendation: **keep it (call it
B-vault)**, harden two residuals (token scope + rotation story), and reject A
and C as strictly worse. No user ever types GitHub credentials in the forge
(exit criterion 4 holds by construction).

## The as-built mechanism (B-vault)

Chain, verified by source inspection at f54db8ae:

1. The launcher mints a short-lived AppRole token scoped to
   `git-mirror-policy` and mounts it at `/run/secrets/vault-token`
   (`images/git/entrypoint.sh:22-33`). No GitHub credential is baked into
   the image or its environment.
2. At push time — and only then — `relay-refs.sh` reads the REAL GitHub
   token via `vault-cli read -field=token secret/github/token`
   (`relay-refs.sh:59-62`), builds
   `https://oauth2:${TOKEN}@github.com/...` **in a process-scoped
   variable**, pushes `--atomic` with `GIT_TERMINAL_PROMPT=0`, and `unset`s
   `PUSH_URL TOKEN BARE_URL` on every exit path. The token never touches
   disk, argv of a long-lived process, or the container env.
3. All logging redacts embedded credentials
   (`redact_url`/`redact_output`, `relay-refs.sh:64-65`) — defense in depth
   against token leakage through the push log.
4. Failure honesty: a missing credential FAILS the relay loudly
   ("HTTPS upstream credential is unavailable; run GitHub Login before
   pushing", exit 1) so the pre-receive rejects the forge push instead of
   acking a false success (the order-318 class). Verified live: fixture
   case 1 ("missing upstream credential rejects the forge push") PASS.
5. Staleness recovery: on push failure the relay attempts a non-forced
   reconcile fetch outside Git's quarantine env (order 368/369 work),
   so fetch-first rejections self-heal without clobbering refs.

The GitHub token itself enters Vault through the tray/CLI GitHub Login flow
(`secret/github/token`), i.e. the credential the user already granted the
host — never typed inside the forge.

## Options analysis

### Option A — deploy key / PAT provisioned into the mirror container
- **Pros**: no Vault dependency at push time; works when Vault is sealed.
- **Cons / security**: a durable credential lives in the mirror's image,
  env, or volume — readable by anything that compromises the container or
  the volume snapshot; rotation requires re-provisioning; per-repo deploy
  keys are SSH-shaped while the enclave egress is HTTPS-through-squid
  (deploy keys would need a second transport + host-key trust);
  fine-grained PATs still tend to outlive their need. Violates the
  project's no-persistent-secret-on-disk stance for containers.
- **Verdict**: rejected. Strictly worse than B-vault on secrecy lifetime
  and rotation; its only advantage (works while Vault is down) is moot —
  if Vault is down, the forge lanes that produce pushes are down too.

### Option B — host injects credential into the mirror at launch (transient)
- **As originally framed** (env/secret injection of the GITHUB token at
  container start): better than A, but the token would sit in the
  container for its whole lifetime and rotation would lag until restart.
- **As actually built (B-vault)**: the injection is INDIRECTED through
  Vault — what's injected at launch is only a short-lived, policy-scoped
  AppRole token; the GitHub token is fetched per push and discarded.
  Window of exposure ≈ the duration of one `git push`. Rotation is
  automatic (next push reads the current secret). Auditability: Vault
  read events per relay.
- **Verdict**: **recommended — keep**. This is the strongest of the three
  on every axis that matters here.

### Option C — skip the mirror's HTTPS upstream push; out-of-forge agents push
- **Pros**: no credential in the enclave at all.
- **Cons**: reintroduces the exact babysitting failure the 2026-07-13
  Windows cycle documented (order 318: mirror acked, origin never moved,
  host relayed manually). Makes in-forge commits durably invisible until
  a host wakes up; multiplies the false-success surface; contradicts the
  operator goal "in-forge agent commits reach GitHub without a separate
  out-of-forge push step".
- **Verdict**: rejected as the steady-state design. It survives only as
  the degraded-mode behavior when the relay fails loudly (which the
  verified-ack fixture pins).

## Residual hardening (filed as the recommendation's follow-ups)

1. **Token scope (exit criterion 3)**: `secret/github/token` currently
   holds the host user's GitHub Login token — broader than push-only. A
   fine-grained PAT restricted to `contents:write` on the mirrored repo
   (or a GitHub App installation token minted host-side) stored at the
   same Vault path would cap blast radius without changing the relay.
   This is a host-side credential-provisioning choice, not a mirror
   change; route to the credential-secrets architecture audit (order 246)
   as an input rather than a new mirror packet.
2. **Rotation/expiry visibility**: a relay failure caused by an expired
   token is currently indistinguishable from other auth failures in the
   log line; adding the HTTP status to the redacted failure log would cut
   triage time. One-line change; fold into order 369's relay work.

## Hybrid-work note (how this research was produced)

Probes ran from a Windows host through the WSL2 build distro:
fixture `test-git-mirror-relay-verified-ack.sh` 3/3 PASS in 3s wall.
Container-runtime behaviors (Vault AppRole mint, podman secret mounts)
were verified by source inspection only — they need a live enclave, which
is exactly the boundary `methodology/multi-host-development.yaml`'s
wsl2_hybrid_work guidance draws.
