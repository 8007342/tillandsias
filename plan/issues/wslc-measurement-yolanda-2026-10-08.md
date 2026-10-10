# WSLC on the Windows fleet host — measured record (2026-10-08)

Row: 1553-gsp2 (research, measurement only; adopt nothing). Context:
`plan/issues/microsoft-mxc-learnings-2026-10-07.md` §3. Host: yolanda-windows,
Windows 11 Home 10.0.26300.9457, Git Bash.

## Verdict

**Not runnable here.** The installed WSL (2.7.13.0) is older than the 2.9.9
that MXC's `wslc` backend requires, and the WSL Container SDK is absent. The
row's rule is "if older, record that and stop", so questions 2 and 3 were not
measured. Reaching 2.9.9 means installing a pre-release WSL (`wsl --update
--pre-release`), which is a system-wide change and the operator's decision.
Nothing was installed.

## 1. `wsl --version` against 2.9.9

```
$ MSYS_NO_PATHCONV=1 wsl.exe --version
WSL version: 2.7.13.0
Kernel version: 6.18.33.2-2
WSLg version: 1.0.73.2
MSRDC version: 1.2.7214
Direct3D version: 1.611.1-81528511
DXCore version: 10.0.26100.1-240331-1435.ge-release
Windows version: 10.0.26300.9457
```

2.7.13.0 < 2.9.9: **below the requirement.**

## 2. WslcGetMissingComponents

**Could not be run.** It is an export of the WSL Container SDK
(`wslcsdk.dll`, closed source per the mxc docs). That SDK is not on this host:

```
$ find "/c/Program Files/WSL" -iname "*wslc*"
(no output)
$ where wslc
INFO: Could not find files for the given pattern(s).
$ MSYS_NO_PATHCONV=1 wsl.exe --help | grep -iE "container"
(no output; the only related flag is "--pre-release  Download a pre-release
version if available.")
```

So the component check has nothing to call. On this WSL the answer is
"everything is missing", and the only stated route to the SDK is the
pre-release WSL.

## 3. Networking questions — not measured

| Question | Answer | Why |
|---|---|---|
| Can a WSLC container reach a TCP listener on the distro loopback? | not measured | no WSLC runtime on this host (WSL 2.7.13 < 2.9.9) |
| Can two WSLC containers share an internal-only network? | not measured | same |

The mxc docs' claims (bridged all-allow or all-deny networking, no internal
networks, a loopback proxy unreachable from a container) therefore remain
**unverified doc claims** on this fleet. Together with the closed-source SDK
and the per-user named-pipe daemon, they are the reasons §3 of the research
note gives for "measure, not adopt". Nothing measured here weakens that verdict.

## To re-run (operator decision)

1. The operator approves a pre-release WSL on a Windows host. A disposable
   host is preferable to yolanda, whose `tillandsias` and `tillandsias-build`
   distros are fleet infrastructure.
2. `wsl --update --pre-release`, then `wsl --version` (expect ≥ 2.9.9).
3. Call `WslcGetMissingComponents` through the mxc `wslc` backend or a small
   SDK caller, and record its output.
4. Start a listener in a distro (`nc -l 127.0.0.1 3128`), run a WSLC container
   that connects to it, and record yes/no. Create two containers on one
   network with no default route out and test container-to-container
   reachability, recording yes/no.

## Instrument note

`wsl.exe` output is UTF-16; it reads cleanly through `tr -d '\0\r'`.
`MSYS_NO_PATHCONV=1` is needed for any `wsl.exe` argument that looks like a
path.
