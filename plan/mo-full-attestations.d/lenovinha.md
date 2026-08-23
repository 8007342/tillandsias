# MO-FULL attestation ledger — <host>.md (see methodology/mo-full-attestation.yaml)
# One verified marker per cycle, appended by: scripts/mo-full-attest.sh record
# Grammar: MO-FULL: <COMPLETE|BLOCKED> <LOCAL_SHA> <BRANCH> <REMOTE_SHA> (LOCAL_SHA == REMOTE_SHA)
# Verified at write time: startup boundary (717-3bvv) + remote convergence (614-2gqx).
# Gate: scripts/check-mo-full-attestations.sh (./build.sh --check).

## 2026-08-22T23:57:48Z lenovinha
MO-FULL: COMPLETE ab994016ac527fdf923ebcdbd4c89b95af92df38 linux-next ab994016ac527fdf923ebcdbd4c89b95af92df38

## 2026-08-23T02:06:39Z lenovinha
MO-FULL: COMPLETE 95b7aef60f8a76707c263dd5b3a49ec7a70e05ab linux-next 95b7aef60f8a76707c263dd5b3a49ec7a70e05ab
