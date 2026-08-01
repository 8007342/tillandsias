# Published-Release Smoke v0.4.260728.2 (Linux, 2026-08-01)

- **Channel**: daily
- **Host**: `linux_mutable` (`macuahuitl`)
- **Branch**: `linux-next`
- **Release**: `v0.4.260728.2`
- **Discovered by**: `/smoke-curl-install-and-test-e2e`
- **Evidence**: `target/smoke-e2e/`
- **Verdict**: PASS with two non-fatal harness findings

## Gate Results

- Curl install: PASS; checksum verified and installed version matched
  `v0.4.260728.2`.
- Destructive reset: PASS; containers, volumes, and images were empty afterward.
- Cold init: PASS; all release images rebuilt and Vault initialized/unsealed with
  the complete 12-policy set.
- Forge meta-orchestration: PASS; exit 0 and pushed `a0eb8111`.
- First-launch egress assertion: PASS; `tillandsias-proxy` remained alive beside
  the forge lane.

## Finding 586-5yc7: Release Smoke Inherited the Litmus Podman Shim

The supposedly clean operator install resolved Podman to the repository test
shim at `target/litmus-runtime/bin/podman`, not `/usr/bin/podman`. The shim
delegated successfully, so this run remains a functional PASS, but the harness
did not exercise the exact executable-discovery boundary a normal operator
would use.

Evidence: `target/smoke-e2e/01-install.log:19` and
`target/smoke-e2e/03-init.log:9`.

## Finding 586-i6j7: Straggler Probe Races a Vanishing Proc Entry

After the store reset, `container-teardown-straggler-probe.sh` emitted
`/proc/200342/cmdline: No such file or directory` while the inspected process
exited. The probe still returned the correct clean verdict, but routine process
exit should not leak shell diagnostics into release evidence.

Evidence: `target/smoke-e2e/02-straggler-probe.log` and the gate transcript.
