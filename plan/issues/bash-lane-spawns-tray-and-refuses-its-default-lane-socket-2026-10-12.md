# A `--bash` lane launch spawns the tray, the tray binds the project's default-lane MCP socket, and the lane then refuses its own sibling as a live owner: the shell dies after the whole project stack is up

Date: 2026-10-12 (UTC)
Status: ready
Plan: `a-bash-lane-launch-spawns-the-tray-whose-default-lane-mcp-socket-the-lane-then-refuses-as-a-live-owner-so-the-shell-dies-after-the-whole-project-stack-is-up` (order 1630-pz77)
Release: v0.5

## Finding

MEASURED on yoga (linux-immutable, installed `tillandsias` v56.10.9.1) on
2026-10-12 while running skills/initialize-bare-metal-host §6.1 to bring the
per-project git mirror up:

```bash
TILLANDSIAS_HOST_PROJECT_ROOT=/var/home/tlatoani/claudia \
TILLANDSIAS_MIRROR_SSHD=1 TILLANDSIAS_HOST_PUSH_HOST=yoga \
  tillandsias --bash /var/home/tlatoani/claudia/tillandsias --debug
```

Before the launch no `tillandsias --tray` was running (the enclave had been
brought up by `tillandsias --ensure-enclave`, which starts no tray). The launch
log shows the project half of the stack coming up in order (`[forge-launch]
inference ready on attempt 2/60`, `git mirror seeded on attempt 1/1200`, the
RAM-only source volume created), then the shell dies:

```text
Error: runtime_unavailable: per-lane MCP listener failed: mcp socket already has a live owner; refusing to unlink: /run/user/1000/tillandsias/mcp/tillandsias-default/mcp.sock
Script terminé … [COMMAND_EXIT_CODE="1"]
```

The owner of that socket is a tray the launch itself started:

```text
$ ss -xlp | grep tillandsias-default/mcp.sock
u_str LISTEN … /run/user/1000/tillandsias/mcp/tillandsias-default/mcp.sock … users:(("tillandsias",pid=40887,fd=18))
$ ps -o pid,ppid,etime,cmd -p 40887
  40887    1257       01:12 Ssl  /var/home/tlatoani/.local/bin/tillandsias --tray
$ ls /run/user/1000/tillandsias/mcp/
se87-default  tillandsias-default  tillandsias.org-default      # all three created at launch time
```

The tray bound a `<project>-default/mcp.sock` for every project under the
project root, including the one the lane was launching. The lane's own bind
for `(tillandsias, default)` then found a live listener, and the live-owner
guard did exactly what it is for: it refused to steal the pathname.

After the error the stack stayed up with no lane open:

```text
$ scripts/check-bare-metal-host-initialized.sh
ok:bare-metal-host:yoga:enclave=up mirror=up router=up inference=up github=seeded lane=wired:til:host-push:yoga
```

so the skill's "the mirror lives only while a lane of that project is open"
is false in this regime: the tray holds it, and nothing says so.

## Code (trunk, symbols)

- `crates/tillandsias-headless/src/main.rs` — the tray-ensure helper that
  probes `control_socket_is_listening` on `control.sock` and, when nothing
  answers, spawns `current_exe()` with `--tray` under `setsid`. A lane launch
  from a host with no tray running takes this path.
- `crates/tillandsias-headless/src/main.rs` — the lane bring-up that calls
  `tray::start_mcp_socket_server_for_lane(project, instance)` AFTER the mirror,
  router, inference and bounded source volume exist, and maps any error to
  `runtime_unavailable: per-lane MCP listener failed`.
- `crates/tillandsias-headless/src/tray/mod.rs` — `start_mcp_socket_server_for_lane`:
  the `lane_listener_registry` is per-process, so a sibling PROCESS that owns
  the pathname is "a live owner" (the `AddrInUse` + `UnixStream::connect` Ok
  arm), and the refusal is correct for a foreign owner and wrong for the tray
  the launcher just spawned for itself.

Compare 1626-r4xm (lenovinha, 2026-10-12): a project OUTSIDE the root, where
the launching CLI owned the socket and every MCP call was refused as "not a
known project". This packet is the complement: a project INSIDE the root,
where the tray owns the socket and the lane refuses to start. Launch, tray and
lane do not agree on who serves `<project>-default/mcp.sock`.

## Unmeasured

- The same launch on a host whose tray was ALREADY running (the operator's
  desktop): if the tray binds every known project at start, the collision is
  the same; if it binds lazily, it is not. Second regime, not measured.
- Whether the tray's hold on the project stack is the refcounted teardown
  working as designed (a sibling launch in flight keeps the stack) or a leak.

## Exit contract

- On a host with no tray running, `tillandsias --bash <project>` (project under
  the root) brings the lane shell up and keeps it: the per-lane listener and
  the tray's default-lane listener for the same `(project, default)` key are
  one owner by design, the other defers. Pinned by a test that runs the two
  bind paths for the same key in sequence and expects no refusal.
- When the per-lane bind cannot proceed, the refusal names the owner (`--tray`,
  pid) and happens BEFORE the mirror, router, inference and source volume are
  created, or the launch degrades to a lane without a local-preview MCP with a
  WARN naming the socket. Never a dead shell behind a healthy stack.
- A launch whose shell exits non-zero leaves the substrate checker's verdict
  explained: the stack is torn down with the lane, or `lane=` names the tray
  as the holder.
