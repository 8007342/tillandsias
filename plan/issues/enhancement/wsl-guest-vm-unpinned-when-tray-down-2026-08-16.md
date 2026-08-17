# WSL runtime guest terminates whenever the last host session closes if the tray is down (2026-08-16)

- class: enhancement (runtime resilience, windows substrate; fail-loud family)
- found by: windows meta-orchestration cycle 7 (windows-fable5-mo-cycle7-20260816T2320Z),
  live during the 781-6gys image rebuild + smoke evidence sequence
- status: open
- owner-attention: The Tlatoāni (windows/Yolanda)

## Symptom

With no `tillandsias-tray.exe` process on the host (verified via Get-Process,
2026-08-16 ~16:52 local), the `tillandsias` runtime distro terminates seconds
after the last `wsl.exe -d tillandsias` session closes, and boots fresh on the
next one. `last reboot` recorded boots at 16:43, 16:47 and 16:48 local — one
per probe burst — each bounce:

- killing every in-flight guest process (a detached image build died this way),
- wiping /tmp (staged scripts and logs vanished between invocations),
- recreating the enclave application-lifetime containers (vault/proxy re-ensure
  on every headless start; ~1 min of stack churn per bounce).

Earlier the guest had stayed up all day: the tray's vsock control-wire session
was the implicit VM pin. The pin is an ACCIDENT of the tray being open, not a
designed property of the runtime substrate; unattended/agent-driven work on
this host has no tray and therefore no pin.

## Mitigation used this cycle

- Host-side detached pin: `Start-Process wsl.exe -ArgumentList
  '-d','tillandsias','--','sleep','7200'` (temporary; expires!).
- Guest-side work via `systemd-run --unit=<name> ...` so it survives session
  churn (see plan/issues/optimization/wsl-runtime-guest-detached-work-systemd-run-2026-08-16.md).

## Smallest next action

Decide the designed pin: either the headless guest should keep the VM alive on
its own (WSL `wsl.conf` boot service holding a session-independent process /
`vmIdleTimeout` policy), or the tray's absence should be surfaced loudly to
lane launchers ("guest is unpinned — long work will die with your session")
instead of silently bouncing. Cross-reference: the 781-6gys evidence session,
and headless-restart-wedges-guest-podman-2026-07-12.md (restart family).
