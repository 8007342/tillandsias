# Proposal — substrate-capability-probe

Packets: `1553-hqrr` (probe), `1553-jq6p` (proxy denials), and the
fail-closed topology note on `1193-e6kv`. Research and verdicts:
`plan/issues/microsoft-mxc-learnings-2026-10-07.md`.

## Why

Microsoft's MXC (v1.0.0, 2026-10-07) runs one untrusted process under a
declarative policy on Windows, Linux and macOS. It does not replace any part
of the enclave, but three of its shapes fix failure modes we have measured:

1. It answers "what can run here" with ONE probe that lists usable backends
   and reports each missing capability once, in `warnings[]`. On a Mac
   without `setsid` every one of our preflight guards refuses on its own
   (1353-ryhq, 1375-amye); the WSL preflight detects without naming the
   remedy (756-dwkm).
2. It refuses a policy its backend cannot enforce in a validate pass, before
   anything starts. Our launcher starts a proxy with no egress network
   although `enclave-network` requires one (1193-e6kv).
3. It treats denials as a policy-authoring artifact (`--audit`). Our
   allowlist grows by grepping Squid logs for `TCP_DENIED`.

## What changes

- NEW capability `substrate-capability-probe`: one machine-readable answer
  (substrate, capabilities, warnings with why/remedy), consulted by
  preflight so a guard whose capability is missing reports a skip naming the
  probe's warning instead of its own refusal.
- `enclave-network`: the topology is validated before any container starts,
  and an unenforceable topology is refused by name.
- `proxy-container`: denied destinations are listable with counts and the
  requesting container.

## What does not change

No dependency on MXC is added. Adopting its Windows `wslc` backend is not
proposed; whether it could host the forge is a measurement (1553-gsp2).
