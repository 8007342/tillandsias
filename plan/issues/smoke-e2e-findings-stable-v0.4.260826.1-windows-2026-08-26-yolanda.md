# Windows/WSL2 stable-channel e2e — v0.4.260826.1

## Run 2026-08-26T03:35Z→03:38Z — **PASS** (tag v0.4.260826.1, commit 341ab0010, channel `stable`)

The one-shot `SMOKE_CHANNEL=stable` run that `promote-stable.sh`'s own NEXT
records as owed after a promotion. The coordinator verified the URL layer
(`/releases/latest` resolving, assets HTTP 200); **this exercises the install
path an actual operator takes**, which is a different claim.

- **Host:** yolanda — Windows 11 26200.9168, WSL 2.7.12.0
- **Channel resolved:** `scripts/resolve-smoke-release.sh stable` → `channel:stable tag:v0.4.260826.1`
- **Install path used:** `irm .../releases/latest/download/install-windows.ps1 | iex` with
  **`TILLANDSIAS_VERSION` and `TILLANDSIAS_RELEASE_BASE` explicitly unset** — no pin,
  no override, the default operator path.

## Result

| check | result |
| --- | --- |
| stable-channel resolution | PASS — installer printed `Resolving latest release...` and selected `tillandsias-tray-0.4.260826.1-windows-x64.zip` |
| SHA-256 verification | PASS — `62cfcea5704786dbee018058b91f0eda5478cfa8dbbfd564fa2966a01aa1d2df` |
| install exit | PASS — `STABLE_INSTALL_RC=0` |
| version after install | PASS — `tillandsias-tray 0.4.260826.1 (341ab0010)` |
| post-condition health | PASS — `Status: HEALTHY (exit 0)`, `Guest health: healthy` |

**The strongest single fact here:** the SHA-256 served by the *stable* path is
**byte-identical** to the one served by the *pinned daily* path in the earlier run
(`62cfcea5…` both times). So the promotion moved a pointer and did not alter the
artifact — which is the property a promotion is supposed to have, and it is now
checked rather than assumed.

Credential store undisturbed by the install: both guest credentials remain ABSENT
(cleared during the earlier run, correctly not repopulated by an install), and
`tillandsias-vm-uuid` is still byte-identical at `4193d527…`.

## What this run does NOT cover

1. **No destructive reset.** This is a stable-channel *install* proof on a host
   already provisioned by the daily run 40 minutes earlier. `Guest wiring: SKIPPED
   (guest already at 0.4.260826.1)` — this tray injected nothing. A cold
   stable-channel provision is untested.
2. **GitHub login still untested**, for the same reason as the daily leg: it needs
   interactive device-flow auth an unattended run cannot perform.
3. **It does not re-prove the daily leg's findings** — see
   `smoke-e2e-findings-v0.4.260826.1-windows-2026-08-26-yolanda.md` for the
   destructive reset, fresh init, and the 803-49re Part A attribution. This file
   covers the stable *channel*, nothing more.

Taken together with the daily leg, the honest Windows claim is: **the promoted
artifact installs and verifies through both the pinned and the default operator
paths, is byte-identical across them, and reaches a healthy provisioned state — with
the interactive login path untested on this platform.**
