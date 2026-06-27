# Enclave Proxy Patterns Cheatsheet

**Status:** `completed`
**Owner:** linux
**Date:** 2026-06-26
**Trace:** `spec:proxy-container`, `spec:enclave-network`

## Summary

Filed and written as part of the user's request to justify every proxy env var
usage in the enclave and back architectural decisions with Unix best practices.

`cheatsheets/runtime/enclave-proxy-patterns.md` covers:
- Three proxy approaches: explicit env vars, containers.conf injection,
  iptables TPROXY intercept
- When `HTTP_PROXY` env vars are the *correct* Unix approach and when they are
  a maintenance anti-pattern
- The `build_stack_common_args` single-injection-point rule
- How to configure Squid for intercept mode (TPROXY)
- iptables PREROUTING rules and feasibility notes for rootless Podman
- Common pitfalls: redundant injection drift, short NO_PROXY lists

## Deliverable

`cheatsheets/runtime/enclave-proxy-patterns.md`
