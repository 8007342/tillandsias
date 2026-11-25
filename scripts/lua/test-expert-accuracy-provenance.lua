-- @env PATH HOME
-- @trace order:1257-jxu9, order:2300-6m9m
--
-- test-expert-accuracy-provenance.lua — record-expert-accuracy.sh keeps its provenance.
-- Ported from the .sh of the same name (2300-6m9m). Two silent losses, yoga 2026-09-18: it
-- asked the ollama-native /api/show on the OpenAI-compatible base (…/v1/api/show, a 404),
-- and it wrote its series under a gitignored cache nobody else could read.
--
-- The script runs as a COPY in a scratch repo (its --path makes a directory), with the host
-- identity stubbed and `curl` stubbed to log what it was asked and answer like ollama.
--
--   1 V1 BASE  a /v1 endpoint asks the NATIVE base; the record carries F16 and bert
--   2 NO GUESS an endpoint that cannot answer leaves both unknown (negative control)
--   3 OVERRIDE TILLANDSIAS_OLLAMA_BASE names the native base outright
--   4 TRACKED  the default log is plan/metrics/expert-accuracy.d/<host>.jsonl, and the real
--              tree's git does not ignore it
--   5 PER HOST two host identities resolve to two files (the .sh compared two literals)
--
-- Usage: tillandsias-plan script run scripts/lua/test-expert-accuracy-provenance.lua
-- Verdict: ok:expert-accuracy-provenance:<n> arms | violation:... | skip:...

local fixture = require "common.fixture"
local T = fixture.new("expert-accuracy-provenance")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
-- jq is the SCRIPT's, which composes the record with it
local okj, j = pcall(proc.run, { argv = { "jq", "--version" }, timeout_ms = 10000 })
if not okj or j.status ~= "exited" or j.code ~= 0 then verdict.skip("expert-accuracy-provenance:jq-absent") end

local r = T:git_repo("ea")
fs.mkdir(r.rel .. "/scripts"); fs.mkdir(r.rel .. "/bin")
for _, f in ipairs{ "record-expert-accuracy.sh", "plan-binary-probe.sh" } do fs.write(r.rel .. "/scripts/" .. f, fs.read("scripts/" .. f)) end
local function host(h)
    fs.write(r.rel .. "/scripts/derive-host-identity.sh", "#!/usr/bin/env bash\necho " .. h .. "\n")
    T:must{ "chmod", "+x", r.abs .. "/scripts/derive-host-identity.sh" }
end
host("silverblue-x-cpu-alpha")
fs.write(r.rel .. "/bin/curl", "#!/usr/bin/env bash\nurl=\nfor a in \"$@\"; do case \"$a\" in http*) url=\"$a\" ;; esac; done\n"
    .. "printf '%s\\n' \"$url\" >> '" .. r.abs .. "/curl.log'\ncase \"$url\" in\n  */v1/api/show) printf '404 page not found' ;;\n"
    .. "  http://127.0.0.1:11434/api/show|http://native.test:11434/api/show)\n    printf '{\"details\":{\"quantization_level\":\"F16\",\"family\":\"bert\"}}' ;;\n"
    .. "  http://empty.test:11434/api/show) printf '{\"details\":{}}' ;;\n"
    .. "  *) printf '404 page not found' ;;\nesac\n")
T:must{ "chmod", "+x", r.abs .. "/bin/curl" }
local function rec(args, e)
    fs.write(r.rel .. "/curl.log", "")
    local full = { PATH = r.abs .. "/bin:" .. env.get("PATH"), HOME = env.get("HOME"),
        TILLANDSIAS_EXPERT_ACCURACY_GRADE_LINE = "groundtruth-result: sets=4 total=33 pass=33 fail=0",
        TILLANDSIAS_EXPERT_ACCURACY_INDEX_MODEL = "all-minilm" }
    for k, v in pairs(e or {}) do full[k] = v end
    local x = proc.run{ argv = { SH, r.abs .. "/scripts/record-expert-accuracy.sh", args }, cwd = r.abs, env = full, timeout_ms = 120000 }
    local o = text.trim(x.stdout or "")
    return o, text.lines(fs.read(r.rel .. "/curl.log"))[1] or "", o:match('"quantisation":"([^"]*)"') or "", o:match('"engine":"([^"]*)"') or ""
end

local o, asked, q, e = rec("--dry-run", { TILLANDSIAS_EMBED_ENDPOINT = "http://127.0.0.1:11434/v1" })
T:arm("1 V1 BASE a /v1 endpoint asks the native base", asked == "http://127.0.0.1:11434/api/show" and q == "F16" and e == "bert", asked .. " " .. q .. " " .. e .. " " .. o)
o, asked, q, e = rec("--dry-run", { TILLANDSIAS_EMBED_ENDPOINT = "http://nowhere.test:11434/v1" })
T:arm("2 NO GUESS an endpoint that cannot answer leaves both unknown", q == "unknown" and e == "unknown", asked .. " " .. q .. " " .. e)
o, asked, q, e = rec("--dry-run", { TILLANDSIAS_EMBED_ENDPOINT = "http://empty.test:11434/v1" })
T:arm("2 NO GUESS an answer without the fields leaves both unknown (the .sh never asked)", asked == "http://empty.test:11434/api/show" and q == "unknown" and e == "unknown", asked .. " " .. q .. " " .. e)
o, asked, q, e = rec("--dry-run", { TILLANDSIAS_EMBED_ENDPOINT = "http://127.0.0.1:11434/v1", TILLANDSIAS_OLLAMA_BASE = "http://native.test:11434" })
T:arm("3 OVERRIDE TILLANDSIAS_OLLAMA_BASE names the native base", asked == "http://native.test:11434/api/show" and q == "F16", asked .. " " .. q)
local pa = rec("--path")
local rel = pa:match("(plan/metrics/expert%-accuracy%.d/[%w._+-]+%.jsonl)$")
local ig = proc.run{ argv = { "git", "-C", ROOT, "check-ignore", "-q", rel or "plan" }, timeout_ms = 30000 }
T:arm("4 TRACKED the default log is per-host under plan/ and git does not ignore it", rel == "plan/metrics/expert-accuracy.d/silverblue-x-cpu-alpha.jsonl" and ig.code == 1, pa .. " check-ignore=" .. tostring(ig.code))
host("silverblue-x-cpu-beta")
local pb = rec("--path")
T:arm("5 PER HOST two hosts write two files", pa ~= pb and pb:find("silverblue-x-cpu-beta.jsonl", 1, true) ~= nil, pa .. " " .. pb)
T:finish()
