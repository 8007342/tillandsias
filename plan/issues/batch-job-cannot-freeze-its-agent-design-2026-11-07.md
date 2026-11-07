# 2019-mfrz design: a batch job cannot freeze the agent that started it

@trace order:2019-mfrz

Filed by lenovinha-silverblue (opus5), 2026-11-07. Measured on lenovinha:
Fedora 44, kernel 7.2.13, podman 5.8.9 rootless, cgroup v2 with the systemd
manager, systemd 259. The probes ran throwaway containers from
`localhost/tillandsias-forge:latest` with `--memory=1g`. No lane was launched.

## The incident, restated

A project script with 8 workers held about 11 GB of a 12 GB forge. No OOM
kill fired. The forge stalled on memory about 90% of the time for 20 minutes,
the agent looked hung, and `podman exec` timed out. Everything in the forge,
the harness included, shares one memory cgroup, so reclaim and swap stall all
of it at once.

## Options compared

| Option | Allowed on this host? | Result |
|---|---|---|
| A. A child sub-cgroup inside the forge, with `memory.max`, `memory.swap.max=0` and `memory.oom.group=1` | Yes, but only with `--systemd=always`. The default mount is `ro`. With `--security-opt unmask=/sys/fs/cgroup` the mount is `rw`, but mkdir is refused | **Works.** The whole job group was killed in 180 ms, the agent and its shell survived, and `memory.events` recorded `oom_group_kill 1` |
| B. The same sub-cgroup with `memory.high` below `memory.max` | Yes | **Reproduces the incident**: the job sat throttled at `memory.high` with PSI full avg10 = 89.9% and was never killed (the probe container was killed by hand after 3 minutes). Never use `memory.high` as the job bound |
| C. Host `systemd-oomd` | Active, but it watches only `system.slice` and `user@1000.service/app.slice` (80%, 20 s). Forge scopes are not covered, and it would kill the whole forge rather than the job | Rejected |
| D. `oom_score_adj` / rlimits per job | An unprivileged user can raise a child's score but cannot lower the agent's; `RLIMIT_AS` breaks runtimes that reserve address space (JVM, Go, node) | Rejected as the main rule |

## Recommended design (A)

1. **Launch.** Forges run with `--systemd=always` and an explicit
   `--stop-signal=SIGTERM`. Measured: `--systemd=always` alone changes the
   stop signal to 37 (SIGRTMIN+3), and the probe then took the 10 s SIGKILL
   path on `podman rm -f`. The forge's own `/tmp` tmpfs (256m) must still win
   over the tmpfs podman adds in systemd mode; verify this in the
   container_profile tests.
2. **Split, done by the tray.** Right after the start, the tray runs
   `podman exec --user 0` with a setup script (measured with
   `--userns=keep-id`):
   - create `agent/` and `jobs/`, and move every process into `agent/`;
   - enable `+memory +pids` in the root subtree;
   - give `jobs/` `memory.max` = forge max minus the agent reserve,
     `memory.swap.max=0` and `memory.oom.group=1`;
   - give `agent/` `memory.min` = the agent reserve;
   - chown only the three `cgroup.procs` files to the forge uid. Measured: the
     forge user can then move its own processes into `jobs/`, but writing
     `jobs/memory.max` is refused, so a job cannot raise its own bound.

   Measured: a later `podman exec` lands in `/agent`, so the tray can still
   reach the forge while the jobs cgroup is under pressure.
3. **Routing.** The harness process stays in `agent/`. Commands from the
   agent's tools run through a shell shim, set as the harness's SHELL or its
   tool shell, that writes `$$` to `jobs/cgroup.procs` and then execs bash. A
   `tillandsias-job -- <cmd>` wrapper does the same for an explicit job. Still
   to verify for each harness: Claude Code, OpenCode and Codex each have to
   spawn tool commands through the shim.
4. **Telling the agent.** The shim or wrapper reads `memory.events`
   `oom_group_kill` before and after the job. When the count rose, it prints
   `refused:job:memory:<used>/<max>`, naming the rule and the remedy (fewer
   workers, or a smaller batch), and exits 137.
5. **Slow thrash.** With swap off for jobs, anonymous memory cannot thrash.
   File-cache thrash still can. As a second stage, a watcher in the agent
   cgroup reads `jobs/memory.pressure` and, after full avg10 > 60% for 20 s,
   writes `1` to `jobs/cgroup.kill` and tells the agent with the same verdict
   line. This was not measured here.

## Agent reserve

Start the agent reserve at 1.5 GiB, which is enough for the harness, MCP
servers and git. Derive it in `forge_budget.rs` next to `memory_max_mib`, so
each tier sets its own value, and refuse a budget whose reserve exceeds half
the forge.

## Exit criteria mapping

- **"Agent stays responsive."** Not yet measured under real pressure. The
  fixture should time an agent-cgroup command while the jobs cgroup is at its
  max, inside a real forge launched through a lane.
- **"Job throttled or killed by a stated rule, the agent told."** Covered by
  steps 2 and 4. The 180 ms group kill is measured; the message is not built
  yet.
- **"Forge and checkout survive."** Measured for the container (pid 1 and the
  agent cgroup survive). Not yet measured for the checkout.

## Open questions for the operator

- Is `--systemd=always` acceptable for forges? It also mounts tmpfs on `/run`,
  `/run/lock` and `/var/log/journal`, and sets `container=podman`.
- Should the shim route every agent tool command into `jobs`, or only commands
  wrapped explicitly? Routing everything is safer, but an interactive
  `cargo build` then counts against the job bound too.
