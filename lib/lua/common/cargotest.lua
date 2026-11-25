-- @trace order:2382-ubmc
--
-- common/cargotest.lua — cargo builds and named unit tests for a fixture that drives them.
--
--   local C = require("common.cargotest").new(T)          -- skips T with no cargo or no linker
--   local bin = C:build("tillandsias-headless", "name")   -- the debug binary's absolute path
--   local x = C:test({ "-p", ... }, { FAKE = bin })       -- x.rc, x.out; x:ok("mod::tests::name")

local fixture = require "common.fixture"
local M, C, X = {}, {}, {}
C.__index, X.__index = C, X

function M.new(T)
    if not fixture.which("cargo") then T:skip("no-cargo") end
    if not (fixture.which("cc") or fixture.which("gcc") or fixture.which("clang") or fixture.which("link")) then T:skip("no-linker") end
    return setmetatable({ T = T, root = fixture.repo_root() }, C)
end

-- The environment goes through a shell: a cargo child needs names the door would drop.
function C:cargo(argv, e)
    local pre = ""
    for k, v in pairs(e or {}) do pre = pre .. "export " .. k .. "='" .. v:gsub("'", "'\\''") .. "'\n" end
    local a = { fixture.posix_shell(), "-s", "--" }
    for _, v in ipairs(argv) do a[#a + 1] = v end
    local r = proc.run{ argv = a, cwd = self.root, stdin = pre .. 'exec cargo "$@" </dev/null 2>&1\n', timeout_ms = 840000 }
    return setmetatable({ rc = r.code, out = "\n" .. (r.stdout or ""):gsub("\r", ""), status = r.status, why = tostring(r.why or "") }, X)
end

function C:build(package, ...)
    local argv = { "build", "-p", package }
    for _, b in ipairs{ ... } do argv[#argv + 1] = "--bin"; argv[#argv + 1] = b end
    local x = self:cargo(argv)
    if x.rc ~= 0 then self.T:refuse("build-failed", x.out:sub(-1500)) end
    local target = env.get("CARGO_TARGET_DIR")
    if not target or target == "" then target = self.root .. "/target" end
    if not fixture.is_abs(target) then target = self.root .. "/" .. target end
    local paths = {}
    for i, b in ipairs{ ... } do
        paths[i] = target .. "/debug/" .. b
        if self.T:run{ "test", "-x", paths[i] }.code ~= 0 then self.T:refuse("binary-missing", paths[i]) end
    end
    return table.unpack(paths)
end

function C:test(argv, e)
    local a = { "test" }
    for _, v in ipairs(argv) do a[#a + 1] = v end
    return self:cargo(a, e)
end

-- A test that passed, by its full name.
function X:ok(name) return text.contains(self.out, "\ntest " .. name .. " ... ok\n") end
function X:failed(name) return text.contains(self.out, "\ntest " .. name .. " ... FAILED\n") end
-- The lines that explain a red run.
function X:tail()
    local l = {}
    for line in self.out:gmatch("[^\n]+") do
        if line:find("panicked", 1, true) or line:find("FAILED", 1, true) or line:match("^error") then l[#l + 1] = line end
    end
    return "rc=" .. tostring(self.rc) .. " " .. table.concat(l, " | "):sub(1, 900) .. self.why
end

return M
