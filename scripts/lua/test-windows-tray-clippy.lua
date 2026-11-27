-- @env PATH HOME
-- @trace order:1434-vm7g, order:2203-wclp, order:1444-bzpu, order:2344-64wz
--
-- test-windows-tray-clippy.lua — scripts/lua/check-windows-tray-clippy.lua refuses a clippy warning
-- in a crate with Windows code. Ported from the .sh of the same name. It lints tiny scratch crates
-- through the decider's manifest seam and fakes the platform through its uname seam, so every arm
-- runs on any host with cargo clippy.
--
--   1 a warning is refused by name          2 CONTROL the same crate without it is clean
--   3 off Windows it skips and runs no cargo (over the crate that WOULD be refused)
--   4 an untouched crate skips; a changed one runs and refuses
--   5 every touched cfg(windows) crate is linted; a comment-only mention is not a candidate
--   6 MUTATION: without -D warnings arm 1's crate passes; reading comments lints arm 5's
--
-- Usage: tillandsias-plan script run scripts/lua/test-windows-tray-clippy.lua
-- Verdict: ok:windows-tray-clippy-fixture:<n> arms | violation:windows-tray-clippy-fixture:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("windows-tray-clippy-fixture")
local PLAN = fixture.plan_binary()
local DEC = "scripts/lua/check-windows-tray-clippy.lua"
if not fs.exists(DEC) then T:refuse("decider-missing", DEC) end
if PLAN == "" then T:refuse("no-plan-binary") end
local cv = proc.run{ argv = { "cargo", "clippy", "--version" }, timeout_ms = 60000 }
if cv.code ~= 0 then T:skip("no-cargo-clippy") end
local src = fs.read(DEC):gsub("\r\n", "\n")
local W = T:scratch()

local LINT = "pub fn one() -> i32 {\n    return 1;\n}\n" -- clippy::needless_return
local CLEAN = "pub fn one() -> i32 {\n    1\n}\n"
local WIN = "#[cfg(windows)]\npub fn only_on_windows() {}\n"

local function crate(repo, dir, name, body)
    fs.mkdir(repo.rel .. "/" .. dir .. "/src")
    fs.write(repo.rel .. "/" .. dir .. "/Cargo.toml",
        '[package]\nname = "' .. name .. '"\nversion = "0.1.0"\nedition = "2021"\n[workspace]\n')
    fs.write(repo.rel .. "/" .. dir .. "/src/lib.rs", body)
end
-- clippy writes Cargo.lock on its first run; it is not a change to the crate.
local function base(repo)
    fs.mkdir(repo.rel .. "/scripts/lua")
    fs.write(repo.rel .. "/" .. DEC, src)
    -- the checker requires common.listed_read (2417-jzhh), which resolves from the repo it runs in
    fs.mkdir(repo.rel .. "/lib/lua/common")
    fs.write(repo.rel .. "/lib/lua/common/listed_read.lua", fs.read("lib/lua/common/listed_read.lua"))
    fs.write(repo.rel .. "/.gitignore", "Cargo.lock\n")
    T:must{ "git", "-C", repo.abs, "add", "-A" }
    T:must{ "git", "-C", repo.abs, "commit", "-q", "-m", "base" }
    T:must{ "git", "-C", repo.abs, "update-ref", "refs/remotes/origin/linux-next", "HEAD" }
end
-- TILLANDSIAS_GATE_DIFF_BASE is a SHA of the gated checkout, not of a scratch repo (1592-idmu).
local function lint(repo, o)
    local e = { TILLANDSIAS_WINDOWS_CLIPPY_UNAME = o.uname or "MINGW64_NT",
        TILLANDSIAS_WINDOWS_CLIPPY_MANIFEST = o.manifest, CARGO_TARGET_DIR = W.abs .. "/" .. (o.target or "target") }
    local r = T:run{ PLAN, "script", "run", o.script or DEC, "--", o.all and "--all" or nil,
        cwd = repo.abs, env_unset = { "TILLANDSIAS_*" }, env = e, timeout_ms = 600000 }
    local last = ""
    for line in (r.stdout or ""):gmatch("[^\r\n]+") do last = line end
    return tostring(r.code) .. " " .. last, tostring(r.stderr)
end
local function arm(name, want, repo, o)
    local got, err = lint(repo, o)
    T:arm(name, got == want, got .. (got == want and "" or " " .. err:sub(1, 400)))
end

local R = T:git_repo("one")
crate(R, "crate", "clippy-fixture", CLEAN)
base(R)
local lib = R.rel .. "/crate/src/lib.rs"
local M, REFUSED, CLEANV, UNTOUCHED = "crate/Cargo.toml", "1 refused:windows-tray-clippy:1-errors",
    "0 ok:windows-tray-clippy:clean", "0 skip:windows-tray-clippy:crate-untouched"

arm("4 an untouched crate skips", UNTOUCHED, R, { manifest = M })
fs.write(lib, LINT)
arm("1 a clippy warning is refused by name", REFUSED, R, { manifest = M, all = true })
arm("4 a changed crate runs and refuses", REFUSED, R, { manifest = M })
arm("3 off Windows it skips by name", "0 skip:windows-tray-clippy:not-windows:Linux", R,
    { manifest = M, all = true, uname = "Linux", target = "off-windows" })
T:arm("3 and ran no cargo", not fs.exists(W.rel .. "/off-windows"), "off-windows target was built")
fs.write(lib, CLEAN)
arm("2 the same crate without the warning is clean", CLEANV, R, { manifest = M, all = true })

-- 1444-bzpu: three crates with the same lint except `clean`; `comment` names cfg(windows) in prose.
local R5 = T:git_repo("crates")
crate(R5, "crates/winlint", "winlint", WIN .. LINT)
crate(R5, "crates/comment", "comment", "// this crate never uses cfg(windows) in code\n" .. LINT)
crate(R5, "crates/clean", "clean", WIN .. CLEAN)
base(R5)
local function touch(name)
    local p = R5.rel .. "/crates/" .. name .. "/src/lib.rs"
    fs.write(p, fs.read(p) .. "// touched\n")
end
touch("comment")
arm("5 a comment-only mention is not a candidate", UNTOUCHED, R5, {})

local function mutant(repo, name, from, to)
    local a, b = src:find(from, 1, true)
    if not a then T:refuse("mutation-anchor-missing", name) end
    fs.write(repo.rel .. "/scripts/lua/" .. name .. ".lua", src:sub(1, a - 1) .. to .. src:sub(b + 1))
    return "scripts/lua/" .. name .. ".lua"
end
arm("6 MUTATION a scan that reads comments lints that crate", REFUSED, R5,
    { script = mutant(R5, "comments", [[line:gsub("//.*$", "")]], "line") })
touch("clean")
arm("5 a touched cfg(windows) crate with no warning is clean", CLEANV, R5, {})
touch("winlint")
arm("5 a touched cfg(windows) crate with a warning is refused", REFUSED, R5, {})

fs.write(lib, LINT)
arm("6 MUTATION without -D warnings the warning passes", CLEANV, R, { manifest = M, all = true,
    script = mutant(R, "nodeny", ', "--", "-D", "warnings" }', " }") })

T:finish()
