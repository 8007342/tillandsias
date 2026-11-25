-- @env PATH
-- @trace order:439, order:429, order:2373-f26m, spec:forge-hot-cold-split
--
-- test-harness-contract-probe.lua — the forge's harness probe checks that every flag we
-- pass still exists, not only that --version answers (order 429: a flag opencode does not
-- have was silently swallowed). Stub harnesses; the functions are extracted from
-- lib-common.sh, whose top level is forge setup. Ported from the .sh (2373-f26m).
--
--   1 a compliant harness passes
--   2 LOAD-BEARING: a missing flag fails, and is NAMED
--   3 the codex contract, both ways
--   4 a harness with no declared contract is not penalised
--   5 unusable or empty help is not a broken contract: only a POSITIVE absence may fail,
--     or network noise would trigger rollbacks
--
-- Verdict: ok:harness-contract-probe:<n> arms | violation:harness-contract-probe:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("harness-contract-probe")
local SH = fixture.posix_shell()
local W = T:scratch()
fs.mkdir(W.rel .. "/bin")
local fns = { 'trace_lifecycle() { printf "trace: %s\\n" "$*"; }' }
for _, name in ipairs{ "harness_contract_help_cmd", "harness_contract_flags", "harness_contract_ok" } do
    local p = false
    for l in (fs.read("images/default/lib-common.sh") .. "\n"):gmatch("([^\n]*)\n") do
        if l:sub(1, #name + 2) == name .. "()" then p = true end
        if p then fns[#fns + 1] = l end
        if p and l:sub(1, 1) == "}" then break end
    end
    if not p then T:refuse("no-subject", name .. " not found in images/default/lib-common.sh") end
end
fs.write(W.rel .. "/probe.sh", table.concat(fns, "\n") .. '\nharness_contract_ok "$1" 2>&1\n')
local function probe(name, body)
    fs.write(W.rel .. "/bin/" .. name, '#!/usr/bin/env bash\ncase "$*" in *--version*) echo "9.9.9"; exit 0 ;; esac\n' .. body .. "\n")
    T:must{ "chmod", "+x", W.abs .. "/bin/" .. name }
    local r = T:run{ SH, W.abs .. "/probe.sh", name, cwd = W.abs, env = { NPM_CONFIG_PREFIX = W.abs, PATH = env.get("PATH"), HOME = W.abs }, env_unset = { "TILLANDSIAS_*" } }
    return r.code, (r.stdout or "") .. (r.stderr or "")
end
local function got(rc, o) return "rc=" .. tostring(rc) .. " " .. o end
local rc, o = probe("opencode", 'echo "  --auto     auto-approve permissions"; echo "  --format   default or json"')
T:arm("1 a compliant harness passes", rc == 0, got(rc, o))
rc, o = probe("opencode", 'echo "  --auto     auto-approve permissions"')
T:arm("2 a missing flag fails the contract and is NAMED", rc ~= 0 and o:find("--format", 1, true), got(rc, o))
rc, o = probe("codex", 'echo "  --json"; echo "  -o, --output-last-message <FILE>"; echo "  --dangerously-bypass-approvals-and-sandbox"')
T:arm("3 a compliant codex passes", rc == 0, got(rc, o))
rc, o = probe("codex", 'echo "  --json"')
T:arm("3 codex with missing flags fails", rc ~= 0, got(rc, o))
rc, o = probe("openspec", 'echo "  --whatever"')
T:arm("4 a harness with no declared contract passes", rc == 0, got(rc, o))
rc, o = probe("opencode", "exit 7")
T:arm("5 unusable help is not a broken contract", rc == 0, got(rc, o))
rc, o = probe("opencode", 'echo ""')
T:arm("5 empty help is not a broken contract", rc == 0, got(rc, o))
T:finish()
