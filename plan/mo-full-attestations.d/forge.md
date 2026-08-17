# MO-FULL attestation ledger — forge
# One verified marker per cycle, appended by: scripts/mo-full-attest.sh record
# Grammar: MO-FULL: <COMPLETE|BLOCKED> <LOCAL_SHA> <BRANCH> <REMOTE_SHA> (LOCAL_SHA == REMOTE_SHA)
# Verified at write time: startup boundary (717-3bvv) + remote convergence (614-2gqx).
# Gate: scripts/check-mo-full-attestations.sh (./build.sh --check).

## 2026-08-15T01:05:04Z forge
MO-FULL: COMPLETE b8bac055f8065b74ccbd179ef4455db32d655348 linux-next b8bac055f8065b74ccbd179ef4455db32d655348

## 2026-08-16T20:32:24Z forge
MO-FULL: BLOCKED 2a9dff4ef93aba13c4ef7c87dfcf0f38526a1cc7 linux-next 2a9dff4ef93aba13c4ef7c87dfcf0f38526a1cc7

## 2026-08-17T05:31:51Z forge
MO-FULL: COMPLETE aa167d939fa53d87eb1861f9481a4d3d2fc0f22b linux-next aa167d939fa53d87eb1861f9481a4d3d2fc0f22b

## 2026-08-17T09:44:20Z forge
MO-FULL: COMPLETE d947384c6c964f4c8c930f51d1fbb2391c40c407 linux-next d947384c6c964f4c8c930f51d1fbb2391c40c407

## 2026-08-17T09:44:56Z forge
MO-FULL: COMPLETE 82dcdac13cc48c54ab26ad030142627e6b61826a linux-next 82dcdac13cc48c54ab26ad030142627e6b61826a
