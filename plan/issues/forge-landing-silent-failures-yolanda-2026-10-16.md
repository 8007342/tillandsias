# Forge landing report: silent failures from first prompt onward (yolanda, 2026-10-16)

- **Forge:** `forge-tillandsias` on yolanda (Windows host, WSL2 guest), image 56.10.16.1
- **Agent:** Claude Code 2.1.301, Opus 5.5, session `tillandsias-87`
- **Checkout:** `linux-next@f25d7c610` at launch
- **Accelerators:** `accel_class=cpu-only`, 16 cores, 8 GB
- **Rows filed with this report:** 1746-2szd, 1746-4q34 (fragment `20261016t024647z-1746-2szd-…`); 1747-e9d6, 1747-we43, 1747-nghx, 1747-qc4d (fragment `20261016t025415z-1747-e9d6-…`). Progress note added to 1713-1dnx.
- **Requested by:** the operator ("include everything from the first prompt to the failure, so agents landing on a forge have everything running from landing") and the fleet coordinator (macuahuitl-fedora).

## What the operator asked

> start this project in dev mode in a sibling container, then open a chromium-framework browser window you can drive and load it locally

**Outcome:** BLOCKED. Neither the sibling container (`publish_local`) nor the window (`browser.open`) could be reached. No workaround was attempted: yolanda-windows asked that the VM be left untouched.

## How I found the instructions (the agent's discovery path)

This is the path a landing agent actually takes, recorded so the documentation can be judged against it.

1. **Project `CLAUDE.md`, "Bootstrap" section, loaded automatically.** It says "Ask, don't read": use the forge-plan / project-info MCP tools first.
2. **The `forge-quick-intro` skill**, invoked by me as the first action.
   - It said "Headless and headful Chrome debugging browsers are pre-installed and configured". That is false; see 1746-2szd.
   - It pointed at `.forge-startup-context.md`.
3. **`.forge-startup-context.md`.**
   - **My error:** I read only `head -60` of it. Line 148 documents `publish_local` on the `host-browser` server, and I did not see it at that point.
   - I found the same guidance a minute later by grepping for `host-browser`, which led to `~/.config/opencode/instructions/web-services.md` and `cheatsheets/web/mcp.md`.
   - The startup context is ~150+ lines of dense prose, and the browser section sits below the fold.
   - No row filed for this; it is recorded here as a discoverability note.
4. **The `spec_answer` MCP tool.** I asked "how does a forge agent start the project in dev mode in a sibling container and open a drivable chromium browser". See T+11s below.
5. **The harness's own startup notice.** "host-browser (CONNECTION_CLOSED)". That is the only reason I knew the browser tools existed and were down.
6. **`plan/issues/e2e-smoke-v56.10.15.1-windows-2026-10-15.md`**, found by grepping `plan/issues` for the socket path. It identified 1713-1dnx as the known cause.

### About "the tillandsias-plan binary was not found"

- **I never ran `tillandsias-plan` myself before it existed.** The not-found message came from the forge-plan MCP server, through `spec_answer`, at 02:41:29Z: `unsupported: the spec expert needs the tillandsias-plan binary (spec-retrieve/spec-envelope) — experts state: building(119s)`
- **Where it was:** `/home/forge/.local/bin/tillandsias-plan` (on PATH), installed at **02:42:35Z**. The lifecycle log says `experts | ready: installed … in 184s` (cold `cargo build --release`; no prebuilt artifact was cached for this lane).
- **Why it was missing at landing:** the entrypoint launches the agent (`exec | launching claude-code`) BEFORE the background expert build finishes. Claude was up at ~02:40Z, about 2.5 minutes before the binary existed.
  - That ordering is by design ("experts are OPTIONAL … never gates this session").
  - But it has two silent, **permanent** consequences, below: 1746-4q34 and 1747-e9d6. These are not transient.

## Timeline (UTC; from `/tmp/forge-lifecycle.log` and the session transcript)

### Forge start (02:39–02:40Z, before the first prompt)

**~02:39:31 — expert build starts** (02:42:35 minus 184 s).
- Line 34: `experts | building tillandsias-plan (src=7cc4031425e2…)`.

**02:39 — lane directories mounted.**
- `/run/host/tillandsias-mcp` and `/run/host/tillandsias-msg/*` were created root:root 0700. See 1713-1dnx.

**02:39–02:40 — silent failures with no surface beyond the log:**
- **Lifecycle log line 3:** `hot-paths | FAILED: cp /opt/cheatsheets-image/. -> /opt/cheatsheets/ (cp=1): cp: preserving times for '/opt/cheatsheets/.': Operation not permitted`. This is **1747-we43**.
  - It does not appear in `.forge-startup-context.md`. The agent is never told.
- **Cargo through the enclave proxy:** **97** lines of `warning: spurious network error (3 tries remaining): [16] Error in the HTTP2 framing layer` (log lines 87–183).
  - The build still succeeded, but every crate fetch retried. This is **1747-nghx**.

**02:40Z — the agent starts while the expert build is still running.**
- `.forge-startup-context.md` is written with `experts: building(53s)`, `spec_index=absent`, `embed_endpoint=unset`.
- `entrypoint | claude launching`.

**02:40 — the forge-plan MCP server starts with an empty `PLAN_BIN`.**
- `forge-plan.sh` line 508 resolves `PLAN_BIN` once, at server start, and the binary does not exist yet.
- **Embed endpoint, 1747-e9d6:** `lib-common.sh` → `resolve_embed_endpoint` runs at launch and leaves `TILLANDSIAS_EMBED_ENDPOINT` unset.
  - Its verdict is sent to `>/dev/null 2>&1`, so the log never says why.
  - Nothing retries it later.

### The first prompt (02:41:18Z onward)

**02:41:18 — the operator's prompt arrives.**

**02:41:21 — `forge-quick-intro` skill.**
- It claims Chrome is pre-installed (false; see 1746-2szd).

**02:41:25 — startup context read** (`head -60` only; see above).
- `env` shows `TILLANDSIAS_CONTROL_SOCKET=/run/host/tillandsias-mcp/mcp.sock`.

**02:41:29 — `spec_answer` → unsupported.**
- Text: `…needs the tillandsias-plan binary … experts state: building(119s)`.
- This is the honest, transient case: retry later.

**02:41:31 — the socket directory is unreadable, and there is no browser.**
- `ls -la /run/host/tillandsias-mcp/` → **Permission denied**.
- `.mcp.json` has no host-browser entry; it comes from the `~/.claude.json` overlay.
- `which chromium chromium-browser google-chrome` → none.

**02:41:42 — the connection script fails when run by hand.**
- `~/.config-overlay/mcp/host-browser.sh` with initialize + tools/list → `{"error":{"code":-32000,"message":"TILLANDSIAS_CONTROL_SOCKET does not exist"}}`.
- **Misleading text:** `[[ -e ]]` is false on EACCES, so "does not exist" is reported for a directory the agent may not traverse. The message names the wrong cause, which is why 1713-1dnx was first read as "empty dir" on macOS.

**02:41:46 — no escalation path, and the mailbox is locked too.**
- No `sudo` (by design).
- `/run/host/tillandsias-msg/{dead,inbox,outbox,receipts}` are root:root 0700.

**02:41:53 — the cause is already on file.**
- Matched to 1713-1dnx via `plan/issues/e2e-smoke-v56.10.15.1-windows-2026-10-15.md`.

**02:41:58 — no browser anywhere in the forge.**
- `/opt` has no browser, and there is no `~/.cache/ms-playwright`.
- I stopped and reported to the operator instead of working around it.

**02:42:35 — the binary arrives.**
- `experts | ready: installed /home/forge/.local/bin/tillandsias-plan … in 184s`.
- `expert-serve` started on 127.0.0.1:11436.

**02:42:35+ — the spec index is skipped, permanently for this session.**
- `[spec-index] skipped (no-embed-endpoint): TILLANDSIAS_EMBED_ENDPOINT is unset — spec_answer keeps its typed refusal (712-r5x8)`.
- The inference service at `inference:11434` was READY with `nomic-embed-text` loaded, according to the same startup context. See **1747-e9d6**.

**02:44:52 — `msg_recv {keep:true}`** → `images/default/config-overlay/mcp/forge-plan.sh: line 1207: : command not found`. This is **1746-4q34**.

**02:45:13 — `msg_status`** → same, line 1207.

**02:45:14 — `msg_send`** → same, line 1224.
- The binary had been on PATH for 2.5 minutes by then.
- `msg_capability_gap` resolves `PLAN_BIN` inside `gap="$(msg_capability_gap)"`, a subshell, so the server process never learns it.
- The capability-gap text is lost too: the subshell resolves the binary, prints no gap, and the parent then calls `""`.

**02:45:28 — the CLI works where the MCP tools fail.**
- `tillandsias-plan msg whoami` → `yolanda/tillandsias-default`.
- `msg status probe-none` → `unknown:no-such-receipt`.

**02:45:31 — but the CLI cannot write to the lane store.**
- `tillandsias-plan msg send --to yolanda/windows …` → `refused:msg:io:lane … Permission denied (os error 13)`.
- `msg recv --keep` → same.
- So fleet messaging from this forge is down at BOTH layers. Messages to peers went through the Claude Code Remote Control channel instead.

**02:45:38 — prose question refused (by design).**
- `methodology_ask "how do I file a new plan row and a progress event from a forge?"` → unsupported (no route matches).
- The deterministic routing table is by design. Noted only because a landing agent's first natural question gets a refusal.

**02:46:44 — PreToolUse policy refused an unquoted heredoc (working as intended).**
- `refused:bash-policy:unquoted-heredoc-executes-prose`.
- My heredoc contained backticked commands that WOULD have executed. The guard caught a real mistake.

**02:47 — first fragment push refused by the hook (working as intended).**
- `push-plan-fragments-to-trunk.sh` → `check-scorable-obligation-added refused (977-448j)`.
- Fixed by adding `unscoreable:` lines; landed as `194352b39`.

### Re-checks after the binary existed

**~02:51 — `spec_answer` still refuses.**
- Text: `unsupported: the spec RAG index is not built at …/spec-index … publishes no 'current' pointer`.
- This is not transient: no launch step will build it in this session.

**~02:51 — `msg_recv` still fails** with `line 1207: : command not found`. Permanent for the session.

**~02:52 — the embed probe succeeds by hand.**
- `curl -m 3 http://inference:11434/v1/models` → **200 in 29 ms**.
- `source images/default/lib-embed-endpoint.sh; resolve_embed_endpoint` → `ok:embed-endpoint:derived:http://inference:11434/v1`.
- So the endpoint was wired by nothing, but is reachable now. The launch-time probe most likely ran before inference answered; the discarded verdict means this cannot be confirmed from the log.

## Transient vs. permanent: what a landing agent saw

| Surface | At landing | After the expert build finished | Signal to the agent |
|---|---|---|---|
| `plan_answer`, `methodology_ask` | unsupported (building) | **works** | typed, honest |
| `spec_answer` | unsupported (needs binary) | **still unsupported** (no index, no embed endpoint) | the reason changes from "building" to "index not built". Nothing says it will never heal in this session. |
| `msg_recv`, `msg_status`, `msg_send` | `line 1207: : command not found` | **same, forever** | bash error text, not an envelope |
| `tillandsias-plan msg` (CLI) | binary absent | EACCES on the lane store | typed refusal |
| host-browser (`publish_local`, `browser.open`) | CONNECTION_CLOSED | same | the error text says "does not exist", but the real cause is permission denied |
| cheatsheet hot-path copy | failed | failed | lifecycle log only |
| proxy HTTP2 for cargo | 97 retries | n/a | lifecycle log only |
| browser binary in forge | absent | absent | the skill says it is present |

## Evidence: permissions and mounts (collected as uid 1000)

```
uid=1000(forge) gid=1000(forge) groups=1000(forge),0(root)
drwxr-xr-t 4 root root 4096 /run/host
drwx------ 2 root root   60 /run/host/tillandsias-mcp        (tmpfs; an empty dir would be 40)
drwxr-xr-x 6 root root 4096 /run/host/tillandsias-msg
drwx------   root root      /run/host/tillandsias-msg/{dead,inbox,outbox,receipts}
986 992 0:90 /tillandsias/mcp/tillandsias-default /run/host/tillandsias-mcp ro,nosuid,nodev,relatime - tmpfs tmpfs rw,size=813020k,nr_inodes=203255,mode=700
985 992 8:80 /root/.local/state/tillandsias/msg/lanes/tillandsias-default /run/host/tillandsias-msg rw,relatime - ext4 /dev/sdf rw,discard,errors=remount-ro,data=ordered
```

The creating process is not visible from inside the forge.

## Harness installs: Antigravity and Codex in a Claude lane (1747-qc4d)

The operator saw "Antigravity installed" in this forge's log and expected each lane to install only its own harness. The startup log confirms the install. It is not a mistake by the recent Antigravity work: it is the all-harness contract from July.

**What was installed in this lane** (`TILLANDSIAS_AGENT=claude`):

| Harness | Channel | Size | When (UTC) | Log line |
|---|---|---|---|---|
| Claude Code 2.1.301 | curl installer | — | 02:39:33 | `harness \| claude curl-install OK` (377) |
| Codex (`@openai/codex@latest`) | npm, background | **411 MB** | 02:40:10 | none (silent on success) |
| openspec | npm | 18 MB | 02:40:23 | 385, 610 |
| Antigravity `agy` 1.3.6 | `antigravity.google/cli/install.sh` | **208 MB** | 02:40:17 | `tools \| agy install attempt 1/3` … `installed successfully` (643–655) |

**Why every lane installs every harness:**
- `entrypoint-forge-claude.sh` backgrounds `ensure_forge_harnesses` (the "EVERY_LAUNCH agent harness update" block).
- That function refreshes Claude, then npm `@openai/codex@latest`, then calls `require_antigravity`.
- It has no `TILLANDSIAS_AGENT` check.
- Source: ef9520dc8 (2026-07-21, order 181), whose comment says "the launch contract is that every ephemeral forge launch attempts to refresh all harnesses".

**Measured cost in this lane:**
- About 620 MB of downloads for harnesses the lane never runs.
- The npm update lock was held, and the foreground path logged `openspec not visible while updater lock held — waiting for sibling npm update` and then `appeared after 18s`.
- These downloads overlapped the cold expert build and its 97 HTTP2 framing retries (1747-nghx). Contention is possible; unconfirmed.

**Antigravity failing to start (operator report):**
- In this forge, `~/.local/bin/agy --version` → `1.3.6`, rc=0, so the binary installs and runs here.
- I did not launch an Antigravity lane and could not reproduce the start failure.
- The most recent lane-launch change is cbf2b396c (2026-10-14, "fix Antigravity lane launch, device login flow and MCP parity", 1496-x76p / 1678-62p7). That is the first place to look.
- The failure needs that lane's own `/tmp/forge-lifecycle.log` to be filed with evidence.

**Supply-chain note:**
- The Antigravity installer script is downloaded and executed on every launch of every lane, with no checksum or version pin.
- Order 307 replaced `curl | bash` with download-then-run, which removes the partial-script hazard but not the integrity one.
- Restricting it to Antigravity lanes (1747-qc4d) would also shrink this exposure.

## Other startup-log entries checked (look correct)

- `git-mirror` clone, `git-identity` (github-app, tillandsia-harrisii on yolanda), seed branch `linux-next` from `.tillandsias/branch-discipline.yaml`: correct.
- `credentials | claude: OAuth document restored from vault`; MCP overlay, bypass consent and project trust seeded: correct for a Claude lane.
- `ssh | no SSH keys or agent detected`: expected; git goes through the mirror.
- `openspec | installed pinned 1.13.2` after `install | openspec: available (1.14.2)`: the project pin wins, as 1441-myz3 intends.
- `[warm] qwen2.5:0.5b loaded in 1498ms`, `expert-serve` listening on 127.0.0.1:11436: correct.
- Prebuilt cargo dev-tools, dart SDK, marksman: these are tools, not harnesses; fine.

## What "everything running from landing" needs (summary for the next run)

1. **Lane mcp/msg dirs reachable by the forge uid** (1713-1dnx Windows arm), plus the lane MCP listener in the guest binary (1713-1dnx).
2. **forge-plan msg tools resolve `PLAN_BIN` in the server process** (1746-4q34). Better still, every forge-plan tool re-resolves lazily; the plan tools already do.
3. **The embed endpoint is resolved when the spec index step runs, not only at launch, and its verdict is logged** (1747-e9d6).
4. **Silent lifecycle failures surface in `.forge-startup-context.md`** (1747-we43 shows the class): a `FAILED` line in the lifecycle log should appear as a typed line the agent reads.
5. **The `host-browser.sh` existence check distinguishes EACCES from ENOENT**, so the error names the real cause (folded into the 1713-1dnx note).
6. **The `forge-quick-intro` browser claim is corrected** (1746-2szd). It should point at `browser.open` and the opt-in Playwright cache install (1726-3mn6, f92aa2063).
8. **A lane installs only its own harness**, pending an operator ruling (1747-qc4d). That saves about 620 MB and an 18 s lock wait on a Claude lane.
7. **The proxy/cargo HTTP2 framing errors are understood** (1747-nghx). Today they are harmless retries that cost build time on every cold lane.
