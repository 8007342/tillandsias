-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
-- @trace order:1397-eppt, order:2080-zcur
--
-- test-spec-registry-status.lua — the spec/registry status guard
-- (scripts/lua/check-spec-registry-status.lua) can fail. Hermetic arms over a
-- scratch registry with alpha(active) beta(obsolete) gamma(active):
--   1 agreement passes; an annotated line and a status: prefix are not mismatches
--   2 a flipped status word is refused by name
--   3 a deleted ## Status section is refused by name
--   4 an UNDECIDED pair is printed and counted apart, not hidden
-- Ported from scripts/test-spec-registry-status.sh onto common.fixture.
--
-- Usage: tillandsias-plan script run scripts/lua/test-spec-registry-status.lua
-- Verdict: ok:spec-registry-status-fixture:<n> arms | violation:spec-registry-status-fixture:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("spec-registry-status-fixture")
local PLAN = fixture.plan_bin()
if not PLAN then T:skip("no-script-runner") end
local CHECK = fixture.repo_root() .. "/scripts/lua/check-spec-registry-status.lua"
local W

local function build()
    W = T:scratch()
    for _, s in ipairs{ "alpha", "beta", "gamma" } do fs.mkdir(W.rel .. "/openspec/specs/" .. s) end
    fs.write(W.rel .. "/openspec/litmus-bindings.yaml",
        "- spec_id: alpha\n  status: active\n- spec_id: beta\n  status: obsolete\n- spec_id: gamma\n  status: active\n")
    fs.write(W.rel .. "/openspec/specs/alpha/spec.md", "# alpha\n\n## Status\n\nactive\n\n## Purpose\nx\n")
    fs.write(W.rel .. "/openspec/specs/beta/spec.md", "# beta\n\n## Status\n\nobsolete (removed in v0.3 — see x)\n")
    fs.write(W.rel .. "/openspec/specs/gamma/spec.md", "# gamma\n\n## Status\n\nstatus: active\n")
end
local function run(undecided)
    local r = T:run{ PLAN, "script", "run", CHECK,
        env = { TILLANDSIAS_SPEC_ROOT = W.abs, TILLANDSIAS_SPEC_UNDECIDED = undecided or "" } }
    return r.code, text.trim(r.stdout or "")
end

build()
local rc, o = run()
T:arm("agreement passes; an annotated line and a status: prefix are not mismatches",
    rc == 0 and o == "ok:spec-registry-status:3 undecided=0", "rc=" .. tostring(rc) .. " " .. o)
build(); fs.write(W.rel .. "/openspec/specs/alpha/spec.md", "# alpha\n\n## Status\n\nobsolete\n\n## Purpose\nx\n")
rc, o = run()
T:arm("a flipped status word is refused by name",
    rc == 1 and o:find("mismatch:alpha:spec=obsolete:registry=active", 1, true)
        and o:find("refused:spec-registry-status:1 (of 3)", 1, true), "rc=" .. tostring(rc) .. " " .. o)
build(); fs.write(W.rel .. "/openspec/specs/alpha/spec.md", "# alpha\n\n## Purpose\nx\n")
rc, o = run()
T:arm("a deleted ## Status section is refused by name",
    rc == 1 and o:find("mismatch:alpha:spec=<none>:registry=active", 1, true), "rc=" .. tostring(rc) .. " " .. o)
build(); fs.write(W.rel .. "/openspec/specs/alpha/spec.md", "# alpha\n\n## Status\n\ndraft\n\n## Purpose\nx\n")
rc, o = run("alpha")
T:arm("an UNDECIDED pair is printed and counted apart, not hidden",
    rc == 0 and o:find("undecided:alpha:spec=draft:registry=active", 1, true)
        and o:find("ok:spec-registry-status:3 undecided=1", 1, true), "rc=" .. tostring(rc) .. " " .. o)

T:finish()
