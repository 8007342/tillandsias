# vm-layer fetch stall/retry diagnostics use eprintln — invisible from a GUI-subsystem tray (2026-07-12)

- class: optimization (observability)
- found by: windows meta-orchestration cycle (windows-bullo-fable5-20260712T1940Z),
  live cold-provision observation during the order-297 destructive e2e
- status: open
- trace: crates/tillandsias-vm-layer/src/fetch.rs (download_verified retry loop)

## Observation

During a cold Windows provision the rootfs download stalled at 22,576,890
bytes for ~4 minutes (connection lost without RST; zero established TCP
connections on the tray PID). The `download_verified` stall machinery
(CHUNK_IDLE_SECS=30 idle timeout, 5 Range-resume retries) recovered it
correctly — the partial resumed and grew past 60 MB.

But BOTH retry paths report via `eprintln!` only. The Windows release tray is
a GUI-subsystem process: stderr goes nowhere, and nothing is written to
`tray.log`. During the ~4-minute window the only operator-visible signal was
a frozen progress percentage — indistinguishable from a hang, on the exact
path a fresh install exercises first.

(The observed stall exceeding one 30s idle window suggests either multiple
consecutive timeout+backoff rounds or a slow reconnect; with no log lines
there is no way to reconstruct which — that is the gap.)

## Fix direction

Replace/augment the two `eprintln!` calls with `tracing::warn!` (the tray
already routes tracing to `tray.log`), including attempt counter, byte
offset, and delay. Optionally surface "retrying download (n/5)…" through the
existing `on_progress`/report_message channel so the tray UI shows recovery
instead of a frozen percentage.

## Repro

Cold provision; drop connectivity mid-rootfs-download for >30s; observe
recovery happens but no log evidence exists in `tray.log`.
