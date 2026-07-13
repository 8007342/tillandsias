# Forge TUI spinner burns a full CPU core while the agent waits on the provider (2026-07-12)

- class: optimization (resource burn; couples with the Windows PTY
  throughput finding but is a distinct in-container burn)
- found by: operator attended smoke (windows-bullo-fable5-20260712T1940Z),
  straggler/pressure audit during the first live Windows OpenCode session
- status: open
- trace: forge lane (OpenCode TUI), order 154 stream domain,
  plan/issues/windows-pty-chain-throughput-2026-07-12.md

## Symptom

During an in-forge /meta-orchestration cycle with the provider (BigPickle)
throttled/slow (no output for a minute+), `podman stats` showed the forge
container at **104% CPU** continuously — while the operator saw the
OpenCode progress bar "flashing slowly and choppily" through the Windows
PTY chain. The spinner/progress redraw loop consumes a full core exactly
when the agent is doing nothing but waiting on tokens; on a
memory/CPU-tight host (15.2 GB, 2.1 GB free, guest vmmem 5.9 GB) this
degrades the whole machine and the redraw itself becomes choppy through
the slow conpty<-wsl.exe<-podman-exec chain.

## Notes

- Root split TBD: opencode's own render loop vs our PTY pump amplifying
  redraws (measure per the throughput issue's plan before attributing).
- Provider-side slowness is expected periodically (order 286 budget class)
  — the UI must idle cheaply during it.

## Fix direction

Measure first (same harness as the throughput issue). If our pump:
coalesce/batch redraw writes. If opencode's loop: cap spinner FPS via
opencode config if available, or file upstream; consider surfacing
provider-throttled state instead of a hot spinner.
