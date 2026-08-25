# MO-FULL attestation ledger — <host>.md (see methodology/mo-full-attestation.yaml)
# One verified marker per cycle, appended by: scripts/mo-full-attest.sh record
# Grammar: MO-FULL: <COMPLETE|BLOCKED> <LOCAL_SHA> <BRANCH> <REMOTE_SHA> (LOCAL_SHA == REMOTE_SHA)
# Verified at write time: startup boundary (717-3bvv) + remote convergence (614-2gqx).
# Gate: scripts/check-mo-full-attestations.sh (./build.sh --check).

## 2026-08-25T01:16:20Z pirria
MO-FULL: COMPLETE e762e485b57370fbd1865c7671adf69f5a2f3af0 linux-next e762e485b57370fbd1865c7671adf69f5a2f3af0
