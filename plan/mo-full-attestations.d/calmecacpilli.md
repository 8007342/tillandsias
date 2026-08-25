# MO-FULL attestation ledger — <host>.md (see methodology/mo-full-attestation.yaml)
# One verified marker per cycle, appended by: scripts/mo-full-attest.sh record
# Grammar: MO-FULL: <COMPLETE|BLOCKED> <LOCAL_SHA> <BRANCH> <REMOTE_SHA> (LOCAL_SHA == REMOTE_SHA)
# Verified at write time: startup boundary (717-3bvv) + remote convergence (614-2gqx).
# Gate: scripts/check-mo-full-attestations.sh (./build.sh --check).

## 2026-08-25T22:41:07Z calmecacpilli
MO-FULL: COMPLETE 7cf78cde05aa66805dd175bac3c31aa6a2092dec linux-next 7cf78cde05aa66805dd175bac3c31aa6a2092dec
