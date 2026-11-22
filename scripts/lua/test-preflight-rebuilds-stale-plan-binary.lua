-- @trace order:2186-x5kv
-- @env TILLANDSIAS_SCRIPT_RUNNER_BIN TILLANDSIAS_PLAN_BIN CARGO_TARGET_DIR
--
-- test-preflight-rebuilds-stale-plan-binary.lua — 2186-x5kv's exit criteria.
-- The preflight door used to refuse a stale plan binary outright, and every
-- host hit that refusal several times on 2026-11-21 (yoga's step 885 read it
-- as a content red). The door now runs ONE `cargo build --release -p
-- tillandsias-plan`, asks the binary again, and refuses only if it is still
-- stale. Each arm runs the REAL door over a one-guard roster with a planted
-- binary (a stub that answers stale:validator-surface until a marker exists,
-- else execs the real binary) and a planted `cargo` named through
-- TILLANDSIAS_PREFLIGHT_CARGO (build.sh puts ~/.cargo/bin first on PATH, so a
-- cargo planted on PATH would never run; the real one must not run here).
--
--   1 REBUILD   a stale binary, a cargo that "rebuilds" it (writes the marker):
--               cargo ran once, the door proceeds, ok:preflight:ran=1, rc 0.
--   2 STILL     a cargo that succeeds but leaves the binary stale: rc 1,
--               refused:preflight:stale-plan-binary, no guard run.
--   3 FAILED    a cargo that fails: rc 1, refused:preflight:stale-plan-binary.
--   4 CONTROL   a current binary: cargo is never run, rc 0 (without this, a
--               door that always rebuilds scores arm 1).
--
-- Usage: tillandsias-plan script run scripts/lua/test-preflight-rebuilds-stale-plan-binary.lua

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run("preflight-rebuilds-stale-plan-binary", "git rev-parse --show-toplevel did not answer")
end
local REAL = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") or ""
if REAL == "" then REAL = env.get("TILLANDSIAS_PLAN_BIN") or "" end
if REAL == "" then
    local ctd = env.get("CARGO_TARGET_DIR") or ""
    REAL = (ctd ~= "" and ctd or ROOT .. "/target") .. "/release/tillandsias-plan"
end
if REAL:sub(1, 2) == "./" then REAL = ROOT .. "/" .. REAL:sub(3) end
if REAL == "" or proc.run({ argv = { "test", "-x", REAL }, timeout_ms = 10000 }).code ~= 0 then
    verdict.could_not_run("preflight-rebuilds-stale-plan-binary", "no plan binary to stand behind the planted stub")
end

local failed = {}
local function arm(name, cond, got)
    got = got and tostring(got):gsub("\n", " | ") or nil
    if cond then out.line("ok:   " .. name .. (got and (" — " .. got) or "")) else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got))
        failed[#failed + 1] = name
    end
end

local REL = "target/plan-scratch/pf-rebuild-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
local D = ROOT .. "/" .. REL
fs.mkdir(REL)
fs.write(REL .. "/check-zz-1.sh", "#!/bin/bash\necho ok:zz-1\n")
fs.write(REL .. "/roster", REL .. "/check-zz-1.sh\n")

-- cargo_body: what the planted cargo does after logging its call.
local function run_door(name, stale_at_start, cargo_body)
    local A = D .. "/" .. name
    fs.mkdir(REL .. "/" .. name)
    if not stale_at_start then fs.write(REL .. "/" .. name .. "/fresh", "") end
    fs.write(REL .. "/" .. name .. "/tillandsias-plan",
        "#!/usr/bin/env bash\n"
        .. "if [ \"$1\" = validator-surface-hash ] && [ ! -e '" .. A .. "/fresh' ]; then\n"
        .. "  echo 'stale:validator-surface built-from=0000 checkout=ffff' >&2; exit 3\nfi\n"
        -- HERMETIC (darwin 2026-11-21): the "current" answer is the stub's own,
        -- never the real binary's, so a host whose release build is from
        -- another branch does not red the control.
        .. "if [ \"$1\" = validator-surface-hash ]; then echo 'ok:validator-surface:ffff'; exit 0; fi\n"
        .. "exec '" .. REAL .. "' \"$@\"\n")
    fs.write(REL .. "/" .. name .. "/cargo",
        "#!/usr/bin/env bash\necho \"$*\" >> '" .. A .. "/cargo.calls'\n" .. cargo_body:gsub("@A@", A) .. "\n")
    proc.run({ argv = { "chmod", "+x", A .. "/tillandsias-plan", A .. "/cargo" }, timeout_ms = 10000 })
    local r = proc.run({ argv = { "/bin/bash", "./build.sh", "--preflight" }, cwd = ROOT, timeout_ms = 300000,
        env = { TILLANDSIAS_PREFLIGHT_ROSTER_FILE = D .. "/roster",
                TILLANDSIAS_PLAN_BIN = A .. "/tillandsias-plan",
                TILLANDSIAS_SKIP_TOOLBOX = "1",
                TILLANDSIAS_PREFLIGHT_CARGO = A .. "/cargo",
                TILLANDSIAS_TIMING_LOG = A .. "/t.jsonl",
                TILLANDSIAS_EXPERT_USAGE_LOG = A .. "/u.jsonl",
                LITMUS_STEP_TIMING_LOG = A .. "/l.jsonl" } })
    local o = (r.stdout or "") .. "\n" .. (r.stderr or "")
    local calls = 0
    if fs.exists(REL .. "/" .. name .. "/cargo.calls") then
        calls = #text.lines(text.trim(fs.read(REL .. "/" .. name .. "/cargo.calls")))
    end
    local v = o:match("(refused:preflight:stale%-plan%-binary)") or o:match("(ok:preflight:ran=%d+)")
        or o:match("(%a+:preflight:ran=%d+)") or "(no verdict)"
    return r.code, calls, v
end

local rc, calls, v = run_door("rebuild", true, "touch '@A@/fresh'")
arm("1 REBUILD a stale binary is rebuilt once and the door proceeds", rc == 0 and calls == 1 and v == "ok:preflight:ran=1",
    "rc=" .. tostring(rc) .. " cargo-calls=" .. calls .. " " .. v)
rc, calls, v = run_door("still", true, "exit 0")
arm("2 STILL a binary still stale after the rebuild is refused", rc == 1 and calls == 1 and v == "refused:preflight:stale-plan-binary",
    "rc=" .. tostring(rc) .. " cargo-calls=" .. calls .. " " .. v)
rc, calls, v = run_door("failed", true, "exit 101")
arm("3 FAILED a failed rebuild is refused", rc == 1 and calls == 1 and v == "refused:preflight:stale-plan-binary",
    "rc=" .. tostring(rc) .. " cargo-calls=" .. calls .. " " .. v)
rc, calls, v = run_door("control", false, "exit 0")
arm("4 CONTROL a current binary is never rebuilt", rc == 0 and calls == 0 and v == "ok:preflight:ran=1",
    "rc=" .. tostring(rc) .. " cargo-calls=" .. calls .. " " .. v)
proc.run({ argv = { "rm", "-rf", D }, timeout_ms = 30000 })

if #failed > 0 then
    verdict.emit("violation:preflight-rebuilds-stale-plan-binary:" .. #failed .. "-failed", 1)
end
verdict.ok("preflight-rebuilds-stale-plan-binary", "4 arms")
