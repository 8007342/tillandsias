# MO-FULL attestation ledger — <host>.md (see methodology/mo-full-attestation.yaml)
# One verified marker per cycle, appended by: scripts/mo-full-attest.sh record
# Grammar: MO-FULL: <COMPLETE|BLOCKED> <LOCAL_SHA> <BRANCH> <REMOTE_SHA> (LOCAL_SHA == REMOTE_SHA)
# Verified at write time: startup boundary (717-3bvv) + remote convergence (614-2gqx).
# Gate: scripts/check-mo-full-attestations.sh (./build.sh --check).

## 2026-08-25T01:16:20Z pirria
MO-FULL: COMPLETE e762e485b57370fbd1865c7671adf69f5a2f3af0 linux-next e762e485b57370fbd1865c7671adf69f5a2f3af0

## 2026-08-25T01:55:36Z pirria
MO-FULL: COMPLETE d452085ff75326663cc890d1c181013dd1e0013e linux-next d452085ff75326663cc890d1c181013dd1e0013e

## 2026-08-25T07:54:50Z pirria
MO-FULL: COMPLETE 292ff760721f1a9cc02a153aef8a872373212be1 linux-next 292ff760721f1a9cc02a153aef8a872373212be1
