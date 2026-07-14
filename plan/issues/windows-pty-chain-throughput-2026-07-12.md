# Windows attach chain: TUI refresh visibly slow — audit buffer sizes across the console↔wsl.exe↔in-VM↔container hops (2026-07-12)

- class: optimization (interactive latency/throughput; order 154 stream domain)
- found by: operator attended smoke (windows-bullo-fable5-20260712T1940Z
  session) — first live OpenCode TUI session on Windows (in-forge
  /meta-orchestration cycle running)
- status: open
- trace: order 154 (windows tray stream refactor), wsl.exe PTY bridge,
  crates/tillandsias-headless run_forge_agent_cli_mode attach path

## Observation

With the full stack finally live on Windows (elevated tray, forge lane,
OpenCode TUI driving a /meta-orchestration cycle), the operator reports the
terminal "refreshing a bit slowly" and suspects buffer limits in the
channel to the containers.

## The chain to audit

Windows Terminal (conpty) ← wsl.exe stdio bridge ← in-guest
`tillandsias-headless --cloud <p> --opencode` (run_forge_agent_cli_mode)
← podman exec/attach TTY ← forge container TUI. Candidate bottlenecks:

- read/copy buffer sizes in any of our own pumps on that path (in-guest
  attach pump; anything doing line-oriented instead of chunked copies);
- PIPE_BUF-sized writes through the wsl.exe stdio bridge;
- tillandsias-secure-channel frame-size cap (secure_stream.rs) if any hop
  rides the control wire on other platforms — compare with the macOS
  PtyOpen path's buffer sizes for parity;
- conpty overhead itself (measure to attribute honestly before tuning ours).

## Next action

Measure per-hop: generate a high-output TUI burst (e.g. `yes` / large file
cat) in (a) plain `wsl.exe -d tillandsias -- bash` (baseline, no
tillandsias code), (b) the maintenance lane, (c) an agent lane; compare
throughput to isolate which hop adds the latency, then size buffers there.
Fold into order 154's reader-task refactor if ours; file upstream/accept if
conpty-bound.
