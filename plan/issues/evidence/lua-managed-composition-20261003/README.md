# Composition evidence

@trace order:1538-pwdr

The raw Rust logs are losslessly archived as `.log.gz`; decompression returns
the exact captured bytes. `archive.sha256` records hashes of the uncompressed
streams under their original names. No diagnostic was rewritten or annotated
to waive the source-citation guard. For inspection, decompress a named archive
to a scratch file and compare its SHA-256 with the manifest.

The initial targeted green was refuted by the long-byte probe. The pre-gate
library failure was caused by repository-bound fixtures writing through an
external target symlink; the refusal itself was correct. The final logs show
427 library, 44 CLI and 32 executor passes, including the9 dispatcher units
also run separately. The18 new CLI cases fail against pre-composition and
the long-capture case fails against pre-repair; both use preserved binaries.

Typed receipts record their actual run identities/statuses. These targeted
logs alone do not prove the forced integration gate, landing or native parity.
