# FORGE_DIAGNOSTICS — tillandsias, 2026-10-25 (opencode-web)

Field report written from inside the forge, per `methodology/forge-diagnostics.yaml`.
Machine-shaped fields are at the top; narrative below. No host permissions,
mounts, credentials or isolation boundaries are requested anywhere in this
document — every proposal is an in-container or in-image change.

| field | value |
|---|---|
| diagnostics_timestamp | 2026-10-25T23:15Z (container started 06:10Z; session 22:39Z–23:15Z) |
| forge host / container | `macuahuitl` / `forge-tillandsia` |
| project | `tillandsias` (`TILLANDSIAS_PROJECT=tillandsias`) |
| agent | OpenCode 1.19.4, `opencode-web` profile, model `opencode/big-pickle` |
| forge version | `VERSION=56.10.20.1`, `git describe` = `stable-267-g20960e4c2` |
| toolchain seen | node v22.23.1, python 3.14.8, rustc 1.99.0, go 1.26.10, openjdk 25.0.4.1, dart 3.13.5, Flutter via host shim |
| task | "start a sibling container and load [observatorium/] locally in a dev browser" |
| outcome | **not possible in this launch**: `host-browser` MCP failed at agent start |

## 1. Capability verdict

| capability | verdict | evidence |
|---|---|---|
| git clone / commit / push via enclave mirror | **ok** | 2 successful pushes to `linux-next` (4 attempts, 2 policy refusals), relay reported `Atomic push ... succeeded`; no host credentials |
| plan ledger CLI (`tillandsias-plan`) | **ok, with sharp edges** | `check` = `ok: 1975 packets`; `append-event`, `next-order`, `status` all worked |
| pre-push discipline hooks | **ok — best-in-class messages** | each refusal named the exact remedy (see §3.3) |
| `forge-plan` / `project-info` / `git-tools` MCP | **ok** | tool list populated; `plan_answer`, `read_file`, `git_status` used throughout |
| grounded experts (`expert-serve` :11436) | **ok** | listening on `127.0.0.1:11436` |
| `tellme` / cheatsheet discovery | **degraded** | `/opt/cheatsheets` is an **empty directory**; only a fallback index answered |
| **`host-browser` MCP (`publish_local`, `browser.open`, `service_*`)** | **FAILED** | see §4.1 |
| **Flutter toolchain** | **FAILED** | same socket; shim exits 69 (§4.2) |
| **in-forge `.localhost` self-test** | **FAILED** | Squid 502 / no resolver (§4.3) |
| in-container browser fallback | **absent by design** | no chromium/playwright browsers; `PLAYWRIGHT_BROWSERS_PATH` points at a missing dir |
| podman/docker inside forge | **absent by design** (correct) | no binary; sibling containers are host-managed only |
| AutoApproval toggle in TUI | **present but disabled** | operator could not enable it (§5) |

`missing_tools`: the four `host-browser` tools were **configured and enabled**
but not registered for the session:
`publish_local`, `service_status`, `service_reload`, `service_stop`,
`service_logs`, `browser.open`, `browser.*`, `cloudflare.*`.
`isolation_or_privacy_risks`: none added by this report.
`proposed_enhancements`: §6 (ranked).

## 2. What worked out of the box

1. **Bootstrap context answered most "where am I" questions.** `.forge-startup-context.md`
   (248 lines) plus the injected instruction set (`web-services.md`,
   `cache-discipline.md`, `nix-first.md`, …) correctly told me the sanctioned
   publish flow *before* I broke anything. `web-services.md` is genuinely
   excellent: it names the tools, the args, the URL convention, the ports per
   framework, and the three things not to do. I did not have to guess.
2. **Discovery scripts are the right idea.** `tillandsias-services` prints the
   enclave catalogue with live `nc -z` status and explicitly labels the router
   as `host-only`. `tillandsias-help`, `tillandsias-inventory`,
   `tillandsias-models`, `tellme` all executable and documented in-place via
   `sed -n '2,9p' "$0"`.
3. **Git push just works and needs no configuration.** `git push origin HEAD:linux-next`
   routes through the enclave mirror, which relays atomically to GitHub and says
   so: `[relay] Atomic push ... succeeded` / `[pre-receive] Relay verified`.
   Nothing about credentials, tokens or remote URLs had to be touched. This is
   the single most valuable property of the forge and it held under repeated use.
4. **Pre-push hooks teach the discipline instead of just refusing.** Three
   separate refusals each contained the exact command to run, a `why:`, and a
   `remedy:` (§3.3). I never had to read a hook source to get through.
5. **`tillandsias-plan check` is fast** (<1s) and its output is a one-line
   verdict plus typed `parked-block:` rows. Cheap enough to run before every push.
6. **`append-event` produces a correctly-shaped fragment** by itself, including
   the immutability header and the "events go to the OVERLAY" rationale.
7. **The fleet rules in the checkout are enforced at push time, not by trust.**
   `scripts/check-forge-findings-persisted.sh` and the pre-push lane mean an
   unpushed finding is caught mechanically. That rule saved this report: the
   first version of my diagnosis was wrong and is now corrected in the ledger
   (§7) rather than lost with the tmpfs.
8. **Durable caches are in the right place.** `CARGO_HOME`, `npm_config_cache`,
   `GOPATH`, `PIP_CACHE_DIR`, `PUB_CACHE`, `GRADLE_USER_HOME` all under
   `/home/forge/.cache/tillandsias-project` (189 GB free) while `/home/forge/src`
   is a 1.5 GB tmpfs. Correct split; nothing needed to be moved by hand.
9. **OpenSpec notices are advisory and say so** (`OpenSpec: 7 notice(s) — not
   blocking commit`). They never blocked work and never pretended to.
10. **Auth-free, offline-capable inference and grounded experts are up.**
    Verified in-session: `curl http://inference:11434/api/version` →
    `{"version":"0.34.0"}`; `curl http://127.0.0.1:11436/v1/models` lists the
    five retrieval domains (`all`, `spec`, `code`, …). Neither needed external
    network or credentials.

## 3. What took figuring out

Ordered by the number of tool calls it cost me. All of these are *learnable* —
the point is that each is a place where a forge-resident agent spends its
budget on infrastructure archaeology instead of the user's task.

### 3.1 "The tool the docs name is not in my tool list" — 12+ calls (the expensive one)

`web-services.md` says to call `publish_local`; my session had no such tool.
The actual cause was **seven files away**: a generated OpenCode config
(`~/.config/opencode/config.json`) declares `mcp.host-browser`, and OpenCode's
own log (`~/.local/share/opencode/log/opencode.log`) records, at container
start:

```
level=WARN message="server unavailable" key=host-browser type=local status=failed
```

A session-scoped, one-line, machine-readable statement that this forge cannot
publish or open a browser. It exists — but only outside the checkout, behind
permission prompts (§5), in a log an agent has no reason to open unless it
already suspects the answer.

**What would have collapsed this to one call:** the launch banner (or
`.forge-startup-context.md`) carrying a per-capability readiness block,
e.g. `capability: publish=failed reason=lane-socket-not-accepting remedy=...`.
The forge already knows this at 06:10:22; it just doesn't say it where the agent
is looking.

### 3.2 One dead socket has four unrelated-looking symptoms

Nobody told me these were the same fault; I had to infer it:

| symptom | looks like | actually |
|---|---|---|
| `publish_local`/`browser.open` missing | tool not shipped | MCP client failed at start |
| `flutter` exits 69 naming `/run/host/tillandsias-mcp/mcp.sock` | Flutter not installed | same host toolchain lane |
| `npm run build` fails at `flutter pub get` | project build bug | same socket |
| in-forge `curl http://opencode.<project>.localhost/` fails | router down | proxy/`.localhost` path (§4.3) |

The first three *do* name the socket, which is good. The fourth actively
misleads (see 4.3). A single `tillandsias-doctor` covering all four would be
the highest-value addition in this report (§6.1).

### 3.3 The plan-only push lane: two correct refusals, one round-trip each

Filing two packets with a new fragment took three `git push` attempts:

1. `plan-only lane: not applicable — remote base <sha> is not present locally
   (full gate required)` → the fix (fetch + rebase) is stated, but it is not an
   obvious prerequisite of "append a YAML file". **Cost:** fetch, rebase,
   retry.
2. `plan-only lane: validation FAILED — check-scorable-obligation-added refused
   (977-448j)` → "carries no scorable obligation — add a `verifiable_closure`
   naming a `litmus:<test>`, or an explicit `unscoreable: <reason>`", **and** it
   anticipated the follow-up trap in the same message: "IF THIS PACKET'S
   DELIVERABLE IS THE TEST ITSELF … use `unscoreable:
   unpinnable-until-the-guard-exists`, name the future litmus filename in it,
   and write that litmus in the same commit". Excellent message; it still
   required two edits because I did not know the vocabulary beforehand.
3. Then the push succeeded.

`tillandsias-plan append-event` additionally requires a canonical agent id
(`<platform>-<workstation>-<backend>-<utc-timestamp>`); my first attempt was
refused with the contract, the example, and the command to derive one
(`scripts/agent-identity.sh id <backend>`). One call to fix — good.

Minor: the MCP tool is `plan_status` while the CLI subcommand is `status`
(and `next` vs `next-order`). Typing the MCP name at the CLI yields a full
command list — self-healing, but it is a naming seam worth closing.

Minor: `tillandsias-plan next-order` prints ~400 lines of "READ THESE BEFORE
FILING" advisory rows and puts the token on the **last** line (`1863-mgti`),
after a line reading "A duplicate is filed by not looking, not by choosing the
wrong number." Two consecutive calls return different suffixes
(`1863-eckw`, `1863-4knc`) — correct by design (self-allocated, permanent), but
an agent can easily mistake the second token for a collision. Printing the
token first (or supporting `--quiet`/`--count N`) would remove the ambiguity.

### 3.4 Distinguishing "router is fine" from "the documented self-test is broken"

The startup context says: *"If host-browser is unreachable, check the page with
`curl -fsS http://<service>.$TILLANDSIAS_PROJECT.localhost/`"*. In this forge
that command **cannot** succeed (§4.3), so the fallback diagnostic for the
primary failure is itself broken. Isolating it required probing three paths by
hand (`no_proxy` direct, via `proxy:3128`, and directly against the router IP)
before the picture separated. A forge-resident agent will read the 502 as "the
app is down" and go looking in the app.

### 3.5 Knowing which launch mode I am in

Tray-launched and CLI-launched forges look identical from inside; the
`host-browser` failure mode differs (a tray that exits orphans the listener, a
CLI that returns orphans it too, and a client that starts too early loses the
tools permanently). I could not determine the mode, so the ledger entry has to
carry both hypotheses and I cannot say which fix the maintainers need. Exposing
`TILLANDSIAS_LAUNCH_MODE` (or writing the owner's liveness into
`.forge-startup-context.md`) would make the report unambiguous.

### 3.6 `/opt/cheatsheets` is an empty directory

`tellme` found no `INDEX.md` at the mounted path, fell back to the repo copy,
and said so (`tellme: serving repo-local cheatsheets ...`). Filtered listing
returned essentially nothing useful (`tellme about --list | grep -Ei …` → one
line, `web`), so I went back to `grep -rl` over the checkout. The sanctioned
discovery path was unusable in a forge that otherwise ships good discovery
tooling.

**This one is already known:** packet `1870-imye`
("tellme prints requested dir /opt/cheatsheets lacks INDEX.md") was filed from
the *ranitas* field report on the same day. So it is systemic across projects,
not specific to tillandsias — which is exactly the kind of confirmation this
loop is supposed to produce.

## 4. What did not work at all

### 4.1 `host-browser` MCP — `publish_local` / `browser.open` unavailable for the whole session

Facts, all reproducible from inside the forge:

- `/home/forge/.config/opencode/config.json` declares
  `mcp.host-browser → /home/forge/.config-overlay/mcp/host-browser.sh`, enabled.
- `host-browser.sh` is a `socat` NDJSON passthrough to
  `$TILLANDSIAS_CONTROL_SOCKET` (= `/run/host/tillandsias-mcp/mcp.sock`).
- `~/.local/share/opencode/log/opencode.log`, container start:
  `WARN "server unavailable" key=host-browser type=local status=failed`.
  OpenCode does **not** retry a failed local MCP server; the tools stay absent
  for the session's lifetime.
- The socket **inode exists** (`srw------- forge:forge`, created 06:10) but
  `connect()` returns `ConnectionRefusedError [Errno 111]` — retried at 22:42Z
  and again at 23:0xZ. No listener.
- Therefore: no sibling static/Wrangler container, no safe Chromium window, no
  `service_*`. There is also no shell-level bypass: the bridge is a dumb pipe,
  so a manual JSON-RPC client fails identically.

The important architectural point is the *ordering*, not the specific death:
the failure was already recorded **at agent start** (06:10:22, ~4 s after
config load). Whatever ended the listener, the agent's client had one shot and
no retry — so any launch in which the lane is not accepting at that instant
loses these capabilities until relaunch. Relaunching without changing the
ordering will race again.

Recorded as: `1863-eckw` (new packet) and a measurement note on the existing
`920-c3af` (`opencode-forge-lane-missing-order-505-control-socket`), which has
been waiting for exactly this in-forge acceptance evidence.

### 4.2 Flutter toolchain — `flutter` exits 69 against the same socket

`/usr/local/sbin/flutter` → `/opt/agents/tillandsias-cli/bin/flutter`, a shim
that runs Flutter in a shared host image over the lane socket. With the lane
down it prints that the host toolchain service is unreachable at
`/run/host/tillandsias-mcp/mcp.sock` and exits **69**. Consequence: no
`flutter pub get`, no `flutter build web`, so `observatorium/`'s documented
build (`scripts/build.mjs` → `build/web`) cannot complete even though the
non-Flutter stages (plan build, git-history collection, precompute →
`observatorium/web/data/metrics.json`, 1.5 MB) succeed.

The shared-image design is good (one warm image, "preparing, one time").
The gap is the *hard dependency*: a lane outage converts "slower first build"
into "cannot build", and Flutter is the only toolchain with that property.

### 4.3 In-forge `.localhost` resolution — Squid forwards to a dead `proxy:80`

- Direct, bypassing the proxy (`.localhost` is in `no_proxy`):
  `curl http://opencode.tillandsias.localhost/` → **connection refused**
  (no in-forge resolver for `.localhost`; expected without a proxy).
- Through the sanctioned proxy: `curl -x http://proxy:3128
  http://opencode.tillandsias.localhost/` → **502**, `Server: squid/6.12`,
  `X-Squid-Error: ERR_READ_ERROR`. The proxy host (`10.0.42.32`) refuses
  connections on port 80.
- The router itself is **healthy**: `curl -H 'Host: opencode.tillandsias.localhost'
  http://10.0.42.38:8080/` → the router's 401 gate
  ("unauthorised — open this project from the Tillandsias tray"), and an
  unrouted name returns `tillandsias-router: no route for
  observatorium.tillandsias.localhost`.

So the router listens on **8080**, Squid's `.localhost` forwarding still aims at
**80**, and `web-services.md` tells agents the proxy "recognises `*.localhost`
as enclave-internal traffic" and that curl "needs nothing special". Filed as
`1863-4knc`.

### 4.4 AutoApproval could not be enabled (operator-reported)

Operator observation, corroborated by measurement: **Settings → AutoApproval
was off, disabled, and could not be turned on.** §5 has the numbers and the
configuration cause.

### 4.5 No in-container verification fallback

The forge deliberately has no browser binary (correct: `browser.open` launches a
host-side Chromium container). But when the lane is down there is *no* path to
verify a rendered page: `PLAYWRIGHT_BROWSERS_PATH` points at
`/home/forge/.cache/tillandsias-project/ms-playwright`, which does not exist,
and no chromium/google-chrome is on `PATH`. An agent is left with `curl` (which
is itself broken for `.localhost`, §4.3) or nothing. Worth stating explicitly
in the startup context: *"no rendering verification exists in-forge; if the
lane is down you cannot verify the page."*

### 4.6 `/home/forge/src` tmpfs is 1.5 GB

Unpacking a Flutter SDK there is impossible (and I deliberately did not, because
the workspace is ephemeral). A real `build/web` for this project fits, but a
first-time toolchain download would not. The startup context already documents
the durable cache; a one-line "do not install SDKs under `$TILLANDSIAS_PROJECT`"
would prevent an agent from trying.

## 5. Approval and workspace-scope friction (quantified)

This is the part that most affected the *outcome* of the session, so it is
reported first with measurements rather than opinion.

**Observations**

- The generated forge config `~/.config/opencode/config.json` sets
  `"permission": "allow"`.
- The **checkout's own** `opencode.json` (tracked in the tillandsias repo) sets
  `"permission": "ask"`.
- OpenCode's log shows both loading, global first and project last
  (`loading path=…/config.json` at 06:10:18, `loading path=…/tillandsias/opencode.json`
  at 06:10:22), i.e. the project file wins. Every decision was therefore
  evaluated against a wildcard `ask` rule:
  `permission=bash … action.permission=* action.action=ask action.pattern=*`,
  including for tools that touch nothing outside the checkout (`todowrite`).
- **48 approval prompts** in ≈28 minutes of active work, logged as
  `message=asking id=…`: 39 `bash`, 6 `external_directory`, 1 `edit`,
  1 `todowrite`, 1 forge MCP tool. 535 permission evaluations in total (the
  rest matched patterns the operator had already allowed in-session).
- **6 `external_directory` prompts** were the ones that cost the most, because
  they were on the *diagnostic evidence itself*: `/home/forge/.config/opencode/*`
  (the MCP config), `/usr/local/share/tillandsias/*` (help), `/run/router/*`,
  `/proc/*`, `/sys/fs/cgroup/*`, `/etc/*`. The user describes this correctly as
  "restricted to the code checkout until I was prompted for access outside".
- The operator could not turn AutoApproval **on**: the control was disabled in
  the TUI. The project-level `permission: "ask"` (inference: OpenCode treats a
  config-pinned permission as authoritative and disables the toggle) is the
  plausible cause; what is *measured* is that the toggle was disabled and the
  wildcard `ask` rule was in force.

**Why it changed the findings, not just the speed**

1. **Time-to-diagnosis.** The root cause lived in two files outside the
   checkout (§4.1). Each read was a prompt. The effective loop was
   "hypothesise → ask permission → read → hypothesise again", with a human
   round-trip in the middle of every step. The single most valuable line in the
   whole session (`server unavailable key=host-browser status=failed`) cost a
   prompt to discover.
2. **Hypothesis quality.** With reads of `$HOME/.config` slow, I first
   over-invested in *in-checkout* source reading (`mcp_socket.rs`, `tray/mod.rs`,
   `main.rs`) and built a **wrong** root-cause story ("the listener is orphaned
   when the launcher exits") that the log later corrected to "the client failed
   at start and never retried". Cheaper access to the two config/log files would
   have produced the accurate story on the first pass. The correction is now in
   the ledger (`1863-eckw` note), but a maintainer reading only the first
   version would have fixed the wrong thing.
3. **Batch size.** Every multi-command pipeline was one more prompt, so I
   compressed probes (`cmd1; cmd2; cmd3` in a single call) and sometimes ran
   less-informative single commands. That reduced evidence quality per call —
   visible in this report as the number of "reproduced twice to be sure" checks
   (e.g. the socket was re-probed at 22:42 and 23:0x).
4. **The gate loop became expensive.** Filing correctly took 3 pushes × (edit +
   commit + push) — each an approval. A well-scoped allowlist for the plan fast
   lane (`plan/index.d/`, `tillandsias-plan`, `git add/commit/push` on
   `linux-next`) would have removed ~10 prompts without weakening anything: the
   pre-push hooks still validate the bytes.

**What is *not* being asked for:** broader mounts, host paths, credentials, or
a blanket `allow`. Every item below is inside the container's existing
filesystem/permission model.

## 6. Proposed enhancements (ranked)

Privacy/isolation note for every item: in-container or in-image only; no new
host mounts, sockets, tokens or network paths.

1. **`tillandsias-doctor` (or a `capability:` block in the startup context).**
   One command, one screen, machine-readable `--json`: lane socket path +
   `connect()` result; each MCP server `ok|failed` with the reason; router
   reachability direct **and** via proxy; proxy upstream; Flutter toolchain
   reachable; `/opt/cheatsheets` populated; tmpfs and cache free space;
   rendering-verification availability. This one addition collapses §3.1, §3.2
   and §4.3 into a single call. Nothing in the forge currently answers "is this
   session able to publish?" directly.
2. **Bind/adopt the lane before spawning the agent's MCP client, and retry.**
   The listener must be accepting when `host-browser.sh` is spawned; if it is
   not, retry with backoff (the client currently gives up forever), and adopt a
   stale socket instead of leaving an inode with no listener. Surface the
   failure into the session (`.forge-capability-alert.md` or the startup
   context) so the agent does not have to read `~/.local/share/opencode/log` to
   learn it. This is the fix for `920-c3af` / `1863-eckw`.
3. **Make the permission profile fit forge work, and make AutoApproval work.**
   Concretely: (a) do not ship a project-level `"permission": "ask"` in a
   checkout agents are expected to work in — or scope it
   (`edit`/`write`: ask; `bash`: ask only for destructive patterns) rather than
   wildcard-asking; (b) if a config-pinned permission is what disables the TUI
   toggle, show *why* it is disabled and name the file, instead of a dead
   control; (c) add a curated **read-only** allowlist for the diagnostic
   surfaces that already exist inside the container:
   `$HOME/.config/opencode/`, `$HOME/.local/share/opencode/log/`,
   `/run/host/tillandsias-mcp/` (already mounted ro), `/opt/agents/tillandsias-cli/`,
   `/opt/cheatsheets/`, `/usr/local/share/tillandsias/`. These are how an agent
   diagnoses the forge; making them prompts adds latency to exactly the loop the
   forge diagnostics methodology wants to run.
4. **Cache the shared Flutter toolchain in the durable cache volume.** Keep the
   host image as the fast path, but fall back to a cached in-container SDK under
   `/home/forge/.cache/tillandsias-project` so a lane outage degrades to
   "first build is slower" instead of "cannot build". (Explicitly allowed by
   `methodology/forge-diagnostics.yaml` → `allowed_examples`: toolchains and
   approved caches.) If a fallback is rejected, make the shim's failure a typed
   refusal naming the one-line remedy, not bare exit 69.
5. **Fix the `.localhost` self-test, or document the truthful one.** Point
   Squid's `.localhost` upstream at the router's 8080 (or give the forge a
   resolver that reaches it) and add the one-curl probe to E2E; until then,
   `web-services.md` should say what actually works from inside a forge (the
   direct router address), because the current text sends agents to a 502.
   Filed as `1863-4knc`.
6. **Populate `/opt/cheatsheets` (or fail loudly when it is hollow).** Already
   packet `1870-imye`, filed from another project the same day — this report is
   the second independent sighting. A hollow mount should be an error at launch,
   not a silent fallback to a repo copy that may not match the image.
7. **Expose launch mode and listener ownership** (`TILLANDSIAS_LAUNCH_MODE`,
   owner pid/liveness) so a field report can say *which* launch path failed.
   Today a report necessarily contains hedged hypotheses (§3.5).
8. **Small CLI ergonomics:** print the `next-order` token first
   (or `--quiet`/`--count`); accept the MCP tool names (`plan_status`) as CLI
   aliases; make `next-order`'s "duplicate" advisory say explicitly that
   *different suffixes from repeated calls are correct and expected*.
9. **State the negative capability in the startup context**: "there is no
   in-forge browser or headless renderer; if `browser.open` is unavailable you
   cannot verify a rendered page" — saves an agent from hunting for Playwright
   (§4.5).

## 7. Facts vs inferences (please read before fixing)

Measured: every command output quoted above; the 48 prompts / 535 evaluations;
the config load order; the log line; the socket `ECONNREFUSED`; router 401/404
vs Squid 502; `/opt/cheatsheets` empty; `flutter` exit 69.

Inferred (labelled, and *not* relied on for any exit criterion): that the
project-level `permission: "ask"` is what disables the TUI AutoApproval toggle;
that the lobby listener was orphaned by a launcher exit rather than never
started; the exact host-side owner of the stale inode. The ledger entry
`1863-eckw` carries a correction event making the ordering evidence primary and
the orphan hypothesis secondary.

## 8. Cost table (why the four findings above are ordered this way)

| phase | calls | human prompts | outcome |
|---|---|---|---|
| orient (startup ctx, web-services.md, repo layout) | ~10 | ~8 | sanctioned flow identified |
| find why `publish_local` is absent | ~12 | ~6 | root cause in log/config outside checkout |
| probe router / proxy / `.localhost` | ~8 | ~5 | 401 vs 502 separated |
| attempt the build (`npm run build`) | 2 | 1 | non-Flutter stages ok; `flutter pub get` exit 69 |
| file + correct findings in the ledger | ~14 | ~10 | 2 packets + 2 events, 4 push attempts (2 refusals, 2 landings) |
| this report | ~8 | ~4 | — |

## 9. Repro cookbook (copy-paste, in-forge)

```bash
# 1. Is the host-browser lane usable at all?
python3 - <<'PY'
import socket
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(3)
try: s.connect('/run/host/tillandsias-mcp/mcp.sock'); print('CONNECTED')
except Exception as e: print(type(e).__name__, e)
PY

# 2. What did the agent's MCP client conclude at launch?
grep 'host-browser' ~/.local/share/opencode/log/opencode.log | head

# 3. Which permission profile actually won?
grep 'loading path=.*opencode.*json' ~/.local/share/opencode/log/opencode.log
grep -c 'message=asking id=' ~/.local/share/opencode/log/opencode.log

# 4. Router vs proxy (the documented self-test vs the truth)
curl -fsS http://opencode.$TILLANDSIAS_PROJECT.localhost/            # fails: no resolver
curl -x http://proxy:3128 http://opencode.$TILLANDSIAS_PROJECT.localhost/ -o /dev/null -sS -w '%{http_code}\n'   # 502
curl -sS -o /dev/null -w '%{http_code}\n' -H "Host: opencode.$TILLANDSIAS_PROJECT.localhost" http://10.0.42.38:8080/  # 401 (healthy)

# 5. Flutter toolchain
flutter --version; echo "exit=$?"   # 69 + "host toolchain service is not reachable"

# 6. Discovery path
ls -la /opt/cheatsheets; tellme about --list | head
```

## 10. Cross-references

- `1863-eckw` — lane MCP socket refuses; `publish_local`/`browser.open`/Flutter dead
  for the whole session (this session's primary packet).
- `1863-4knc` — in-forge `.localhost` goes through Squid to `proxy:80`, which refuses
  while the router answers on 8080.
- `920-c3af` (`opencode-forge-lane-missing-order-505-control-socket`) — in-forge
  measurement note appended from this session; the acceptance evidence it was
  waiting for now exists, and it fails.
- `1870-imye` — `tellme` / `/opt/cheatsheets` hollow-index defect (second sighting,
  first was ranitas the same day).
- `1859-v5iv` — "quitting stops everything it started, and starting after a crash
  cleans up the dead run" (adjacent lifecycle concern; not a duplicate).
- `methodology/forge-diagnostics.yaml`, `plan/diagnostics/README.md`,
  `images/default/config-overlay/opencode/instructions/web-services.md`,
  `plan/issues/research/forge-web-preview-cold-start-2026-10-12.md`.
