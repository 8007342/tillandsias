-- @env PATH HOME
-- @trace order:1804-sccl, order:1812-bztj, order:1841-7pvs, order:2080-zcur
--
-- test-sccache-long-tmpdir.lua — land run 184 (#590): "sccache: encountered
-- fatal error" on cargo's rustc probe. Cause: sccache's server-start socket
-- lives under $TMPDIR; a long TMPDIR (the door's pf-guard dir under an agent
-- TMPDIR) overflows SUN_LEN when no server runs.
--   arm1 (control)  bare sccache, long TMPDIR, dead server: FAILS (reproduces defect)
--   arm2            scripts/sccache-wrapper.sh, same conditions: rustc -vV succeeds
--   arm3            sccache that always fails (rc 254): wrapper falls back, rc 0
--   arm4            server started under a short TMPDIR that is then deleted:
--                   next compile ok (1812-bztj). Driven by cargo with
--                   CARGO_INCREMENTAL=0, because an incremental or hand-rolled
--                   rustc call is non-cacheable and never reaches the server's
--                   temp dir (an arm that cannot fail pre-fix proves nothing).
--   arm5            a HUNG sccache must not hang the build; bounded by timeout,
--                   so pre-fix it FAILS instead of hanging (1841-7pvs)
-- Ported from scripts/test-sccache-long-tmpdir.sh onto common.fixture.
--
-- Usage: tillandsias-plan script run scripts/lua/test-sccache-long-tmpdir.lua
-- Verdict: ok:sccache-long-tmpdir:<n> arms | violation:sccache-long-tmpdir:<n>-failed
--          | skip:sccache-long-tmpdir:no-sccache

local fixture = require "common.fixture"
local T = fixture.new("sccache-long-tmpdir")
local ROOT = fixture.repo_root()
local PATH = env.get("PATH") or "/usr/bin:/bin"
local HOME = env.get("HOME") or ""

local w = proc.run{ argv = { "which", "sccache" }, env = { PATH = PATH } }
if w.code ~= 0 then T:skip("no-sccache") end
local SC = text.trim(w.stdout)
local WRAP = ROOT .. "/scripts/sccache-wrapper.sh"

local W = T:scratch()
local LONG = W.rel .. "/" .. string.rep("d", 100)
fs.mkdir(LONG)
local LONGABS = ROOT .. "/" .. LONG
local PORT = tostring(20000 + time.now_ms() % 20000)
local function e(extra)
    local t = { PATH = PATH, HOME = HOME, SCCACHE_DIR = W.abs .. "/cache", SCCACHE_SERVER_PORT = PORT }
    for k, v in pairs(extra or {}) do t[k] = v end
    return t
end
local function stop() T:run{ SC, "--stop-server", env = e() } end
local function is_rustc(r) return (r.stdout or ""):find("^rustc ") ~= nil end

stop()
local r = T:run{ SC, "rustc", "-vV", env = e{ TMPDIR = LONGABS } }
T:arm("arm1 defect reproduces: bare sccache fails with a long TMPDIR and no server",
    r.status ~= "exited" or r.code ~= 0, "bare sccache did not fail under a long TMPDIR (fixture proves nothing)")

stop()
r = T:run{ WRAP, "rustc", "-vV", env = e{ TMPDIR = LONGABS, TILLANDSIAS_SCCACHE_BIN = SC } }
T:arm("arm2 wrapper survives a long TMPDIR with a dead server", is_rustc(r), "wrapper failed under a long TMPDIR")

fs.write(W.rel .. "/badsc", "#!/bin/sh\nexit 254\n")
T:must{ "chmod", "+x", W.abs .. "/badsc" }
r = T:run{ WRAP, "rustc", "-vV", env = e{ TILLANDSIAS_SCCACHE_BIN = W.abs .. "/badsc" } }
T:arm("arm3 broken sccache falls back to the bare compiler", is_rustc(r), "broken sccache redded the build")

stop()
local EPH = T:short_scratch()
fs.mkdir(W.rel .. "/p/src")
fs.write(W.rel .. "/p/Cargo.toml", '[package]\nname = "sclt"\nversion = "0.0.0"\nedition = "2021"\n[workspace]\n')
fs.write(W.rel .. "/p/src/lib.rs", "pub fn a() -> u8 { 1 }\n")
local function build(tmp)
    return T:run{ "cargo", "build", "-q", "--offline", cwd = W.abs .. "/p", timeout_ms = 600000,
        env = e{ TMPDIR = tmp, CARGO_INCREMENTAL = "0", RUSTC_WRAPPER = WRAP,
            TILLANDSIAS_SCCACHE_BIN = SC, CARGO_TARGET_DIR = W.abs .. "/t" } }
end
build(EPH.abs)
T:must{ "rm", "-rf", EPH.abs }
fs.write(W.rel .. "/p/src/lib.rs", "pub fn b() -> u8 { 2 }\n")
r = build("/tmp")
T:arm("arm4 server survives its starter's deleted TMPDIR", r.code == 0,
    "compile failed after the starter's TMPDIR was deleted: " .. (r.stderr or ""):sub(1, 300))

if proc.run{ argv = { "which", "timeout" }, env = { PATH = PATH } }.code == 0 then
    fs.write(W.rel .. "/hungsc", "#!/bin/sh\nexec sleep 3600\n")
    T:must{ "chmod", "+x", W.abs .. "/hungsc" }
    r = T:run{ "timeout", "60", WRAP, "rustc", "-vV", timeout_ms = 90000,
        env = e{ TILLANDSIAS_SCCACHE_PROBE_SECS = "2", TILLANDSIAS_SCCACHE_BIN = W.abs .. "/hungsc" } }
    T:arm("arm5 hung sccache falls back to the bare compiler within a bound", is_rustc(r),
        "hung sccache hung or redded the build")
else
    out.line("skip:arm5:no-timeout")
end
stop()
T:finish()
