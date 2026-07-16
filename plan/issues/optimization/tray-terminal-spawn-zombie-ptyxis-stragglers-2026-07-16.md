# Tray leaks `[ptyxis] <defunct>` zombies: terminal-launcher `Child` handles are never reaped

- Date: 2026-07-16
- Class: optimization
- discovered_by: operator ("leftover ptyxis process straggling around after
  terminals close", 2026-07-16), root-caused by
  linux-tlatoani-claude-20260716T0725Z

## Observation

On the operator's Fedora Silverblue host, after tray-launched terminals close,
`ptyxis` processes straggle. Live evidence this cycle:

```
$ ps -eo pid,ppid,stat,etime,cmd | grep ptyxis
   7956    3040 Ssl  01:04:48 /usr/bin/ptyxis --gapplication-service   # resident, normal
   7967    7956 Ssl  01:04:47 /usr/libexec/ptyxis-agent --socket-fd=3  # resident, normal
  32292   30010 Z+      51:13 [ptyxis] <defunct>
  38453   30010 Z+      49:02 [ptyxis] <defunct>
  98920   30010 Z+      19:26 [ptyxis] <defunct>
 101102   30010 Z+      18:48 [ptyxis] <defunct>
 123796   30010 Z+      09:16 [ptyxis] <defunct>
 126458   30010 Z+      08:21 [ptyxis] <defunct>
```

Six `Z` (zombie) `[ptyxis] <defunct>` processes, all sharing parent **PID
30010 = `tillandsias --tray --debug`**. They are NOT the resident
`--gapplication-service` / `ptyxis-agent` (those are healthy and expected).
They are unreaped children of the tray, one per terminal launch, accumulating
over the session.

## Root cause

The tray spawns a terminal (`ptyxis --new-window -- <cmd>`) and never `wait()`s
on the returned `std::process::Child`. Rust's `Child` does **not** reap on
`Drop` (documented std behavior), so the OS keeps the exited child as a zombie
until the parent reaps it or itself exits. Ptyxis uses the GNOME **GApplication
single-instance** model: `ptyxis --new-window` is a thin client that hands the
window request to the resident `--gapplication-service` over D-Bus and then
exits within milliseconds. So the launcher child exits almost immediately —
and because nothing reaps it, every launch leaves exactly one zombie. Six
launches → six zombies. (`-e`-style terminals like `xterm`/`konsole` keep the
child alive until the window closes, so they leak a zombie at close time
instead; same defect, different timing.)

Two spawn sites, both drop the `Child` without reaping:

1. `crates/tillandsias-headless/src/tray/mod.rs:1862` — `launch_in_terminal()`
   does `child.spawn().map_err(..)?; return Ok(())`. The `Child` temporary is
   dropped at the `?`. Callers: Root maintenance shell (mod.rs:1960), GitHub
   Login (mod.rs:2341).
2. `crates/tillandsias-headless/src/main.rs:8955` — `launch_forge_agent()` does
   `match child.spawn() { Ok(_) => ... }`, discarding the `Child`. This is the
   main forge-agent / meta-orchestration terminal path and is almost certainly
   the source of most of the six zombies observed above.

Zombies hold only a PID-table slot (no memory/FDs), so the impact is low per
launch — but the tray is long-lived, so they accumulate unbounded across a
session and can eventually exhaust the user PID budget. They are also exactly
the "straggling processes" the operator wants gone, and they make the process
tree noisy during teardown diagnostics.

## Smallest next action (verifiable closure — order 385)

Introduce one shared reaping helper (e.g. `spawn_detached_reaped(cmd) -> Result`)
that spawns the child and moves the `Child` into a detached thread which calls
`.wait()`, so the child is reaped whenever it exits (immediately for Ptyxis
GApplication clients; at window-close for `-e`-style terminals). Route BOTH
launch sites through it. Verify with:

- a **behavioral** unit test: spawn a fast-exiting process (`/bin/true` or
  `sh -c 'exit 0'`) through the helper, join the reaper, assert the child was
  reaped (exit status observed; no `ECHILD`-after-leak) — mirrors the house
  style of `inference_run_args_use_replace_for_idempotency`; and
- a **source-shape** guard asserting neither `launch_in_terminal` nor
  `launch_forge_agent` calls `.spawn()` without routing through the reaper (the
  repo already uses source-introspection guards, e.g. tray/mod.rs:4512).

## Secondary: container-teardown straggler audit (order 386)

The operator framed this as "when we terminate containers." The confirmed
defect above is at terminal-*spawn* time, but the general invariant they want is
"tearing down the stack leaves no straggling host processes." Terminals opened
*into* a container (`podman exec … ptyxis` — e.g. the live `podman exec … tools
… btop` session PID 136375 this cycle) do not auto-close when the container is
stopped/removed, and their host-side launcher children may straggle. File an
executable regression probe that, after a full `cleanup_shared_stack…` / stack
teardown, asserts zero tray-parented zombies and zero orphaned terminal-launcher
processes — so this class of straggler fails loud instead of relying on manual
`ps` inspection.
