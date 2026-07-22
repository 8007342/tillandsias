# Final-wave adversarial review findings: 443 slice-3 refcount + vault unseal seam (residuals)

- Date: 2026-07-22
- Class: bug (hardening residuals from reviewed-and-landed wave work)
- Source: read-only adversarial review (Opus) of a5cc14ed + cdd43e57; the one
  CRITICAL-adjacent finding (swallowed `podman ps` failure biasing to
  teardown) was FIXED by the coordinator in the same 2026-07-22 batch.

## Open findings (each is a claimable slice; file:line from review)

1. MAJOR — tray non-credentialed forge launch releases its launch-in-flight
   marker when the spawning function returns, BEFORE the spawned terminal's
   forge container exists (main.rs ~10651): the pre-create teardown window
   reopens for exactly that lane. Fix direction: the marker must survive
   until the child owns a container — have the spawned terminal re-exec a
   lane that acquires its own marker first, or hand the flock fd to the
   child.
2. MINOR — vault recovery seam zeroize gaps: `existing` bytes not zeroized
   on the `write_res?` / `launch_vault_container(...)?` early returns
   (vault_bootstrap.rs ~2208); use a drop-guard.
3. MINOR — recovery seam leaves the podman secret at the UNVERIFIED
   candidate when launch fails after the candidate write (~2209): any
   post-write failure must restore prior bytes.
4. MINOR — `podman secret inspect --showsecret --format {{.SecretData}}`
   byte round-trip is unpinned (~1506): add a fixture incl. a key ending
   0x0a so a format/rendering change cannot silently disable recovery.
5. INFO — held_resources_with_prefix biases to DESTROY on lock-dir read
   error while is_held biases to HELD (resource_lock.rs ~169): bias both to
   HELD for existing dirs.
6. INFO — launch markers are never pruned; O(N-historical) opens per
   teardown (resource_lock.rs ~166): optional mtime-based prune.

## Exit criteria

Each numbered finding closed by a scoped commit + test, or explicitly
rejected with an event. Finding 1 is the only one in the data-loss
direction and should ride before v0.4 STABLE promotion (not the daily).
