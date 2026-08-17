# WSL runtime-guest detached work must go through systemd-run, not nohup (2026-08-16)

- class: optimization (workflow friction, windows host / WSL runtime guest)
- found by: windows meta-orchestration cycle 7 (windows-fable5-mo-cycle7-20260816T2320Z),
  live during the 781-6gys forge-image rebuild
- status: open

## What cost time

Two traps in the `tillandsias` runtime distro (systemd-enabled WSL2), each of
which silently ate a step of the 781-6gys image-rebuild sequence:

1. **`nohup ... &` does not survive the `wsl.exe` session.** A detached
   `tillandsias --init` launched via `nohup` from a `wsl.exe -d tillandsias --
   bash -ls` invocation was gone by the next probe, and its redirect log file
   was never observable from a later session. systemd-WSL tears down the
   per-connection session scope when the `wsl.exe` process exits; nohup only
   shields SIGHUP, not the cgroup kill. The working pattern (used by this
   cycle for the forge-image ensure, the warm-up lane, and both harness runs):

   ```bash
   systemd-run --unit=<name> --setenv=HOME=/root --setenv=XDG_RUNTIME_DIR=/run/user/0 \
     --working-directory=/root/src/tillandsias <command...>
   # then poll: systemctl is-active <name>; journalctl -u <name>
   ```

2. **`pgrep` does not exist in the runtime guest** (procps-ng is in the forge
   image, not the guest rootfs). A waiter loop keyed on
   `pgrep -f ... || break` exits on its FIRST iteration with a
   command-not-found masquerading as "process finished". Use
   `systemctl is-active <unit>` (after trap 1's pattern) or `ps -e` instead.

## Smallest next action

When any skill/cheatsheet documents guest-side detached work (image rebuilds,
lanes, harness runs), name the systemd-run pattern as the ONLY sanctioned
detach on the WSL runtime guest. Candidate landing spot:
`cheatsheets/` windows-guest runbook alongside the stdin-feeding rule
(guest has no /mnt/c).
