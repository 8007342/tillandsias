-- @env PATH
-- @trace spec:host-state-lifecycle, order:1559-2uw3, order:1437-3iux
--
-- test-purge-guard-soft-arm.lua — check-purge-clears-vault-credentials.sh's
-- NEGATIVE arm (1437-3iux S4): the Windows SOFT reset body calls NO credential
-- clearer. The guard's positive arm (every path that unregisters the distro
-- must clear) is unchanged; this pins the other direction, so a later edit that
-- brings the clearer back into --reset-state is refused by name.
--
-- Ported from scripts/test-purge-guard-soft-arm.sh (order 2234-a964 pays the
-- carried shell-to-lua item); the arms and verdicts are unchanged.
--
-- Arms (each runs the REAL guard; the SOFT body source is pointed at a scratch
-- copy through TILLANDSIAS_PURGE_GUARD_SOFT_SRC):
--   1 the real tree                                   -> ok
--   2 SOFT body calls clear_guest_vault_credentials   -> violation soft-reset-calls-a-clearer
--   3 the same call only in a // comment              -> ok (comments are stripped)
--   4 a source with no SOFT body                      -> violation soft-body-not-found
-- Each sabotage asserts its own edit landed exactly once before it is judged.
--
-- Usage: tillandsias-plan script run scripts/lua/test-purge-guard-soft-arm.lua
-- Verdict: ok:purge-guard-soft-arm:4 arms | fail:purge-guard-soft-arm:<n>

local GUARD = "scripts/check-purge-clears-vault-credentials.sh"
local SRC = "crates/tillandsias-windows-tray/src/notify_icon.rs"
local SIG = "pub fn reset_state_once() -> i32 {"
local CALL = "    let _ = crate::installation_uuid::clear_guest_vault_credentials();"
local CMT = "    // let _ = crate::installation_uuid::clear_guest_vault_credentials();"

local fails = 0
local function pass(m) out.line("ok:   " .. m) end
local function bad(m) out.line("FAIL: " .. m); fails = fails + 1 end

local root = text.trim(proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 }).stdout or "")
local REL = "target/plan-scratch/purge-guard-soft-" .. tostring(time.now_ms())
fs.mkdir(REL)

local ENV = env
local function guard(soft)
    local e = { PATH = ENV.get("PATH") or "/usr/bin:/bin" }
    if soft then e.TILLANDSIAS_PURGE_GUARD_SOFT_SRC = root .. "/" .. soft end
    local r = proc.run({ argv = { "bash", GUARD }, env = e, timeout_ms = 120000 })
    local o = (r.stdout or "") .. (r.stderr or "")
    return r.code, text.trim(o)
end

local function inject(line, dst)
    local buf = {}
    for _, l in ipairs(text.lines(fs.read(SRC) or "")) do
        buf[#buf + 1] = l
        if l == SIG then buf[#buf + 1] = line end
    end
    fs.write(dst, table.concat(buf, "\n") .. "\n")
end

local function landed(path, line)
    local n = 0
    for _, l in ipairs(text.lines(fs.read(path) or "")) do
        if l == line then n = n + 1 end
    end
    return n
end

local function last_line(s)
    local ls = text.lines(s)
    return ls[#ls] or ""
end

-- 1 — the real tree passes.
local rc, o = guard(nil)
if rc == 0 then pass("1 real tree: " .. last_line(o)) else bad("1 real tree rc=" .. rc .. ": " .. o) end

-- 2 — a SOFT body that calls the clearer is refused.
inject(CALL, REL .. "/sab.rs")
local n2 = landed(REL .. "/sab.rs", CALL)
if n2 ~= 1 then
    bad("2 sabotage did not land exactly once (count=" .. n2 .. ")")
else
    rc, o = guard(REL .. "/sab.rs")
    if rc == 1 and o:find("soft-reset-calls-a-clearer", 1, true) then
        pass("2 clearer in the SOFT body is refused")
    else
        bad("2 clearer in the SOFT body: rc=" .. rc .. " out=[" .. o .. "]")
    end
end

-- 3 — the same call only in a comment is not a call.
inject(CMT, REL .. "/cmt.rs")
local n3 = landed(REL .. "/cmt.rs", CMT)
if n3 ~= 1 then
    bad("3 comment mutant did not land exactly once (count=" .. n3 .. ")")
else
    rc, o = guard(REL .. "/cmt.rs")
    if rc == 0 then pass("3 a commented-out clearer is not a call") else bad("3 comment read as a call: rc=" .. rc .. " out=[" .. o .. "]") end
end

-- 4 — no SOFT body at all is refused by name, never passed vacuously.
fs.write(REL .. "/none.rs", "fn unrelated() {}\n")
rc, o = guard(REL .. "/none.rs")
if rc == 1 and o:find("soft-body-not-found", 1, true) then
    pass("4 a missing SOFT body is refused by name")
else
    bad("4 missing SOFT body: rc=" .. rc .. " out=[" .. o .. "]")
end

proc.run({ argv = { "rm", "-rf", root .. "/" .. REL }, timeout_ms = 60000 })

if fails ~= 0 then
    verdict.emit("fail:purge-guard-soft-arm:" .. fails, 1)
end
verdict.emit("ok:purge-guard-soft-arm:4 arms", 0)
