# Proposal — proc-detach

Packet: `2294-dtch`.

## Why

The runtime runs every `proc.run` and `proc.spawn` child as the leader of its
own process group, and reaps that group (TERM, then KILL) the moment the
leader exits. That ends every descendant a check leaves behind, which is
right for an ordinary call. But it makes one question unanswerable from Lua:
"did the subject leave a process behind?" The runner kills the leak before the
fixture can look for it, so every such arm passes on a subject that leaks.

Measured on darwin, 2026-11-24:

- `test-fleet-run` arm 10 ("the step's child is killed with it") stayed green
  on a fleet-run mutant that runs its step with `group=false` and leaks the
  step's child. It went red only once the test's own call stopped reaping.
- A `.sh`→`.lua` port of `test-macos-vz-orphan-diagnosis` read `ok:4` on a stub
  helper that outlives a SIGKILLed tray, a mutant the `.sh` reds. A bare
  `setsid` does not escape the reap: the new group's id is the leader's own
  pid, which is the group the runner kills.

Separately, the `group()` doc comment in `tillandsias-exec` said "only the
timeout path kills the group", which is not what the code did.

## What Changes

- `tillandsias_exec::Command::detach(bool)`: a grouped run whose leader exits,
  by itself or by a signal from outside, does not reap its group. The
  deadline, a cancel (`:kill()`) and the scope close still kill the whole
  group. The managed scope refuses `detach` without `group`.
- Lua: `detach = true` on `proc.run{}` and `proc.spawn{}`. It must be a
  boolean, and `group = false` with `detach = true` raises.
- The `group()` doc comment is corrected.
- `test-fleet-run`'s arm-10 call uses `detach`. It is green on the real
  fleet-run and red on the leaking mutant.

## Impact

- Unix only. On Windows the job object (KILL_ON_JOB_CLOSE) still ends every
  descendant when the run's handle drops, so `detach` changes nothing there,
  and arm 10 on native Windows stays as it was.
- A detached run's leftovers outlive the run. The caller owns killing them.
