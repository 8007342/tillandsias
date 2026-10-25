-- @trace order:1833-ytbe, spec:local-coding-delegation
--
-- local-delegate.lua — the decider behind scripts/local-delegate.sh. It hands
-- ONE packet to the local inference endpoint, bounds what the model may touch
-- to the row's owned_files, runs the row's closure, and prints ONE verdict
-- line. It never commits: the frontier session reviews the diff, runs the
-- gate, and commits or discards (openspec change
-- local-coding-experts-delegation-ladder, design §2).
--
--   tillandsias-plan script run scripts/lua/local-delegate.lua -- implement <order>
--       --repo <abs> --endpoint <url> --model <name>
--       [--max-rounds N] [--max-turns N] [--wall-s N]
--
-- WHY LUA, NOT BASH. The loop parses and builds JSON (chat requests, tool
-- calls), walks YAML fragments for the row, and keeps a small state machine
-- with a revert path that must run on every exit. The plan binary already
-- carries json/yaml/fs/proc/time for Lua, and the project is retiring bash
-- deciders; scripts/local-delegate.sh is only the entry that resolves the
-- binary and the repo.
--
-- VERDICT, one stdout line (packet grammar local-delegate:<order>:<reason>,
-- prefixed by the runner's class so `script classify` reads it unchanged):
--   ok:local-delegate:<order>:ok:rounds=<n>:closure=<passed|none>          exit 0
--   refused:local-delegate:<order>:closure-red:rounds=<n>                  exit 1
--   refused:local-delegate:<order>:out-of-scope:<first stray path>         exit 1
--   refused:local-delegate:<order>:timeout:<turns=n|wall=s>                exit 1
--   refused:local-delegate:<order>:no-endpoint                            exit 1
--   refused:local-delegate:<order>:<no-row|no-owned-files|dirty-tree|
--                                   malformed-reply|revert-failed|head-moved|
--                                   usage>                                 exit 1
--   (the bash entry adds not-a-work-tree and no-plan-binary)
--
-- PROTOCOL. OpenAI-compatible /v1/chat/completions with tools. Tools:
--   read_file(path)            any repo-relative path (no .git, no ..)
--   write_file(path, content)  whole-file replacement. A path outside
--                              owned_files is WRITTEN and then caught by the
--                              scope check: the post-run `git status` is the
--                              one authority, so a stray edit from any channel
--                              (the tool, the closure's side effects) is
--                              reverted the same way. The tool result warns
--                              the model so it can stop.
--   finish(summary)            ends a ROUND: scope check, then the closure
--                              runs ONCE. Red output is fed back as the next
--                              round's prompt until --max-rounds.
-- (design.md's run_closure tool is folded into finish: the closure runs once
-- per round, never at the model's whim, so a passing first round runs it
-- exactly once.)
--
-- FAIL-CLOSED. The endpoint is probed before anything is read or written; a
-- transport failure mid-run reverts. Every non-ok verdict restores the tree to
-- HEAD (the run refuses to start on a dirty tree, so HEAD is the start state).
-- The idiom-retrieval step of design §2 waits on the expert (1815-tei4) and is
-- skipped; the context pack is used when `.forge-expert-context.md` exists.

local ORDER = "?"

local function emit(line, code)
    verdict.emit(line, code)
end

-- ---------------------------------------------------------------- arguments
local opts = { max_rounds = 3, max_turns = 24, wall_s = 1200 }
do
    local i = 1
    local pos = {}
    while arg[i] ~= nil do
        local a = arg[i]
        local function val()
            i = i + 1
            if arg[i] == nil then
                emit("refused:local-delegate:" .. ORDER .. ":usage", 1)
            end
            return arg[i]
        end
        if a == "--repo" then opts.repo = val()
        elseif a == "--endpoint" then opts.endpoint = val()
        elseif a == "--model" then opts.model = val()
        elseif a == "--max-rounds" then opts.max_rounds = tonumber(val())
        elseif a == "--max-turns" then opts.max_turns = tonumber(val())
        elseif a == "--wall-s" then opts.wall_s = tonumber(val())
        else pos[#pos + 1] = a end
        i = i + 1
    end
    if pos[2] ~= nil then ORDER = pos[2] end
    if pos[1] ~= "implement" or pos[2] == nil or not ORDER:match("^[%w][%w%-]*$")
        or not opts.repo or not opts.model or not opts.max_rounds
        or not opts.max_turns or not opts.wall_s then
        log.error("usage: local-delegate implement <order> --repo <abs> --endpoint <url> --model <name>")
        emit("refused:local-delegate:" .. ORDER .. ":usage", 1)
    end
end

local REPO = opts.repo
local T0 = time.now_ms()
local DEADLINE = T0 + opts.wall_s * 1000
local function remaining_ms() return DEADLINE - time.now_ms() end

local function run(argv, extra)
    local spec = { argv = argv, cwd = REPO, timeout_ms = 120000 }
    if extra then for k, v in pairs(extra) do spec[k] = v end end
    return proc.run(spec)
end

-- ---------------------------------------------------------------- endpoint
local function base_url(ep)
    ep = (ep or ""):gsub("/+$", "")
    ep = ep:gsub("/v1$", "")
    return ep
end
local BASE = base_url(opts.endpoint)

if BASE == "" then
    log.error("no endpoint: set TILLANDSIAS_INFERENCE_ENDPOINT or pass --endpoint")
    emit("refused:local-delegate:" .. ORDER .. ":no-endpoint", 1)
end
do
    local r = run({ "curl", "-fsS", "--max-time", "5", BASE .. "/v1/models" }, { timeout_ms = 10000 })
    if not r.ok then
        log.error("endpoint " .. BASE .. " did not answer /v1/models: "
            .. tostring(r.stderr or r.status or ""):sub(1, 300))
        emit("refused:local-delegate:" .. ORDER .. ":no-endpoint", 1)
    end
end

-- ---------------------------------------------------------------- the row
local function as_list(v)
    if type(v) ~= "table" then return {} end
    return v
end

local row
do
    local pat = "^[[:space:]]*(- )?order:[[:space:]]*['\"]?" .. ORDER .. "['\"]?[[:space:]]*$"
    local files = {}
    for _, where in ipairs({ "plan/index.yaml", "plan/index.d" }) do
        if fs.exists(where) then
            local g = run({ "grep", "-rlE", "--include=*.yaml", pat, where })
            for f in tostring(g.stdout or ""):gmatch("[^\n]+") do files[#files + 1] = f end
        end
    end
    table.sort(files) -- fragments are timestamp-named: byte order is append order
    for _, f in ipairs(files) do
        local okp, doc = pcall(function() return yaml.parse(fs.read(f)) end)
        if okp and type(doc) == "table" then
            local lists = { doc.packets }
            if type(doc.plan_index) == "table" then lists[#lists + 1] = doc.plan_index.steps end
            for _, l in ipairs(lists) do
                for _, p in ipairs(as_list(l)) do
                    if type(p) == "table" and tostring(p.order) == ORDER then
                        row = row or {}
                        for k, v in pairs(p) do
                            if k ~= "events" then row[k] = v end
                        end
                    end
                end
            end
        end
    end
end
if not row then emit("refused:local-delegate:" .. ORDER .. ":no-row", 1) end

local OWNED, OWNED_LIST = {}, {}
for _, f in ipairs(as_list(row.owned_files)) do
    if type(f) == "string" then
        local n = f:gsub("^%./", "")
        OWNED[n] = true
        OWNED_LIST[#OWNED_LIST + 1] = n
    end
end
if #OWNED_LIST == 0 then emit("refused:local-delegate:" .. ORDER .. ":no-owned-files", 1) end

-- The closure command: the first `scripts/<x>.sh` that exists, named by
-- verifiable_closure, else by unscoreable (design §2 "whichever names it").
local CLOSURE
for _, field in ipairs({ "verifiable_closure", "unscoreable" }) do
    local text = row[field]
    if type(text) == "string" and not CLOSURE then
        for p in text:gmatch("scripts/[%w%._/%-]+%.sh") do
            if fs.exists(p) or OWNED[p] then CLOSURE = p; break end
        end
    end
end

-- ---------------------------------------------------------------- tree state
local function status_paths()
    local r = run({ "git", "status", "--porcelain=v1", "-z", "--untracked-files=all" })
    if not r.ok then return nil end
    local out = {}
    for entry in tostring(r.stdout):gmatch("([^%z]+)") do
        local xy, path = entry:sub(1, 2), entry:sub(4)
        out[#out + 1] = { xy = xy, path = path }
    end
    return out
end

do
    local st = status_paths()
    if st == nil then
        log.error(REPO .. " is not a git work tree")
        emit("refused:local-delegate:" .. ORDER .. ":not-a-work-tree", 1)
    end
    if #st > 0 then
        log.error("refusing to start on a dirty tree (first: " .. st[1].path
            .. "); the revert path restores HEAD, so HEAD must be the start state")
        emit("refused:local-delegate:" .. ORDER .. ":dirty-tree", 1)
    end
end
local HEAD0 = tostring(run({ "git", "rev-parse", "HEAD" }).stdout or ""):gsub("%s+$", "")

local function revert_all()
    for _ = 1, 2 do
        local st = status_paths() or {}
        if #st == 0 then return true end
        for _, e in ipairs(st) do
            if e.xy == "??" then
                run({ "git", "clean", "-fq", "--", e.path })
            else
                run({ "git", "restore", "--source=HEAD", "--staged", "--worktree", "--", e.path })
            end
        end
    end
    local st = status_paths() or { 1 }
    return #st == 0
end

local function finish(line, code)
    if code ~= 0 and not revert_all() then
        line = "refused:local-delegate:" .. ORDER .. ":revert-failed"
    end
    local head = tostring(run({ "git", "rev-parse", "HEAD" }).stdout or ""):gsub("%s+$", "")
    if head ~= HEAD0 then
        -- never ours (the tool surface has no commit), but never reported green
        line, code = "refused:local-delegate:" .. ORDER .. ":head-moved", 1
    end
    log.info(string.format("wall_ms=%d", time.now_ms() - T0))
    emit(line, code)
end

local function strays()
    local out = {}
    for _, e in ipairs(status_paths() or {}) do
        if not OWNED[e.path] then out[#out + 1] = e.path end
    end
    return out
end

-- ---------------------------------------------------------------- prompt
local function safe_path(p)
    if type(p) ~= "string" or p == "" or p:sub(1, 1) == "/" then return nil end
    p = p:gsub("^%./", "")
    for c in p:gmatch("[^/]+") do
        if c == ".." or c == ".git" then return nil end
    end
    return p
end

local function read_or(p, alt)
    local okr, s = pcall(fs.read, p)
    if okr and type(s) == "string" then return s end
    return alt
end

local function render(v)
    if type(v) == "string" then return v end
    if type(v) == "table" then
        local parts = {}
        for _, x in ipairs(v) do parts[#parts + 1] = "- " .. tostring(x) end
        return table.concat(parts, "\n")
    end
    return ""
end

local prompt = {}
local pack = read_or(".forge-expert-context.md", nil)
if pack then
    prompt[#prompt + 1] = "## Forge context pack\n\n" .. pack:sub(1, 12000)
else
    log.info("no .forge-expert-context.md; prompting without the context pack")
end
prompt[#prompt + 1] = "## Goal (packet " .. ORDER .. ")\n\n" .. render(row.title)
    .. (type(row.context) == "string" and ("\n\n" .. row.context) or "")
prompt[#prompt + 1] = "## Exit criteria\n\n" .. render(row.exit_criteria)
prompt[#prompt + 1] = "## Files you may change (owned_files) — ONLY these\n\n" .. render(OWNED_LIST)
for _, f in ipairs(OWNED_LIST) do
    prompt[#prompt + 1] = "### " .. f .. "\n\n```\n"
        .. read_or(f, "(this file does not exist yet; create it with write_file)"):sub(1, 20000) .. "\n```"
end
prompt[#prompt + 1] = "## Closure\n\n" .. (CLOSURE
    and ("When you call finish, `bash " .. CLOSURE .. "` runs; it must exit 0. If it fails you get its output and another round.")
    or "No closure command is declared; finish when the exit criteria hold.")
prompt[#prompt + 1] = "## Rules\n\nUse the tools. write_file replaces the WHOLE file. "
    .. "Never write outside the owned files: such an edit is reverted and the whole run is refused. "
    .. "Call finish when done."

local SYSTEM = "You are a careful coding agent working in a git repository through tools. "
    .. "You change only the files you are told you own, with complete file contents, and then call finish."

local function fn(name, desc, props, req)
    return { type = "function", ["function"] = { name = name, description = desc,
        parameters = { type = "object", properties = props, required = req } } }
end
local TOOLS = {
    fn("read_file", "Read a repository file (repo-relative path).",
        { path = { type = "string" } }, { "path" }),
    fn("write_file", "Replace the whole content of an owned file (repo-relative path).",
        { path = { type = "string" }, content = { type = "string" } }, { "path", "content" }),
    fn("finish", "End this round; the closure command runs next.",
        { summary = { type = "string" } }, { "summary" }),
}

local messages = {
    { role = "system", content = SYSTEM },
    { role = "user", content = table.concat(prompt, "\n\n") },
}

-- ---------------------------------------------------------------- the loop
local function chat()
    local body = json.encode({ model = opts.model, messages = messages, tools = TOOLS,
        temperature = 0, stream = false })
    local secs = math.max(1, math.floor(remaining_ms() / 1000))
    local r = run({ "curl", "-sS", "--fail-with-body", "--max-time", tostring(secs),
        "-H", "Content-Type: application/json", "--data-binary", "@-",
        BASE .. "/v1/chat/completions" }, { stdin = body, timeout_ms = (secs + 5) * 1000 })
    if not r.ok then
        if r.code == 28 or remaining_ms() <= 0 then return nil, "timeout" end
        log.error("chat request failed: rc=" .. tostring(r.code) .. " "
            .. tostring(r.stderr or ""):sub(1, 300) .. tostring(r.stdout or ""):sub(1, 300))
        return nil, "no-endpoint"
    end
    local okp, resp = pcall(json.parse, r.stdout)
    if not okp or type(resp) ~= "table" or type(resp.choices) ~= "table"
        or type(resp.choices[1]) ~= "table" or type(resp.choices[1].message) ~= "table" then
        log.error("malformed reply: " .. tostring(r.stdout):sub(1, 300))
        return nil, "malformed-reply"
    end
    return resp.choices[1].message
end

local function call_args(c)
    local a = c["function"] and c["function"].arguments
    if type(a) == "string" then
        local okp, t = pcall(json.parse, a)
        if okp and type(t) == "table" then return t end
        return {}
    end
    if type(a) == "table" then return a end
    return {}
end

local function tool(name, a)
    if name == "read_file" then
        local p = safe_path(a.path)
        if not p then return "error: path must be repo-relative, without .. or .git" end
        return read_or(p, "error: " .. tostring(a.path) .. " does not exist"):sub(1, 60000), false
    elseif name == "write_file" then
        local p = safe_path(a.path)
        if not p or type(a.content) ~= "string" then
            return "error: write_file needs a repo-relative path and string content"
        end
        local mode = tostring(run({ "git", "ls-files", "-s", "--", p }).stdout or ""):match("^(%d+)")
        local dir = p:match("^(.*)/[^/]+$")
        if dir and not fs.exists(dir) then pcall(fs.mkdir, dir) end
        local okw, err = pcall(fs.write, p, a.content)
        if not okw then return "error: " .. tostring(err) end
        if mode == "100755" then run({ "chmod", "+x", p }) end -- fs.write renames: keep the bit
        if not OWNED[p] then
            return "written, BUT " .. p .. " is not an owned file: this edit will be reverted and the run refused"
        end
        return "ok: wrote " .. #a.content .. " bytes to " .. p
    elseif name == "finish" then
        return "ok: round ends; the closure runs now", true
    end
    return "error: unknown tool " .. tostring(name)
end

local round, turns = 1, 0
while true do
    if remaining_ms() <= 0 then
        finish("refused:local-delegate:" .. ORDER .. ":timeout:wall=" .. opts.wall_s, 1)
    end
    if turns >= opts.max_turns then
        finish("refused:local-delegate:" .. ORDER .. ":timeout:turns=" .. turns, 1)
    end
    turns = turns + 1
    local msg, why = chat()
    if not msg then
        if why == "timeout" then why = "timeout:wall=" .. opts.wall_s end
        finish("refused:local-delegate:" .. ORDER .. ":" .. why, 1)
    end
    local calls = type(msg.tool_calls) == "table" and msg.tool_calls or {}
    local amsg = { role = "assistant", content = type(msg.content) == "string" and msg.content or "" }
    if #calls > 0 then amsg.tool_calls = calls end
    messages[#messages + 1] = amsg
    local ended = false
    if #calls == 0 then
        messages[#messages + 1] = { role = "user",
            content = "Reply with tool calls only: write_file for each owned file you change, then finish." }
    end
    for i, c in ipairs(calls) do
        local name = type(c["function"]) == "table" and c["function"].name or "?"
        local result, fin = tool(name, call_args(c))
        if type(c.id) ~= "string" then c.id = "call_" .. turns .. "_" .. i end
        messages[#messages + 1] = { role = "tool", tool_call_id = c.id, content = result }
        if fin then ended = true end
    end
    if ended then
        local s = strays()
        if #s > 0 then
            log.error("edit outside owned_files: " .. table.concat(s, ", ") .. " — reverting the run")
            finish("refused:local-delegate:" .. ORDER .. ":out-of-scope:" .. s[1], 1)
        end
        if not CLOSURE then
            finish("ok:local-delegate:" .. ORDER .. ":ok:rounds=" .. round .. ":closure=none", 0)
        end
        local ms = math.max(1000, remaining_ms())
        local r = run({ "bash", CLOSURE }, { timeout_ms = ms })
        local last = tostring(r.stdout or ""):match("([^\n]+)\n*$") or ""
        log.info(string.format("round %d: closure bash %s exited %s in %d ms; last line: %s",
            round, CLOSURE, tostring(r.code or r.status), r.wall_ms or -1, last))
        local s2 = strays()
        if #s2 > 0 then
            log.error("the closure left edits outside owned_files: " .. table.concat(s2, ", "))
            finish("refused:local-delegate:" .. ORDER .. ":out-of-scope:" .. s2[1], 1)
        end
        if r.ok then
            finish("ok:local-delegate:" .. ORDER .. ":ok:rounds=" .. round .. ":closure=passed", 0)
        end
        log.warn("round " .. round .. ": closure " .. CLOSURE .. " exited " .. tostring(r.code or r.status))
        if round >= opts.max_rounds then
            finish("refused:local-delegate:" .. ORDER .. ":closure-red:rounds=" .. round, 1)
        end
        round = round + 1
        local outp = tostring(r.stdout or "") .. "\n" .. tostring(r.stderr or "")
        messages[#messages + 1] = { role = "user", content = "The closure `bash " .. CLOSURE
            .. "` FAILED (exit " .. tostring(r.code or r.status) .. "). Output tail:\n```\n"
            .. outp:sub(-4000) .. "\n```\nFix the owned files with write_file, then finish." }
    end
end
