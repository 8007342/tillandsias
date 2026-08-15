# MO-FULL attestation ledger

Durable record of verified full-mode terminal markers (order 614-2gqx, gap
651-2x5s). One file per host — `<host>.md` — so concurrent hosts append
without cross-host merge conflicts (same fragment philosophy as
`plan/loop_status.d`, packet 582-nqw5). Canonical contract:
`methodology/mo-full-attestation.yaml`.

- **Writer**: `scripts/mo-full-attest.sh record` — derives the marker from live
  git state (never typed), verifies the startup boundary (717-3bvv) and remote
  convergence, and appends the verified line. A failed verification leaves no
  record.
- **Gate**: `scripts/check-mo-full-attestations.sh`, wired into
  `./build.sh --check` — grammar over every file; for the current host's file,
  each recorded `LOCAL_SHA` must be a real commit reachable from the current
  branch head.
- **Host label**: `scripts/mo-full-attest.sh host` (`MO_FULL_HOST` if set,
  else `forge` inside the forge container, else short hostname lowercased).
- **Entry shape**:
  ```text
  ## <ISO-UTC-timestamp> <host>
  MO-FULL: <COMPLETE|BLOCKED> <LOCAL_SHA> <BRANCH> <REMOTE_SHA>
  ```

The ledger records the marker for a cycle's WORK head; the cycle then commits
the ledger and re-derives the terminal marker at the head containing the record
(see `bookkeeping_commit` in `methodology/mo-full-attestation.yaml`). A ledger
`LOCAL_SHA` is verified as reachable, not as equal to the current remote head —
the head advances with each cycle.
