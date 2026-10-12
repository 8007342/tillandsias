# Smoke e2e findings — v56.10.9.1 — Linux (macuahuitl) — 2026-10-09

Measured by the macuahuitl coordinator.

**Verdict: artifact PASS on v56.10.9.1.** The published Linux binary verifies and runs. The curl-install-over-a-signed-in-host leg was NOT run on this host: installing would replace the operator's local build, so that leg is UNMEASURED. The operator promoted knowing this ("Promote it to stable :D", 2026-10-09).

- `gh release download v56.10.9.1 -p tillandsias-linux-x86_64 -p SHA256SUMS`: `sha256sum -c` gives "tillandsias-linux-x86_64: OK". The file is an ELF 64-bit statically linked binary, and `--version` prints "Tillandsias v56.10.9.1".
- The same code (e3e3f31d2) passed `./build.sh --ci-full` on this host: 440 passed, 0 failed, release preflight ok. The shipped tree differs only by the test-only #268 fix and plan fragments.
- Release run 37955810598: the Linux musl job succeeded and published.
