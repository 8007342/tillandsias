# macOS UNSTABLE-channel + stable-download validation — 2026-08-09 (order 624-q4jj)

- **Host:** Apple Silicon (M1), macOS 26 (Darwin 25.6.0), bash 3.2 host shell
- **Agent:** macos-tlatoanis-macbook-air-fable5-20260809t162731z (operator-directed v0.5 drain)
- **Lease:** macos-v05-drain-624-q4jj-20260809t1628z
- **Checkout at validation:** osx-next (VERSION 0.4.260809.2); the channel
  prologue of `scripts/install-macos.sh` (lines 20–66, the region
  `check-installer-channel.sh` extracts) is byte-identical to the shipped
  installer — the order-421 edit in this same cycle touched only the
  Gatekeeper-hint block further down.

## Step 2 — channel-resolution probes (side-effect-free) — **PASS**

Ran first (pure local). `TILLANDSIAS_RELEASE_BASE`, `TILLANDSIAS_VERSION`,
`TILLANDSIAS_CHANNEL` all unset in the probing shell.

```
$ scripts/check-installer-channel.sh scripts/install-macos.sh
base:https://github.com/8007342/tillandsias/releases/latest/download
exit=0
$ scripts/check-installer-channel.sh scripts/install-macos.sh unstable
base:https://github.com/8007342/tillandsias/releases/download/unstable
exit=0
$ scripts/check-installer-channel.sh scripts/install-macos.sh bogus
refused:unknown-channel:scripts/install-macos.sh channel=bogus
exit=1
```

All three lines exact-match the pinned grammar; the bogus channel is refused
with a non-zero exit, not silently defaulted.

## Step 3 — unstable artifact checksum integrity — **PASS**

Downloads into a scratch dir from
`https://github.com/8007342/tillandsias/releases/download/unstable/`.
The unstable channel currently serves **v0.4.260809.2**.

Raw `SHA256SUMS-macos` (exactly two lines, both parseable — **no 623-iwq4
merged-line signature**; every line has one 64-hex run and a bare filename):

```
cb9e69d81abfb51986b5ae1cbc8bbd0538b1c625718eb89ad1747713eb1fd992  tillandsias-tray-0.4.260809.2-macos-arm64.tar.gz
28a1ae6248534b73bf9492de4a808bac345d90f47f148aeac58d189bd82b1d24  Tillandsias.dmg
```

Verification, both verifiers (tarball name parsed from field 2 as the
installer does, not guessed):

```
$ sha256sum -c SHA256SUMS-macos          # Darwin /sbin/sha256sum
tillandsias-tray-0.4.260809.2-macos-arm64.tar.gz: OK
Tillandsias.dmg: OK
exit=0
$ shasum -a 256 -c SHA256SUMS-macos      # portable cross-check (installer's own tool)
tillandsias-tray-0.4.260809.2-macos-arm64.tar.gz: OK
Tillandsias.dmg: OK
exit=0
```

Every line parses AND verifies. The macOS artifact set has no equivalent of
the 623-iwq4 Windows defect.

## Step 1 — unstable curl one-liner — **PASS**

Ran the exact published one-liner:
`curl -fsSL .../releases/download/unstable/install-macos.sh | bash -s -- --channel unstable`

```
  channel: unstable
    !! UNSTABLE channel — newest daily build, NOT promoted to stable.
  downloading https://github.com/8007342/tillandsias/releases/download/unstable/tillandsias-tray-0.4.260809.2-macos-arm64.tar.gz
  Installed: /Applications/Tillandsias.app
  verifying installed binary via --diagnose --json
  installed: version=0.1.0 pin=55c60a3b80d3
  Launching Tillandsias (--init / VM provisioning runs automatically on first launch)...
  Tray started. Look for the Tillandsias icon in the menu bar.
```

- The UNSTABLE banner printed **before** any download ✓
- The download URL resolves `/releases/download/unstable/` (not
  `/releases/latest/download`) ✓
- SHA verified, post-install `--diagnose` gate green (manifest pin
  `55c60a3b80d3` matches), tray launched, previous app backed up to
  `Tillandsias.app.bak` ✓
- Live footnote: the shipped installer printed the Gatekeeper
  "unidentified developer / right-click Open" guidance on this cleanly
  launching curl install — exactly the order-421 over-warn fixed on
  osx-next this same cycle (commit 052d3a19).

## Step 4 — stable DMG e2e (order-455 macOS smoke for v0.4.260809.2) — **PASS**

```
$ curl -fsSLO .../releases/latest/download/Tillandsias.dmg
$ grep Tillandsias.dmg SHA256SUMS-macos-stable | sha256sum -c -
Tillandsias.dmg: OK
$ hdiutil attach Tillandsias.dmg -nobrowse -readonly    # mounts /Volumes/Tillandsias
$ ls /Volumes/Tillandsias                               # Applications (drop link) + Tillandsias.app
$ cp -R /Volumes/Tillandsias/Tillandsias.app /Applications/   # the drag-install
$ xattr -p com.apple.quarantine /Applications/Tillandsias.app
No such xattr: com.apple.quarantine                     # curl-fetched DMG => clean launch, no Gatekeeper block
$ codesign --verify /Applications/Tillandsias.app       # ok
$ open -a /Applications/Tillandsias.app
tray PID up; Virtualization.framework VM booted; guest console reached login.
```

The tray appeared and drove the VM to a booted guest (existing provisioned
substrate). **This explicitly discharges the order-455 macOS curl-install
smoke owed for the force-promoted v0.4.260809.2** (see
plan/issues/stable-promotion-v0.4.260809.2-2026-08-09.md).

## Step 5 — installed version proof — **PASS (via CFBundleVersion + git SHA)**

```
$ /Applications/Tillandsias.app/Contents/MacOS/tillandsias-tray --version
tillandsias-tray 0.1.0 (git c3b5b633, built 2026-08-09T04:36:38Z)
$ plutil -p .../Info.plist | grep CFBundleVersion
"CFBundleVersion" => "0.4.260809.2"
```

git `c3b5b633` is the release commit for the v0.4.260809.2 tag;
CFBundleVersion carries the release version — the installed app IS the
promoted stable build.

Note (pre-known, found by this cycle's research): the literal packet
expectation `--version >= 0.4.260809.2` cannot pass on ANY build —
`tillandsias-tray --version` prints `CARGO_PKG_VERSION` which is hardcoded
`0.1.0` (never synced to VERSION; the release version lands only in
Info.plist `CFBundleVersion`). Version proof below therefore uses
`CFBundleVersion` + the git SHA. Defect filed as packet
`tray-crate-version-never-synced-to-release` (order 635-bhkb).

## Verdict summary

| Step | Verdict |
|------|---------|
| 1 — unstable curl one-liner | PASS |
| 2 — channel-resolution probes | PASS |
| 3 — SHA256SUMS-macos integrity | PASS (fully green, both verifiers) |
| 4 — stable DMG e2e | PASS — discharges order-455 macOS smoke for v0.4.260809.2 |
| 5 — version proof | PASS via CFBundleVersion+SHA (defect 635-bhkb filed for --version) |

Host steady state restored afterward: locally-built tray (git af34d5f8 +
the 628-yd8f guest fix) reinstalled and relaunched.

## Sequencing note

Steps 1/4/5 replace `/Applications/Tillandsias.app` and boot the release
tray against the live VM substrate, so they ran LAST in this cycle — after
the 598-kibt M3/M6 and order-349/401 evidence that depends on the
locally-built tray and the existing guest state.
