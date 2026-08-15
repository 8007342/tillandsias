# MO-FULL attestation ledger — <host>.md (see methodology/mo-full-attestation.yaml)
# One verified marker per cycle, appended by: scripts/mo-full-attest.sh record
# Grammar: MO-FULL: <COMPLETE|BLOCKED> <LOCAL_SHA> <BRANCH> <REMOTE_SHA> (LOCAL_SHA == REMOTE_SHA)
# Verified at write time: startup boundary (717-3bvv) + remote convergence (614-2gqx).
# Gate: scripts/check-mo-full-attestations.sh (./build.sh --check).

## 2026-08-15T00:14:14Z yoga
MO-FULL: COMPLETE a174e3cc0b6cccfe4b9f7bfdd64c542915a984c1 linux-next a174e3cc0b6cccfe4b9f7bfdd64c542915a984c1

## 2026-08-15T00:22:15Z yoga
MO-FULL: COMPLETE f7d82adc9fda3fe3fb861a52dcf9d03719321331 linux-next f7d82adc9fda3fe3fb861a52dcf9d03719321331
