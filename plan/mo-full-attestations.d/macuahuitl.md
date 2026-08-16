# MO-FULL attestation ledger — <host>.md (see methodology/mo-full-attestation.yaml)
# One verified marker per cycle, appended by: scripts/mo-full-attest.sh record
# Grammar: MO-FULL: <COMPLETE|BLOCKED> <LOCAL_SHA> <BRANCH> <REMOTE_SHA> (LOCAL_SHA == REMOTE_SHA)
# Verified at write time: startup boundary (717-3bvv) + remote convergence (614-2gqx).
# Gate: scripts/check-mo-full-attestations.sh (./build.sh --check).

## 2026-08-16T06:06:30Z macuahuitl
MO-FULL: COMPLETE eabefd387e7b2b0a7944b7cf98a84bd4d7af5902 linux-next eabefd387e7b2b0a7944b7cf98a84bd4d7af5902

## 2026-08-16T06:13:32Z macuahuitl
MO-FULL: COMPLETE e0fa762a4580090011d73dc76853f89c3d71b674 linux-next e0fa762a4580090011d73dc76853f89c3d71b674

## 2026-08-16T06:48:04Z macuahuitl
MO-FULL: COMPLETE 575c08f7da815ec9f0b7988f9f5ed881b58b2312 linux-next 575c08f7da815ec9f0b7988f9f5ed881b58b2312

## 2026-08-16T06:58:28Z macuahuitl
MO-FULL: COMPLETE 2badc8a4458c43b62b72c1a08bf0a4a47e78c5cc linux-next 2badc8a4458c43b62b72c1a08bf0a4a47e78c5cc
