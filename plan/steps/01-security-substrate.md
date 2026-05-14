# Step 01: Security Substrate and Podman Layer Closure

## Status

completed

## Objective

Finish the security, isolation, container, and secret-lifecycle cluster before moving to higher-level UX work.

## Included Specs

- `security-privacy-isolation`
- `enclave-network`
- `proxy-container`
- `podman-container-spec`
- `podman-container-handle`
- `podman-orchestration`
- `podman-secrets-integration`
- `secrets-management`
- `native-secrets-store`
- `secret-rotation`
- `git-mirror-service`
- `inference-container`
- `reverse-proxy-internal`

## Deliverables

- Bound live specs to executable litmuses or a minimal falsifiable boundary.
- Tombstone or obsolete any stale security/substrate spec that no longer has a live executable contract.
- Reconcile docs and trace annotations so the security substrate reads as one coherent model.

## Evidence

- Updated the live `git-mirror-service` spec to remove the stale D-Bus/keyring-forwarding contract.
- Rebound the live contract to the existing host-side secrets pipeline: `/run/secrets/github_token` plus `GIT_ASKPASS=/usr/local/bin/git-askpass-tillandsias.sh`.
- Confirmed the replacement architecture already exists in the repo through the git entrypoint and askpass helper scripts.
- Verified `./scripts/run-litmus-test.sh git-mirror-service` passes.
- Verified `./scripts/run-litmus-test.sh secrets-management` passes.

## Notes

- This pass was a spec-repair step, not a Podman runtime change. The code already matches the replacement contract.

## Suggested Hourly Flow

1. Read `plan.yaml`, `plan/index.yaml`, and `methodology.yaml`.
2. Inspect the live security/substrate specs and their current litmus bindings.
3. Pick the smallest high-value residual that reduces ambiguity across the cluster.
4. Apply the smallest spec, binding, or tombstone edit that closes that residual.
5. Run the narrow litmus, then the strict filter, then the install verification.

## Verification

- Narrow litmus for the selected spec bundle.
- `./build.sh --ci --strict --filter <security-bundle>`
- `./build.sh --ci-full --install --strict --filter <security-bundle>`

## Hand-off Rules

- If a spec is historical only, mark it `obsolete` and preserve the replacement reference.
- If a live contract still lacks a real boundary, mark the step `blocked` only for that spec and continue with the next independent ready step if one exists.
