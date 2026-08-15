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

### Cause 3 — the probe asserts a path the host never uses

With the wire reachable and `phase: Ready`, the readiness unit still sat in
`activating`:

```
vsock_loopback loaded: 0
socat VSOCK-CONNECT:1:42420 -> E connect(… cid:1 …): Network is unreachable
```

CID 1 is `VMADDR_CID_LOCAL` and needs the `vsock_loopback` module. The host does
not use that path — it arrives over hvsocket to the VM's own CID. So the probe
reported the control wire down *while the control wire was working*: a false
alarm about a healthy system, and the exact mirror of the defect 735-ewzp was
filed for.

Fixed and falsified by execution in all three states: module absent → loads it,
reports `bound` (exit 0); transport up with a dead port → `NOT-BOUND` (exit 1);
no loopback transport → `INDETERMINATE` (exit 2), explicitly stating it implies
nothing about host reachability.

### Correction — `VmStatusRequest: early eof` was not a defect

An earlier revision of this report listed that error as a third, undiagnosed
problem. It was transient: the guest was mid-restart when it was sampled. Held
running deliberately instead of racing WSL's idle shutdown, the reading is:

```
distro_running True   guest_version 0.4.260815.1
wire {"reachable": true, "phase": "Ready", "podman_ready": true, "error": null}
```

The `WSA_ERROR(10060)` timeout seen earlier was real and is explained by the
daemon being killed every fifteen seconds by cause 1.

## Current status of the tag

**The verdict for v0.4.260815.1 remains FAIL.** The released tray carries the
defect; nothing here changes the artifact on GitHub.

The three causes are fixed in `windows-next`, and the fix is verified by a
clean-room provision from a **rebuilt** tray (no hand edits):

```
build_commit       83d3339cb        ← the fix, not the release
guest_version      0.4.260815.1
exit_code          0
wire  {"reachable": true, "phase": "Ready", "podman_ready": true, "error": null}
```

Sequence: tray stopped → `wsl --unregister tillandsias` → rebuilt tray installed
→ `--provision` from nothing. The first in-guest sample after the distro
appeared already read `headless=active ready=active loopback=1 wire=BOUND`.
The units the tray wrote carry no `ExecStartPost` on the daemon and a
`Type=oneshot`, `Wants=` (never `Requires=`) assertion unit. The negative
control re-run on that same fresh guest still catches a dead port
(`NOT-BOUND`, exit 1), so the original 735-ewzp discrimination survives in the
shipped artifact rather than only in a fixture.

So: a tag cut from `windows-next` should pass this smoke. That is a prediction,
and it is worth exactly one re-run against the new tag — not an assumption.
756-rfdr (the unsigned installer) is independent and still open.

## What this run does not establish

The `--opencode` forge lane was never reached; it is Linux/Podman today and the
run stopped at provisioning. No claim is made about it.

Logs: `target/smoke-e2e/` (00-pre-state, 01-install-windows.log, 02-reset.log,
03-diagnose-full.json, 04-diagnose-after.txt, 05-diagnose-final.txt).
