## Cycle 2026-09-03T09:19Z — tlatoanis-macbook-air (osx-next)

989-ykks: criteria 1-4 met, released to ready for a Linux and a Windows host to
close criterion 5. Landed 24ddcaec4.

The host-tool prerequisites were prose a human maintained and were wrong twice
in one week. The packet's hard criterion was "derived from the gate rather than
from the prose list, or it will drift the same way" — and a hardcoded list in a
script is prose in a different file. So: every required entry names a PROVER, a
check that fails without the tool, and the fixture runs it under constructed
absence. An entry that is not really required goes red. Entries with no cheap
prover are counted and reported as unverified rather than assumed.

TWO ERRORS I MADE, both worth more than the script.

My first isolation technique PROVED NOTHING. I hid tools with a non-executable
shim in a PATH prefix; command -v skips a non-executable entry and finds the
real binary further along, so nothing was hidden. It produced "jq is not
required" — a result shaped exactly like a measurement and worthless. Killed the
run, discarded every result. Sound isolation is a symlink farm used as the whole
PATH. The fixture now asserts the farm REALLY hides the tool, so the
constructed-absence arm cannot pass vacuously — a negative control on the
control, which exists only because I got it wrong.

I also nearly mis-reported coreutils: my single-tool shim for `timeout` left
`gtimeout` in place and 988-7kxf's fallback found it, so the guard passed and I
briefly doubted a requirement I had already confirmed by a different route. The
requirement is coreutils, not one binary name.

jq is deliberately not in the required set and that is measured: with jq hidden,
the credential guard and the long-running view both still pass, preferring the
compiled plan binary. My first draft listed it.

Criterion 5 is partial and the packet says so — the script is platform-aware but
every entry was verified on macOS. Not closeable on this host's say-so.

Gate green (190s). land-on-platform-branch.sh landed first attempt now that
991-85bh made it merge-aware.
