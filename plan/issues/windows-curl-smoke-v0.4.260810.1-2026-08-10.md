# Windows curl-install e2e smoke — v0.4.260810.1 (644-a3wj)

- Date: 2026-08-10 (host local 2026-08-09 21:31 PDT)
- Host: windows (windows-next), meta-orchestration cycle 7
- Packet: `644-a3wj` p0, `release_target: stable-milestone-v1`
- Release under test: `v0.4.260810.1` via the **unstable** channel
- **Verdict: PASS — all four steps, with one transient-diagnose observation**

Destructive reset was explicitly authorized by the operator for this run. Only
the `tillandsias` runtime distro was unregistered; `tillandsias-build` (the cargo
lane) was deliberately left untouched and verified intact afterwards.

## Step 0 — destructive reset: DONE

```
pre:   tillandsias-build Stopped | tillandsias Stopped | AlmaLinux-10 | Ubuntu
wsl --unregister tillandsias
post:  tillandsias-build Stopped | AlmaLinux-10 | Ubuntu          <- tillandsias gone
```

## Step 1 — UNSTABLE channel install: PASS

Ran the exact one-liner the README publishes, with `$env:TILLANDSIAS_CHANNEL='unstable'`:

```
  Channel: unstable
    !! UNSTABLE channel - newest daily build, NOT promoted to stable.
       Expect breakage. Clear TILLANDSIAS_CHANNEL for the stable build.
  Resolving latest release...
  Fetching SHA256SUMS-windows...
  Asset: tillandsias-tray-0.4.260810.1-windows-x64.zip
  Downloading .../releases/download/unstable/tillandsias-tray-0.4.260810.1-windows-x64.zip...
  Verifying SHA-256...
  sha256: ok (c0b02ae4a5eecda536b237dea83b456fb22455945e7dbd57b5b6dcda055ae3eb)
  tillandsias-tray 0.4.260810.1 (1496e89f)
```

- The UNSTABLE banner precedes every download. ✓
- Resolves `/releases/download/unstable`. ✓
- The installer's own SHA-256 matches the digest independently verified in
  `windows-unstable-channel-validation-2026-08-10.md` — two separate paths, same
  value. ✓
- Installed build commit `1496e89f` == `origin/main`. ✓

**Channel default (second half of step 1): PASS.** With the variable cleared, a
second run reported `Channel: stable`, printed **no** UNSTABLE banner, resolved
`/releases/latest/download`, and installed `tillandsias-tray-0.4.260809.2`
(`c3b5b633`) — `latest` is still the older release because `v0.4.260810.1` is a
pre-release. The host was then restored to the unstable build; final state is
`0.4.260810.1 (1496e89f)`.

Incidental: the installer backs up the previous install to `Tillandsias.bak`
before extracting, so the downgrade/restore round-trip was non-destructive.

## Step 2 — portable EXE standalone: PASS. **The 621-2re2 question is answered: NOT a defect.**

`624-su5r` asked whether the unversioned `tillandsias-tray.exe` alias — a primary
landing-page download — is usable standalone, and flagged that a bare exe needing
sibling files from the zip would be a real defect. It had never been executed.

Downloaded the alias into an isolated directory containing **nothing else**:

```
dir contents: tillandsias-tray.exe        (sole file)
--version    -> tillandsias-tray 0.4.260810.1 (1496e89f)      exit 0
--diagnose   -> Status: HEALTHY (exit 0)
                Install path: …\Temp\bare-exe-test\tillandsias-tray.exe
                Distro `tillandsias`: registered ✓, running
                Control wire: REACHABLE, phase=Ready, podman_ready=true
```

It runs with no installer, no unzip, and no sibling files, and correctly reports
its own path rather than the installed copy's. **The alias is usable standalone.**

Scope note, stated plainly: this establishes the binary is self-contained and its
CLI surface works. It does **not** cover the GUI observations
(`tray icon appears`, `no flashing consoles`) — those need a human at the desktop
and remain in `646-qde5`.

## Step 3 — checksum integrity (623-iwq4 field regression check): PASS

Verified in the field on the platform that consumes them, all three channels:

```
latest (v0.4.260809.2)     293 bytes, 3 lines, every line newline-terminated, 3/3 OK
v0.4.260810.1              293 bytes, 3 lines, every line newline-terminated, 3/3 OK
unstable (= v0.4.260810.1) 293 bytes, 3 lines, every line newline-terminated, 3/3 OK
```

Framing was checked with `cat -A`, because `623-iwq4` was precisely a missing
trailing newline merging lines — a plain read does not show it. The alias zip and
the versioned zip share a digest, so the alias is a true copy, not a re-zip.

Additionally, the installer performed its own independent SHA-256 verification
during step 1 and reported `sha256: ok`. The regression has not recurred.

## Step 4 — launch to a working tray: PASS

```
provisioning phase  🔵 Setting up Fedora Linux…
provisioning phase  🔵 Downloading Fedora rootfs…
provisioning phase  🔵 Installing Tillandsias…
guest root headroom OK: 954 GiB available
forge user + /home/forge/src ownership ensured (order 326)
Injecting embedded tillandsias-headless binary arch=x86_64
provisioning phase  🔵 Starting Fedora Linux…
WSL start poke succeeded
VM ready — control wire established
```

- `tillandsias` distro re-created from nothing and **Running**. ✓
- Tray process alive (pid 20056). ✓
- `wsl -d tillandsias --exec true` exits 0. ✓
- `--diagnose`: **HEALTHY (exit 0)**, control wire REACHABLE, `phase=Ready`,
  `podman_ready=true`, guest health healthy. ✓

Full destroy → curl-install → re-provision → healthy took roughly 70 seconds.

## Observation: `--diagnose` reports DEGRADED transiently right after provisioning

The first `--diagnose`, run immediately after the installer returned, reported:

```
Control wire: unreachable (hvsocket AF_HYPERV connect to WSL VM (vsock 42420)
              failed: WSA_ERROR(10060))
Status: DEGRADED (exit 2)
```

The log shows why — the check landed in the gap between
`04:32:12 provisioning phase "🔵 Connecting…"` and `04:32:20 VM ready — control
wire established`, about **8 seconds**. A re-run reported HEALTHY.

Not a product defect: the tray was still converging and said so accurately. But
it is a live trap for automation, and this smoke walked straight into it. Any
scripted post-install check that runs `--diagnose` once and branches on the exit
code will intermittently conclude the install is broken — the same
false-terminal-state shape this lane spent the session fixing in
`select-work-batch.sh`. Filed as `647-*` (low priority): either have `--diagnose`
wait briefly for a converging control wire, or give the transient state its own
exit code distinct from a genuine failure.

## Summary

| Step | Result |
|---|---|
| 0 destructive reset | done, `tillandsias-build` preserved |
| 1 UNSTABLE channel + default | **PASS** (banner precedes download; default resolves latest) |
| 2 portable EXE standalone | **PASS** — not a 621-2re2 defect |
| 3 checksum integrity | **PASS** — 623-iwq4 has not recurred |
| 4 launch to working tray | **PASS** — HEALTHY, ~70s from nothing |

No FAIL to file. One automation-hazard observation filed separately. GUI-visual
confirmation remains open in `646-qde5`.
