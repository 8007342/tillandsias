# Stable-channel promotion: v0.4.260809.2 (2026-08-09)

Classification: `research/` (release evidence record)
Order: 621-2re2 (landing-page channel work that motivated it)
Host: linux_mutable

## Operator directive

The Tlatoāni directed promotion of the 2026-08-09 daily to the stable channel so
the landing page's advertised Windows portable links resolve. Those links
(`/releases/latest/download/tillandsias-tray.exe` and
`tillandsias-windows-x64.zip`) 404 against any release cut before 621-2re2,
because the version-stable aliases did not exist; `/releases/latest` resolves to
the newest NON-prerelease, which was v0.4.260728.2.

Two candidates were put to the operator. **v0.4.260809.1 was rejected** for
promotion: it shipped a Cosign-signed, corrupt `SHA256SUMS-windows` (623-iwq4),
so promoting it would have made a broken verification path the stable one. The
operator chose to cut **v0.4.260809.2** carrying the fix and promote that.

## Promotion basis

`scripts/promote-stable.sh` correctly refused with
`refused:no-evidence:v0.4.260809.2` — no `/smoke-curl-install-and-test-e2e` PASS
names this tag. Promotion proceeded via `--force` under the operator directive
above. **This is an override, not evidence.** The order-455 cross-platform
curl-install smoke queue is still owed against this tag, exactly as it was for
v0.4.260728.2.

## What WAS verified against the published artifacts

Not a substitute for the e2e smoke; recorded so the override is not mistaken for
a blind one. All against the rolling `unstable` channel, which served the
identical v0.4.260809.2 artifact set at the time of promotion.

| Check | Result |
|---|---|
| `sha256sum -c SHA256SUMS-windows` — ALL entries, incl. both new aliases | OK (3/3) |
| Alias zip hash == versioned zip hash (byte-identical by construction) | OK (`9560ff21…`) |
| `tillandsias-linux-x86_64` against `SHA256SUMS` | OK |
| Downloaded Linux binary `--version` | `Tillandsias v0.4.260809.2` |
| `Tillandsias.dmg` against `SHA256SUMS-macos` | OK |
| Release run 31294386232, all three platform jobs | success |
| `unstable` channel carries the full three-platform set from ONE run | OK |

The Windows checksum verification is the point of this build: the same command
fails on v0.4.260809.1.

## Residual

- Order-455 curl-install e2e still owed for v0.4.260809.2 on all three hosts.
  Until it runs, the stable channel rests on artifact verification plus a green
  release run, not on an install-and-launch proof.
- v0.4.260809.1 remains published as a prerelease with its corrupt
  `SHA256SUMS-windows`. It cannot be repaired in place without invalidating its
  Cosign bundle. The README ledger row states this plainly.
