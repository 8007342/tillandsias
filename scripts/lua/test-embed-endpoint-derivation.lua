-- @trace order:967-xq5e, order:2303-h6qe
--
-- test-embed-endpoint-derivation.lua — pin images/default/lib-embed-endpoint.sh.
-- Ported from the .sh (2303-h6qe).
--
-- scripts/spec-index-ensure.sh INHERITED TILLANDSIAS_EMBED_ENDPOINT and refused
-- when absent, while every derivation lived in the forge lane, so the host lane
-- never refreshed an index: 32 consecutive skips on macuahuitl, and the one host
-- that worked did so because of a git-ignored settings file.
--
-- No network: the probe is a stub `curl` that answers only the URL in STUB_OK.
--
--   1 an explicit endpoint is never probed and never overridden
--   2 the host lane derives loopback; 3 the forge lane the enclave service name
--   4 PROBE, DO NOT ASSUME (712-r5x8): nothing answers, nothing is exported
--   5 a root url gains /v1; 6 one spelled /v1 does not gain a second
--   7 OLLAMA_HOST beats the convention default
--   8 THE SUBSHELL TRAP: v="$(resolve_embed_endpoint)" loses the export, so the
--     verdict says derived while the variable is unset. Asserted, so that the
--     contract comment in the library stays earned.
--   9 the real caller does not use that form
--  10 nothing outside the helper re-derives the endpoint (an EXECUTABLE export;
--     prose that quotes the statement is documentation, not a copy)
--
-- Verdict: ok:embed-endpoint-derivation:10 arms | violation:embed-endpoint-derivation:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("embed-endpoint-derivation")
local ROOT = fixture.repo_root()
local LIB = ROOT .. "/images/default/lib-embed-endpoint.sh"
local W = T:scratch()
fs.mkdir(W.rel .. "/bin")
fs.write(W.rel .. "/bin/curl", [==[
#!/usr/bin/env bash
for a in "$@"; do case "$a" in http*) url="$a";; esac; done
[ -n "${STUB_OK:-}" ] && [ "$url" = "$STUB_OK" ] && exit 0
exit 7
]==])
T:must{ "chmod", "+x", W.abs .. "/bin/curl" }
-- PATH is set inside the shell, from the script's own dir: a C:/ dir would
-- split it on native Windows.
-- proc.run passes TILLANDSIAS_* through, so an arm's own values come in as ARM_*
-- and everything else the library reads is unset.
local HEAD = 'for v in TILLANDSIAS_EMBED_ENDPOINT TILLANDSIAS_INFERENCE_ENDPOINT TILLANDSIAS_HOST_KIND OLLAMA_HOST; do\n'
    .. '  unset "$v"; eval "[ -z \\"\\${ARM_$v:-}\\" ] || export $v=\\"\\$ARM_$v\\""\ndone\n'
    .. 'PATH="$(cd "$(dirname "$0")" && pwd)/bin:$PATH"\n. "$LIB"\n'
fs.write(W.rel .. "/direct.sh", HEAD .. 'resolve_embed_endpoint >/dev/null 2>&1\nprintf "%s|%s" "${TILLANDSIAS_EMBED_ENDPOINT_VERDICT:-none}" "${TILLANDSIAS_EMBED_ENDPOINT:-unset}"\n')
fs.write(W.rel .. "/subshell.sh", HEAD .. 'v="$(resolve_embed_endpoint)"\nprintf "%s|%s" "$v" "${TILLANDSIAS_EMBED_ENDPOINT:-unset}"\n')
local function run(script, arm)
    local e = { LIB = LIB, STUB_OK = arm.STUB_OK or "" }
    for k, v in pairs(arm) do if k ~= "STUB_OK" then e["ARM_" .. k] = v end end
    return T:run{ fixture.posix_shell(), W.abs .. "/" .. script, env = e, timeout_ms = 20000 }.stdout or ""
end
local function check(name, want, e)
    local o = run("direct.sh", e)
    T:arm(name, o == want, o .. " want " .. want)
end
local function derived(url) return "ok:embed-endpoint:derived:" .. url .. "|" .. url end
local LOOP = "http://127.0.0.1:11434/v1"

check("1 an explicit endpoint wins unprobed", "ok:embed-endpoint:explicit:http://explicit:1/v1|http://explicit:1/v1",
    { TILLANDSIAS_EMBED_ENDPOINT = "http://explicit:1/v1" })
check("2 the host lane derives loopback", derived(LOOP), { STUB_OK = LOOP .. "/models" })
check("3 the forge lane derives the enclave service", derived("http://inference:11434/v1"),
    { TILLANDSIAS_HOST_KIND = "forge", STUB_OK = "http://inference:11434/v1/models" })
check("4 an unreachable endpoint exports nothing", "unreachable:embed-endpoint:" .. LOOP .. "|unset", {})
check("5 a root url gains /v1", derived("http://host:9/v1"),
    { TILLANDSIAS_INFERENCE_ENDPOINT = "http://host:9", STUB_OK = "http://host:9/v1/models" })
check("6 an existing /v1 is not doubled", derived("http://host:9/v1"),
    { TILLANDSIAS_INFERENCE_ENDPOINT = "http://host:9/v1", STUB_OK = "http://host:9/v1/models" })
check("7 OLLAMA_HOST is honoured", derived("http://olla:2/v1"),
    { OLLAMA_HOST = "http://olla:2", STUB_OK = "http://olla:2/v1/models" })

local o = run("subshell.sh", { STUB_OK = LOOP .. "/models" })
T:arm("8 the subshell trap still reproduces: derived, and the variable unset",
    o == "ok:embed-endpoint:derived:" .. LOOP .. "|unset", o .. " (if it is gone, update the contract comment in the library)")
T:arm("9 spec-index-ensure.sh does not call it in a command substitution",
    not fs.read("scripts/spec-index-ensure.sh"):find('_sie_verdict="$(resolve_embed_endpoint)"', 1, true), "see arm 8")

local r = T:run{ "grep", "-rlE", "^[[:space:]]*export[[:space:]]+TILLANDSIAS_EMBED_ENDPOINT=", "--include=*.sh", "images", "scripts", cwd = ROOT }
local copies, helper = {}, false
for _, l in ipairs(text.lines(r.stdout or "")) do
    if l:find("lib-embed-endpoint.sh", 1, true) then helper = true
    elseif l ~= "" then copies[#copies + 1] = l end
end
T:arm("10 the helper is the only derivation", helper and #copies == 0,
    "helper seen: " .. tostring(helper) .. "; copies: " .. table.concat(copies, " "))
T:finish()
