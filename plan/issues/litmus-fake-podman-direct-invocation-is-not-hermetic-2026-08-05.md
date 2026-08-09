# `LITMUS_PODMAN_MODE=fake` direct invocation is not hermetic

- **Observed**: 2026-08-06 UTC
- **Desired release**: v0.5
- **Priority**: P1 test safety
- **Area**: litmus runner / image-build convergence fixture

## Finding

The bound litmus command advertises:

```sh
LITMUS_PODMAN_MODE=fake scripts/test-image-build-convergence.sh proxy
```

That command is hermetic only when `scripts/run-litmus-test.sh` has already
installed its fake Podman shim on `PATH`. Running the displayed command
directly from the repository does not interpret `LITMUS_PODMAN_MODE`; it calls
the host's real Podman with a temporary `HOME`, reports zero fake build calls,
and can leave rootless user-namespace-owned overlay files that ordinary `rm`
cannot clean.

The 2026-08-06 reproduction failed with `expected 1 podman builds, saw 0` and
left one `/tmp/tmp.*` store. The exact temporary directory was inspected and
removed with `podman unshare`; the canonical runner invocation then passed
`litmus:image-build-convergence-shape` 1/1.

## Required behavior

Choose one explicit contract and make it executable:

1. make the fixture interpret `LITMUS_PODMAN_MODE=fake` itself and install/use a
   fixture-owned shim; or
2. make direct invocation fail before any Podman call unless the runner's shim
   contract is present, and change the litmus command/help text to the canonical
   runner entrypoint.

In either design, fake mode must never create containers, images, volumes, or a
real containers/storage tree. Cleanup must remain possible as the invoking
user even when an assertion fails.

## Exit criteria

- the exact command displayed by the litmus is safe and deterministic when
  copied into a plain shell;
- a spy proves fake mode executes zero calls to the real Podman binary;
- an injected mid-fixture failure leaves no temporary containers/storage tree
  and no user-namespace-owned residue;
- canonical runner and direct/documented entrypoints produce the same verdict.
