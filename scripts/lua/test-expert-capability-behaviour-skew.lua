-- @trace order:984-i4k2, order:2341-324y, spec:meta-orchestration
--
-- test-expert-capability-behaviour-skew.lua — the behaviour half of the expert
-- capability skew line (images/default/lib-expert-capability.sh). Comparing two
-- SUBCOMMAND SETS cannot see a subcommand whose behaviour changed: on 2026-09-03
-- four hosts ran stale binaries, all reporting skew=none. Ported from the .sh
-- (2341-324y).
--
--   0 CONTROL the binary answers build-id and source-revision at all
--   1 a current binary and its own checkout: none
--   2 the same subcommand set, one source byte changed: rebuild-required
--   3 a binary that CANNOT say its sources: unknown-currency, never none
--   4 the advice for both is non-empty and does not reassure
--   5 source-revision differs for different sources
--
-- Verdict: ok:expert-capability-behaviour-skew:<n> arms | violation:expert-capability-behaviour-skew:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("expert-capability-behaviour-skew")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local BIN = fixture.plan_binary()
if BIN == "" then T:skip("no-plan-binary") end
local W = T:scratch()
local CRATE = ROOT .. "/crates/tillandsias-plan"

fs.write(W.rel .. "/skew.sh", '. "$1"\nif [ "$2" = advice ]; then tillandsias_expert_capability_advice "$3"; exit 0; fi\n'
    .. 'tillandsias_expert_capability "$3" "$4" >/dev/null 2>&1\nprintf %s "${TILLANDSIAS_EXPERT_CAP_SKEW:-<unset>}"\n')
local function lib(...)
    local a = { SH, W.abs .. "/skew.sh", ROOT .. "/images/default/lib-expert-capability.sh", env_unset = { "TILLANDSIAS_EXPERT_*" }, timeout_ms = 60000 }
    for _, x in ipairs({ ... }) do a[#a + 1] = x end
    return (text.trim(T:run(a).stdout or ""))
end
local function skew(bin, checkout) return lib("skew", bin, checkout) end
local function revision(dir) local r = T:run{ BIN, "source-revision", dir, timeout_ms = 60000 }; return r.code, (text.trim(r.stdout or "")) end

T:arm("0 CONTROL the binary has a build-id", T:run{ BIN, "build-id", timeout_ms = 30000 }.code == 0, "no build-id subcommand")
local c0, rev = revision(CRATE)
T:arm("0 CONTROL the binary has a source-revision", c0 == 0 and rev ~= "", "rc=" .. tostring(c0))

local got = skew(BIN, ROOT)
T:arm("1 a current binary and its own checkout: none", got == "none", got)

fs.mkdir(W.rel .. "/checkout/crates")
T:must{ "cp", "-R", CRATE, W.abs .. "/checkout/crates/tillandsias-plan" }
local main = W.rel .. "/checkout/crates/tillandsias-plan/src/main.rs"
fs.write(main, fs.read(main) .. "\n// behaviour-skew fixture perturbation\n")
got = skew(BIN, W.abs .. "/checkout")
T:arm("2 the same subcommands from other sources: rebuild-required", got == "rebuild-required", got)

fs.write(W.rel .. "/oldbin", '#!/bin/sh\ncase "$1" in\n  capabilities) cat "' .. CRATE .. '/capabilities.txt" ;;\n'
    .. "  build-id) echo \"error: unknown subcommand 'build-id'\" >&2; exit 2 ;;\n  *) exit 2 ;;\nesac\n")
T:must{ "chmod", "+x", W.abs .. "/oldbin" }
got = skew(W.abs .. "/oldbin", ROOT)
T:arm("3 a binary with no build-id: unknown-currency", got == "unknown-currency", got)

for _, v in ipairs({ "rebuild-required", "unknown-currency" }) do
    local a = lib("advice", v)
    T:arm("4 the advice for " .. v .. " does not reassure", a ~= "" and not a:find("No capability skew", 1, true), "[" .. a .. "]")
end
local c5, other = revision(W.abs .. "/checkout/crates/tillandsias-plan")
T:arm("5 source-revision differs for different sources", c5 == 0 and other ~= "" and other ~= rev, rev .. " vs " .. other)
T:finish()
