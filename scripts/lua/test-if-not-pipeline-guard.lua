-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
-- @trace order:2080-zcur
--
-- test-if-not-pipeline-guard.lua — scripts/lua/check-no-spawn-in-if-not.lua
-- refuses `if ! <pipeline>` (a pipeline whose producer can die on SIGPIPE
-- reads as a negative) and accepts the bare-command and case idioms.
--   1 refuses  if ! printf "%s" "foo" | grep -q "foo"
--   2 accepts  if ! grep -q "foo" <<<"foo"
--   3 accepts  the case $'\n'..$'\n' idiom
-- Keeps the established verdict line the litmus greps: ok:if-not-pipeline-guard-shape:3
-- Ported from scripts/test-if-not-pipeline-guard.sh onto common.fixture.
--
-- Usage: tillandsias-plan script run scripts/lua/test-if-not-pipeline-guard.lua

local fixture = require "common.fixture"
local T = fixture.new("if-not-pipeline-guard")
local PLAN = fixture.plan_bin()
if not PLAN then T:skip("no-script-runner") end
local CHECK = fixture.repo_root() .. "/scripts/lua/check-no-spawn-in-if-not.lua"
local W = T:scratch()
fs.write(W.rel .. "/fail_fixture.sh",
    '#!/usr/bin/env bash\nif ! printf "%s" "foo" | grep -q "foo"; then\n    exit 1\nfi\n')
fs.write(W.rel .. "/pass_fixture1.sh", '#!/usr/bin/env bash\nif ! grep -q "foo" <<<"foo"; then\n    exit 1\nfi\n')
fs.write(W.rel .. "/pass_fixture2.sh",
    "#!/usr/bin/env bash\ncase $'\\n'foo'\\n' in\n    *$'\\n'foo'\\n'*) ;;\n    *) exit 1 ;;\nesac\n")
local function check(f) return T:run{ PLAN, "script", "run", CHECK, "--", W.abs .. "/" .. f }.code end

T:arm("1 refuses a pipeline under if !", check("fail_fixture.sh") ~= 0, "accepted")
T:arm("2 accepts a bare command under if !", check("pass_fixture1.sh") == 0, "refused")
T:arm("3 accepts the case idiom", check("pass_fixture2.sh") == 0, "refused")
T:finish{
    ok = function(p) return "ok:if-not-pipeline-guard-shape:" .. p end,
}
