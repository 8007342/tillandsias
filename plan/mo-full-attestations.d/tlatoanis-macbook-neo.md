# MO-FULL attestation ledger — <host>.md (see methodology/mo-full-attestation.yaml)
# One verified marker per cycle, appended by: scripts/mo-full-attest.sh record
# Grammar: MO-FULL: <COMPLETE|BLOCKED> <LOCAL_SHA> <BRANCH> <REMOTE_SHA> (LOCAL_SHA == REMOTE_SHA)
# Verified at write time: startup boundary (717-3bvv) + remote convergence (614-2gqx).
# Gate: scripts/check-mo-full-attestations.sh (./build.sh --check).

## 2026-09-06T10:26:31Z tlatoanis-macbook-neo
MO-FULL: COMPLETE def4bfe8898e3c7b15b920344a317aaaf8759e13 osx-next def4bfe8898e3c7b15b920344a317aaaf8759e13
