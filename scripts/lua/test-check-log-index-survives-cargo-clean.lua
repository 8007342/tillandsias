-- @env PATH HOME
-- @trace order:888-vgs8, order:2372-snfs
--
-- test-check-log-index-survives-cargo-clean.lua — the check log index lives outside target/, adopts
-- a legacy one once, and the freshness reader still answers after target/ is swept. Ported from the
-- .sh of the same name (2372-snfs). Every tree is scratch.
--
--   1 the default is <root>/.cache/convergence    2 TILLANDSIAS_CHECK_LOG_INDEX wins, adopting nothing
--   3 adoption copies once                        4 target/ removed: the records stay
--   5 the same with a real cargo clean            6 the reader answers before and after the sweep
--   7 the three consumers resolve through the resolver and keep no target/ default
--
-- Usage: tillandsias-plan script run scripts/lua/test-check-log-index-survives-cargo-clean.lua
-- Verdict: ok:check-log-index-survives-cargo-clean:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("check-log-index-survives-cargo-clean")
local SH = fixture.posix_shell()
local RES, READER = "scripts/convergence-log-path.sh", "scripts/lua/check-release-tier-freshness.lua"
local PLAN = fixture.plan_binary()
if PLAN == "" then T:refuse("no-plan-binary") end
local OLD, NEW = "/target/convergence/check-logs.jsonl", "/.cache/convergence/check-logs.jsonl"
T:arm("0 the resolver is executable", T:run{ "test", "-x", fixture.repo_root() .. "/" .. RES }.code == 0, RES)
local RUN = "local-ci-" .. text.trim(T:must{ "date", "-u", "+%Y%m%dT%H%M%SZ" }.stdout)
local function rec(id) return '{"ci_run_id":"' .. RUN .. '","ci_phase":"all","check_id":"' .. id .. '","status":"pass","source_log":"","archived_log":"a","sha256":"x","duration_ms":1}\n' end
local function tree(...)
    -- A repo of its own: the plan binary roots a script at its git toplevel, and the reader resolves from there.
    local t = T:git_repo()
    fs.mkdir(t.rel .. "/scripts"); fs.mkdir(t.rel .. "/scripts/lua"); fs.mkdir(t.rel .. "/target/convergence")
    for _, f in ipairs{ RES, READER } do fs.write(t.rel .. "/" .. f, fs.read(f)); T:must{ "chmod", "+x", t.abs .. "/" .. f } end
    local b = ""
    for _, id in ipairs{ ... } do b = b .. rec(id) end
    if b ~= "" then fs.write(t.rel .. OLD, b) end
    return t
end
local function run(t, script, e)
    local env_ = { PATH = env.get("PATH"), HOME = env.get("HOME") }
    for k, v in pairs(e or {}) do env_[k] = v end
    -- The reader is Lua since 2409-qbgu: it runs on the plan binary, the resolver on the shell.
    local argv = script:find("%.lua$") and { PLAN, "script", "run", t.abs .. "/" .. script } or { SH, script }
    local r = proc.run{ argv = argv, cwd = t.abs, env = env_, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 60000 }
    return { rc = r.code, out = text.trim(r.stdout or ""), err = text.trim(r.stderr or "") }
end
local function lines(t, f)
    if not fs.exists(t.rel .. f) then return "absent" end
    local _, n = fs.read(t.rel .. f):gsub("\n", "")
    return n
end
local t = tree()
local x = run(t, RES)
T:arm("1 the default is outside target/", fixture.native_path(x.out) == t.abs .. NEW, x.out .. x.err)
t = tree("a")
x = run(t, RES, { TILLANDSIAS_CHECK_LOG_INDEX = t.abs .. "/own.jsonl" })
T:arm("2 the override wins verbatim and adopts nothing", x.out == t.abs .. "/own.jsonl" and lines(t, NEW) == "absent" and lines(t, "/own.jsonl") == "absent", x.out .. x.err)
t = tree("a", "b", "c")
x = run(t, RES)
local n1, o1 = lines(t, NEW), lines(t, OLD)
fs.write(t.rel .. OLD, (fs.exists(t.rel .. OLD) and fs.read(t.rel .. OLD) or "") .. rec("d"))
local y = run(t, RES)
local why = table.concat({ x.err, y.err, tostring(n1), tostring(o1), tostring(lines(t, NEW)) }, " | ")
T:arm("3a legacy history is copied, with a note, and left intact", n1 == 3 and o1 == 3 and x.err == "note:check-log-index:adopted-legacy:3", why)
T:arm("3b a legacy file that grew is not merged again", lines(t, NEW) == 3 and y.err == "" and x.out == y.out, why)
t = tree("a", "b")
x = run(t, RES)
T:must{ "rm", "-rf", t.abs .. "/target" }
T:arm("4 with target/ removed the index keeps its records", lines(t, OLD) == "absent" and fixture.native_path(x.out) == t.abs .. NEW and lines(t, NEW) == 2, x.out .. tostring(lines(t, NEW)))
if fixture.which("cargo") then
    t = tree("a", "b")
    fs.mkdir(t.rel .. "/src"); fs.write(t.rel .. "/src/lib.rs", "")
    fs.write(t.rel .. "/Cargo.toml", '[package]\nname = "scratch"\nversion = "0.0.0"\nedition = "2021"\n\n[workspace]\n')
    x = run(t, RES)
    local r = proc.run{ argv = { "cargo", "clean", "-q", "--offline" }, cwd = t.abs, env = { CARGO_TARGET_DIR = t.abs .. "/target" }, timeout_ms = 60000 }
    T:arm("5 a real cargo clean takes the legacy file and not the index", r.code == 0 and lines(t, OLD) == "absent" and lines(t, NEW) == 2, "rc=" .. tostring(r.code) .. " " .. (r.stderr or ""):sub(1, 300) .. tostring(lines(t, OLD)) .. tostring(lines(t, NEW)))
else
    out.line("skip: 5 no cargo on PATH (arm 4 covers the property)")
end
t = tree("spec-cheatsheet-binding", "expert-groundtruth-harness")
x = run(t, READER)
T:must{ "rm", "-rf", t.abs .. "/target" }
y = run(t, READER)
local want = "ok:release-tier-fresh:" .. RUN .. ":"
T:arm("6a the reader answers from adopted history", x.rc == 0 and text.contains(x.out, want), x.out .. x.err)
T:arm("6b and still answers after the sweep", y.rc == 0 and text.contains(y.out, want), y.out .. y.err)
local missing, left = {}, {}
for _, f in ipairs{ "scripts/local-ci.sh", "scripts/record-ci-phase-result.sh", READER } do
    local code = {}
    for l in (fs.read(f) .. "\n"):gmatch("([^\n]*)\n") do
        if not l:match("^%s*#") and not l:match("^%s*%-%-") then code[#code + 1] = l end
    end
    code = table.concat(code, "\n")
    if not text.contains(code, "convergence-log-path.sh") then missing[#missing + 1] = f end
    if text.contains(code, "target/convergence/check-logs.jsonl") then left[#left + 1] = f end
end
T:arm("7 the consumers resolve through it and keep no target/ default", #missing + #left == 0, "missing: " .. table.concat(missing, " ") .. " left: " .. table.concat(left, " "))
T:finish()
