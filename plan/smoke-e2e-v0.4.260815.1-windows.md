# Published-release smoke — v0.4.260815.1 — windows — **FAIL**

Run 2026-08-15, host `Yolanda` (Windows 11 26200.9168, WSL 2.7.11.0).
Skill: `smoke-curl-install-and-test-e2e`. This is item 3 of the linux host's
queue packet 738-yw6p, which had been waiting for the tag.

**This is the evidence `scripts/promote-stable.sh` requires for the tag, and it
is a FAIL. v0.4.260815.1 must not be promoted to stable on the strength of this
run.**

## Verdict by step

| step | result |
|---|---|
| 0 — release published, assets present | pass (29 assets, prerelease) |
| 0b — installer integrity | **FAIL** → 756-rfdr |
| 1 — curl install, version pin | **pass** |
| 2 — destructive substrate reset | pass |
| 3 — fresh init / provisioning | **FAIL** → 757-4hdt + residue |

## Step 1 passed, and passed properly

```
Pinned to v0.4.260815.1
Fetching SHA256SUMS-windows...
Verifying SHA-256...
sha256: ok (324046c5c918f7a6685d40d1518068b9a5231e138f7e604a75fbd7bf70ba390a)
tillandsias-tray 0.4.260815.1 (0548ee1f2)
```

The installer pins the tag, fetches the signed sums, and verifies its payload
before extracting. The reported build commit `0548ee1f2` is exactly the tagged
commit. Nothing about the install path is broken.

## Step 0b — the installer itself has no integrity path (756-rfdr, p1)

Of 29 assets, five carry no `.cosign.bundle`. Four have a transitive path —
they are either a manifest whose entries are each signed, or they are named in
a manifest that is signed. `install-windows.ps1` is the exception: no signature,
and it appears in none of `SHA256SUMS`, `SHA256SUMS-macos`, or
`SHA256SUMS-windows`. `install.sh` and `install-macos.sh` both have their own
bundles.

README.md:62 tells Windows users to `irm … | iex` it.

Found because the smoke checked integrity *before* running the installer. Every
existing check on this path runs after, and asks whether the install worked — an
unsigned installer that installs perfectly passes all of them.

## Step 3 — provisioning never completes

```
ERROR WSL recipe provisioning failed err=wsl root sh exited exit code: 1
for: systemctl daemon-reload && systemctl enable --now podman.socket
     tillandsias-headless-fetch.service tillandsias-headless.service
```

Isolated per unit: `podman.socket` OK, `tillandsias-headless-fetch.service` OK,
`tillandsias-headless.service` FAILED.

### Cause 1 — a readiness probe that kills its subject (757-4hdt, p0, mine)

```
Process: 742 ExecStartPost=…/headless-ready.sh 42420 (code=exited, status=1/FAILURE)
Main PID: 740 (tillandsias-hea)
Active: deactivating (stop-sigterm) (Result: exit-code)
```

The daemon was healthy — bootstrapping Vault, then `building image proxy …
this may take several minutes`. The probe allows fifteen seconds. Because an
`ExecStartPost` is a control process, systemd stopped a working daemon
mid-build; `Restart=on-failure` restarted the same minutes-long work, and it
never converged. Five NOT-BOUND failures, unit still `activating`.

Shipped by me in `9138147b4` (order 735-ewzp). I verified that packet against an
already-provisioned guest where the listener binds in about a second. The probe
is only wrong on a cold boot — the state my testing never entered and a release
smoke always creates.

Fixed this cycle and verified in the live guest: same PID at t+15s through
t+480s where it previously died at 15s, with the assertion failing harmlessly
beside it. **Not yet verified end-to-end from a rebuilt installer.**

### Cause 2 — the probe depends on a module that a fresh guest lacks

On first boot `vsock_loopback` was not loaded; the daemon logged
`[tillandsias] preflight vsock_loopback missing` and continued. The probe
connects to CID 1 (`VMADDR_CID_LOCAL`), which requires that module, so the
assertion was unsatisfiable regardless of the daemon. `modprobe vsock_loopback`
made `VSOCK-CONNECT:1:42420` succeed immediately. A later boot had the module
present and the wire bound at t+15s.

Same mistake as cause 1 in a different variable: verified where the dependency
happened to already be satisfied.

### Residue — not yet diagnosed

Final reading after the guest converged internally:

```
guest_version   0.4.260815.1
wire            {"reachable": false, "error": "VmStatusRequest: early eof"}
```

The host can now read the guest's version, so the wire opens — then the guest
closes it mid-request. This is a *different* error from the
`WSA_ERROR(10060)` timeout seen while the daemon was being killed every fifteen
seconds, and it is a third problem. It has no packet yet and needs its own
investigation before this tag can pass.

## What this run does not establish

The `--opencode` forge lane was never reached; it is Linux/Podman today and the
run stopped at provisioning. No claim is made about it.

Logs: `target/smoke-e2e/` (00-pre-state, 01-install-windows.log, 02-reset.log,
03-diagnose-full.json, 04-diagnose-after.txt, 05-diagnose-final.txt).
