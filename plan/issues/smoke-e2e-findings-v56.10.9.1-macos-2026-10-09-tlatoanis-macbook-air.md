# Smoke e2e findings — v56.10.9.1 — macOS (tlatoanis-macbook-air) — 2026-10-09

Reported by macbookair-macos to the macuahuitl coordinator; relayed in substance.

**Verdict: S1 curl-install PASS on v56.10.9.1 for version, signature and no prompts.** Known gaps are named and scheduled; none is a regression from stable v56.9.27.2.

- Preconditions: the release lists v56.10.9.1; run 37955810598 succeeded on 3/3 jobs; SHA256SUMS-macos verifies the tarball (76a1fad4…).
- S1: `curl …/v56.10.9.1/install-macos.sh | TILLANDSIAS_VERSION=v56.10.9.1 bash`, exit 0 (17:38:41Z→17:38:55Z). Tray 56.10.9.1 (d3e8c8729); `codesign --verify --deep --strict` ok; no prompts; VM Ready at 17:39:31Z. FAIL on two power-user lines naming TILLANDSIAS_DESTRUCTIVE_RESET_OK (install-macos.sh and the tray's reset banner), scheduled in 1437-8c6p. The documented pin form at install-macos.sh header does not pin (the env var is set on curl), also in 8c6p.
- S3 quit baseline (pre-fix baseline for 1430-rnpd): the in-VM shutdown request is never heard, so VZ requestStop runs, the guest powers off about 11.6 s later, but VZ never observes the stop. Every quit costs the 60 s drain timeout plus a force-stop (76 s). Nothing is left alive at exit+10s.
- S2 reinstall over a running tray: the handover is clean (no superseded loop) and the tray returns on 56.10.9.1. Sign-ins are lost BY CONSTRUCTION, because macOS --reset-state still clears the Keychain Vault share, so the Vault re-inits. This is the known gap 1437-8c6p (operator ruling: SOFT only), unchanged from v56.9.27.2.
- GitHub re-seed: UNMEASURED. It uncovered 1566-tkan (p1): the piped --github-login remedy would feed a token to the author-name prompt. Nothing leaked.
