-- @env PATH
-- @trace spec:default-image, order:626-p4xd, order:2379-p5dq
--
-- test-opencode-render-probe.lua — the opencode render contract in images/default/lib-common.sh: a binary
-- that answers --version but never draws is refused, one that draws is accepted, a crash is noticed before
-- the budget is spent, and the memo is keyed on the binary. Both functions are cut from the library and
-- run on stubs; what is judged is the return code. Ported from the .sh of the same name.
--
-- Usage: tillandsias-plan script run scripts/lua/test-opencode-render-probe.lua
-- Verdict: ok:opencode-render-probe:<n> arms | violation:...:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("opencode-render-probe")
local SH = fixture.posix_shell()
local lib = "\n" .. fs.read("images/default/lib-common.sh"):gsub("\r\n", "\n")
local function cut(name)
    local a = lib:find("\n" .. name .. "() {\n", 1, true)
    local b = a and select(2, lib:find("\n}\n", a, true))
    if not b then T:refuse("function-missing", name) end
    return lib:sub(a + 1, b)
end
local FUNCS = cut("opencode_render_contract_ok") .. cut("opencode_render_contract_cached")
local function mutant(from, to)
    local a, b = FUNCS:find(from, 1, true)
    if not a then T:refuse("mutation-anchor-missing", from) end
    return FUNCS:sub(1, a - 1) .. to .. FUNCS:sub(b + 1)
end
if not fixture.which("timeout") then T:skip("no-timeout") end -- the probe's own dependency

local W = T:scratch()
local VERSION = '#!/usr/bin/env bash\n[ "${1:-}" != --version ] || { echo 1.18.10; exit 0; }\necho ran >> "$RUNS"\n'
fs.write(W.rel .. "/blind", VERSION .. "echo starting...\nexec sleep 30\n")
fs.write(W.rel .. "/good", VERSION .. "printf '\\033[?1049h'\nprintf '\\033[38;2;128;128;128mhello\\033[0m\\n'\nexec sleep 30\n")
fs.write(W.rel .. "/crash", VERSION .. 'echo "Failed to initialize OpenTUI" >&2\nexit 1\n')
T:must{ SH, "-s", "--", W.abs, stdin = 'cd "$1" && chmod +x blind good crash\n' }

-- Run shell lines against the functions; each `got <label> <command>` prints label=rc, and SECONDS a budget.
local function probe(lines, o)
    o = o or {}
    local r = T:run{ SH, "-s", "--", W.abs, stdin = 'cd "$1" || exit 96\nexport RUNS="$PWD/runs"; : > runs\ntrace_lifecycle() { :; }\n'
        .. 'export HARNESS_CURL_ROOT="$PWD/' .. (o.cache or "cache") .. '" TILLANDSIAS_RENDER_PROBE_BUDGET_S=' .. (o.budget or 10) .. "\n"
        .. 'got() { l="$1"; shift; "$@" >/dev/null 2>&1; echo "$l=$?"; }\nruns() { echo "$1=$(grep -c ran runs)"; }\n' .. (o.funcs or FUNCS) .. lines .. "\nexit 0\n",
        env = { PATH = env.get("PATH") }, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 120000 }
    local s = " " .. (r.stdout or ""):gsub("%s+", " ")
    return function(kv) return s:find(" " .. kv .. " ", 1, true) ~= nil end, s .. " " .. (r.stderr or ""):sub(1, 200)
end
local OK = "opencode_render_contract_ok ./"
local has, got = probe("got blind " .. OK .. "blind", { budget = 2 })
T:arm("1 a binary that never draws is refused", has("blind=1"), got)
has, got = probe("got good " .. OK .. "good")
T:arm("2 CONTROL one that draws is accepted", has("good=0"), got)
has, got = probe("SECONDS=0\ngot crash " .. OK .. "crash\n[ $SECONDS -lt 10 ] && echo early=yes", { budget = 20 })
T:arm("3 one that exits before drawing is refused", has("crash=1"), got)
T:arm("4 and the probe does not wait out its budget", has("early=yes"), got)
local SWAP = "cp good swap\ngot first opencode_render_contract_cached ./swap\ncp blind swap\nexport TILLANDSIAS_RENDER_PROBE_BUDGET_S=2\n"
    .. "got swapped opencode_render_contract_cached ./swap\n"
has, got = probe(SWAP, { cache = "c5" })
T:arm("5 a broken binary swapped in at the same path is probed again and refused", has("first=0") and has("swapped=1"), got)
local TWICE = "got a opencode_render_contract_cached ./good\ngot b opencode_render_contract_cached ./good\nruns runs\n"
has, got = probe(TWICE, { cache = "c6" })
T:arm("6 a binary already cleared is not run again", has("a=0") and has("b=0") and has("runs=1"), got)

has, got = probe("got blind " .. OK .. "blind", { budget = 2, funcs = mutant("waited=0 status=1", "waited=0 status=0") })
T:arm("7 MUTATION a probe that passes unless told otherwise fails arm 1", has("blind=0"), got)
has, got = probe(SWAP, { cache = "c7", funcs = mutant('{ sha256sum "$bin_path" 2>/dev/null || shasum -a 256 "$bin_path" 2>/dev/null; }', 'printf "%s" "$bin_path"') })
T:arm("7 MUTATION a memo keyed on the path fails arm 5", has("first=0") and has("swapped=0"), got)
has, got = probe(TWICE, { cache = "c8", funcs = mutant('[ -f "$stamp" ] && return 0', ":") })
T:arm("7 MUTATION a memo that is never read fails arm 6", has("b=0") and has("runs=2"), got)

T:finish()
