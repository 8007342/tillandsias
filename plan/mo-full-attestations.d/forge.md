# MO-FULL attestation ledger — forge
# One verified marker per cycle, appended by: scripts/mo-full-attest.sh record
# Grammar: MO-FULL: <COMPLETE|BLOCKED> <LOCAL_SHA> <BRANCH> <REMOTE_SHA> (LOCAL_SHA == REMOTE_SHA)
# Verified at write time: startup boundary (717-3bvv) + remote convergence (614-2gqx).
# Gate: scripts/check-mo-full-attestations.sh (./build.sh --check).

## 2026-08-15T01:05:04Z forge
MO-FULL: COMPLETE b8bac055f8065b74ccbd179ef4455db32d655348 linux-next b8bac055f8065b74ccbd179ef4455db32d655348
