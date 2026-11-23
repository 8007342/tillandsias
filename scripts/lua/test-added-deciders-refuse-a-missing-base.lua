-- @trace order:2241-f8jg
--
-- test-added-deciders-refuse-a-missing-base.lua — `git rev-parse --verify
-- <40-hex>` answers 0 for an object that does NOT exist (it only parses the
-- name), so a diff-scoped decider handed the gate's frozen
-- TILLANDSIAS_GATE_DIFF_BASE in a checkout that lacks that commit passed its
-- base check and judged a diff git could not produce. Each decider below has
-- a NAMED unavailable-base path; this fixture hands every one a well-formed
-- 40-hex base that names no object and requires that named path, so a
-- decider that skips its check by accident cannot pass silently.
--
-- One arm per decider, in two families: the shell deciders (bash) and the
-- Lua deciders (tillandsias-plan script run). Every base override a decider
-- reads first is set to "" so only TILLANDSIAS_GATE_DIFF_BASE is in play
-- (TILLANDSIAS_* names pass proc.run's scrub from the parent).
--
-- Verdict: ok:added-deciders-missing-base:<n> | violation:added-deciders-missing-base:<failed>/<n>

local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local MISSING = string.rep("de", 20)

local probe = proc.run{ argv = { "bash", "-s" }, cwd = root, timeout_ms = 60000,
    stdin = '. scripts/plan-binary-probe.sh\np="$(resolve_plan_binary 2>/dev/null)" || p=""\ncase "$p" in ./*) p="$PWD/${p#./}" ;; esac\nprintf "%s" "$p"\n' }
local PB = text.trim(probe.stdout or "")
if PB == "" then verdict.emit("could-not-run:added-deciders-missing-base:no-plan-binary", 3) end

local OVERRIDES = {
    "TILLANDSIAS_ADDED_TEST_BASE", "TILLANDSIAS_ROUTING_BASE", "TILLANDSIAS_ISSUE_CITATION_BASE",
    "TILLANDSIAS_SIGPIPE_BASE", "TILLANDSIAS_DEFAULT_TARGET_BASE", "TILLANDSIAS_FRAGMENT_PARSE_BASE",
    "TILLANDSIAS_DECLARED_CLOSURES_BASE", "TILLANDSIAS_EXACT_VERSION_BASE", "TILLANDSIAS_CLOSURE_EVIDENCE_BASE",
    "TILLANDSIAS_LITMUS_BIND_BASE", "TILLANDSIAS_PIN_ENFORCE_BASE", "TILLANDSIAS_WINDOWS_CLIPPY_BASE",
}
-- the windows decider skips off-Windows before its base check; its uname seam
-- stands in for a MinGW host so the arm reaches the check.
local ENV = { TILLANDSIAS_GATE_DIFF_BASE = MISSING, TILLANDSIAS_WINDOWS_CLIPPY_UNAME = "MINGW64_NT", TILLANDSIAS_PLAN_BIN = PB, TILLANDSIAS_SCRIPT_RUNNER_BIN = PB }
for _, k in ipairs(OVERRIDES) do ENV[k] = "" end

-- { family, path, marker the named unavailable-base path prints }
local CASES = {
    { "sh",  "scripts/check-added-test-is-referenced.sh",           "unavailable — added-test" },
    { "sh",  "scripts/check-arrival-routing.sh",                    "no-diff-base" },
    { "sh",  "scripts/check-issue-citation-convention.sh",          "unavailable — added-citation" },
    { "sh",  "scripts/check-sigpipe-verdict-pipelines-added.sh",    "base-unavailable" },
    { "sh",  "scripts/preflight-fixtures-default-target.sh",        "base-ref-unavailable" },
    { "lua", "scripts/lua/check-added-fragments-parse.lua",         "unavailable — added-fragment" },
    { "lua", "scripts/lua/check-declared-closures-added.lua",       "unavailable — declared-closures" },
    { "lua", "scripts/lua/check-exact-version-literal-added.lua",   "base-unavailable" },
    { "lua", "scripts/lua/check-fragment-closure-evidence-added.lua", "unavailable — closure-evidence" },
    { "lua", "scripts/lua/check-litmus-bindings.lua",               "no-base-ref:" },
    { "lua", "scripts/lua/check-litmus-expression-pinning-added.lua", "no-base-ref" },
    { "lua", "scripts/lua/check-packet-tier-declared.lua",          "unavailable — packet-tier" },
    { "lua", "scripts/lua/check-windows-tray-clippy.lua",           "base-ref-unavailable" },
}

local pass, failn = 0, 0
for _, c in ipairs(CASES) do
    local fam, path, marker = c[1], c[2], c[3]
    local argv = fam == "sh" and { "bash", root .. "/" .. path } or { PB, "script", "run", path }
    local r = proc.run{ argv = argv, cwd = root, env = ENV, timeout_ms = 300000 }
    local o = (r.stdout or "") .. (r.stderr or "")
    if o:find(marker, 1, true) then
        pass = pass + 1
        out.line("ok:   [" .. fam .. "] " .. path .. " names the missing base (" .. marker .. ")")
    else
        failn = failn + 1
        local first = text.lines(text.trim(r.stdout or ""))[1] or ""
        out.line("FAIL: [" .. fam .. "] " .. path .. " judged past a missing base (rc=" .. tostring(r.code) .. ", first stdout line: " .. first .. ")")
    end
end

local total = pass + failn
if failn == 0 then verdict.ok("added-deciders-missing-base:" .. total) end
verdict.emit("violation:added-deciders-missing-base:" .. failn .. "/" .. total, 1)
