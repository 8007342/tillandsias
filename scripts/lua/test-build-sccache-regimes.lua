-- @trace order:1916-dvlp, order:1804-sccl
--
-- test-build-sccache-regimes.lua — build.sh's sccache block (between the
-- BEGIN-SCCACHE / END-SCCACHE markers) splits the two regimes:
--   DEV   CARGO_INCREMENTAL=1: no RUSTC_WRAPPER (sccache refuses an
--         incremental unit: "incremental compilation is prohibited"), and the
--         dev loop builds headless with assets-from-source (1916-embd);
--   GATE  CARGO_INCREMENTAL=0 or unset: the sccache wrapper is set, as before.
-- LINKER (dev regime only): mold when it resolves, else ld.lld, else the
-- default with the reason printed; set for the host target only. Gate: none.
-- The block runs extracted, under fake sccache, rustc, mold and ld.lld on a
-- PATH the fixture controls, so no build runs and no VERSION is bumped.
--
-- Usage: tillandsias-plan script run scripts/lua/test-build-sccache-regimes.lua

local function run(argv, opts)
    local spec = { argv = argv, timeout_ms = 30000 }
    for k, v in pairs(opts or {}) do spec[k] = v end
    return proc.run(spec)
end
local ROOT = text.trim(run({ "git", "rev-parse", "--show-toplevel" }).stdout or "")
if ROOT == "" then verdict.could_not_run("build-sccache-regimes", "not inside a git checkout") end
local ok_read, src = pcall(fs.read, ROOT .. "/build.sh")
if not ok_read then verdict.could_not_run("build-sccache-regimes", "build.sh unreadable") end
local block = src:match("# BEGIN%-SCCACHE\n(.-)# END%-SCCACHE")
if not block then
    verdict.emit("violation:build-sccache-regimes:no-markers", 1, "build.sh has no BEGIN-SCCACHE/END-SCCACHE block")
end

local REL = "target/plan-scratch/sccache-regimes-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
local W = ROOT .. "/" .. REL
fs.mkdir(REL .. "/bin")
fs.mkdir(REL .. "/lld")
fs.mkdir(REL .. "/mold")
local FAKES = {
    { "bin/sccache", "#!/bin/sh\nexit 0\n" },
    { "bin/rustc", "#!/bin/sh\necho 'host: x86_64-unknown-linux-gnu'\n" },
    { "lld/ld.lld", "#!/bin/sh\nexit 0\n" },
    { "mold/mold", "#!/bin/sh\nexit 0\n" },
}
for _, f in ipairs(FAKES) do
    fs.write(REL .. "/" .. f[1], f[2])
    run({ "chmod", "+x", W .. "/" .. f[1] })
end
-- The block needs tr and sed; the host's own PATH may hold a real mold or
-- ld.lld, so the system tools are linked into a dir that holds nothing else.
fs.mkdir(REL .. "/sys")
for _, tool in ipairs({ "tr", "sed" }) do
    local where
    for _, d in ipairs({ "/usr/bin/", "/bin/", "/usr/local/bin/", "/opt/homebrew/bin/" }) do
        if not where then
            local t = run({ "test", "-x", d .. tool })
            if t.status == "exited" and t.code == 0 then where = d .. tool end
        end
    end
    if not where then verdict.could_not_run("build-sccache-regimes", "no " .. tool .. " in the usual places") end
    run({ "ln", "-s", where, W .. "/sys/" .. tool })
end
local SYS = W .. "/sys"
fs.write(REL .. "/block.sh", "SCRIPT_DIR=" .. ROOT .. "\n" .. block ..
    '\necho "wrapper=${RUSTC_WRAPPER:-}"\necho "features=${TILLANDSIAS_DEV_BUILD_FEATURES:-}"\n' ..
    'echo "hostflags=${CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS:-}"\n')

local passed, failed = 0, 0
local function check(name, cond, why)
    if cond then passed = passed + 1; out.line("ok:   " .. name)
    else failed = failed + 1; out.line("FAIL: " .. name .. " — " .. why) end
end
local function regime(incr, linkers)
    local path = W .. "/bin"
    for _, d in ipairs(linkers or {}) do path = path .. ":" .. W .. "/" .. d end
    local e = { PATH = path .. ":" .. SYS, HOME = W }
    if incr then e.CARGO_INCREMENTAL = incr end
    local r = run({ "/bin/bash", W .. "/block.sh" }, { env = e })
    return (r.stdout or "") .. (r.stderr or "")
end

local dev = regime("1")
check("DEV CARGO_INCREMENTAL=1 sets no RUSTC_WRAPPER", dev:find("wrapper=\n", 1, true) ~= nil, dev)
check("DEV says why sccache is off", dev:find("sccache: off (CARGO_INCREMENTAL=1", 1, true) ~= nil, dev)
check("DEV builds headless with assets-from-source",
    dev:find("features=--features tillandsias-headless/assets-from-source", 1, true) ~= nil, dev)
local both = regime("1", { "mold", "lld" })
check("LINKER DEV prefers mold when it resolves",
    both:find("hostflags=-C link-arg=-fuse-ld=mold\n", 1, true) ~= nil
        and both:find("linker: mold (dev regime; CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS)", 1, true) ~= nil, both)
local lld = regime("1", { "lld" })
check("LINKER DEV falls back to ld.lld",
    lld:find("hostflags=-C link-arg=-fuse-ld=lld\n", 1, true) ~= nil and lld:find("linker: lld", 1, true) ~= nil, lld)
check("LINKER DEV with neither keeps the default and says why",
    dev:find("hostflags=\n", 1, true) ~= nil and dev:find("linker: default (neither mold nor ld.lld on PATH)", 1, true) ~= nil, dev)
local gate = regime("0", { "mold", "lld" })
check("LINKER GATE never switches the linker",
    gate:find("hostflags=\n", 1, true) ~= nil and gate:find("linker:", 1, true) == nil, gate)
check("GATE CARGO_INCREMENTAL=0 keeps the sccache wrapper",
    gate:find("wrapper=" .. ROOT .. "/scripts/sccache-wrapper.sh", 1, true) ~= nil, gate)
check("GATE embeds its assets", gate:find("features=\n", 1, true) ~= nil, gate)
local unset = regime(nil)
check("UNSET keeps the sccache wrapper (the gate default)",
    unset:find("wrapper=" .. ROOT .. "/scripts/sccache-wrapper.sh", 1, true) ~= nil, unset)

run({ "rm", "-rf", W })
if failed > 0 then verdict.emit("refused:build-sccache-regimes:" .. passed .. "/" .. (passed + failed), 1) end
verdict.emit("ok:build-sccache-regimes:" .. passed .. " arms", 0)
