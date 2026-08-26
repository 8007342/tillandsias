# macOS (Apple Silicon, darwin) STABLE-channel curl-install e2e — v0.4.260826.1

## Run 2026-08-26T03:36:18Z — **PASS** (stable channel, tag v0.4.260826.1, commit 341ab0010)

RESULT: PASS — promoted release 0.4.260826.1 installs through the STABLE-channel code path on macos.

- **Host**: tlatoanis-macbook-air, macOS 26.6.2, arm64, branch `osx-next`
- **Agent**: `macos-tlatoanis-macbook-air-opus5-20260826t033618z`
- **Channel**: `stable` — the one-shot the runbook prescribes immediately after `promote-stable.sh`

## Why this run exists and is not a duplicate

`promote-stable.sh`'s own NEXT records a stable-channel e2e as owed after promotion. The coordinator verified the **URL layer** — all seven `/releases/latest/download/` assets HTTP 200, stable Linux binary byte-identical to `SHA256SUMS`. **That is artifact identity, not the installer's channel resolution.** The daily run earlier tonight pinned `TILLANDSIAS_RELEASE_BASE`, which overrides channel selection entirely, so no run so far had exercised the code path a real operator takes.

**This run is UNPINNED.** No `TILLANDSIAS_RELEASE_BASE`. The installer was fetched from `/releases/latest/download/install-macos.sh` and left to resolve the channel itself — `install-macos.sh` defaults its `CHANNEL` variable to `${TILLANDSIAS_CHANNEL:-stable}`.

**Finding 3 of the daily report is exactly why this distinction cannot be checked from a log**: `install-macos.sh` prints `channel: stable` whether or not a pin is in effect, so the log is identical in both runs and cannot distinguish them. The only way to establish that the stable path resolves correctly is to run it unpinned. Now that stable is real again, that ambiguity is live rather than theoretical.

## Assertions

```
resolve stable            PASS  channel:stable tag:v0.4.260826.1  (was v0.4.260810.1 before promotion)
install exit 0            PASS  via /releases/latest/download/, NO pin
  asset resolved          PASS  .../releases/latest/download/tillandsias-tray-0.4.260826.1-macos-arm64.tar.gz
  sha256                  PASS  0701fe67d14c89776a4c53c8eef80b8340f68def813881614ae968997b0121a7
                                — byte-identical to the daily run's artifact
no ~/Applications fallback PASS
--version EXACT tag       PASS  tillandsias-tray 0.4.260826.1 (git 341ab0010, built 2026-08-26T02:43:10Z)
tray stopped              PASS  (bounded wait + verified exit, per daily finding 2)
substrate destroyed       PASS  (existed before: yes — a real clean room)
no residue                PASS
provision exit 0          PASS
image FRESH not survivor  PASS  (test -nt against a post-destruction marker)
diagnose exit 0           PASS
provisioned == true       PASS
diagnose.version == tag   PASS
```

## What this establishes beyond the daily run

The **only** variable changed is channel resolution; the artifact is byte-identical by sha256. So this isolates one thing and confirms it: **`/releases/latest` now serves the promoted release and the installer's default (unpinned) path installs it correctly on macOS.** Before promotion that path served v0.4.260810.1, sixteen days old.

## What it does NOT establish

Unchanged from the daily report, and restated because a second PASS invites a wider reading than the first:

- The VM was **provisioned but never BOOTED**. Guest-side behaviour, the control wire, vault init and the guest/tray skew check remain untested; `guest_version` is `null` for that reason.
- Step 4 (`--opencode` forge) is Linux/Podman-only.
- No codesign or notarisation verification.
- This is the same artifact as the daily run. **A second PASS on identical bytes is not independent evidence about the artifact** — it is evidence about the resolution path, which is all it claims.

No new findings. The three from the daily run stand unchanged; finding 3 is reinforced, since the stable and pinned logs are now provably indistinguishable while describing different resolutions.
