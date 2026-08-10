# macOS curl-install e2e smoke — PUBLISHED v0.4.260810.1 (order 644-7w89)

- **Host:** Apple Silicon (M1), macOS 26 (Darwin 25.6.0)
- **Agent:** macos-tlatoanis-macbook-air-fable5-20260810t043031z (operator /loop)
- **Lease:** macos-644-7w89-20260810t0431z
- **Baseline:** same agent ran 624-q4jj's 5/5 PASS on v0.4.260809.2 ~12h earlier,
  so the regression comparison below is against a same-day, same-host baseline.

## Step 1 — unstable curl one-liner — **PASS**

```
  channel: unstable
    !! UNSTABLE channel — newest daily build, NOT promoted to stable.
  downloading https://github.com/8007342/tillandsias/releases/download/unstable/tillandsias-tray-0.4.260810.1-macos-arm64.tar.gz
  Installed: /Applications/Tillandsias.app
  verifying installed binary via --diagnose --json
  installed: version=0.1.0 pin=55c60a3b80d3
  Tray started. Look for the Tillandsias icon in the menu bar.
```

Banner precedes any download; base resolves `/releases/download/unstable/`;
SHA verified; post-install `--diagnose` gate green; exit 0.

**Improvement vs .2 (not a regression):** the shipped installer printed ZERO
Gatekeeper lines on this clean curl install — yesterday's .2 installer
over-warned (2 lines). Order 421, fixed on osx-next this morning, is live in
a published artifact same-day.

## Step 2 — version proof — **PASS (CFBundleVersion + git SHA)**

```
$ tillandsias-tray --version
tillandsias-tray 0.1.0 (git 1496e89f, built 2026-08-10T01:58:49Z)
$ plutil -p Info.plist | grep CFBundleVersion
"CFBundleVersion" => "0.4.260810.1"
```

`--version` still prints the unsynced crate version — 635-bhkb remains OPEN,
exactly as the packet anticipated; proof used CFBundleVersion (0.4.260810.1)
+ git SHA (1496e89f = the release commit).

## Step 3 — checksum integrity — **PASS**

```
88455c050c30b7cbc3dd02dc5b2f069b9b854c7d2c29b835e5a4dfca48cc1175  tillandsias-tray-0.4.260810.1-macos-arm64.tar.gz
6035cdd241a7a292dae8e1f6a5773ca5934edc9cfff44a6044b4149fec781683  Tillandsias.dmg
```

Both lines parse and verify under BOTH `sha256sum -c` and `shasum -a 256 -c`.
No 623-iwq4 merged-line signature.

## Step 4 — launch to a working tray — **PASS**

Release tray (PID live) provisioned/booted the Fedora VM;
`crashloop.state`: `ever_ready 1, last_phase ready`, no crash-loop window
tripped.

## Step 5 — forge lane /meta-orchestration — **PASS (operator-attended, tray lane)**

The operator ran a BigPickle `/meta-orchestration` through the TRAY's forge
lane on this host tonight and it completed successfully. Recorded here as
attended evidence. This is also new 635-kagg data: the wedge reproduces ONLY
in the bare exec-wire context — through the tray-attach lane the same
bring-up works — sharpening the hypothesis that the wedge is an unbounded
wait on a tray-context resource (prime suspect: the host control socket,
which the router already retries on a 60s backoff in one-shot sessions).

## Verdict summary + regression statement

| Step | v0.4.260809.2 (baseline) | v0.4.260810.1 |
|------|--------------------------|----------------|
| 1 unstable one-liner | PASS (with 421 over-warn) | PASS (over-warn GONE — 421 shipped) |
| 2 version proof | PASS via CFBundleVersion | PASS via CFBundleVersion (635-bhkb still open) |
| 3 checksums | PASS | PASS |
| 4 tray+VM | PASS | PASS |
| 5 forge lane | (n/a in .2 run) | PASS attended via tray lane |

**Nothing that passed on v0.4.260809.2 fails on v0.4.260810.1.** One
improvement shipped (421). No new packets to file from this smoke.

Host end state: the published v0.4.260810.1 tray left running (it is a
superset of the local af34d5f8 build); the prior local build preserved at
/Applications/Tillandsias.app.bak.
