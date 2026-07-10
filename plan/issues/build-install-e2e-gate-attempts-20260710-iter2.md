# Overnight loop iteration 2 — gate 1 burn-down across three attempts — 2026-07-10

- agent: linux-macuahuitl-fable5-20260710T0621Z (loop iteration 2/8)
- commits tested: 5912cd89 → 63e0a497 → 9e7e47cc(+relay a41fdda3)
- evidence: `target/build-install-smoke-e2e/{20260710T062345Z,062934Z,064525Z}/`

Three gate-1 attempts, each red for a DIFFERENT, now-understood cause —
the burn-down worked; the destructive gates 2-4 were correctly never
reached (stop-at-first-failure):

| Attempt | Red | Classification | Action taken |
|---|---|---|---|
| 062345Z | `write_forge_gitconfig_*` test panic | Latent non-hermetic test (HOME set_var without the existing env_lock) first fired as new tests shifted interleavings | FIXED (63e0a497), pair 3× green, 142 bin tests pass |
| 062934Z | `litmus:environment-isolation` STEP 2 empty output in 5s | Cold-start timing flake in a YAML-invalid litmus file | File REWRITTEN (8ac2abdd): valid YAML, pre-warm step, explicit verdicts, 30-60s budgets |
| 064525Z | `litmus:inference-deferred-model-pulls` + `litmus:opencode-prompt-e2e-shape` STEP 3 TIMEOUT | (a) Known parked red: the runner's fake-podman shim injects `--userns=host` without `label=disable` → SELinux denies the cache write (fix recipe incl. preferred product-path launch recorded in the 267 issue). (b) First one-packet-doctrine timeout: the in-forge cycle exceeded 600s with NO push landed — packet didn't fit and wasn't split | (a) queued as the next 267 slice; (b) single occurrence — recorded as an order-265 (liveness) data point; if a second STEP 3 timeout occurs under the doctrine, bump 265 priority and inspect the in-forge session log for what it claimed |

Positives across the attempts: the all-features clippy lane passed in
all three; the opencode litmus passed fully in 062934Z (its 2nd/3rd
historical greens); order 268's proxy guard held (download SUCCEEDS in
the bad shape; only the SELinux write remains); env-isolation passed in
064525Z under the old file, consistent with flake.

Next iteration's plan: rewrite the inference litmus (267 slice, option
(c) product-path launch per the order-271 doctrine), then re-run gate 1
→ on green, proceed to the destructive gates 2-4 at last.
