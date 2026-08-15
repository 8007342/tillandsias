# Host hard-freeze 2026-08-10 19:28-19:30Z — forensics: wedged WSL VM start, platform-layer hang, NOT a Tillandsias fault (664-frz0)

- Date: 2026-08-10; host: windows "Yolanda"; operator hard reset required.
- Question asked: "make sure it wasn't us."

## Timeline (System log + Tillandsias Event Log + tray.log, all UTC)

| Time | Evidence | Meaning |
|---|---|---|
| 19:13:26-42Z | Hyper-V-VmSwitch 102/291 | WSL utility VM (re)started — a fresh VM boot |
| 19:23:56-19:28:20Z | Tillandsias INFO x6 | control wire NEVER connected: hvsocket connect+handshake timed out, bounded backoff attempts 4-9 |
| ~19:28:28Z | EventLog 6008 estimate | Windows' unexpected-shutdown timestamp (periodic-flush estimate) |
| 19:29:26Z | tray.log LAST line | ERROR "WSL recipe provisioning failed ... AF_HYPERV connect (vsock 42420) WSA_ERROR(10060)" — userspace still limping past the 6008 estimate |
| ~19:30Z | operator | total freeze, hard reset |
| 19:30:57Z | Kernel-Power 41 + boot | reboot after unclean shutdown |

## What is NOT in the logs (the exculpatory part)

- ZERO Resource-Exhaustion-Detector 2004 events (no commit/memory
  exhaustion — the July soak's suspect pattern is absent).
- No disk/Ntfs/storahci errors, no WHEA hardware faults, no GPU TDR
  (Display 4101), no BugCheck (hard freeze, no crash dump).
- The tray behaved CORRECTLY: bounded backoff (attempts 4-9, 30s cap),
  then a clean classified ERROR — no crash loop, no spin.

## Verdict

The Tillandsias workload was the proximate CONTEXT (a VM start whose
guest wedged before the control wire ever answered), but the failure
layer is Hyper-V/WSL2: a guest VM plus a userspace tray cannot
legitimately freeze a Windows host, and no host resource pressure was
logged. Signature: VM boots -> hvsocket never connects -> host
progressively locks over ~15 min -> total freeze. Consistent priors on
this box: WSL relay stress (dmesg "delayed stdin write failed", "No
buffer space available" telemetry errors, 2026-07-24 audit) and the
chronic Intel audio-driver warning spam running ~6x its baseline rate
during the final 30 min (DPC/interrupt distress symptom, not cause).

## Cheap hardening opportunity (the packet)

The wedged VM sat unreachable for ~15 minutes while the host sickened.
The tray already owns a bounded `wsl --shutdown` recovery
(perform_wsl_shutdown_recovery, 148a9076). Proposal: after handshake
budget exhaustion on a FRESH VM start (the 19:29:26 ERROR path), invoke
that recovery once instead of leaving a wedged utility VM running.
Unprovable whether it would have saved the host, but it is cheap,
bounded, uses an existing mechanism, and a wedged-from-boot VM has no
value alive.
