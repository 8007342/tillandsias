-- @trace order:1951-vv5m
-- @env PATH
--
-- test-flaky-installs-background.lua — a flaky-optional install cannot hold a
-- forge build or a forge start hostage, and its first-use shim tells the truth
-- about it.
--
-- LIVE (macuahuitl, 2026-11-01): the forge-base image build sat ~10 min in
-- `timeout 600 pip3 install --timeout 30 --retries 2 pyright bandit` at 0% CPU
-- with no traffic while PyPI answered the host in 0.39 s, and the tray menu
-- froze. 1771-4iw3 had bounded that step; bounded still blocks. Operator
-- direction the same day: a separate background family with longer timeouts,
-- and first-use shims that know the tool may still be installing.
--
-- This fixture REPLACES test-forge-base-pip-bounded.lua (1771-4iw3): its subject,
-- the build-time pip step, no longer exists. Its stall arm is kept in spirit as
-- the `hang` arm below, against the runtime family instead of the build.
--
-- Arms:
--   static: Containerfile.base runs no pip3 install; no entrypoint calls a
--           flaky-optional installer directly; every forge entrypoint starts
--           the family; the image ships lib-flaky-installs.sh.
--   hang:   an installer that never returns. flaky_install_start returns at
--           once (the forge's readiness is not held), the status reads
--           installing, and the shim prints the still-installing line, exit 75.
--   budget: the same hang under a 1 s budget ends as failed timeout-after-1s,
--           and the shim names that reason.
--   fail:   an installer that exits 3 ends as failed rc=3.
--   control (NEGATIVE): an installer that puts the real tool on PATH and exits
--           0 ends as ok, and the shim runs the real tool instead of answering.
local NAME = "flaky-installs-background"
local LIB = "images/default/lib-flaky-installs.sh"

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
local base = fs.read("images/default/Containerfile.base")
if not base then verdict.could_not_run(NAME, "images/default/Containerfile.base is unreadable") end
local pip_at_build = false
for _, line in ipairs(text.lines(base)) do
    if not line:match("^%s*#") and line:find("pip3 install", 1, true) then pip_at_build = true end
end
arm("static: Containerfile.base runs no pip3 install at build time", not pip_at_build)

local direct, missing = {}, {}
for _, e in ipairs(fs.list("images/default")) do
    local f = e:match("([^/]+)$")
    if f:match("^entrypoint%-forge%-.+%.sh$") or f == "entrypoint-terminal.sh" then
        local src = fs.read("images/default/" .. f) or ""
        local starts = false
        for _, line in ipairs(text.lines(src)) do
            if not line:match("^%s*#") then
                if line:match("^%s*ensure_forge_prebuilt_tools") then
                    direct[#direct + 1] = f
                end
                if line:match("^%s*start_flaky_installs") then starts = true end
            end
        end
        if not starts then missing[#missing + 1] = f end
    end
end
arm("static: no entrypoint calls a flaky-optional installer directly", #direct == 0, table.concat(direct, ","))
arm("static: every forge entrypoint starts the family", #missing == 0, table.concat(missing, ","))
local cf = fs.read("images/default/Containerfile") or ""
arm("static: the image ships lib-flaky-installs.sh",
    cf:find("COPY lib-flaky-installs.sh /usr/local/lib/tillandsias/lib-flaky-installs.sh", 1, true) ~= nil)

-- ── behaviour ─────────────────────────────────────────────────────────────────
if not fs.exists(LIB) then
    arm("behaviour: " .. LIB .. " exists", false, "absent")
else
    local REL = "target/plan-scratch/flaky-installs-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
    local ABS = ROOT .. "/" .. REL
    fs.mkdir(REL)
    local PATH0 = env.get("PATH") or "/usr/bin:/bin"

    -- One driver per arm: source the library, start one installer, report.
    local function drive(case, installer, budget, settle)
        local dir = ABS .. "/" .. case
        fs.mkdir(REL .. "/" .. case)
        fs.mkdir(REL .. "/" .. case .. "/real")
        fs.write(REL .. "/" .. case .. "/driver.sh", table.concat({
            "set -u",
            ". " .. ROOT .. "/" .. LIB,
            "export TILLANDSIAS_FLAKY_STATUS_DIR=" .. dir .. "/status",
            "export TILLANDSIAS_FLAKY_INSTALL_TIMEOUT_S=" .. budget,
            "export TILLANDSIAS_FLAKY_SHIM_WAIT_S=1",
            "export PATH=" .. dir .. "/real:$PATH:" .. dir .. "/shims",
            "installer() { " .. installer .. "; }",
            "flaky_install_shim faketool fake " .. dir .. "/shims",
            "t0=$(date +%s%N)",
            "flaky_install_start fake installer",
            "echo start_ms=$(( ($(date +%s%N) - t0) / 1000000 ))",
            "sleep " .. settle,
            "echo status=$(cat " .. dir .. "/status/fake)",
            "out=$(" .. dir .. "/shims/faketool --probe 2>&1); rc=$?",
            "echo shim_rc=$rc",
            "echo shim_out=$out",
        }, "\n") .. "\n")
        local r = proc.run({ argv = { "bash", dir .. "/driver.sh" }, env = { PATH = PATH0, HOME = dir },
            timeout_ms = 30000 })
        local o = r.stdout or ""
        local res = { raw = o .. (r.stderr or "") }
        for k, v in o:gmatch("([%w_]+)=([^\n]*)") do res[k] = res[k] or v end
        return res
    end

    local hang = drive("hang", "exec sleep 20", "1800", "1")
    arm("hang: flaky_install_start returns inside 2 s", tonumber(hang.start_ms or "") ~= nil
        and tonumber(hang.start_ms) < 2000, hang.start_ms)
    arm("hang: status reads installing", (hang.status or ""):match("^installing ") ~= nil, hang.status)
    arm("hang: the shim says still installing", (hang.shim_out or ""):find("faketool is still installing (started ", 1, true) ~= nil,
        hang.shim_out)
    arm("hang: the shim exits 75 (try again)", hang.shim_rc == "75", hang.shim_rc)

    local bud = drive("budget", "exec sleep 600", "1", "3")
    arm("budget: a hang past the budget ends failed timeout-after-1s",
        (bud.status or ""):match("^failed timeout%-after%-1s ") ~= nil, bud.status)
    arm("budget: the shim names the reason", (bud.shim_out or ""):find("did not install: timeout-after-1s", 1, true) ~= nil,
        bud.shim_out)

    local fl = drive("fail", "return 3", "1800", "1")
    arm("fail: an installer exiting 3 ends failed rc=3", (fl.status or ""):match("^failed rc=3 ") ~= nil, fl.status)
    arm("fail: the shim exits 127", fl.shim_rc == "127", fl.shim_rc)

    local ok = drive("control", "printf '#!/bin/sh\\necho real-tool-ran\\n' > \"$(dirname \"$TILLANDSIAS_FLAKY_STATUS_DIR\")/real/faketool\"; chmod 755 \"$(dirname \"$TILLANDSIAS_FLAKY_STATUS_DIR\")/real/faketool\"", "1800", "1")
    arm("control: a healthy installer ends ok", (ok.status or ""):match("^ok ") ~= nil, ok.status)
    arm("control: the shim runs the real tool", ok.shim_out == "real-tool-ran" and ok.shim_rc == "0",
        tostring(ok.shim_rc) .. ":" .. tostring(ok.shim_out))
end

if #failed > 0 then
    verdict.emit("violation:" .. NAME .. ":" .. #failed .. "-failed", 1)
end
verdict.ok(NAME, "static + hang + budget + fail + control arms")
