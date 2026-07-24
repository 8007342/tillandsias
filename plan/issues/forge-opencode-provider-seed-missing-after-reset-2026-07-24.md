# P1 (smoke-gate): in-forge OpenCode has no provider bootstrap on a pristine substrate — "No provider available" after every full reset

- Date: 2026-07-24
- Class: fix (credential lifecycle / smoke-gate blocker)
- Area: forge opencode lane / vault provider seeds / destructive-reset semantics
- Severity: P1 for the Linux local-build e2e gate (order-455 family) — gates 1-3
  PASS on a pristine substrate, gate 4 (forge lane) CANNOT pass until an
  operator manually re-seeds a secret that has no owning flow
- Owner: linux (framework) + operator (holds the Gemini key for the interim reseed)
- Discovered-by: /build-install-and-smoke-test-e2e (linux), evidence
  `target/build-install-smoke-e2e/20260724T062902Z/04-meta-orchestration.log`

## Symptom

Full destructive smoke on the linux host (local build v0.3.260724.3 @ 25d7f26f):
`podman system reset --force` clean, straggler probe clean, cold
`tillandsias --init --debug` exit 0 with zero panic/ERROR lines, forge
launches, the enclave `git://` mirror clone of the project succeeds
("Cloning into '/home/forge/src/tillandsias'"), the opencode harness starts —
and dies:

```
> build · big-pickle
Error: No provider available
[tillandsias] no active lane containers; cleaning project + shared stack
Error: [OpenCode] forge session exited: stage 'opencode' attached command exited with status 1
```

`forge_exit=1` (agent/runtime class per the launcher's own taxonomy — NOT a
podman launch failure; the container and stack were healthy).

## Root cause (traced, file:line)

The order-431 credential-free OpenCode vault auth reads exactly one producer:

- `vault_bootstrap.rs:873` — `OPENCODE_AUTH_VAULT_PATH: "secret/gemini/api-key"`;
  `opencode_auth_content_available` (vault_bootstrap.rs:881) gates the lease.
- `images/default/lib-common.sh:1057` — "The existing credential producer
  remains secret/gemini/api-key"; the entrypoint adapts it to
  `OPENCODE_AUTH_CONTENT` in memory (no auth.json materialized).

But that secret has NO owning flow:

1. **No login lane.** `run_provider_login` providers are GitHub / Claude /
   Codex / Antigravity only (main.rs:442-472; vault paths at main.rs:6692-6695).
   Nothing in the codebase writes `secret/gemini/api-key`; it was seeded
   out-of-band (operator `vault kv put`) at some point in the past.
2. **Destroyed by design.** `podman system reset --force` wipes the vault —
   the seed dies with every destructive smoke (this is correct reset
   semantics; the gap is the missing re-seed path).
3. **Not recoverable from host state.** The host's
   `~/.local/share/opencode/auth.json` holds only an `openai` oauth record —
   no Gemini key exists anywhere on the host after the wipe.

Consequence: the Linux leg of the order-455 smoke family can never pass its
forge gate unattended; the same applies to any fresh operator install that
wants the opencode lane.

## Positive evidence from the same run (do not lose)

- Fresh-substrate mirror seeding + in-forge enclave `git://` clone: WORKED
  (452/454 lineage live evidence on a rebuilt image).
- Forge launch, stack ensure, teardown refcount: clean (`no active lane
  containers; cleaning project + shared stack` fired exactly once).
- Known cosmetic residual reproduced: `[entrypoint] WARNING: OpenSpec init
  failed` (existing packet class, forge-openspec-init-fails-warning-2026-07-12;
  not re-filed).

## Fix shape

1. **Interim (operator, unblocks the next smoke):** documented one-liner to
   re-seed after any reset —
   `podman exec ... vault kv put secret/gemini/api-key key=<GEMINI_API_KEY>`
   via the root-token seam — recorded in the smoke skill's runbook as a
   post-init step when the opencode lane will be exercised, with a pre-reset
   WARNING when `secret/gemini/api-key` is present (the reset destroys it).
2. **Durable:** generalize order 468's transparent capture (Claude
   setup-token -> Vault) into a provider-seed framework: a
   gemini/opencode-capable login lane (device flow or key paste) joining the
   four existing providers, writing `secret/gemini/api-key`, refresh-capable.
   The 455-family smoke then performs provider seeding through the same
   idiomatic lane every operator uses.
3. **Gate hygiene:** the forge launcher already refuses the lane loudly; add
   a pre-launch `opencode_auth_content_available` check surfaced in
   `--diagnose` so a missing seed is visible BEFORE a 4-minute forge launch.

## Exit criteria

- A pristine-substrate smoke (reset -> init -> seed-or-capture -> forge
  opencode lane) reaches the in-forge meta-orchestration prompt without
  manual vault CLI use, verified by a dated PASS report on a linux host.
- `--diagnose` (or the launch preflight) names the missing opencode provider
  seed explicitly when absent (litmus-pinned single-line grammar).
- The destructive-smoke runbook documents the credential-destruction
  consequence and its re-seed step until (2) lands.
