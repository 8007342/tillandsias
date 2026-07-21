# Concurrent forges are unsafe: launching one bounces the shared stack and can tear it down under a live sibling (2026-07-20)

- **Class**: enhancement (concurrency correctness) — operator-stated requirement
- **Severity**: P1 — a second forge launch kills the first; blocks the whole
  concurrent-delegation direction
- **Found**: live, 2026-07-20 attended session. Operator had an OpenCode forge
  running (clean, responsive — verifies order 306), then launched Antigravity.
  Antigravity's launch killed the OpenCode session ("stole its terminal") and
  bounced the shared stack.
- **Specs**: forge-hot-cold-split, socket-container-orchestration
- **Owner host**: linux
- **Related**: 427 (instance-scoped names — necessary, done), 428 (per-worker
  state — necessary, partial), 437 (tmpfs+clone checkout isolation — necessary,
  operator-gated). Those make each forge's OWN container safe; this packet is
  the SHARED-STACK half that is still missing.

## Operator requirement (2026-07-20)

> Any user should be able to launch concurrent forges and harnesses, even of the
> same type, even in the same project. They work on independent checkouts from
> the mirror in their own podman containers, so concurrent work should be
> supported.

This is correct and is the whole premise of the delegation ladder (prompting
OpenCode + Codex concurrently). It does not hold today.

## Observed

- OpenCode forge (`tillandsias-tillandsias-forge`) running and healthy.
- Operator launched Antigravity.
- After launch: `tillandsias-tillandsias-forge` is GONE; only
  `tillandsias-tillandsias-forge-antigravity` runs. `proxy`, `git-mirror`, and
  `inference` show "Up ~3 minutes" while `vault`/`router` show 30+ — i.e. the
  first three were RESTARTED by the launch.
- Log line: `[tillandsias] no active lane containers; cleaning project + shared
  stack for tillandsias`.
- Side effect: bouncing `tillandsias-git-tillandsias` re-ran its startup sweep
  (order 441), and BigPickle's concurrently-running cycle had its mirror bounced
  mid-flight (it survived; its push had already landed).

## Root cause — two mechanisms, one cause (no concurrency model for the shared stack)

The vault/proxy/router/git-mirror/inference stack is SHARED infrastructure, but
it is managed as if exactly one forge exists at a time.

1. **Bounce on launch.** A forge launch re-ensures the shared stack, and at
   least the git-mirror is created with `--replace` (`build_git_run_args`), so a
   second launch RESTARTS shared containers the first forge is actively using —
   dropping the first forge's mirror/proxy connections. That is the proximate
   cause of OpenCode dying.

2. **Teardown race on exit.** `cleanup_shared_stack_if_no_running_forge` (called
   from 7 forge-session exit sites) tears the shared stack down whenever a
   session exits and no lane is detected as running. `is_active_lane_container`
   correctly matches both `-forge` names, so DETECTION is fine — the defect is
   that the check is a point-in-time race with no reference count and no
   launch-in-flight lock. A sibling still in "created/installing" state (e.g.
   Antigravity downloading `agy`) is momentarily not "running", so an exiting
   sibling can tear the stack down under it.

Instance-scoped forge NAMES (order 427) let two forge CONTAINERS coexist, but
that is necessary-not-sufficient: the shared stack underneath has no such model.

## The fix (design + verifiable closure)

Give the shared stack a concurrency model:

- **Idempotent ensure, not replace.** The shared stack is ensure-if-absent-and-
  healthy: a launch must NOT `--replace` a healthy shared container another
  forge is using. `--replace` stays only for genuinely unhealthy/exited stack
  containers.
- **Reference-count the stack per project.** Track live forges for a project;
  tear the shared stack down only when the LAST forge exits AND no launch is in
  flight (a short grace window absorbs the create/install gap). A launch takes a
  reference before the teardown check can observe zero.
- **Each forge keeps its own terminal.** A launch must never reuse or kill a
  sibling's terminal window.

Verifiable closure (fixtures, fail-loud style — reproduce the break first):

1. A fixture that marks the shared stack healthy, runs the launch-time ensure
   for a second forge, and asserts the shared containers are NOT restarted
   (same container IDs before/after).
2. A fixture that simulates two lanes where one exits while the other is in a
   non-running "created" state, runs the teardown check, and asserts the shared
   stack is PRESERVED (reproduce the current teardown-under-sibling first).

## Non-goals

Do not weaken the single-forge teardown (a genuinely last-forge exit must still
clean up). Do not touch the mirror push-path invariants (orders 413/415/424).

## Live observation 2026-07-20 15:21-15:24 PDT (coordinator host)

The support stack started at 15:21 (vault, proxy, and inference) and was torn
down at 15:24. Podman recorded exit 137 for vault, exit 137 for inference, and
exit 139 for proxy. Squid itself logged the graceful sequence `Preparing for
shutdown ... Exiting normally`, so the proxy's 139 is evidence that the
entrypoint or certificate helper died on the teardown signal, not that Squid
crashed.

No `tillandsias-git` container existed at teardown time, and the persistent
mirror volume was completely empty: it contained no bare repository. This is
consistent with launch failing during checkout (see
`mirror-bare-repo-unborn-head-breaks-all-clones-2026-07-20.md`) and then taking
down the shared support stack on its exit path while no reference count or
launch-in-flight guard protected the stack. This is direct live evidence for
slice 3 of this packet's shared-stack teardown race.
