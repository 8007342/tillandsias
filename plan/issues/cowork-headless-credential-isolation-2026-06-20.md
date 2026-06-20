# Cowork Headless Runtime: Credential Isolation Defect + Feedback Packet

- branch: linux-next
- status: ready
- owner_host: any (Claude CLI client preferred — must be able to file feedback via `/bug`)
- source: meta-orchestration field incident, 2026-06-20 (Cowork scheduled-task runtime)
- pickup: This is an actionable feedback packet. Any Claude CLI worker with the
  ability to file feedback (`/bug` in Claude Code, or a GitHub issue against the
  appropriate feedback repo) should claim the `file-feedback` task, submit the
  report verbatim from the "Feedback Submission Payload" section below, then
  record a `completed` event with the submission reference (issue URL or `/bug`
  acknowledgement id).

## Summary

For roughly two days, the Tillandsias meta-orchestration loop running inside the
**Cowork scheduled-task runtime** committed work normally but could **never
push** to `origin`. Every unattended cycle silently no-op'd and accreted
unpushable commits (17 stranded before this incident was diagnosed and fixed).
The root cause is not networking, not HTTPS-vs-SSH, and not a Tillandsias bug.
It is an **incorrect isolation boundary** in the Cowork headless runtime that
inherits environment variables pointing at runtime sockets which the sandbox
does not actually provide.

## Root-Cause Analysis

The Cowork scheduled-task context runs without an interactive login session.
Concretely, observed in-sandbox:

- `/run/user/<uid>` does **not** exist (no XDG runtime dir, no rootless podman
  socket, no keyring daemon).
- Yet the inherited environment still advertises sockets *inside* that missing
  tree:
  - `DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus`
  - `SSH_AUTH_SOCK=/run/user/1000/gcr/ssh`
- `gh` stores the GitHub token in the GNOME keyring (`gh auth status` in an
  interactive shell shows `Logged in ... (keyring)`). In the headless context
  the secret-service backend cannot reach the keyring daemon over the dangling
  D-Bus socket, so `gh auth status` reports **"not logged into any GitHub
  hosts."**
- The gcr ssh-agent socket is dangling → SSH auth is dead for the same reason.
- HTTPS `git push` therefore has no credential and fails with
  `fatal: could not read Username for 'https://github.com'`.
- `git fetch` / `git ls-remote` **succeed** because reads on a public repo are
  anonymous. This is the trap: read works, so it *looks* like the network and
  HTTPS are fine, when in fact no credential channel exists at all.

### Why the isolation boundary is incorrect

1. **Leaky, lying environment.** The runtime inherits env vars
   (`DBUS_SESSION_BUS_ADDRESS`, `SSH_AUTH_SOCK`, and by extension
   `XDG_RUNTIME_DIR`) that reference filesystem objects it does not mount. The
   environment advertises capabilities the context cannot honor. A correct
   sandbox must either (a) provide the referenced sockets, or (b) **scrub the
   dangling variables** so client tools fall back to a working path instead of
   blindly dialing a dead socket. Inheriting half of a session is worse than
   inheriting none of it.

2. **Implicit dependence on ambient session state.** Authentication silently
   depends on a *user login session* (unlocked keyring + live D-Bus) being
   present. That assumption holds in interactive Cowork/terminal use and breaks
   in scheduled/headless use — even though both share `$HOME`, hostname, and
   nearly all of the environment. There is **no declared, explicit channel** to
   broker a secret into the headless context. Implicit ambient-state coupling is
   the core design error.

3. **Silent failure / observability gap.** The loop could fetch but not push,
   and nothing surfaced credential reachability. The contract "commit and push
   before exit" became unsatisfiable, but the only signal was a growing pile of
   local-only commits. The runtime should fail loud at context entry when no
   credential channel is detected.

### Why this makes the runtime extremely finicky

Because interactive and scheduled contexts differ *only* in the presence of the
login session, behavior diverges exactly where it is hardest to observe: it
works when a human tests it by hand and fails when it runs unattended. That is a
Heisenbug by construction. Hours of agent cycles were burned re-discovering and
re-logging "push blocked" instead of doing useful work — the precise
velocity-killer the meta-orchestration exit contract exists to prevent.

## The Right Way — Tillandsias as Reference Implementation

Tillandsias already models the correct posture: **capabilities are explicit,
declared, and brokered — never inherited from ambient session state.**

- **Explicit credential brokering, not keyring ambient.** Tillandsias injects
  credentials through declared channels (e.g. the GitHub login helper and Vault)
  rather than assuming an unlocked desktop keyring exists. A headless agent gets
  exactly the secrets it was granted, by a path that does not depend on a human
  having logged in.
- **Hermetic, declared environment.** The `./codex` / `./repeat` wrappers set
  repo-local defaults and do not assume a login session, so a cold-start agent
  behaves identically interactive or unattended.
- **Managed egress + network enclave.** Network reachability is an explicit
  attached capability (`tillandsias-enclave`, managed egress), not an implicit
  property of the host — the same discipline that the Cowork sandbox violates
  with its dangling `DBUS_SESSION_BUS_ADDRESS`.
- **Fail-loud contracts.** The exit contract demands a dated finding for any
  blocked state. The fix here applies that same principle to the runtime itself:
  detect a missing credential channel at start-of-cycle and halt with a clear
  operator message, instead of silently spinning.

The general rule Cowork should adopt: **a sandbox must make its environment
honest.** Either provide the socket it advertises, or remove the advertisement.
And secrets must travel through an explicit, declared broker that does not
depend on ambient desktop session state.

## Fix Applied (this incident)

Repo-local credential store that does not depend on the keyring and persists in
the mounted workspace (never tracked, so it cannot leak via a commit):

```bash
cd ~/3src/tillandsias
git config credential.helper 'store --file=.git/.gh-credentials'
printf 'https://8007342:%s@github.com\n' "$(gh auth token)" > .git/.gh-credentials
chmod 600 .git/.gh-credentials
```

Belt-and-suspenders for the scheduled runner: inject `GH_TOKEN` into the task
environment; both `git` and `gh` honor it directly and bypass the keyring.

Result: the 17 stranded commits were merged with `origin/linux-next` and pushed
(`3de6de90..4f5fd488`). Backlog drained.

### Follow-on hardening (task: `runtime-guard`)

Add a start-of-cycle guard to `skills/meta-orchestration/SKILL.md` that, before
worker drain, verifies a usable credential channel exists (any of:
`.git/.gh-credentials` present, `GH_TOKEN`/`GITHUB_TOKEN` set, or a reachable
keyring) and, if none is found, files a blocker and exits loud rather than
committing unpushable work.

## Feedback Submission Payload (file verbatim)

> **Title:** Cowork scheduled tasks silently fail `git push` — headless runtime
> inherits dangling session sockets, breaking all credential channels
>
> **Severity:** High (autonomous runs cannot persist any work; failure is silent)
>
> **Environment:** Cowork scheduled-task runtime on Linux. Interactive session
> fully authenticated (`gh auth status` green, token in keyring, HTTPS protocol).
>
> **Repro:**
> 1. Authenticate `gh` interactively (token lands in the GNOME keyring).
> 2. Run a scheduled/headless Cowork task that performs `git push` over HTTPS.
> 3. Observe: `git fetch` succeeds (anonymous public read) but `git push` fails
>    with `could not read Username for 'https://github.com'`; `gh auth status`
>    in the task reports "not logged into any GitHub hosts."
>
> **Root cause:** The headless context has no `/run/user/<uid>` (no XDG runtime
> dir, keyring daemon, or rootless podman socket), yet still inherits
> `DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus` and
> `SSH_AUTH_SOCK=/run/user/1000/gcr/ssh`. The keyring is unreachable over the
> dangling D-Bus socket, so `gh`'s secret-service backend can't read the token;
> the gcr ssh-agent socket is dangling, so SSH auth also fails. HTTPS has no
> credential; only anonymous reads work. The environment advertises capabilities
> the sandbox does not provide.
>
> **Impact:** An autonomous loop committed 17 times across ~2 days and could
> never push; every cycle re-logged "push blocked." No credential state was
> surfaced to the operator. Behavior diverges between interactive and scheduled
> contexts that share `$HOME` and hostname, making it a Heisenbug.
>
> **Recommended fixes:**
> 1. **Make the environment honest** — at context entry, either provide
>    `/run/user/<uid>` and its sockets, or scrub `DBUS_SESSION_BUS_ADDRESS`,
>    `SSH_AUTH_SOCK`, and `XDG_RUNTIME_DIR` so client tools fall back gracefully
>    instead of dialing dead sockets.
> 2. **Provide an explicit credential broker** for scheduled tasks (e.g.
>    first-class `GH_TOKEN`/credential injection) rather than implicitly relying
>    on an unlocked desktop keyring.
> 3. **Surface credential reachability** at task start and fail loud when no
>    channel exists, instead of silently accreting unpushable commits.
>
> **Reference implementation:** The Tillandsias project demonstrates the correct
> posture — credentials and runtime capabilities are explicit, declared, and
> brokered (GitHub login helper, Vault, network enclave, managed egress, hermetic
> wrappers) rather than inherited from ambient session state. Source and the full
> multi-agent meta-orchestration architecture this incident was found in:
> https://github.com/8007342/tillandsias/
>
> **Reporter:** Luis Daniel Rangel Tovar —
> https://www.linkedin.com/in/luisdanielrangeltovar/

## Tasks

- id: file-feedback
  status: completed
  submission_ref: "https://github.com/anthropics/claude-code/issues/69776"
  owner_files:
    - plan/issues/cowork-headless-credential-isolation-2026-06-20.md
  action: >
    A Claude CLI worker submits the "Feedback Submission Payload" verbatim via
    `/bug` in Claude Code and/or a GitHub issue on the appropriate Cowork
    feedback channel. Include both reference links. Record the submission
    reference as a `completed` event below.
- id: runtime-guard
  status: completed
  depends_on: []
  owner_files:
    - skills/meta-orchestration/SKILL.md
  action: >
    Add the start-of-cycle credential-channel guard described in "Follow-on
    hardening" so the loop never silently spins on missing credentials again.

## Events

- type: finding
  ts: "2026-06-20T18:55:00Z"
  agent_id: "linux-macuahuitl-opus-cowork-20260620T1855Z"
  host: "linux_mutable (Cowork)"
  note: >
    Diagnosed the dangling-session-socket credential isolation defect after the
    loop sat 17 commits ahead of origin for ~2 days. Applied the repo-local
    credential-store fix, merged origin/linux-next, and pushed
    (3de6de90..4f5fd488). Filed this packet for a Claude CLI worker to submit
    stellar, accurate feedback to Anthropic with the tillandsias reference
    implementation and reporter references attached.

- type: completed
  ts: "2026-06-20T19:15:00Z"
  agent_id: "linux-macuahuitl-opus-cowork-20260620T1908Z"
  host: "linux_mutable (Cowork)"
  note: >
    Completed the runtime-guard task. Added the start-of-cycle Credential
    Channel Guard section to skills/meta-orchestration/SKILL.md (and a pointer in
    Start Of Cycle step 2): after git fetch, the loop must confirm a usable
    credential channel — .git/.gh-credentials non-empty, GH_TOKEN/GITHUB_TOKEN
    set, or gh auth status green — before any committable work, else file a
    no-credential-channel blocker and exit loud. Notes explicitly that anonymous
    read success is not evidence of push capability. Dogfooded this cycle: the
    repo-local credential store from the 18:55Z fix is still present, the guard
    passed, and the push path is healthy. The file-feedback task remains ready —
    it is a write-to-Anthropic submission for a Claude CLI /bug worker and is out
    of scope for this unattended meta-orchestration loop.

- type: completed
  ts: "2026-06-20T19:24:18Z"
  agent_id: "linux-claude-opus48-20260620T1924Z"
  host: "linux_mutable (interactive Claude Code CLI)"
  note: >
    Completed the file-feedback task. Submitted the "Feedback Submission Payload"
    verbatim to Anthropic as a GitHub issue on the canonical Claude Code feedback
    channel: https://github.com/anthropics/claude-code/issues/69776 (title
    "Cowork scheduled tasks silently fail `git push` — headless runtime inherits
    dangling session sockets, breaking all credential channels", state OPEN,
    author 8007342). Both the tillandsias reference-implementation link and the
    reporter reference were included in the body. The `/bug` in-CLI path was not
    used because it is an interactive command, not a callable tool; the GitHub
    issue is the appropriate, verifiable feedback channel named in the task. The
    `bug` label did not attach (external reporters cannot self-assign labels on
    that repo); this is cosmetic and triage will classify it. This packet is now
    fully resolved — both file-feedback and runtime-guard are completed.
