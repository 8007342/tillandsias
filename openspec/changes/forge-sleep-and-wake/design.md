# Design — a forge with nothing to do pushes, exits, and is woken later (2014-slpw)

Status: **proposed, design only.** Nothing is built. For operator review.

@trace order:2014-slpw, order:2011-amqd

Harness facts were read on 2026-11-06 from official docs and source; quotes and
URLs are in the appendix below.
[unproven] marks what no official source confirms.

## 1. Session names and harness command lines

Name: `<YYYYMMDD>-<project-name>`, date in UTC from the tray's clock at first
launch. A second forge on the same project the same day appends `-2`, `-3`.
The tray keeps the map `name -> {harness, harness_session_id, forge}` in the
project's state volume, because only one harness accepts a name as an id.

| Step | Claude Code | OpenCode | Codex CLI |
|---|---|---|---|
| Launch with a name | `claude -n <name>` (`--session-id` takes UUIDs only) | `opencode run --title <name>`; id captured from `session list --format json` | No launch flag. Launch, then capture `thread_id` from the first `--json` line, or the rollout file name |
| Resume (headless) | `claude -p --resume <name> "<prompt>"` | `opencode run -s <id> "<prompt>"` | `codex exec resume <id> "<prompt>"` |
| Fresh session | plain launch (no `-c`/`-r`) | plain `opencode run` | plain `codex exec` |
| Graceful exit | SIGINT, then SIGTERM after a grace period (SIGTERM leaves an in-flight turn unfinished; session stays resumable) | SIGINT or SIGTERM cancel the session and return [exit code unproven] | SIGINT (interrupt then clean shutdown). **Never SIGTERM first**: no handler [flush unproven] |
| State to keep on a volume | `$CLAUDE_CONFIG_DIR`, with `CLAUDE_CODE_PROJECT_DIR_NAME` pinned | `~/.local/share/opencode` (also holds `auth.json`: must stay behind the host proxy rule, never copied out) | `$CODEX_HOME` [unproven that sessions follow it] |

Lookup is always by the stored id, never by "last": `claude -c` skips `-p`
sessions and `codex resume --last` skips non-interactive ones.

## 2. Block or exit: the boundary with 2011-amqd `what_next`

Operator: long waits exit. One rule, measured against the harness's own limit:

| Wait | Behaviour |
|---|---|
| Expected ≤ 10 min, and under every harness's call limit (Codex 300 s is the floor) | **Block** in `what_next` (held call with progress). Codex sessions never block longer than 240 s; they exit instead |
| Expected > 10 min, unknown, or waiting on a human / another host / a release | **Exit**: push, then the shutdown-and-wake sequence (§3) |
| Idle with an empty queue for 30 min | **Exit** (replaces 2011-amqd's graceful shutdown after 30 min idle; same number) |

So `what_next` keeps its held call only for short waits. It returns
`{action: "exit", wake_on: <condition>}` for long ones instead of holding.
The 2011-amqd spec text "held what_next calls" gets this bound in the same PR.

## 3. The shutdown-and-wake sequence

1. **Agent decides to exit.** It runs the exit check:
   - nothing unpushed: no uncommitted changes, no local commits ahead of
     the work ref's remote, no stash entries tagged to this session;
   - otherwise it **refuses** and prints each unpushed item (path, or
     `<sha> <subject>`), then commits/pushes per discipline and re-checks.
2. It writes a **wake request** to the tray: `{session_name, wake_on,
   mode: resume|fresh, reason}`. `wake_on` is one of: a time, a ledger
   event on an order, a message, a release.
3. It exits gracefully (signals per §1). The tray stops the forge
   container. Volumes are kept.
4. The tray watches `wake_on`. This is the only cold start not initiated by
   the user, and only for a forge that asked for it.
5. **Wake**: the tray recreates the forge from its image (idempotent: same
   volumes, same work ref, `git fetch` + fast-forward), then:
   - `resume`: harness resume by stored id with a short prompt naming the
     wake reason;
   - `fresh`: a new session, named the same day's name, seeded from the
     work ref and the ledger, not from the old transcript.
   The waker may override the agent's choice: a wake for an unrelated task
   is always `fresh`.

Same state either way: the repo state comes from the pushed work ref, not
the session, so resume and fresh differ only in conversational memory.

## 4. Routing a message when several forges share a project

Rule: a message names a session, or an order.
- Named session: deliver to it, waking it if asleep.
- Order only: deliver to the forge holding the claim on that order (the
  ledger has exactly one claimant); if none, to the oldest awake forge on the
  project; if none awake, wake the most recent session `fresh`.
- Delivery is exactly-once by a message id the tray records as delivered.

## 5. Who chooses work and when to wake

A local tiny model ranks `plan_next` candidates and judges `wake_on`
conditions. Low tier: CPU baseline. Mid tier: NPU/iGPU per 2014-f45n's
findings. The model only proposes; the rules in §2–4 decide.

## 6. Tests (from the exit criteria)

- Refuse to shut down with unpushed work and name it: fixture with a dirty
  tree, an unpushed commit, and a clean control.
- Resume vs fresh reach the same repo state; volumes survive: one real
  project on Linux.
- Two forges, one project: a message reaches exactly one, by §4; tested
  with a control where the rule is broken.
- Verifiable closure: a real shutdown-and-wake on a Linux host, the agent
  continuing its task.

## 7. Questions for the operator

1. Is 10 minutes the right block/exit boundary, given Codex's 300 s call limit?
2. Should the tray wake a forge for a release, or only for ledger events,
   messages and times?
3. Should the second same-day session be `-2`, or include the order?

## Appendix — harness session research (2026-11-06)


## Summary table

| Capability | Claude Code (`claude`) | OpenCode (`opencode`, repo now anomalyco/opencode) | Codex CLI (`codex`) |
|---|---|---|---|
| 1. Caller-chosen name at launch | `-n/--name "<name>"` (display name, resumable by name) [C1]. Caller-chosen ID: `--session-id <UUID>` (must be a valid UUID) [C2] | `opencode run --title "<t>"` sets a title [O2]. There is no name-based resume. Source: `-s <id>` for an id that doesn't exist creates the session with that id (`create({ id: input.session, ...})`) [O5]. Whether an arbitrary string like `20261106-tillandsias` passes id validation is [unproven] | No launch flag; the CLI reference has no `--name` [X-searched]. Naming happens in the TUI (`/new <name>`, `/rename <name>`) [X5]. Capture the id from `--json`: first event `{"type":"thread.started","thread_id":"<uuid>"}` [X3] |
| Capture auto id | `claude -p ... --output-format json \| jq -r .session_id` [C4] | `opencode session list --format json` [O3]; on error, `--format json` prints `sessionID` [O6]. Field names of the normal json events are [unproven] | `thread_id` from the `thread.started` JSONL event [X3]; also the filename `rollout-<ts>-<uuid>.jsonl` [X7] |
| 2. Resume by name/id, headless | `claude -p --resume <id\|name> "q"`; `-r` also takes the absolute `.jsonl` path [C3][C4] | `opencode run -s <id> "msg"` [O2]; by id only (`client.session.get({sessionID})`) [O5] | `codex exec resume <SESSION_ID> "prompt"` or `--last` (`--all` for any cwd) [X2]. Resuming exec by *name* is [unproven]; the docs say "by ID" |
| 2. Resume, interactive | `claude -r <id\|name>`, or `claude -r` for the picker [C3] | `opencode -s <id>` / `-c` [O1] | `codex resume <uuid\|session name>` or `--last` [X1]; `/resume` picker [X5] |
| 3. Fresh vs. last session | A new session is the default. `-c` continues the last one in the cwd. `--fork-session` gives a new id when you resume [C5] | A new session is the default. `-c` continues the last one. `--fork` with `-c`/`-s` [O1] | A new session is the default (`codex`, `codex exec`). `--last` continues. `codex fork <id>`, `/new` [X1][X5] |
| 4. Exit / signals (headless) | SIGTERM gives exit code 143. The turn in progress is left unfinished, SessionEnd hooks run, and the session stays resumable. To end the turn first, send SIGINT [C6] | SIGINT and SIGTERM abort the run: "cancels its Session and background jobs and returns" [O4]. Errors set `process.exitCode = 1` [O6]. The exit code on a signal is [unproven] | Ctrl-C (SIGINT) sends `turn/interrupt` and then shuts down cleanly [X6]. Exits 1 if any error was seen [X6]. SIGTERM has no handler in exec, so it gets the default kill; whether the rollout is flushed then is [unproven] |
| 5. On-disk state | `~/.claude/projects/<cwd-mangled>/<session-id>.jsonl`. Move it with `CLAUDE_CONFIG_DIR`, and pin the project dir name with `CLAUDE_CODE_PROJECT_DIR_NAME` [C7] | `~/.local/share/opencode/` (`opencode.db` SQLite holds sessions; also `auth.json`, `snapshot/`). `opencode db path` / `OPENCODE_DB` [O7] | `~/.codex/sessions/` (rollout `.jsonl`) and `archived_sessions/`, both under `$CODEX_HOME` [X7][X8] |
| 6. Headless mode | `-p/--print`; `--output-format text\|json\|stream-json`; works with `-c`/`-r`. `--no-session-persistence` turns persistence off [C4][C8] | `opencode run [msg]`, `--format json`, works with `-c`/`-s`/`--fork`. `--attach <url>` connects to `opencode serve` [O2] | `codex exec`, `--json`, `-o <file>`; `exec resume` works. `--ephemeral` turns persistence off [X2][X4] |

Container note: to keep sessions across recreation, mount these volumes:
- Claude Code: `$CLAUDE_CONFIG_DIR`, or `~/.claude`. Its `projects/<name>` must match the cwd, or be pinned with `CLAUDE_CODE_PROJECT_DIR_NAME`.
- OpenCode: `~/.local/share/opencode`.
- Codex: `$CODEX_HOME`, or `~/.codex`.

Claude `-c` skips `-p` sessions, but `claude -p --continue` includes them [C5]. Codex `resume --last` excludes non-interactive sessions unless you pass `--include-non-interactive` [X1].

## Citations

Claude Code (fetched with curl from https://code.claude.com/docs/en/cli-reference.md, headless.md, sessions.md):
- C1 cli-reference: "`--name`, `-n` | Set a display name for the session, shown in `/resume` and the terminal title. You can resume a named session with `claude --resume <name>`."
- C2 cli-reference: "`--session-id` | Use a specific session ID for the conversation (must be a valid UUID)"
- C3 cli-reference: "`--resume`, `-r` | Resume a specific session by ID or name, or show an interactive picker ... you can pass the absolute path to a session's `.jsonl` transcript file"
- C4 headless.md: "session_id=$(claude -p \"Start a review\" --output-format json | jq -r '.session_id')" / "claude -p \"Continue that review\" --resume \"$session_id\""
- C5 cli-reference: "`--continue`, `-c` | Load the most recent conversation in the current directory ... Skips sessions created with `claude -p` ... `claude -p --continue` includes `-p`, SDK, and `/loop` sessions"; "`--fork-session` | When resuming, create a new session ID instead of reusing the original"
- C6 headless.md "Stop a run with SIGTERM": "If you stop a `claude -p` run with SIGTERM ... Claude Code exits with code 143. Claude Code leaves the turn that was in progress unfinished ... To end the turn instead, send SIGINT"; "Claude Code then runs `SessionEnd` hooks and exits"; "When you resume the session ... leaves the interrupted turn as it is" (`CLAUDE_CODE_RESUME_INTERRUPTED_TURN=1` to continue it).
- C7 sessions.md: "Claude Code stores transcripts as JSONL at `~/.claude/projects/<project>/<session-id>.jsonl`"; "`CLAUDE_CONFIG_DIR=/srv/tenant-a CLAUDE_CODE_PROJECT_DIR_NAME=work claude` ... writes the session's transcripts to `/srv/tenant-a/projects/work/`"
- C8 cli-reference: "`--no-session-persistence` | Disable session persistence ... Print mode only"; "`--output-format` | ... (options: `text`, `json`, `stream-json`)"

OpenCode (opencode.ai/docs now serves a different, shorter "Intro" page, so the claims below are cited from the docs source at https://raw.githubusercontent.com/anomalyco/opencode/dev/packages/web/src/content/docs/{cli,troubleshooting}.mdx and the CLI source. github.com/sst/opencode redirects to anomalyco/opencode):
- O1 cli.mdx (tui flags): "`--continue` | `-c` | Continue the last session"; "`--session` | `-s` | Session ID to continue"; "`--fork` | | Fork the session when continuing (use with `--continue` or `--session`)"
- O2 cli.mdx (run flags): same -c/-s/--fork, plus "`--format` | | Format: default (formatted) or json (raw JSON events)"; "`--title` | | Title for the session (uses truncated prompt if no value provided)"; "`--attach` | | Attach to a running opencode server"
- O3 cli.mdx: "`opencode session list` ... `--format` | | Output format: table or json (table)"; also `opencode export [sessionID]` / `opencode import <file>`
- O4 packages/cli/src/run/run.ts: "/** `signal` aborts on SIGINT or SIGTERM; the run then cancels its Session and background jobs and returns. */"; packages/cli/src/commands/handlers/run.ts: "SIGINT and SIGTERM interrupt this fiber. Interruption waits for the run to cancel its Session and jobs"
- O5 packages/cli/src/session-target.ts: "const explicit = input.session ? await findSession(input.client, input.session, input.signal) : undefined" ... "if (input.session && !explicit) { if (input.fork) throw new Error(\"Session not found\"); return { session: undefined } }" ... then "client.session.create({ id: input.session, ..."
- O6 run.ts reportRunError: "process.exitCode = 1" and JSON `{type:"error", sessionID, ...}`
- O7 troubleshooting.mdx: "opencode stores session data ... at: macOS/Linux: `~/.local/share/opencode/`"; "`opencode.db` - SQLite database containing projects, sessions, and messages"; "Run `opencode db path` to find the active database. Custom `OPENCODE_DB` settings ..."

Codex CLI (fetched with curl from https://developers.openai.com/codex/cli/reference and https://developers.openai.com/codex/noninteractive, and from the openai/codex source):
- X1 reference: "codex resume Continue an interactive session by ID or resume the most recent chat ... `--include-non-interactive` ... `--last` ... SESSION_ID uuid | session name Resume the specified session."
- X2 reference: "codex exec resume [SESSION_ID] Resume an exec session by ID or add --last to continue the most recent session from the current working directory. Add --all to consider sessions from any directory. Accepts an optional follow-up prompt."
- X3 noninteractive: "When you enable --json, stdout becomes a JSON Lines (JSONL) stream ... { \"type\" : \"thread.started\" , \"thread_id\" : \"0199a213-...\" }"
- X4 reference: "--ephemeral boolean Run without persisting session rollout files to disk."; "--output-last-message, -o path Write the assistant's final message to a file."
- X5 reference: "To name the new chat as you create it, run /new bug bash"; "Type /rename <name> ... Codex updates the saved chat name"; "/resume Resume a saved chat from your session list."
- X6 codex-rs/exec/src/lib.rs: `if tokio::signal::ctrl_c().await.is_ok() { ... interrupt_tx.send(()) }` leads to a `ClientRequest::TurnInterrupt` request, then `client.shutdown()`; `if error_seen { std::process::exit(1); }`
- X7 sdk/typescript/README.md: "Threads are persisted in `~/.codex/sessions`."; codex-rs/rollout/src/recorder.rs: "~/.codex/sessions/rollout-2025-05-07T17-24-21-5973b6c0-....jsonl"
- X8 codex-rs/rollout/src/lib.rs: `pub const SESSIONS_SUBDIR: &str = "sessions"; pub const ARCHIVED_SESSIONS_SUBDIR: &str = "archived_sessions";` (both under CODEX_HOME. That they resolve under CODEX_HOME is inferred, not read from code, so [unproven])
- X-searched: the CLI reference page text has no match for `--name`, so there is no launch-time name flag.

## Unproven items
- OpenCode: whether an arbitrary `-s` id string is accepted on create (it may need an `ses_` prefix); the exit code on a signal; the field names in the normal json events.
- Codex: resuming `exec` by name; whether the rollout is flushed on SIGTERM; that the sessions dir follows `$CODEX_HOME`.
