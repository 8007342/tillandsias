# Smoke e2e findings — v56.9.12.2, Windows, yolanda, 2026-09-12

**VERDICT: PASS. Not the promotable closure — this is the WEAKER ARM.**
The distro carried prior state; no `wsl --unregister` was performed because the
operator's per-run consent was not granted, and a peer cannot supply it. The
tray and the guest are both CI-published, which is stronger than a locally built
pair, but the VM was not cold. State that plainly wherever this is cited.

## What this proves

The 1084-x8ya keying conversion works END TO END THROUGH CI on Windows. The
published tray injected the published guest and the control wire came up.

    [provision] RESULT: VM Ready — control wire up
    provision_exit=0
    seconds=38

    published guest asset (v56.9.12.2 SHA256SUMS)
      85495603d8ae36fb343566e4f8feab4511f1e46ecb1fa7abbc1edb428c798a0d
    guest injected into the distro by the CI tray
      85495603d8ae36fb343566e4f8feab4511f1e46ecb1fa7abbc1edb428c798a0d
    MATCH — 14,554,320 bytes at /usr/local/bin/tillandsias-headless

The tray's embedded digest is not directly readable out of a shipped binary, so
the pairing is evidenced two ways rather than asserted: the injected guest is
byte-identical to the published asset CI staged into the tray, and the NNpsk0
handshake succeeded, which cannot happen unless the host's derived PSK matches
the guest's. Under the old derivation these could never match — the host hashed
tillandsias-tray.exe and the guest hashed tillandsias-headless, different files
by construction.

## Sections

### §1 install — PASS
    install_exit=0
    tray=%LOCALAPPDATA%\Programs\Tillandsias\tillandsias-tray.exe
    tillandsias-tray 56.9.12.2 (8a45bd522)
Exact-tag assertion holds, and the build sha is the tag's own commit. Installed
from the release's own install-windows.ps1 with TILLANDSIAS_VERSION pinned.

### §2 substrate — PARTIAL, and this is what makes the arm weaker
No `wsl --unregister tillandsias`. Instead the guest binary inside the distro
was removed to force `GuestWiringOutcome::Reinjected` rather than
`SkippedVersionMatch` — the outcome's own doc says an absent guest triggers
injection. Before removal the distro held a locally built guest
(4434eb13cc801dde…) from the earlier comparison arm; after provisioning it holds
the published 85495603…, so re-injection demonstrably occurred and
SkippedVersionMatch cannot account for this result.

Not done, and it is the gap: a cold VM. Podman state, images, volumes and the
model cache are whatever the previous runs left.

### §3 provision — PASS
Ready in 38 s. Compare the same host earlier: the UNKEYED release pair died at
Connecting with `noise: input error` in 210 s, and a keyed but locally built
pair reached Ready in 521 s from a distro that had to rebuild more.

### §4 diagnose — run LAST, after every mutating step
    diagnose_exit=0        (runbook: 0 = registered AND wire reachable AND Ready)
    distro_registered=true
    distro_running=true
    phase=Ready
    podman_ready=true
    ready_history=observed-ready
`ready_history: observed-ready` is the field that distinguishes this from the
v56.9.12.1 failure on this host, where it read never-observed-ready.

## Method notes

Evidence directory archived BEFORE the run, per esme-windows's finding. It held
13 files from this host's earlier runs the same night, on top of 13 from
2026-09-04 archived at the start of the night. Two clearings in one night on one
host, by an agent who already knew about the trap — nothing clears that
directory and every run adds to it. Everything above is this run's own bytes in
a directory that was empty when it began.

The tray was run with `$ErrorActionPreference = 'Continue'` and `$LASTEXITCODE`
asserted explicitly, per esme-windows: under `Stop` a native command's benign
stderr line ("Failed to set locale…") becomes a terminating NativeCommandError
and aborts the block mid-provision, producing a failure that looks like a
provision failure and is not.

## What would make this promotable

A cold provision: `wsl --unregister tillandsias` first, everything else
identical. That needs the operator's consent for that run, which a coordinator
cannot grant on their behalf (the runbook says so in as many words). Until then
this arm answers "does CI-built keying work on Windows" — yes — and does not
answer "does a pristine Windows host reach Ready on this tag".
