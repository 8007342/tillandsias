-- @trace order:1397-eppt, order:2302-pspt
--
-- test-spec-registry-status.lua — the spec/registry status guard
-- (scripts/lua/check-spec-registry-status.lua) refuses what it must and names
-- what it cannot decide. Ported from test-spec-registry-status.sh (2302-pspt).
--
-- Hermetic: a fake openspec tree, pointed at through TILLANDSIAS_SPEC_ROOT.
--   1 agreement passes; an annotated line and a `status:` prefix are not mismatches
--   2 a flipped status word is refused by name
--   3 a deleted ## Status section is refused by name
--   4 an UNDECIDED pair is printed and counted apart, never hidden
-- No plan binary is a loud skip, never a silent pass.
--
-- GRAMMAR ok:spec-registry-status-fixture:4 arms | violation:spec-registry-status-fixture:<n>-failed

local fixture = require "common.fixture"
local V = require "common.verdict"
local T = fixture.new("spec-registry-status-fixture")
local ROOT = fixture.repo_root()
local BIN = fixture.plan_binary()
if BIN == "" then
    V.skip("spec-registry-status-fixture", "no-script-runner — rebuild it (cargo build --release -p tillandsias-plan)")
end
local CHECK = ROOT .. "/scripts/lua/check-spec-registry-status.lua"
local W = T:scratch()

local ALPHA = "# alpha\n\n## Status\n\nactive\n\n## Purpose\nx\n"
local function build(alpha)
    local t = W.rel .. "/t/openspec"
    for _, d in ipairs({ "alpha", "beta", "gamma" }) do fs.mkdir(t .. "/specs/" .. d) end
    fs.write(t .. "/litmus-bindings.yaml",
        "- spec_id: alpha\n  status: active\n- spec_id: beta\n  status: obsolete\n- spec_id: gamma\n  status: active\n")
    fs.write(t .. "/specs/alpha/spec.md", alpha or ALPHA)
    fs.write(t .. "/specs/beta/spec.md", "# beta\n\n## Status\n\nobsolete (removed in v0.3 — see x)\n")
    fs.write(t .. "/specs/gamma/spec.md", "# gamma\n\n## Status\n\nstatus: active\n")
end
local function run(undecided)
    local r = proc.run{ argv = { BIN, "script", "run", CHECK }, cwd = ROOT, timeout_ms = 60000,
        env = { TILLANDSIAS_SPEC_ROOT = W.abs .. "/t", TILLANDSIAS_SPEC_UNDECIDED = undecided or "" } }
    return text.trim((r.stdout or "") .. (r.stderr or "")), (r.status == "exited") and r.code or -1
end
local function has(o, ...)
    local at = 1
    for _, s in ipairs({ ... }) do
        local i = o:find(s, at, true); if not i then return false end; at = i + #s
    end
    return true
end

build()
local o, rc = run()
T:arm("agreement passes; an annotated line and a status: prefix are not mismatches",
    rc == 0 and o == "ok:spec-registry-status:3 undecided=0", "rc=" .. rc .. " " .. o)

build((ALPHA:gsub("\nactive\n", "\nobsolete\n")))
o, rc = run()
T:arm("a flipped status word is refused by name",
    rc == 1 and has(o, "mismatch:alpha:spec=obsolete:registry=active", "refused:spec-registry-status:1 (of 3)"),
    "rc=" .. rc .. " " .. o)

build("# alpha\n\n## Purpose\nx\n")
o, rc = run()
T:arm("a deleted ## Status section is refused by name",
    rc == 1 and has(o, "mismatch:alpha:spec=<none>:registry=active"), "rc=" .. rc .. " " .. o)

build((ALPHA:gsub("\nactive\n", "\ndraft\n")))
o, rc = run("alpha")
T:arm("an UNDECIDED pair is printed and counted apart, not hidden",
    rc == 0 and has(o, "undecided:alpha:spec=draft:registry=active", "ok:spec-registry-status:3 undecided=1"),
    "rc=" .. rc .. " " .. o)

T:finish()
