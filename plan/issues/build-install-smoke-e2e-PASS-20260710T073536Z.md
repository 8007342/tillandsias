# local-build e2e FULL PASS — run 20260710T073536Z — 2026-07-10

- agent: linux-macuahuitl-fable5 (overnight loop iterations 3-4)
- commit tested: `3a6e4c48` (gate 1) / gates 2-4 on the same install;
  HEAD relay-advanced to `2cc5a066` mid-gate (in-forge 267 slice 2)
- evidence: `target/build-install-smoke-e2e/20260710T073536Z/`

**First fully-green destructive local-build e2e on this host** — all four
gates in one run:

| Gate | Verdict |
|---|---|
| 1. `./build.sh --ci-full --install` | exit 0 — every litmus green incl. the three rewritten this night (opencode 7/7, inference cold chain on the product shape, environment-isolation allowlist) and the all-features clippy lane |
| 2. `podman system reset --force` | exit 0, zero residue (containers/volumes/images all empty) |
| 3. `tillandsias --init --debug` cold re-provision | exit 0 — full image set rebuilt from a pristine store; the order-263 mirror YAML pre-receive gate is now baked into the live git image |
| 4. forge lane (`--opencode` meta-orchestration cycle) | exit 0 — live in-forge agent drained one packet and exited clean |

Burn-down that made it possible (iterations 2-4): env_lock test race →
fixed; environment-isolation → rewritten (resolution, entrypoint
overrides, env-key allowlist); inference-deferred-model-pulls →
rewritten on the product launch shape after the fake-podman-shim
diagnosis; 31 folded litmus steps → rewritten by the in-forge agent
(267 slice 2) with the coordinator repairing its placeholder expecteds;
gate-4 orphan fixes adopted (alias grep, doc path, entrypoint stubs);
runner anchor parked.

Residual known-open on the litmus infrastructure (order 267 tail):
strict-exit default flip + [PARSE WARNING]→FAIL promotion + the parked
command:-regex anchor, all gated on the corpus staying green under
TILLANDSIAS_LITMUS_STRICT_EXIT=1 sweeps.
