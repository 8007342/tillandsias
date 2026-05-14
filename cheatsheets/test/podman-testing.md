---
tags: [podman, testing, integration, system, runtime, mock]
languages: [bash]
since: 2026-05-06
last_verified: 2026-05-06
sources:
  - https://github.com/containers/podman/blob/main/CONTRIBUTING.md
  - https://github.com/containers/podman/blob/main/test/README.md
  - https://github.com/containers/podman/blob/main/docs/source/markdown/podman-system-service.1.md
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: false
---
# Podman testing

## Provenance

- Podman contributing guide: <https://github.com/containers/podman/blob/main/CONTRIBUTING.md> - Podman ships unit, integration, system, API, and machine tests; PRs are expected to include tests.
- Podman test README: <https://github.com/containers/podman/blob/main/test/README.md> - the upstream split between `make localunit`, `make localintegration`, `make remoteintegration`, and `make localsystem`.
- Podman API service man page: <https://github.com/containers/podman/blob/main/docs/source/markdown/podman-system-service.1.md> - `podman system service`, socket activation, rootless default socket path.
- **Last updated:** 2026-05-06

## Use when

You are deciding how to test code that shells out to Podman, or you want to split Podman-related checks into fast command-shape tests and slower real-runtime checks.

## Quick reference

| Test class | What it should prove | Preferred seam |
|---|---|---|
| Command-shape / CLI contract | The code passed the right `podman` flags, image names, mounts, and env | Mock Podman subprocess boundary |
| API/service-control logic | The client talks to the right Podman service socket / connection | `podman system service` + `podman system connection` seam |
| Runtime semantics | Containers actually start, stop, isolate, and clean up | Real Podman integration/system test |

## Upstream Podman test strata

- `make localunit` - unit tests for `test/utils`
- `make localintegration` - Ginkgo integration tests in `test/e2e/`
- `make remoteintegration` - integration tests against a remote Podman service
- `make localsystem` - BATS-based system tests in `test/system/`

The upstream docs explicitly say system tests are meant to validate Podman in a complete system context, while integration tests are the primary Go-based suite.

## Tillandsias inference

This repo should not use real containers for every assertion. If a test only needs to prove the CLI invoked Podman with the correct arguments, mock the subprocess boundary and inspect recorded calls. Reserve real container runs for the smaller set of tests that need runtime behavior.

That split keeps the litmus suite fast and makes uncertainty reduction sharper: command construction is one signal, container behavior is another.

## Secret lifecycle litmus shape

Use this pattern for secret-bearing flows such as `--github-login`, keyring sync, or token handoff:

| Tier | Purpose | Inputs | What to assert |
|---|---|---|---|
| Pre-build command-shape | Prove the code asks Podman for the right secret transport and cleanup commands | Synthetic identity, temp HOME, fake Podman shim, repo-local helper script | Recorded `podman secret create`, `podman exec gh auth login`, `podman exec gh auth token`, and cleanup calls |
| Post-build smoke | Prove the installed binary can run the full login path once | Installed `tillandsias` binary, temp HOME, same synthetic identity | Completion message plus generated log/artifact files |
| Runtime residual | Prove the live stack does not leak secret state after a real run | Real container-backed runtime | No leftover secret files, sockets, or mounted credentials |

Rules:

- Never encode host PII or host-specific identity in the repo fixtures.
- Prefer synthetic names and `example.invalid` addresses.
- Keep the helper script repo-local so GitHub CI and local runs execute the same command path.
- If a test needs the full runtime, mark it `phase: post-build` or `phase: runtime`; do not hide that dependency inside a pre-build gate.
- Keep command-shape assertions separate from success-of-work assertions. The former should be cheap and deterministic; the latter can be representative smoke.

## Useful environment variables from Podman integration tests

- `PODMAN_BINARY`
- `PODMAN_REMOTE_BINARY`
- `QUADLET_BINARY`
- `CONMON_BINARY`
- `OCI_RUNTIME`
- `PODMAN_DB`
- `PODMAN_TEST_IMAGE_CACHE_DIR`

## See also

- `runtime/podman-service-testing.md` - the service/socket seam
- `runtime/podman.md` - general Podman CLI reference
- `runtime/runtime-limitations.md` - record runtime gaps instead of papering over them
