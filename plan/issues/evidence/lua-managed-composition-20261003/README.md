# Composition evidence

@trace order:1538-pwdr

The raw Rust logs live as byte-exact plain text in
`plan/evidence/lua-managed-composition-20261003/`; `archive.sha256` records
their hashes. Runtime source-line diagnostics are raw evidence, not durable
prose citations. Keeping them outside the prose-audit area also preserves
the repository's no-tracked-binary rule. No diagnostic was rewritten or
annotated and neither guard was changed or waived. An earlier gzip packaging
attempt was refused by that binary guard; its real failure receipt is kept.

The initial targeted green was refuted by the long-byte probe. The pre-gate
library failure was caused by repository-bound fixtures writing through an
external target symlink; the refusal itself was correct. The final logs show
427 library, 44 CLI and 32 executor passes, including the9 dispatcher units
also run separately. The18 new CLI cases fail against pre-composition and
the long-capture case fails against pre-repair; both use preserved binaries.

Typed receipts record their actual run identities/statuses. These targeted
logs alone do not prove the forced integration gate, landing or native parity.
