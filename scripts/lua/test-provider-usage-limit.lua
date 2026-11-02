-- @trace order:1941-rlim
-- @env PATH
--
-- test-provider-usage-limit.lua — a provider usage limit is reported as
-- itself, stops the lane with a distinct verdict, records its deadline, and a
-- launch before the deadline refuses without calling the provider.
--
-- LIVE (yoga, 2026-11-01): after 11 opencode sessions the shared free tier
-- answered 429 with Retry-After 78443 and "Free usage limit reached"; the lane
-- had reported earlier refusals only as "EPROTO: The TLS handshake failed",
-- and later lanes kept calling. The lines below are the RECORDED ones from
-- that night (the ERROR line from opencode's log, the header from a fetch
-- trace). No network: everything runs against the library, the real
-- harness-supervisor and a stub harness.
--
-- Arms:
--   record:   Retry-After seen, then the limit line -> the operator line, the
--             verdict, a record ~78443 s ahead;
--   default:  the limit line alone -> the 24 h default hold;
--   control (NEGATIVE): the night's EPROTO ERROR line records nothing;
--   refuse:   an active record refuses (and says when); an expired one and
--             TILLANDSIAS_IGNORE_PROVIDER_LIMIT=1 go ahead;
--   supervise: a harness run that records a limit ends rc 75 with the
--             verdict; a clean run with no record is rc 0 and silent; a
--             record from BEFORE the run does not hijack its exit;
--   static:   the opencode entrypoint refuses before every opencode launch,
--             the follower watches every log line, the image ships the lib.
local NAME = "provider-usage-limit"
local LIB = "images/default/lib-provider-limit.sh"
local SUP = "images/default/harness-supervisor.sh"

local LIMIT_LINE = 'timestamp=2026-11-01T02:55:15.223Z level=ERROR run=0af93892 message="stream error" '
    .. 'providerID=opencode modelID=big-pickle session.id=ses_e6af87cdcffeuINn9ND6mMFn2x small=false '
    .. 'agent=build mode=primary error.error="AI_APICallError: Free usage limit reached. Free models work '
    .. 'in OpenCode (https://opencode.ai); subscribe to OpenCode Go to keep going: https://opencode.ai/go"'
local RETRY_LINE = "< Retry-After: 78443"
local EPROTO_LINE = 'timestamp=2026-11-01T01:20:02.000Z level=ERROR message="stream error" '
    .. 'error.error="EPROTO: The TLS handshake failed"'

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run(NAME, "git rev-parse --show-toplevel did not answer")
end

local failed = {}
local function arm(name, cond, got)
    got = got and tostring(got):gsub("\n", " | ") or nil
    if cond then out.line("ok:   " .. name .. (got and (" — " .. got) or "")) else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got))
        failed[#failed + 1] = name
    end
end

-- ── static ────────────────────────────────────────────────────────────────────
local ep = fs.read("images/default/entrypoint-forge-opencode.sh") or ""
local refuse_at, first_launch = nil, nil
for i, line in ipairs(text.lines(ep)) do
    if not line:match("^%s*#") then
        if not refuse_at and line:find("provider_limit_refuse opencode", 1, true) then refuse_at = i end
        if not first_launch and (line:find("exec /usr/local/bin/harness-supervisor opencode", 1, true)
            or line:find('exec "$OC_BIN"', 1, true)) then
            first_launch = i
        end
    end
end
arm("static: the opencode entrypoint refuses before its first launch",
    refuse_at ~= nil and first_launch ~= nil and refuse_at < first_launch,
    tostring(refuse_at) .. " < " .. tostring(first_launch))
local follower = fs.read("images/default/opencode-tool-start-follower.sh") or ""
arm("static: the log follower watches every line for a limit",
    follower:find("provider_limit_watch_line opencode", 1, true) ~= nil)
local cf = fs.read("images/default/Containerfile") or ""
arm("static: the image ships lib-provider-limit.sh",
    cf:find("COPY lib-provider-limit.sh /usr/local/lib/tillandsias/lib-provider-limit.sh", 1, true) ~= nil)

if not fs.exists(LIB) then
    arm("behaviour: " .. LIB .. " exists", false, "absent")
else
    local REL = "target/plan-scratch/provider-limit-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
    local ABS = ROOT .. "/" .. REL
    fs.mkdir(REL)
    local PATH0 = env.get("PATH") or "/usr/bin:/bin"

    local function bash(case, body, extra_env)
        fs.mkdir(REL .. "/" .. case)
        local dir = ABS .. "/" .. case
        fs.write(REL .. "/" .. case .. "/run.sh", table.concat({
            "set -u",
            "export TILLANDSIAS_PROVIDER_LIMIT_DIR=" .. dir .. "/limits",
            "export TILLANDSIAS_PROVIDER_LIMIT_LIB=" .. ROOT .. "/" .. LIB,
            ". " .. ROOT .. "/" .. LIB,
            body,
        }, "\n") .. "\n")
        local e = { PATH = PATH0, HOME = dir }
        for k, v in pairs(extra_env or {}) do e[k] = v end
        local r = proc.run({ argv = { "bash", dir .. "/run.sh" }, env = e, timeout_ms = 30000 })
        return r, dir
    end
    local function record_of(dir)
        local p = (dir:sub(#ROOT + 2)) .. "/limits/opencode"
        if not fs.exists(p) then return nil end
        local s = fs.read(p)
        if not s then return nil end
        local u = s:match("^(%d+)")
        return tonumber(u)
    end
    local now = tonumber(text.trim(proc.run({ argv = { "date", "-u", "+%s" }, timeout_ms = 5000 }).stdout or "0"))

    -- record
    local r, dir = bash("record", table.concat({
        "provider_limit_watch_line opencode " .. string.format("%q", RETRY_LINE),
        "provider_limit_watch_line opencode " .. string.format("%q", LIMIT_LINE),
        "provider_limit_watch_line opencode " .. string.format("%q", LIMIT_LINE),
    }, "\n"))
    local o = r.stdout or ""
    arm("record: says the limit as itself",
        o:find("provider usage limit reached, retry after ", 1, true) ~= nil, o:sub(1, 160))
    arm("record: the verdict names provider and deadline",
        o:find("blocked:provider-usage-limit:provider=opencode:retry_after=20", 1, true) ~= nil, o)
    local _, n = o:gsub("blocked:provider%-usage%-limit", "")
    arm("record: a repeated limit line is recorded once", n == 1, n)
    local until1 = record_of(dir)
    arm("record: the deadline is the provider's own Retry-After (78443 s)",
        until1 and math.abs(until1 - now - 78443) <= 10, until1 and (until1 - now))

    -- default
    r, dir = bash("default", "provider_limit_watch_line opencode " .. string.format("%q", LIMIT_LINE))
    local until2 = record_of(dir)
    arm("default: no Retry-After seen holds 24 h", until2 and math.abs(until2 - now - 86400) <= 10,
        until2 and (until2 - now))

    -- control
    r, dir = bash("control", "provider_limit_watch_line opencode " .. string.format("%q", EPROTO_LINE))
    arm("control: the EPROTO line records nothing", record_of(dir) == nil and (r.stdout or "") == "",
        r.stdout)

    -- refuse
    r = bash("refuse", table.concat({
        "provider_limit_record opencode 600 >/dev/null",
        "if provider_limit_refuse opencode; then echo REFUSED; else echo WENT; fi",
    }, "\n"))
    o = r.stdout or ""
    arm("refuse: an active limit refuses", o:find("REFUSED", 1, true) ~= nil, o)
    arm("refuse: and says when it lifts and how to override",
        o:find("retry after ", 1, true) ~= nil and o:find("TILLANDSIAS_IGNORE_PROVIDER_LIMIT=1", 1, true) ~= nil, o)
    r = bash("expired", table.concat({
        'mkdir -p "$TILLANDSIAS_PROVIDER_LIMIT_DIR"',
        'echo "$(( $(date -u +%s) - 5 )) 2026-11-01T00:00:00Z 2026-11-01T00:00:00Z" > "$TILLANDSIAS_PROVIDER_LIMIT_DIR/opencode"',
        "if provider_limit_refuse opencode; then echo REFUSED; else echo WENT; fi",
    }, "\n"))
    arm("refuse: an expired limit goes ahead", (r.stdout or ""):find("WENT", 1, true) ~= nil, r.stdout)
    r = bash("ignored", table.concat({
        "provider_limit_record opencode 600 >/dev/null",
        "if provider_limit_refuse opencode; then echo REFUSED; else echo WENT; fi",
    }, "\n"), { TILLANDSIAS_IGNORE_PROVIDER_LIMIT = "1" })
    arm("refuse: the operator override goes ahead", (r.stdout or ""):find("WENT", 1, true) ~= nil, r.stdout)

    -- supervise (the real harness-supervisor, a stub harness)
    local function supervise(case, child_body, pre)
        fs.mkdir(REL .. "/" .. case)
        local dir = ABS .. "/" .. case
        fs.write(REL .. "/" .. case .. "/child.sh", table.concat({
            "set -u", ". " .. ROOT .. "/" .. LIB, child_body,
        }, "\n") .. "\n")
        fs.write(REL .. "/" .. case .. "/run.sh", table.concat({
            "export TILLANDSIAS_PROVIDER_LIMIT_DIR=" .. dir .. "/limits",
            "export TILLANDSIAS_PROVIDER_LIMIT_LIB=" .. ROOT .. "/" .. LIB,
            "export TILLANDSIAS_CRASH_EVIDENCE_DIR=" .. dir .. "/crash",
            pre or ":",
            "bash " .. ROOT .. "/" .. SUP .. " opencode bash " .. dir .. "/child.sh",
        }, "\n") .. "\n")
        return proc.run({ argv = { "bash", dir .. "/run.sh" }, env = { PATH = PATH0, HOME = dir }, timeout_ms = 30000 })
    end
    r = supervise("sup-limit", "provider_limit_record opencode 600 >/dev/null\nexit 1")
    arm("supervise: a run that hit the limit ends rc 75", r.status == "exited" and r.code == 75, r.code)
    arm("supervise: with the verdict on stdout",
        (r.stdout or ""):find("blocked:provider-usage-limit:provider=opencode:retry_after=", 1, true) ~= nil, r.stdout)
    r = supervise("sup-clean", "exit 0")
    arm("supervise (NEGATIVE): a clean run is rc 0 and silent",
        r.code == 0 and (r.stdout or "") == "" and (r.stderr or "") == "", tostring(r.code) .. ":" .. tostring(r.stdout))
    r = supervise("sup-stale", "sleep 1.2\nexit 3", table.concat({
        'mkdir -p "$TILLANDSIAS_PROVIDER_LIMIT_DIR"',
        '( . ' .. ROOT .. "/" .. LIB .. ' && provider_limit_record opencode 600 >/dev/null )',
        "sleep 1.1",
    }, "\n"))
    arm("supervise: a limit recorded before the run does not hijack its exit", r.code == 3, r.code)
end

if #failed > 0 then
    verdict.emit("violation:" .. NAME .. ":" .. #failed .. "-failed", 1)
end
verdict.ok(NAME, "static + record + default + control + refuse + supervise arms")
