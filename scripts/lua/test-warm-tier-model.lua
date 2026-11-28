-- @env PATH HOME
-- @trace order:965-hz3f, spec:inference-container, order:2332-ae6r
--
-- test-warm-tier-model.lua — images/default/lib-common.sh picks which tier model a forge warms, and
-- the warmed model is the one expert-serve answers with. Ported from the .sh of the same name.
-- lib-common.sh cannot be sourced outside the image (vendor CA bundle), so its two functions are
-- cut out and driven: the selection is pure, the warm gets a stubbed curl.
--
--   1 GPU lanes prefer 14b, among models PRESENT    2 the CPU floor is 0.5b first, never 7b or 14b
--   3 nothing to pick is non-zero                   4 no substring match
--   5 the selection is exported                     6 the lane warms in-shell, before expert-serve
--   7 MUTATION each rule, removed, changes an arm's answer
--
-- Usage: tillandsias-plan script run scripts/lua/test-warm-tier-model.lua
-- Verdict: ok:warm-tier-model-select:<n> arms | violation:warm-tier-model-select:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("warm-tier-model-select")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
local LIB = "images/default/lib-common.sh"
local src = "\n" .. fs.read(LIB):gsub("\r\n", "\n")
local function cut(name)
    local a = src:find("\n" .. name .. "() {\n", 1, true)
    local b = a and src:find("\n}\n", a, true)
    if not b then T:refuse("function-not-found", name) end
    return src:sub(a + 1, b + 2)
end
local SELECT, WARM = cut("_tillandsias_select_warm_model"), cut("warm_tier_model_fail_soft")
local W = T:scratch()

local function sh(script)
    local r = T:run{ SH, "-s", cwd = ROOT, env_unset = { "TILLANDSIAS_*" },
        env = { PATH = env.get("PATH"), HOME = env.get("HOME") }, stdin = script }
    return r.code, text.trim(r.stdout or "")
end
-- "<model> <rc>": the function answers on stdout.
local function pick(class, avail, fn)
    local rc, o = sh((fn or SELECT) .. "set -eu\n_tillandsias_select_warm_model '" .. class .. "' '" .. avail .. "'\n")
    return o .. " " .. tostring(rc)
end
local function arm(name, want, got) T:arm(name, got == want, got) end

local ALL = "qwen2.5:0.5b,qwen2.5:3b,qwen2.5:7b,qwen2.5:14b,nomic-embed-text:latest"
arm("1 gpu prefers 14b", "qwen2.5:14b 0", pick("workstation-gpu", ALL))
arm("1 hybrid prefers 14b", "qwen2.5:14b 0", pick("hybrid-gpu-npu", ALL))
arm("1 gpu without 14b takes 7b", "qwen2.5:7b 0", pick("workstation-gpu", "qwen2.5:3b,qwen2.5:7b"))
arm("1 gpu with only 3b takes 3b", "qwen2.5:3b 0", pick("workstation-gpu", "qwen2.5:3b"))
arm("2 the cpu floor prefers 0.5b, with 14b present", "qwen2.5:0.5b 0", pick("cpu-only", ALL))
arm("2 mobile-npu uses the cpu floor", "qwen2.5:0.5b 0", pick("mobile-npu", ALL))
arm("2 an unknown class uses the cpu floor", "qwen2.5:0.5b 0", pick("", ALL))
arm("2 the cpu floor without 0.5b takes 3b", "qwen2.5:3b 0", pick("cpu-only", "qwen2.5:7b,qwen2.5:3b"))
arm("2 the cpu floor never takes 7b", " 1", pick("cpu-only", "qwen2.5:7b,nomic-embed-text:latest"))
arm("2 the cpu floor never takes 14b", " 1", pick("cpu-only", "qwen2.5:14b"))
arm("3 no candidate is non-zero", " 1", pick("workstation-gpu", "nomic-embed-text:latest"))
arm("3 an empty inventory is non-zero", " 1", pick("workstation-gpu", ""))
arm("4 a name that contains a candidate is not it", " 1", pick("workstation-gpu", "notqwen2.5:14bx"))

-- expert-serve synthesises with TILLANDSIAS_INFERENCE_MODEL (default 0.5b). The warm once loaded
-- 14b and exported nothing, so the server answered with a cold 0.5b.
local CURL = [[
curl() {
    case "$*" in
        */api/tags*) printf '{"models":[{"name":"qwen2.5:0.5b"},{"name":"qwen2.5:7b"},{"name":"qwen2.5:14b"}]}\n' ;;
        */v1/chat/completions*) return 0 ;;
        *) return 7 ;;
    esac
}
]]
-- The answer is read by a CHILD, as expert-serve would: a shell variable does not reach one.
local READ = [[exec "$BASH" -c 'printf "%s" "${TILLANDSIAS_INFERENCE_MODEL:-<unset>}"']]
local function serving(class, preset, warm)
    local _, o = sh(SELECT .. (warm or WARM) .. CURL .. "set -euo pipefail\n"
        .. (preset and ("export TILLANDSIAS_INFERENCE_MODEL='" .. preset .. "'\n") or "")
        .. "export FORGE_EXPERTS_STATE_DIR='" .. W.rel .. "/state' TILLANDSIAS_ACCEL_ENVELOPE='accel_class=" .. class .. "'\n"
        .. "export TILLANDSIAS_INFERENCE_ENDPOINT='http://stub:11434/v1'\n"
        .. "warm_tier_model_fail_soft >/dev/null 2>&1\n" .. READ .. "\n")
    return o
end
arm("5 a gpu warm exports 14b", "qwen2.5:14b", serving("workstation-gpu"))
arm("5 a cpu warm exports 0.5b", "qwen2.5:0.5b", serving("cpu-only"))
arm("5 the operator's model is kept", "qwen2.5:7b", serving("workstation-gpu", "qwen2.5:7b"))

local function lane(fn) return (src:find("\n        " .. fn .. " >>/tmp/forge-lifecycle.log 2>&1 || true\n", 1, true)) end
local warm_at, serve_at = lane("warm_tier_model_fail_soft"), lane("start_expert_serve_fail_soft")
T:arm("6 the lane warms in-shell, before expert-serve", warm_at and serve_at and warm_at < serve_at,
    "warm=" .. tostring(warm_at) .. " serve=" .. tostring(serve_at))

local function without(fn, from, to)
    local a, b = fn:find(from, 1, true)
    if not a then T:refuse("mutation-anchor-missing", from) end
    return fn:sub(1, a - 1) .. to .. fn:sub(b + 1)
end
arm("7 MUTATION a floor that lists 7b takes 7b", "qwen2.5:7b 0", pick("cpu-only", "qwen2.5:7b,nomic-embed-text:latest",
    without(SELECT, '_wm_order="qwen2.5:0.5b qwen2.5:3b"', '_wm_order="qwen2.5:0.5b qwen2.5:7b"')))
arm("7 MUTATION an unanchored match takes the substring", "qwen2.5:14b 0", pick("workstation-gpu", "notqwen2.5:14bx",
    without(SELECT, '*",${_wm_cand},"*', '*"${_wm_cand}"*')))
arm("7 MUTATION a warm that does not export leaves the server unset", "<unset>", serving("workstation-gpu", nil,
    without(WARM, "    export TILLANDSIAS_INFERENCE_MODEL=", "    TILLANDSIAS_INFERENCE_MODEL=")))

T:finish()
